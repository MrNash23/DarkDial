/// Storage of the time tracking: jobs, their Lightroom sources and time
/// entries in SQLite.
library;

import 'package:sqlite3/sqlite3.dart';

/// A collection or folder in Lightroom.
class LrSource {
  const LrSource({required this.kind, required this.key, required this.name});

  /// `collection` or `folder`.
  final String kind;

  /// Stable within the catalog: collection identifier or folder path.
  final String key;
  final String name;

  @override
  bool operator ==(Object other) => other is LrSource && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);
}

/// Who a job is for. Created in the app, or unnamed on the device.
class Client {
  const Client({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.createdOffset,
    required this.lastUsedAt,
  });

  final int id;

  /// Empty for a client created on the device and not named yet.
  final String name;
  final DateTime createdAt;
  final int createdOffset;
  final DateTime lastUsedAt;

  bool get unnamed => name.isEmpty;
}

class Job {
  const Job({
    required this.id,
    required this.name,
    required this.short,
    required this.clientId,
    required this.client,
    required this.color,
    required this.archived,
    required this.createdAt,
    required this.createdOffset,
    required this.lastUsedAt,
    this.sources = const [],
  });

  final int id;

  /// Full name; empty for a job created on the device and not named yet.
  final String name;

  /// Optional short name for the display, at most 10 characters.
  final String short;
  final int? clientId;

  /// Name of the client, empty if the job has none or the client is unnamed.
  final String client;

  /// `0xRRGGBB` for overview and charts, null = none.
  final int? color;
  final bool archived;
  final DateTime createdAt;

  /// UTC offset in minutes when the job was created.
  final int createdOffset;
  final DateTime lastUsedAt;
  final List<LrSource> sources;

  bool get unnamed => name.isEmpty;
}

class TimeEntry {
  const TimeEntry({
    required this.id,
    required this.jobId,
    required this.start,
    required this.startOffset,
    required this.end,
    required this.endOffset,
    required this.note,
    required this.origin,
    required this.edited,
  });

  final int id;
  final int jobId;

  /// UTC.
  final DateTime start;

  /// UTC offset in minutes at the start, so local times survive travelling
  /// and daylight saving changes.
  final int startOffset;

  /// UTC; null while the clock runs.
  final DateTime? end;
  final int? endOffset;
  final String note;

  /// `device`, `app` or `manual`.
  final String origin;

  /// Changed by hand after it was recorded.
  final bool edited;

  bool get running => end == null;

  /// Length of the entry; a running one is measured up to [now].
  Duration duration(DateTime now) => (end ?? now).difference(start);

  /// Start as wall-clock time where it was recorded.
  DateTime get localStart => _wallClock(start, startOffset);
  DateTime? get localEnd => end == null ? null : _wallClock(end!, endOffset ?? startOffset);
}

/// [utc] shifted by [offsetMinutes], as a UTC-flagged DateTime whose fields
/// read as the local wall-clock time.
DateTime _wallClock(DateTime utc, int offsetMinutes) => utc.toUtc().add(Duration(minutes: offsetMinutes));

/// SQLite access. All timestamps are stored as UTC milliseconds plus the UTC
/// offset in minutes; durations are always computed from the absolute times.
class TimeDatabase {
  TimeDatabase._(this._db) {
    _migrate();
  }

  factory TimeDatabase.open(String path) => TimeDatabase._(sqlite3.open(path));
  factory TimeDatabase.inMemory() => TimeDatabase._(sqlite3.openInMemory());

  static const int schemaVersion = 2;

  final Database _db;

  void close() => _db.dispose();

  /// Brings an older file up to [schemaVersion], one step at a time.
  void _migrate() {
    _db.execute('PRAGMA foreign_keys = ON');
    final version = _db.select('PRAGMA user_version').first.values.first as int;
    if (version > schemaVersion) {
      throw StateError('time database is from a newer version of Darkdial ($version)');
    }
    if (version < 1) {
      _db.execute('BEGIN');
      _db.execute('''
        CREATE TABLE jobs (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL DEFAULT '',
          short TEXT NOT NULL DEFAULT '',
          client TEXT NOT NULL DEFAULT '',
          color INTEGER,
          archived INTEGER NOT NULL DEFAULT 0,
          created_utc INTEGER NOT NULL,
          created_offset INTEGER NOT NULL,
          last_used_utc INTEGER NOT NULL
        )''');
      _db.execute('''
        CREATE TABLE job_sources (
          job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
          kind TEXT NOT NULL,
          key TEXT NOT NULL,
          name TEXT NOT NULL,
          PRIMARY KEY (job_id, kind, key)
        )''');
      _db.execute('''
        CREATE TABLE time_entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          job_id INTEGER NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
          start_utc INTEGER NOT NULL,
          start_offset INTEGER NOT NULL,
          end_utc INTEGER,
          end_offset INTEGER,
          note TEXT NOT NULL DEFAULT '',
          origin TEXT NOT NULL,
          edited INTEGER NOT NULL DEFAULT 0
        )''');
      _db.execute('CREATE INDEX time_entries_job ON time_entries(job_id, start_utc)');
      _db.execute('CREATE INDEX time_entries_start ON time_entries(start_utc)');
      _db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
      _db.execute('PRAGMA user_version = 1');
      _db.execute('COMMIT');
    }
    if (version < 2) _migrateToClients();
  }

