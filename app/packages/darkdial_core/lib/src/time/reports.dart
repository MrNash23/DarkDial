/// Evaluations over the time entries: totals, per-day split, search, CSV.
library;

import 'database.dart';
import 'time_tracker.dart';

/// How durations are rounded in an export. Stored times are never rounded.
enum Rounding {
  exact,

  /// To the nearest minute.
  minute,

  /// Up to the next started quarter of an hour.
  quarterUp,
}

Duration roundDuration(Duration duration, Rounding rounding) => switch (rounding) {
      Rounding.exact => duration,
      Rounding.minute => Duration(minutes: (duration.inSeconds / 60).round()),
      Rounding.quarterUp => Duration(minutes: (duration.inSeconds / 900).ceil() * 15),
    };

/// `h:mm`, or `h:mm:ss` with [seconds].
String formatDuration(Duration duration, {bool seconds = false}) {
  final total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  final text = '${total ~/ 3600}:${two(total ~/ 60 % 60)}';
  return seconds ? '$text:${two(total % 60)}' : text;
}

/// The time shown on the device: `mm:ss` below one hour, then `h:mm`.
/// Same rule as `formatElapsed` in the firmware.
String formatClock(Duration duration) {
  final total = duration.inSeconds < 0 ? 0 : duration.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  return total < 3600 ? '${two(total ~/ 60)}:${two(total % 60)}' : '${total ~/ 3600}:${two(total ~/ 60 % 60)}';
}

class SearchResult {
  const SearchResult(this.jobs, this.entries);
  final List<Job> jobs;
  final List<TimeEntry> entries;
}

class Reports {
  Reports(this.tracker);
  final TimeTracker tracker;

  TimeDatabase get _db => tracker.db;

  /// Time per job inside [from] … [to]. Entries reaching over the borders
  /// only count with the part inside; a running clock counts until now.
  Map<int, Duration> totals({DateTime? from, DateTime? to, Set<int>? jobIds}) {
    final now = tracker.now;
    final result = <int, Duration>{};
    for (final entry in _db.entries(from: from, to: to, now: now)) {
      if (jobIds != null && !jobIds.contains(entry.jobId)) continue;
      var start = entry.start;
      var end = entry.end ?? now.toUtc();
      if (from != null && start.isBefore(from)) start = from.toUtc();
      if (to != null && end.isAfter(to)) end = to.toUtc();
      if (!end.isAfter(start)) continue;
      result[entry.jobId] = (result[entry.jobId] ?? Duration.zero) + end.difference(start);
    }
    return result;
  }

  /// Time per calendar day (wall-clock date where the entry started) and job.
  /// An entry across midnight is one entry but is split between the days.
  Map<DateTime, Map<int, Duration>> perDay({DateTime? from, DateTime? to}) {
    final now = tracker.now;
    final result = <DateTime, Map<int, Duration>>{};
    for (final entry in _db.entries(from: from, to: to, now: now)) {
      final offset = Duration(minutes: entry.startOffset);
      // Work in wall-clock time of the entry.
      var start = entry.start.add(offset);
      final end = (entry.end ?? now.toUtc()).add(offset);
      while (start.isBefore(end)) {
        final day = DateTime.utc(start.year, start.month, start.day);
        final nextDay = day.add(const Duration(days: 1));
        final sliceEnd = end.isBefore(nextDay) ? end : nextDay;
        final jobs = result.putIfAbsent(day, () => {});
        jobs[entry.jobId] = (jobs[entry.jobId] ?? Duration.zero) + sliceEnd.difference(start);
        start = sliceEnd;
      }
    }
    return result;
  }

  /// Jobs matching by name, short name or client and entries matching by
  /// note; entries can be limited to a period. Archived jobs are included.
  SearchResult search(String query, {DateTime? from, DateTime? to}) {
    final text = query.trim();
    if (text.isEmpty) return const SearchResult([], []);
    final now = tracker.now;
    final entries = _db.entriesWithNote(text).where((entry) {
      final end = entry.end ?? now.toUtc();
      return (to == null || entry.start.isBefore(to)) && (from == null || end.isAfter(from));
    }).toList();
    return SearchResult(_db.jobsMatching(text), entries);
  }

  /// CSV with one line per entry: job, client, start, end, duration, note.
  /// Semicolon-separated with a byte order mark, which is what Excel expects.
  String exportCsv({
    DateTime? from,
    DateTime? to,
    Set<int>? jobIds,
    Rounding rounding = Rounding.exact,
    List<String> header = const ['Job', 'Kunde', 'Start', 'Ende', 'Dauer', 'Notiz'],
  }) {
    final now = tracker.now;
    final jobs = <int, Job?>{};
    final lines = <String>[header.map(_csvField).join(';')];
    final entries = _db.entries(from: from, to: to, now: now).reversed;
    for (final entry in entries) {
      if (jobIds != null && !jobIds.contains(entry.jobId)) continue;
      final job = jobs.putIfAbsent(entry.jobId, () => _db.job(entry.jobId));
      final duration = roundDuration(entry.duration(now.toUtc()), rounding);
      lines.add([
        job == null ? '' : (job.name.isEmpty ? tracker.displayLabel(job) : job.name),
        job?.client ?? '',
        _timestamp(entry.localStart),
        entry.localEnd == null ? '' : _timestamp(entry.localEnd!),
        formatDuration(duration, seconds: rounding == Rounding.exact),
        entry.note,
      ].map(_csvField).join(';'));
    }
    return '﻿${lines.join('\r\n')}\r\n';
  }

  static String _timestamp(DateTime wallClock) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${wallClock.year}-${two(wallClock.month)}-${two(wallClock.day)} '
        '${two(wallClock.hour)}:${two(wallClock.minute)}:${two(wallClock.second)}';
  }

  static String _csvField(String value) {
    if (!value.contains(RegExp('[;"\r\n]'))) return value;
    return '"${value.replaceAll('"', '""')}"';
  }
}
