import 'dart:async';

import 'database.dart';

/// The clock as it is now.
class RunningClock {
  const RunningClock(this.job, this.entry);
  final Job job;
  final TimeEntry entry;

  Duration elapsed(DateTime now) => entry.duration(now);
}

/// A clock was still running when the app last ended.
class PendingRecovery {
  const PendingRecovery(this.clock, this.lastAlive);
  final RunningClock clock;

  /// Last moment the app is known to have been running.
  final DateTime lastAlive;
}

/// The app did not run for a while (sleep) although a clock was running.
class PendingPause {
  const PendingPause(this.from, this.to);
  final DateTime from;
  final DateTime to;

  Duration get length => to.difference(from);
}

/// Thrown for actions the rules do not allow; [message] is shown to the user.
class TimeTrackingError implements Exception {
  const TimeTrackingError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Jobs and the one clock. The single source of truth for time tracking;
/// device and menu bar only display it and ask it to start or stop.
class TimeTracker {
  TimeTracker(this.db, {DateTime Function()? now}) : _now = now ?? DateTime.now {
    _checkRecovery();
    beat();
  }

  /// A gap between two signs of life longer than this counts as a pause
  /// (sleep) or, at startup, as a crash.
  static const Duration gapThreshold = Duration(seconds: 90);
  static const Duration beatInterval = Duration(seconds: 30);
  static const int maxShortLength = 10;
  static const String _aliveKey = 'last_alive_utc';

  final TimeDatabase db;
  final DateTime Function() _now;
  final StreamController<void> _changes = StreamController<void>.broadcast();
  Timer? _beatTimer;

  LrSource? _source;
  PendingRecovery? pendingRecovery;
  PendingPause? pendingPause;

  /// Fires after every change to jobs, entries or the clock.
  Stream<void> get changes => _changes.stream;

  DateTime get now => _now();

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Starts the periodic sign of life. Tests call [beat] themselves.
  void startHeartbeat() {
    _beatTimer ??= Timer.periodic(beatInterval, (_) => beat());
  }

  Future<void> dispose() async {
    _beatTimer?.cancel();
    beat();
    await _changes.close();
  }

  // Clock ------------------------------------------------------------------------

  RunningClock? get running {
    final entry = db.openEntry();
    if (entry == null) return null;
    final job = db.job(entry.jobId);
    return job == null ? null : RunningClock(job, entry);
  }

  /// Starts the clock for [jobId]; a clock running for another job is
  /// stopped at the same instant. Starting the job that already runs does
  /// nothing.
  RunningClock start(int jobId, {required String origin}) {
    final job = db.job(jobId);
    if (job == null) throw const TimeTrackingError('unknown job');
    if (job.archived) throw const TimeTrackingError('archived');
    final current = running;
    if (current != null && current.job.id == jobId) return current;
    final at = now;
    if (current != null) db.closeEntry(current.entry.id, at, at.timeZoneOffset.inMinutes);
    db.insertEntry(jobId: jobId, start: at, startOffset: at.timeZoneOffset.inMinutes, origin: origin);
    db.touchJob(jobId, at);
    if (job.clientId != null) db.touchClient(job.clientId!, at);
    _changed();
    return running!;
  }

  /// Creates an unnamed job, optionally for [clientId], and starts its clock.
  RunningClock startNew({required String origin, int? clientId}) {
    final id = db.insertJob(now: now, clientId: clientId);
    return start(id, origin: origin);
  }

  /// Creates an unnamed client with a first unnamed job and starts its clock.
  /// Both get their names later in the app.
  RunningClock startNewClient({required String origin}) =>
      startNew(origin: origin, clientId: db.insertClient(now: now));

  /// Stops the clock; false if none was running.
  bool stop() {
    final current = running;
    if (current == null) return false;
    final at = now;
    db.closeEntry(current.entry.id, at, at.timeZoneOffset.inMinutes);
    db.touchJob(current.job.id, at);
    _changed();
    return true;
  }

  // Jobs -------------------------------------------------------------------------

  List<Job> jobs({bool archived = false}) => db.jobs(archived: archived);

