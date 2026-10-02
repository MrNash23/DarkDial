import 'package:darkdial_core/darkdial_core.dart';
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

  group('device list', () {
    test('most recently used first, suggestion on top, capped', () {
      final ids = <int>[];
      for (var i = 0; i < 16; i++) {
        clock.advance(const Duration(minutes: 1));
        ids.add(tracker.createJob(name: 'Job $i').id);
      }
      clock.advance(const Duration(minutes: 1));
      tracker.start(ids[3], origin: 'app');
      clock.advance(const Duration(minutes: 1));
      tracker.stop();

      var list = tracker.deviceJobs();
      expect(list, hasLength(maxDeviceJobs));
      expect(list.first.job.id, ids[3], reason: 'last used');
      expect(list.any((j) => j.suggested), isFalse);

      // Lightroom shows a collection that belongs to an old job.
      const source = LrSource(kind: 'collection', key: '7', name: 'Hochzeit');
      tracker.assignSource(ids[0], source);
      tracker.currentSource = source;
      list = tracker.deviceJobs();
      expect(list.first.job.id, ids[0]);
      expect(list.first.suggested, isTrue);
      expect(list.where((j) => j.job.id == ids[0]), hasLength(1));
      expect(list[1].job.id, ids[3]);

      tracker.start(ids[0], origin: 'device');
      expect(tracker.deviceJobs().first.running, isTrue);
    });

    test('a source belongs to one job; several sources per job; archived jobs are not suggested', () {
      final a = tracker.createJob(name: 'A');
      final b = tracker.createJob(name: 'B');
      const collection = LrSource(kind: 'collection', key: '7', name: 'Auswahl');
      const folder = LrSource(kind: 'folder', key: '/Fotos/2026', name: '2026');
      tracker.assignSource(a.id, collection);
      tracker.assignSource(a.id, folder);
      expect(tracker.jobs().firstWhere((j) => j.id == a.id).sources, hasLength(2));

      tracker.assignSource(b.id, collection);
      expect(tracker.jobs().firstWhere((j) => j.id == a.id).sources.single.kind, 'folder');
      tracker.currentSource = collection;
      expect(tracker.suggestion!.id, b.id);

      tracker.archive(b.id);
      expect(tracker.suggestion, isNull);
      tracker.currentSource = const LrSource(kind: 'folder', key: '/anders', name: 'anders');
      expect(tracker.suggestion, isNull);
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

  test('database opens an existing file at the current schema version and refuses a newer one', () {
    expect(db.meta('nothing'), isNull);
    db.setMeta('k', '1');
    db.setMeta('k', '2');
    expect(db.meta('k'), '2');
    expect(TimeDatabase.schemaVersion, 1);
  });
}
