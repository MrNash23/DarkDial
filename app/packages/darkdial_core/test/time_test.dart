import 'dart:io';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// A clock the test moves by hand.
class FakeClock {
  FakeClock(this.time);
  DateTime time;
  DateTime call() => time;
  void advance(Duration by) => time = time.add(by);
}

void main() {
  late FakeClock clock;
  late TimeDatabase db;
  late TimeTracker tracker;

  setUp(() {
    clock = FakeClock(DateTime.utc(2026, 10, 1, 12, 32));
    db = TimeDatabase.inMemory();
    tracker = TimeTracker(db, now: clock.call);
  });
  tearDown(() async {
    await tracker.dispose();
    db.close();
  });

  group('clock', () {
    test('new job is unnamed, runs, and is labelled with date and time', () {
      final running = tracker.startNew(origin: 'device');
      expect(running.job.unnamed, isTrue);
      expect(tracker.displayLabel(running.job), '01.10. 12:32');
      clock.advance(const Duration(minutes: 90));
      expect(tracker.running!.elapsed(clock.time), const Duration(minutes: 90));
      expect(tracker.jobs().single.id, running.job.id);
    });

    test('only one clock: starting another job stops the first at the same instant', () {
      final a = tracker.createJob(name: 'Hochzeit Müller, Potsdam', short: 'Müller');
      final b = tracker.createJob(name: 'Katalog');
      tracker.start(a.id, origin: 'device');
      clock.advance(const Duration(minutes: 20));
      tracker.start(b.id, origin: 'device');
      clock.advance(const Duration(minutes: 5));

      final entries = tracker.entries();
      expect(entries, hasLength(2));
      expect(entries.where((e) => e.running), hasLength(1));
      expect(tracker.running!.job.id, b.id);
      final first = entries.firstWhere((e) => e.jobId == a.id);
      expect(first.end, entries.firstWhere((e) => e.jobId == b.id).start);
      expect(first.duration(clock.time), const Duration(minutes: 20));
    });

    test('starting the running job again changes nothing; stop ends it', () {
      final a = tracker.createJob(name: 'A');
      tracker.start(a.id, origin: 'app');
      clock.advance(const Duration(minutes: 3));
      tracker.start(a.id, origin: 'app');
      expect(tracker.entries(), hasLength(1));
      expect(tracker.stop(), isTrue);
      expect(tracker.running, isNull);
      expect(tracker.stop(), isFalse);
      expect(tracker.entries().single.duration(clock.time), const Duration(minutes: 3));
    });

    test('labels: short name, else name cut to 10, else date', () {
      expect(tracker.displayLabel(tracker.createJob(name: 'Hochzeit Müller', short: 'Müller')), 'Müller');
      expect(tracker.displayLabel(tracker.createJob(name: 'Hochzeit Müller')), 'Hochzeit M');
      expect(tracker.createJob(name: 'x', short: 'viel zu langes Kürzel').short, 'viel zu la');
    });

    test('archiving a running job is refused; archived jobs cannot be started', () {
      final a = tracker.createJob(name: 'A');
      tracker.start(a.id, origin: 'app');
      expect(() => tracker.archive(a.id), throwsA(isA<TimeTrackingError>()));
      tracker.stop();
      tracker.archive(a.id);
      expect(tracker.jobs(), isEmpty);
      expect(tracker.jobs(archived: true).single.id, a.id);
      expect(() => tracker.start(a.id, origin: 'app'), throwsA(isA<TimeTrackingError>()));
      tracker.unarchive(a.id);
      expect(tracker.jobs().single.id, a.id);
    });

    test('merge moves entries and sources', () {
      final a = tracker.createJob(name: 'A');
      final b = tracker.createJob(name: 'B');
      const source = LrSource(kind: 'collection', key: '42', name: 'Auswahl');
      tracker.assignSource(a.id, source);
      tracker.start(a.id, origin: 'app');
      clock.advance(const Duration(minutes: 10));
      tracker.start(b.id, origin: 'app');
      clock.advance(const Duration(minutes: 10));
      tracker.stop();

      tracker.merge(from: a.id, into: b.id);
      expect(tracker.jobs().single.id, b.id);
      expect(tracker.entries(jobId: b.id), hasLength(2));
      expect(tracker.jobs().single.sources.single.key, '42');
    });

    test('changes are announced', () async {
      var count = 0;
      final subscription = tracker.changes.listen((_) => count++);
      tracker.startNew(origin: 'device');
      tracker.stop();
      await Future<void>.delayed(Duration.zero);
      expect(count, greaterThanOrEqualTo(2));
      await subscription.cancel();
    });
  });

  group('device menu', () {
    List<String> labels(MenuPage page) => [for (final item in page.items) item.label];

    test('start page lists the clients, most recently used first, and ends with the help line', () {
      final menu = DeviceMenu(tracker, Language.de);
      var page = menu.start();
      expect(page.title, 'Kunde wählen');
      expect(page.items.single.info, isTrue, reason: 'no clients yet: only the help line');
      expect(page.items.single.closes, isTrue);

      tracker.createJob(name: 'Katalog', client: 'Verlag');
      clock.advance(const Duration(minutes: 1));
      final wedding = tracker.createJob(name: 'Hochzeit', client: 'Fam. Müller');
      tracker.createJob(name: 'Ohne Kunde');
      clock.advance(const Duration(minutes: 1));
      tracker.start(wedding.id, origin: 'app');
      tracker.stop();

      page = menu.start();
      expect(labels(page), ['Fam. Müller', 'Verlag', '']);
      expect(page.items.take(2).every((i) => i.submenu), isTrue);
      expect(page.items.last.info, isTrue);
      expect(labels(page), isNot(contains('Ohne Kunde')), reason: 'jobs without client are not offered');
    });

    test('stop comes first while a clock runs; the Lightroom suggestion follows if it has a client', () {
      final menu = DeviceMenu(tracker, Language.de);
      final wedding = tracker.createJob(name: 'Hochzeit', client: 'Fam. Müller');
      final loose = tracker.createJob(name: 'Lose');
      const source = LrSource(kind: 'collection', key: '7', name: 'Auswahl');
      tracker.assignSource(wedding.id, source);
      tracker.currentSource = source;

      var page = menu.start();
      expect(labels(page), ['Hochzeit', 'Fam. Müller', '']);
      expect(page.items.first.highlighted, isTrue);

      tracker.start(wedding.id, origin: 'app');
      page = menu.start();
      expect(labels(page), ['Stopp', 'Hochzeit', 'Fam. Müller', '']);
      expect(page.items[0].running && page.items[1].running, isTrue);
      expect(menu.select(0).result!.code, TimerResult.stopped);
      expect(tracker.running, isNull);

      // A suggestion without client is not offered: every job started here has one.
      tracker.assignSource(loose.id, source);
      expect(labels(menu.start()), ['Fam. Müller', '']);
    });

    test('client, then one of its jobs', () {
      final menu = DeviceMenu(tracker, Language.de);
      final wedding = tracker.createJob(name: 'Hochzeit', client: 'Fam. Müller');
      tracker.createJob(name: 'Album', client: 'Fam. Müller');
      tracker.createJob(name: 'Katalog', client: 'Verlag');
      tracker.archive(tracker.createJob(name: 'Altes', client: 'Fam. Müller').id);

      var page = menu.start();
      page = menu.select(labels(page).indexOf('Fam. Müller')).page!;
      expect(page.title, 'Fam. Müller');
      expect(labels(page), containsAll(['Hochzeit', 'Album', 'Neuer Job', 'Zurück']));
      expect(labels(page).sublist(labels(page).length - 2), ['Neuer Job', 'Zurück']);
      expect(labels(page), isNot(contains('Altes')), reason: 'archived');
      expect(labels(page), isNot(contains('Katalog')));

      // Back returns to the clients.
      final up = menu.select(labels(page).indexOf('Zurück')).page!;
      expect(up.title, 'Kunde wählen');
      page = menu.select(labels(up).indexOf('Fam. Müller')).page!;

      final outcome = menu.select(labels(page).indexOf('Hochzeit'));
      expect(outcome.result!.code, TimerResult.started);
      expect(tracker.running!.job.id, wedding.id);
      expect(menu.open, isFalse);
    });

    test('new job is created for the chosen client and waits for its name', () {
      final menu = DeviceMenu(tracker, Language.de);
      tracker.createJob(name: 'Katalog', client: 'Verlag');
      var page = menu.start();
      page = menu.select(labels(page).indexOf('Verlag')).page!;
      expect(menu.select(labels(page).indexOf('Neuer Job')).result!.code, TimerResult.started);
      expect(tracker.running!.job.unnamed, isTrue);
      expect(tracker.running!.job.client, 'Verlag');
      expect(tracker.running!.entry.origin, 'device');
    });

    test('a client without jobs offers a new job; English texts', () {
      final menu = DeviceMenu(tracker, Language.en);
      tracker.createClient('Publisher');
      var page = menu.start();
      expect(page.title, 'Choose client');
      page = menu.select(0).page!;
      expect(labels(page), ['New job', 'Back']);
    });

    test('the help line closes the menu; a stale job reports an error; a wild index shows the page again', () {
      final menu = DeviceMenu(tracker, Language.en);
      final job = tracker.createJob(name: 'A', client: 'C');
      var page = menu.start();
      expect(menu.select(page.items.length - 1).page, isNotNull);
      expect(menu.open, isFalse);

      page = menu.select(0).page!; // not open any more, but harmless
      page = menu.start();
      page = menu.select(labels(page).indexOf('C')).page!;
      db.setArchived(job.id, true);
      final outcome = menu.select(labels(page).indexOf('A'));
      expect(outcome.result!.code, TimerResult.error);
      expect(outcome.result!.text, 'Archived');
      expect(menu.open, isFalse);

      menu.start();
      expect(menu.select(99).page, isNotNull);
    });

    test('pages never exceed what the device holds', () {
      final menu = DeviceMenu(tracker, Language.de);
      for (var i = 0; i < 30; i++) {
        tracker.createJob(name: 'Job $i', client: i.isEven ? 'Kunde $i' : 'Großkunde');
      }
      // The big client was used last, so it is among the clients shown.
      clock.advance(const Duration(minutes: 1));
      tracker.start(tracker.jobs().firstWhere((j) => j.client == 'Großkunde').id, origin: 'app');
      var page = menu.start();
      expect(page.items, hasLength(maxMenuItems));
      expect(page.items.first.label, 'Stopp');
      expect(page.items.last.info, isTrue);
      page = menu.select(labels(page).indexOf('Großkunde')).page!;
      expect(page.items, hasLength(maxMenuItems));
      expect(labels(page).sublist(maxMenuItems - 2), ['Neuer Job', 'Zurück']);
    });
  });

  group('clients', () {
    test('a client name creates the client once, ignoring case; empty means none', () {
      final a = tracker.createJob(name: 'A', client: 'Verlag');
      final b = tracker.createJob(name: 'B', client: ' verlag ');
      final c = tracker.createJob(name: 'C');
      expect(tracker.clients(), hasLength(1));
      expect(a.clientId, b.clientId);
      expect(b.client, 'Verlag');
      expect(c.clientId, isNull);
      expect(tracker.jobsOf(a.clientId!), hasLength(2));
    });

    test('renaming to an existing name merges; updateJob can keep an unnamed client', () {
      final a = tracker.createJob(name: 'A', client: 'Verlag');
      // An unnamed client, as older versions could create on the device.
      final unnamedId = db.insertClient(now: clock.time);
      final unnamed = db.client(unnamedId)!;
      expect(tracker.clientLabel(unnamed), 'Kunde 01.10. 12:32');
      final job = tracker.startNew(origin: 'device', clientId: unnamedId).job;

      // Naming the job must not lose its still unnamed client.
      tracker.updateJob(job.id, name: 'Titelbild', short: '', client: null, color: null);
      expect(tracker.db.job(job.id)!.clientId, unnamed.id);

      tracker.renameClient(unnamed.id, 'verlag');
      expect(tracker.clients(), hasLength(1));
      expect(tracker.db.job(job.id)!.clientId, a.clientId);
      expect(tracker.db.job(job.id)!.client, 'Verlag');

      tracker.renameClient(a.clientId!, 'Verlag Neu');
      expect(tracker.db.job(a.id)!.client, 'Verlag Neu');
    });

    test('deleting a job removes its entries, not while it runs; deleting a client keeps its jobs', () {
      final job = tracker.createJob(name: 'A', client: 'Verlag');
      tracker.start(job.id, origin: 'app');
      expect(() => tracker.deleteJob(job.id), throwsA(isA<TimeTrackingError>()));
      clock.advance(const Duration(minutes: 5));
      tracker.stop();

      tracker.deleteClient(job.clientId!);
      expect(tracker.db.job(job.id)!.clientId, isNull);
      expect(tracker.entries(), hasLength(1));

      tracker.deleteJob(job.id);
      expect(tracker.jobs(), isEmpty);
      expect(tracker.entries(), isEmpty);
    });

    test('wipe empties everything', () {
      tracker.createJob(name: 'A', client: 'Verlag');
      tracker.startNew(origin: 'device', clientId: tracker.createClient('Neu').id);
      tracker.wipe();
      expect(tracker.jobs(), isEmpty);
      expect(tracker.clients(), isEmpty);
      expect(tracker.entries(), isEmpty);
      expect(tracker.running, isNull);
    });
  });

  group('entries', () {
    test('manual entries, editing marks them, bad ranges are refused', () {
      final a = tracker.createJob(name: 'A');
      final start = DateTime.utc(2026, 9, 30, 9);
      final entry = tracker.addManualEntry(jobId: a.id, start: start, end: start.add(const Duration(hours: 2)), note: 'Auswahl');
      expect(entry.origin, 'manual');
      expect(entry.edited, isFalse);
      expect(() => tracker.addManualEntry(jobId: a.id, start: start, end: start), throwsA(isA<TimeTrackingError>()));

      tracker.updateEntry(entry.id, start: start, end: start.add(const Duration(hours: 3)), note: 'Auswahl und Retusche');
      final edited = tracker.entries().single;
      expect(edited.edited, isTrue);
      expect(edited.note, 'Auswahl und Retusche');
      expect(edited.duration(clock.time), const Duration(hours: 3));
      expect(
        () => tracker.updateEntry(entry.id, start: start, end: start.subtract(const Duration(hours: 1)), note: ''),
        throwsA(isA<TimeTrackingError>()),
      );

      tracker.deleteEntry(entry.id);
      expect(tracker.entries(), isEmpty);
    });

    test('the start of the running entry can be corrected, its end stays open', () {
      final clockRunning = tracker.startNew(origin: 'device');
      clock.advance(const Duration(minutes: 30));
      tracker.updateEntry(clockRunning.entry.id,
          start: clockRunning.entry.start.subtract(const Duration(minutes: 15)), end: clock.time, note: '');
      expect(tracker.running!.elapsed(clock.time), const Duration(minutes: 45));
    });
  });

  group('reports', () {
    test('totals clip to the period and include the running clock', () {
      final reports = Reports(tracker);
      final a = tracker.createJob(name: 'A');
      final b = tracker.createJob(name: 'B');
      tracker.addManualEntry(jobId: a.id, start: DateTime.utc(2026, 9, 28, 22), end: DateTime.utc(2026, 9, 29, 2));
      tracker.start(b.id, origin: 'app');
      clock.advance(const Duration(minutes: 40));

      final all = reports.totals();
      expect(all[a.id], const Duration(hours: 4));
      expect(all[b.id], const Duration(minutes: 40));
      final tuesday = reports.totals(from: DateTime.utc(2026, 9, 29), to: DateTime.utc(2026, 9, 30));
      expect(tuesday, {a.id: const Duration(hours: 2)});
      expect(reports.totals(jobIds: {b.id}).keys, [b.id]);
    });

    test('an entry over midnight is split between the days', () {
      final reports = Reports(tracker);
      final a = tracker.createJob(name: 'A');
      tracker.addManualEntry(jobId: a.id, start: DateTime.utc(2026, 9, 28, 22), end: DateTime.utc(2026, 9, 29, 2));
      final days = reports.perDay();
      final offset = DateTime.utc(2026, 9, 28, 22).toLocal().timeZoneOffset;
      final localStart = DateTime.utc(2026, 9, 28, 22).add(offset);
      final firstDay = DateTime.utc(localStart.year, localStart.month, localStart.day);
      final untilMidnight = firstDay.add(const Duration(days: 1)).difference(localStart);
      expect(days[firstDay]![a.id], untilMidnight < const Duration(hours: 4) ? untilMidnight : const Duration(hours: 4));
      final total = days.values.fold(Duration.zero, (sum, jobs) => sum + jobs[a.id]!);
      expect(total, const Duration(hours: 4));
    });

    test('duration comes from absolute times, whatever the zone offsets say', () {
      final a = tracker.createJob(name: 'A');
      final id = db.insertEntry(
        jobId: a.id,
        start: DateTime.utc(2026, 10, 24, 23),
        startOffset: 120, // summer time
        end: DateTime.utc(2026, 10, 25, 2),
        endOffset: 60, // winter time
        origin: 'manual',
      );
      final entry = db.entry(id)!;
      expect(entry.duration(clock.time), const Duration(hours: 3));
      expect(entry.localStart.hour, 1);
      expect(entry.localEnd!.hour, 3);
    });

    test('search finds jobs by name, short name and client and entries by note', () {
      final reports = Reports(tracker);
      final a = tracker.createJob(name: 'Hochzeit Müller, Potsdam', short: 'Müller', client: 'Fam. Müller');
      final b = tracker.createJob(name: 'Katalog 100%', client: 'Verlag');
      tracker.addManualEntry(
          jobId: b.id, start: DateTime.utc(2026, 9, 1, 9), end: DateTime.utc(2026, 9, 1, 10), note: 'Retusche Titelbild');
      tracker.archive(a.id);

      expect(reports.search('müller').jobs.single.id, a.id, reason: 'archived jobs stay searchable');
      expect(reports.search('Verlag').jobs.single.id, b.id);
      expect(reports.search('100%').jobs.single.id, b.id, reason: '% is taken literally');
      expect(reports.search('titelbild').entries.single.jobId, b.id);
      expect(reports.search('titelbild', from: DateTime.utc(2026, 9, 2)).entries, isEmpty);
      expect(reports.search('  ').jobs, isEmpty);
    });

    test('CSV export with the three roundings', () {
      final reports = Reports(tracker);
      final a = tracker.createJob(name: 'Hochzeit; "Müller"', client: 'Müller');
      final start = DateTime.utc(2026, 9, 1, 9);
      tracker.addManualEntry(jobId: a.id, start: start, end: start.add(const Duration(minutes: 61, seconds: 40)), note: 'a\nb');

      final exact = reports.exportCsv();
      expect(exact.startsWith('﻿Job;Kunde;Start;Ende;Dauer;Notiz\r\n'), isTrue);
      expect(exact, contains('"Hochzeit; ""Müller""";Müller;'));
      expect(exact, contains(';1:01:40;"a\nb"'));
      expect(reports.exportCsv(rounding: Rounding.minute), contains(';1:02;'));
      expect(reports.exportCsv(rounding: Rounding.quarterUp), contains(';1:15;'));
      expect(reports.exportCsv(jobIds: {999}).trim().split('\r\n'), hasLength(1));
      expect(roundDuration(const Duration(minutes: 15), Rounding.quarterUp), const Duration(minutes: 15));
      expect(roundDuration(const Duration(seconds: 1), Rounding.quarterUp), const Duration(minutes: 15));
    });

    test('clock format matches the device', () {
      expect(formatClock(Duration.zero), '00:00');
      expect(formatClock(const Duration(minutes: 59, seconds: 59)), '59:59');
      expect(formatClock(const Duration(hours: 1)), '1:00');
      expect(formatClock(const Duration(hours: 12, minutes: 5, seconds: 59)), '12:05');
    });
  });

  group('crash and sleep', () {
    test('a clock survives a restart; after a long gap a decision is pending', () async {
      tracker.startNew(origin: 'device');
      clock.advance(const Duration(minutes: 10));
      tracker.beat();
      final lastAlive = clock.time;

      // Crash: no dispose. The app comes back two hours later.
      clock.advance(const Duration(hours: 2));
      final restarted = TimeTracker(db, now: clock.call);
      expect(restarted.running, isNotNull, reason: 'no time is lost');
      expect(restarted.pendingRecovery!.lastAlive, lastAlive);
      expect(restarted.pendingPause, isNull);

      restarted.recoverStopAt();
      expect(restarted.running, isNull);
      expect(restarted.entries().single.duration(clock.time), const Duration(minutes: 10));
      await restarted.dispose();
    });

    test('recovery can also continue or stop at a chosen time', () async {
      tracker.startNew(origin: 'device');
      clock.advance(const Duration(hours: 3));
      var restarted = TimeTracker(db, now: clock.call);
      restarted.recoverContinue();
      expect(restarted.pendingRecovery, isNull);
      expect(restarted.running!.elapsed(clock.time), const Duration(hours: 3));
      await restarted.dispose();

      clock.advance(const Duration(hours: 1));
      restarted = TimeTracker(db, now: clock.call);
      final start = restarted.pendingRecovery!.clock.entry.start;
      restarted.recoverStopAt(start.add(const Duration(minutes: 45)));
      expect(restarted.entries().single.duration(clock.time), const Duration(minutes: 45));
      await restarted.dispose();
    });

    test('a quick restart asks nothing', () async {
      tracker.startNew(origin: 'device');
      clock.advance(const Duration(seconds: 20));
      final restarted = TimeTracker(db, now: clock.call);
      expect(restarted.pendingRecovery, isNull);
      expect(restarted.running, isNotNull);
      await restarted.dispose();
    });

    test('sleep while a clock runs offers to deduct the pause, and never stops by itself', () {
      final started = tracker.startNew(origin: 'device');
      // Half an hour of work, with the regular sign of life.
      for (var i = 0; i < 60; i++) {
        clock.advance(TimeTracker.beatInterval);
        tracker.beat();
      }
      expect(tracker.pendingPause, isNull);
      final sleepStart = clock.time;
      clock.advance(const Duration(hours: 1)); // lid closed
      tracker.beat();

      expect(tracker.running, isNotNull);
      expect(tracker.pendingPause!.length, const Duration(hours: 1));
      expect(tracker.pendingPause!.from, sleepStart);

      clock.advance(const Duration(minutes: 15));
      tracker.deductPause();
      expect(tracker.pendingPause, isNull);
      final entries = tracker.entries(jobId: started.job.id);
      expect(entries, hasLength(2));
      final total = entries.fold(Duration.zero, (sum, e) => sum + e.duration(clock.time));
      expect(total, const Duration(minutes: 45));
      expect(tracker.running!.job.id, started.job.id);
    });

    test('keeping the pause leaves the entry whole; no pause without a running clock', () {
      tracker.beat();
      clock.advance(const Duration(hours: 1));
      tracker.beat();
      expect(tracker.pendingPause, isNull);

      tracker.startNew(origin: 'app');
      tracker.beat();
      clock.advance(const Duration(hours: 1));
      tracker.beat();
      tracker.keepPause();
      expect(tracker.entries().single.duration(clock.time), const Duration(hours: 1));
    });
  });

  test('a version 1 database is migrated: client texts become clients, data stays', () {
    final dir = Directory.systemTemp.createTempSync('darkdial_migration');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/time.sqlite';
    final old = sqlite3.open(path);
    old.execute('''
      CREATE TABLE jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL DEFAULT '', short TEXT NOT NULL DEFAULT '',
        client TEXT NOT NULL DEFAULT '', color INTEGER, archived INTEGER NOT NULL DEFAULT 0, created_utc INTEGER NOT NULL,
        created_offset INTEGER NOT NULL, last_used_utc INTEGER NOT NULL)''');
    old.execute('''
      CREATE TABLE job_sources (job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE, kind TEXT NOT NULL,
        key TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (job_id, kind, key))''');
    old.execute('''
      CREATE TABLE time_entries (id INTEGER PRIMARY KEY AUTOINCREMENT, job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
        start_utc INTEGER NOT NULL, start_offset INTEGER NOT NULL, end_utc INTEGER, end_offset INTEGER,
        note TEXT NOT NULL DEFAULT '', origin TEXT NOT NULL, edited INTEGER NOT NULL DEFAULT 0)''');
    old.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    old.execute("INSERT INTO jobs(name, client, created_utc, created_offset, last_used_utc) VALUES "
        "('Hochzeit', 'Fam. Müller', 1000, 120, 5000), ('Album', ' fam. müller', 2000, 120, 9000), "
        "('Katalog', 'Verlag', 3000, 120, 4000), ('', '', 3500, 120, 3500)");
    old.execute("INSERT INTO time_entries(job_id, start_utc, start_offset, end_utc, end_offset, origin) VALUES (1, 1000, 120, 61000, 120, 'device')");
    old.execute("INSERT INTO job_sources VALUES (1, 'collection', '77', 'Auswahl')");
    old.execute('PRAGMA user_version = 1');
    old.dispose();

    final migrated = TimeDatabase.open(path);
    addTearDown(migrated.close);
    final clients = migrated.clients();
    expect(clients.map((c) => c.name), ['Fam. Müller', 'Verlag'], reason: 'most recently used first');
    expect(clients.first.lastUsedAt.millisecondsSinceEpoch, 9000);
    final jobs = {for (final job in migrated.jobs(archived: false)) job.name: job};
    expect(jobs['Hochzeit']!.clientId, jobs['Album']!.clientId);
    expect(jobs['Album']!.client, 'Fam. Müller');
    expect(jobs['Katalog']!.client, 'Verlag');
    expect(jobs['']!.clientId, isNull);
    expect(jobs['Hochzeit']!.sources.single.key, '77');
    expect(migrated.entries(now: DateTime.utc(2026)).single.duration(DateTime.utc(2026)), const Duration(minutes: 1));

    // Opening again changes nothing.
    migrated.close();
    final again = TimeDatabase.open(path);
    expect(again.clients(), hasLength(2));
    again.close();
  });

  test('database opens an existing file at the current schema version and refuses a newer one', () {
    expect(db.meta('nothing'), isNull);
    db.setMeta('k', '1');
    db.setMeta('k', '2');
    expect(db.meta('k'), '2');
    expect(TimeDatabase.schemaVersion, 2);
  });
}