  /// [client] is a name: an existing client with that name is used, a new
  /// name creates one, empty means no client.
  Job createJob({required String name, String short = '', String client = '', int? color}) {
    final id = db.insertJob(now: now, name: name.trim(), short: _short(short), clientId: _clientIdFor(client), color: color);
    _changed();
    return db.job(id)!;
  }

  /// Changes a job. [client] is a name as in [createJob]; null keeps the
  /// client the job has (which may be an unnamed one).
  void updateJob(int id, {required String name, required String short, required String? client, required int? color}) {
    final clientId = client == null ? db.job(id)?.clientId : _clientIdFor(client);
    db.updateJob(id, name: name.trim(), short: _short(short), clientId: clientId, color: color);
    _changed();
  }

  int? _clientIdFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    return db.clientNamed(trimmed)?.id ?? db.insertClient(now: now, name: trimmed);
  }

  /// Deletes a job with all its time entries. Not possible while its clock runs.
  void deleteJob(int id) {
    if (running?.job.id == id) throw const TimeTrackingError('running');
    db.deleteJob(id);
    _changed();
  }

  // Clients ----------------------------------------------------------------------

  List<Client> clients() => db.clients();

  /// Active jobs of a client, most recently used first.
  List<Job> jobsOf(int clientId) => db.jobs(archived: false).where((job) => job.clientId == clientId).toList();

  /// Renames a client. If another client already has that name, the two
  /// become one.
  void renameClient(int id, String name) {
    final trimmed = name.trim();
    final existing = db.clientNamed(trimmed);
    if (existing != null && existing.id != id) {
      db.mergeClients(from: id, into: existing.id);
    } else {
      db.renameClient(id, trimmed);
    }
    _changed();
  }

  /// Deletes a client; its jobs stay, without client.
  void deleteClient(int id) {
    db.deleteClient(id);
    _changed();
  }

  /// Name of a client for narrow places; unnamed ones show [word] with date
  /// and time of creation, e.g. `Kunde 01.10. 14:32`.
  String clientLabel(Client client, {String word = 'Kunde'}) {
    if (client.name.isNotEmpty) return client.name;
    return '$word ${_stamp(client.createdAt, client.createdOffset)}';
  }