  /// Version 2: clients become a table of their own instead of a text on the
  /// job, so they can be picked on the device and renamed in one place.
  void _migrateToClients() {
    _db.execute('BEGIN');
    _db.execute('''
      CREATE TABLE clients (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL DEFAULT '',
        created_utc INTEGER NOT NULL,
        created_offset INTEGER NOT NULL,
        last_used_utc INTEGER NOT NULL
      )''');
    _db.execute('ALTER TABLE jobs ADD COLUMN client_id INTEGER REFERENCES clients(id) ON DELETE SET NULL');
    // One client per distinct text, ignoring case and surrounding spaces;
    // the spelling of the oldest job wins.
    final ids = <String, int>{};
    for (final row in _db.select('SELECT id, client, created_utc, created_offset, last_used_utc FROM jobs ORDER BY created_utc')) {
      final name = (row['client'] as String).trim();
      if (name.isEmpty) continue;
      final id = ids.putIfAbsent(name.toLowerCase(), () {
        _db.execute('INSERT INTO clients(name, created_utc, created_offset, last_used_utc) VALUES (?, ?, ?, ?)',
            [name, row['created_utc'], row['created_offset'], row['last_used_utc']]);
        return _db.lastInsertRowId;
      });
      _db.execute('UPDATE jobs SET client_id = ? WHERE id = ?', [id, row['id']]);
      _db.execute('UPDATE clients SET last_used_utc = MAX(last_used_utc, ?) WHERE id = ?', [row['last_used_utc'], id]);
    }
    _db.execute('ALTER TABLE jobs DROP COLUMN client');
    _db.execute('PRAGMA user_version = 2');
    _db.execute('COMMIT');
  }

  /// Removes every job, client and entry (factory reset).
  void wipe() {
    _db.execute('BEGIN');
    _db.execute('DELETE FROM time_entries');
    _db.execute('DELETE FROM job_sources');
    _db.execute('DELETE FROM jobs');
    _db.execute('DELETE FROM clients');
    _db.execute('DELETE FROM meta');
    _db.execute('COMMIT');
  }

  // Meta -------------------------------------------------------------------------

