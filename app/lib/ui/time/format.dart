import 'package:flutter/material.dart';

String _two(int v) => v.toString().padLeft(2, '0');

/// `01.10.2026`
String formatDate(DateTime t) => '${_two(t.day)}.${_two(t.month)}.${t.year}';

/// `14:32`
String formatTime(DateTime t) => '${_two(t.hour)}:${_two(t.minute)}';

String formatDateTime(DateTime t) => '${formatDate(t)} ${formatTime(t)}';

/// The period shown in overview, search and export.
class Period {
  const Period(this.kind, this.from, this.to);

  final PeriodKind kind;

  /// Null = open on that side.
  final DateTime? from;
  final DateTime? to;

  /// Monday to Sunday around [now].
  factory Period.week(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final monday = day.subtract(Duration(days: day.weekday - 1));
    return Period(PeriodKind.week, monday, monday.add(const Duration(days: 7)));
  }

  factory Period.month(DateTime now) =>
      Period(PeriodKind.month, DateTime(now.year, now.month), DateTime(now.year, now.month + 1));

  static const Period all = Period(PeriodKind.all, null, null);

  factory Period.custom(DateTimeRange range) => Period(
        PeriodKind.custom,
        range.start,
        DateTime(range.end.year, range.end.month, range.end.day).add(const Duration(days: 1)),
      );

  /// `29.09.2026 – 05.10.2026`, empty for [all].
  String get label {
    if (from == null || to == null) return '';
    return '${formatDate(from!)} – ${formatDate(to!.subtract(const Duration(days: 1)))}';
  }
}

enum PeriodKind { week, month, all, custom }

/// Asks for date and time, starting from [initial]. Null if cancelled.
Future<DateTime?> pickDateTime(BuildContext context, DateTime initial) async {
  final date = await showDatePicker(
    context: context,
    initialDate: initial,
    firstDate: DateTime(2000),
    lastDate: DateTime.now().add(const Duration(days: 366)),
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// Colours a job can have in overview and lists.
const List<int> jobColors = [0xFF9F0A, 0xFA3A31, 0xF8D32D, 0x7FE530, 0x63F0ED, 0x5394FC, 0xD146F7, 0xF71DBA];