  static String _stamp(DateTime utc, int offsetMinutes) {
    final local = utc.add(Duration(minutes: offsetMinutes));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(local.day)}.${two(local.month)}. ${two(local.hour)}:${two(local.minute)}';
  }

  /// Removes all jobs, clients and entries (factory reset).
  void wipe() {
    db.wipe();
    pendingRecovery = null;
    pendingPause = null;
    beat();
    _changed();
  }

  static String _short(String text) {
    final trimmed = text.trim();
    return trimmed.length <= maxShortLength ? trimmed : trimmed.substring(0, maxShortLength);
  }

  /// Archives a job. A job whose clock runs cannot be archived.
  void archive(int id) {
    if (running?.job.id == id) throw const TimeTrackingError('running');
    db.setArchived(id, true);
    _changed();
  }

  void unarchive(int id) {
    db.setArchived(id, false);
    _changed();
  }

  /// Moves everything of [from] into [into] and removes [from].
  void merge({required int from, required int into}) {
    if (from == into) return;
    db.mergeJobs(from: from, into: into);
    _changed();
  }

  /// Name for the device and other narrow places: the short name, else the
  /// name cut to length, else date and time of creation.
  String displayLabel(Job job) {
    if (job.short.isNotEmpty) return job.short;
    if (job.name.isNotEmpty) return _short(job.name);
    return _stamp(job.createdAt, job.createdOffset);
  }

  // Lightroom sources ------------------------------------------------------------

  /// What is open in Lightroom, as reported by the plugin.
  LrSource? get currentSource => _source;

  set currentSource(LrSource? source) {
    if (source == _source && source?.name == _source?.name) return;
    _source = source;
    _changed();
  }

  /// The active job that belongs to what is open in Lightroom.
  Job? get suggestion {
    final source = _source;
    return source == null ? null : db.jobForSource(source);
  }

  /// Ties [source] to [jobId]. A source belongs to one job only, so it is
  /// taken away from any other.
  void assignSource(int jobId, LrSource source) {
    db.removeSource(source);
    db.addSource(jobId, source);
    _changed();
  }

  void removeSource(int jobId, LrSource source) {
    db.removeSource(source, jobId: jobId);
    _changed();
  }

  // Entries ----------------------------------------------------------------------

  List<TimeEntry> entries({int? jobId, DateTime? from, DateTime? to}) =>
      db.entries(jobId: jobId, from: from, to: to, now: now);

  TimeEntry addManualEntry({required int jobId, required DateTime start, required DateTime end, String note = ''}) {
    if (!end.isAfter(start)) throw const TimeTrackingError('end before start');
    final id = db.insertEntry(
      jobId: jobId,
      start: start,
      startOffset: start.toLocal().timeZoneOffset.inMinutes,
      end: end,
      endOffset: end.toLocal().timeZoneOffset.inMinutes,
      note: note.trim(),
      origin: 'manual',
    );
    _changed();
    return db.entry(id)!;
  }

  /// Changes start, end and note of an entry and marks it as edited. The end
  /// of the running entry stays open.
  void updateEntry(int id, {required DateTime start, DateTime? end, required String note, int? jobId}) {
    final entry = db.entry(id);
    if (entry == null) return;
    final newEnd = entry.running ? null : end ?? entry.end;
    if (newEnd != null && !newEnd.isAfter(start)) throw const TimeTrackingError('end before start');
    if (entry.running && start.isAfter(now)) throw const TimeTrackingError('start in the future');
    db.updateEntry(id, start: start, end: newEnd, note: note.trim(), jobId: jobId);
    _changed();
  }

  void deleteEntry(int id) {
    db.deleteEntry(id);
    _changed();
  }

  // Crash and sleep ----------------------------------------------------------------

  DateTime? get _lastAlive {
    final stored = int.tryParse(db.meta(_aliveKey) ?? '');
    return stored == null ? null : DateTime.fromMillisecondsSinceEpoch(stored, isUtc: true);
  }

  /// At startup: a clock still open from a session that ended a while ago
  /// needs a decision; nothing is changed until it is made.
  void _checkRecovery() {
    final clock = running;
    final lastAlive = _lastAlive;
    if (clock == null || lastAlive == null) return;
    if (now.toUtc().difference(lastAlive) > gapThreshold) {
      pendingRecovery = PendingRecovery(clock, lastAlive);
    }
  }

  /// Records that the app is alive. A long silence since the previous sign of
  /// life while a clock runs means the computer slept: that becomes a
  /// [pendingPause]. The clock is never stopped automatically.
  void beat() {
    final at = now.toUtc();
    final lastAlive = _lastAlive;
    if (lastAlive != null &&
        pendingRecovery == null &&
        at.difference(lastAlive) > gapThreshold &&
        running != null) {
      // Several sleeps before the question is answered merge into one pause.
      pendingPause = PendingPause(pendingPause?.from ?? lastAlive, at);
      _changed();
    }
    db.setMeta(_aliveKey, at.millisecondsSinceEpoch.toString());
  }

  /// Recovery: keep the clock running as if nothing happened.
  void recoverContinue() {
    pendingRecovery = null;
    _changed();
  }

  /// Recovery: end the entry at [end] (default: when the app was last alive).
  void recoverStopAt([DateTime? end]) {
    final recovery = pendingRecovery;
    if (recovery == null) return;
    var at = (end ?? recovery.lastAlive).toUtc();
    if (!at.isAfter(recovery.clock.entry.start)) at = recovery.clock.entry.start.add(const Duration(seconds: 1));
    db.closeEntry(recovery.clock.entry.id, at, at.toLocal().timeZoneOffset.inMinutes);
    pendingRecovery = null;
    _changed();
  }

  /// Pause: take it out of the running entry by ending it where the pause
  /// began and continuing in a new entry from where it ended.
  void deductPause() {
    final pause = pendingPause;
    final clock = running;
    pendingPause = null;
    if (pause != null && clock != null && pause.from.isAfter(clock.entry.start)) {
      db.closeEntry(clock.entry.id, pause.from, pause.from.toLocal().timeZoneOffset.inMinutes);
      db.insertEntry(
        jobId: clock.job.id,
        start: pause.to,
        startOffset: pause.to.toLocal().timeZoneOffset.inMinutes,
        origin: clock.entry.origin,
      );
    }
    _changed();
  }

  void keepPause() {
    pendingPause = null;
    _changed();
  }
}