  String? meta(String key) {
    final rows = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  void setMeta(String key, String value) {
    _db.execute('INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value]);
  }

  // Clients ----------------------------------------------------------------------

  Client _client(Row row) => Client(
        id: row['id'] as int,
        name: row['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_utc'] as int, isUtc: true),
        createdOffset: row['created_offset'] as int,
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(row['last_used_utc'] as int, isUtc: true),
      );

  int insertClient({required DateTime now, String name = ''}) {
    final at = now.toUtc().millisecondsSinceEpoch;
    _db.execute('INSERT INTO clients(name, created_utc, created_offset, last_used_utc) VALUES (?, ?, ?, ?)',
        [name, at, now.timeZoneOffset.inMinutes, at]);
    return _db.lastInsertRowId;
  }

  Client? client(int id) {
    final rows = _db.select('SELECT * FROM clients WHERE id = ?', [id]);
    return rows.isEmpty ? null : _client(rows.first);
  }

  /// Clients, most recently used first.
  List<Client> clients() =>
      [for (final row in _db.select('SELECT * FROM clients ORDER BY last_used_utc DESC, id DESC')) _client(row)];

  /// The client with this name, ignoring case; unnamed clients never match.
  Client? clientNamed(String name) {
    if (name.isEmpty) return null;
    final rows = _db.select('SELECT * FROM clients WHERE LOWER(name) = LOWER(?) LIMIT 1', [name]);
    return rows.isEmpty ? null : _client(rows.first);
  }

  void renameClient(int id, String name) => _db.execute('UPDATE clients SET name = ? WHERE id = ?', [name, id]);

  void touchClient(int id, DateTime now) {
    _db.execute('UPDATE clients SET last_used_utc = ? WHERE id = ?', [now.toUtc().millisecondsSinceEpoch, id]);
  }

  /// Moves the jobs of [from] to [into] and deletes [from].
  void mergeClients({required int from, required int into}) {
    _db.execute('BEGIN');
    _db.execute('UPDATE jobs SET client_id = ? WHERE client_id = ?', [into, from]);
    _db.execute('DELETE FROM clients WHERE id = ?', [from]);
    _db.execute('COMMIT');
  }

  /// Deletes a client; its jobs stay, without client.
  void deleteClient(int id) => _db.execute('DELETE FROM clients WHERE id = ?', [id]);

  // Jobs -------------------------------------------------------------------------

  static const String _jobSelect =
      'SELECT jobs.*, COALESCE(clients.name, \'\') AS client_name FROM jobs LEFT JOIN clients ON clients.id = jobs.client_id';

  Job _job(Row row) => Job(
        id: row['id'] as int,
        name: row['name'] as String,
        short: row['short'] as String,
        clientId: row['client_id'] as int?,
        client: row['client_name'] as String,
        color: row['color'] as int?,
        archived: row['archived'] == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_utc'] as int, isUtc: true),
        createdOffset: row['created_offset'] as int,
        lastUsedAt: DateTime.fromMillisecondsSinceEpoch(row['last_used_utc'] as int, isUtc: true),
        sources: [
          for (final s in _db.select('SELECT kind, key, name FROM job_sources WHERE job_id = ? ORDER BY name', [row['id']]))
            LrSource(kind: s['kind'] as String, key: s['key'] as String, name: s['name'] as String),
        ],
      );

  int insertJob({required DateTime now, String name = '', String short = '', int? clientId, int? color}) {
    _db.execute(
      'INSERT INTO jobs(name, short, client_id, color, created_utc, created_offset, last_used_utc) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [name, short, clientId, color, now.toUtc().millisecondsSinceEpoch, now.timeZoneOffset.inMinutes, now.toUtc().millisecondsSinceEpoch],
    );
    return _db.lastInsertRowId;
  }

  Job? job(int id) {
    final rows = _db.select('$_jobSelect WHERE jobs.id = ?', [id]);
    return rows.isEmpty ? null : _job(rows.first);
  }

  /// Jobs, most recently used first.
  List<Job> jobs({required bool archived}) => [
        for (final row in _db.select(
            '$_jobSelect WHERE jobs.archived = ? ORDER BY jobs.last_used_utc DESC, jobs.id DESC', [archived ? 1 : 0]))
          _job(row),
      ];

  void updateJob(int id, {required String name, required String short, required int? clientId, required int? color}) {
    _db.execute('UPDATE jobs SET name = ?, short = ?, client_id = ?, color = ? WHERE id = ?', [name, short, clientId, color, id]);
  }

  void setArchived(int id, bool archived) {
    _db.execute('UPDATE jobs SET archived = ? WHERE id = ?', [archived ? 1 : 0, id]);
  }

  void touchJob(int id, DateTime now) {
    _db.execute('UPDATE jobs SET last_used_utc = ? WHERE id = ?', [now.toUtc().millisecondsSinceEpoch, id]);
  }

  void deleteJob(int id) => _db.execute('DELETE FROM jobs WHERE id = ?', [id]);

  /// Active job that owns [source], if any.
  Job? jobForSource(LrSource source) {
    final rows = _db.select(
      '$_jobSelect JOIN job_sources ON job_sources.job_id = jobs.id '
      'WHERE jobs.archived = 0 AND job_sources.kind = ? AND job_sources.key = ? LIMIT 1',
      [source.kind, source.key],
    );
    return rows.isEmpty ? null : _job(rows.first);
  }

  void addSource(int jobId, LrSource source) {
    _db.execute('INSERT OR REPLACE INTO job_sources(job_id, kind, key, name) VALUES (?, ?, ?, ?)',
        [jobId, source.kind, source.key, source.name]);
  }

  /// Removes [source] from [jobId], or from every job if [jobId] is null.
  void removeSource(LrSource source, {int? jobId}) {
    if (jobId == null) {
      _db.execute('DELETE FROM job_sources WHERE kind = ? AND key = ?', [source.kind, source.key]);
    } else {
      _db.execute('DELETE FROM job_sources WHERE job_id = ? AND kind = ? AND key = ?', [jobId, source.kind, source.key]);
    }
  }

  /// Moves entries and sources of [from] to [into] and deletes [from].
  void mergeJobs({required int from, required int into}) {
    _db.execute('BEGIN');
    _db.execute('UPDATE time_entries SET job_id = ? WHERE job_id = ?', [into, from]);
    _db.execute('UPDATE OR IGNORE job_sources SET job_id = ? WHERE job_id = ?', [into, from]);
    _db.execute('DELETE FROM jobs WHERE id = ?', [from]);
    _db.execute('COMMIT');
  }

  // Entries ----------------------------------------------------------------------

  TimeEntry _entry(Row row) => TimeEntry(
        id: row['id'] as int,
        jobId: row['job_id'] as int,
        start: DateTime.fromMillisecondsSinceEpoch(row['start_utc'] as int, isUtc: true),
        startOffset: row['start_offset'] as int,
        end: row['end_utc'] == null ? null : DateTime.fromMillisecondsSinceEpoch(row['end_utc'] as int, isUtc: true),
        endOffset: row['end_offset'] as int?,
        note: row['note'] as String,
        origin: row['origin'] as String,
        edited: row['edited'] == 1,
      );

  int insertEntry({
    required int jobId,
    required DateTime start,
    required int startOffset,
    DateTime? end,
    int? endOffset,
    String note = '',
    required String origin,
  }) {
    _db.execute(
      'INSERT INTO time_entries(job_id, start_utc, start_offset, end_utc, end_offset, note, origin) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [jobId, start.toUtc().millisecondsSinceEpoch, startOffset, end?.toUtc().millisecondsSinceEpoch, endOffset, note, origin],
    );
    return _db.lastInsertRowId;
  }

  TimeEntry? entry(int id) {
    final rows = _db.select('SELECT * FROM time_entries WHERE id = ?', [id]);
    return rows.isEmpty ? null : _entry(rows.first);
  }

  /// The entry whose clock is running, if any.
  TimeEntry? openEntry() {
    final rows = _db.select('SELECT * FROM time_entries WHERE end_utc IS NULL ORDER BY start_utc DESC LIMIT 1');
    return rows.isEmpty ? null : _entry(rows.first);
  }

  void closeEntry(int id, DateTime end, int endOffset) {
    _db.execute('UPDATE time_entries SET end_utc = ?, end_offset = ? WHERE id = ?',
        [end.toUtc().millisecondsSinceEpoch, endOffset, id]);
  }

  void updateEntry(int id, {required DateTime start, required DateTime? end, required String note, int? jobId}) {
    _db.execute(
      'UPDATE time_entries SET start_utc = ?, end_utc = ?, note = ?, job_id = COALESCE(?, job_id), edited = 1 WHERE id = ?',
      [start.toUtc().millisecondsSinceEpoch, end?.toUtc().millisecondsSinceEpoch, note, jobId, id],
    );
  }

  void deleteEntry(int id) => _db.execute('DELETE FROM time_entries WHERE id = ?', [id]);

  /// Entries that overlap [from] … [to] (either may be null), newest first.
  /// A running entry counts as lasting until [now].
  List<TimeEntry> entries({int? jobId, DateTime? from, DateTime? to, required DateTime now}) {
    final where = <String>[];
    final args = <Object?>[];
    if (jobId != null) {
      where.add('job_id = ?');
      args.add(jobId);
    }
    if (to != null) {
      where.add('start_utc < ?');
      args.add(to.toUtc().millisecondsSinceEpoch);
    }
    if (from != null) {
      where.add('COALESCE(end_utc, ?) > ?');
      args
        ..add(now.toUtc().millisecondsSinceEpoch)
        ..add(from.toUtc().millisecondsSinceEpoch);
    }
    final sql = 'SELECT * FROM time_entries ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY start_utc DESC';
    return [for (final row in _db.select(sql, args)) _entry(row)];
  }

  /// Entries whose note contains [text], newest first.
  List<TimeEntry> entriesWithNote(String text) => [
        for (final row in _db.select(
            "SELECT * FROM time_entries WHERE note LIKE ? ESCAPE '\\' ORDER BY start_utc DESC", ['%${_escapeLike(text)}%']))
          _entry(row),
      ];

  /// Jobs whose name, short name or client contains [text].
  List<Job> jobsMatching(String text) {
    final pattern = '%${_escapeLike(text)}%';
    return [
      for (final row in _db.select(
          "$_jobSelect WHERE jobs.name LIKE ? ESCAPE '\\' OR jobs.short LIKE ? ESCAPE '\\' "
          "OR clients.name LIKE ? ESCAPE '\\' ORDER BY jobs.last_used_utc DESC",
          [pattern, pattern, pattern]))
        _job(row),
    ];
  }

  static String _escapeLike(String text) =>
      text.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');
}
