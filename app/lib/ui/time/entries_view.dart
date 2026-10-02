import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../../app_controller.dart';
import 'format.dart';
import 'jobs_view.dart' show jobColor;

/// Chronological list of time entries, for one job or all.
class EntriesView extends StatefulWidget {
  const EntriesView({super.key, required this.controller, this.entries});

  final AppController controller;

  /// Shows these instead of the filtered list (search results).
  final List<TimeEntry>? entries;

  @override
  State<EntriesView> createState() => _EntriesViewState();
}

class _EntriesViewState extends State<EntriesView> {
  int? _jobId;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.strings;
    final allJobs = [...c.tracker.jobs(), ...c.tracker.jobs(archived: true)];
    final byId = {for (final job in allJobs) job.id: job};
    if (_jobId != null && !byId.containsKey(_jobId)) _jobId = null;
    final entries = widget.entries ?? c.tracker.entries(jobId: _jobId);
    final now = DateTime.now();

    return Column(
      children: [
        if (widget.entries == null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                DropdownButton<int?>(
                  value: _jobId,
                  items: [
                    DropdownMenuItem(value: null, child: Text(s.allJobs)),
                    for (final job in allJobs) DropdownMenuItem(value: job.id, child: Text(c.jobTitle(job))),
                  ],
                  onChanged: (value) => setState(() => _jobId = value),
                ),
                const Spacer(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(s.add),
                  onPressed: allJobs.isEmpty ? null : () => showEntryDialog(context, c, jobId: _jobId ?? allJobs.first.id),
                ),
              ],
            ),
          ),
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text(s.noEntries))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final job = byId[entry.jobId];
                    final end = entry.localEnd;
                    final tags = [
                      if (entry.running) s.running,
                      if (entry.origin == 'manual') s.manual,
                      if (entry.edited) s.edited,
                    ];
                    return ListTile(
                      key: ValueKey('entry-${entry.id}'),
                      dense: true,
                      leading: job == null ? null : CircleAvatar(radius: 6, backgroundColor: jobColor(job)),
                      title: Text(
                        '${formatDate(entry.localStart)}   ${formatTime(entry.localStart)} – '
                        '${end == null ? '…' : formatTime(end)}   ${job == null ? '' : c.jobTitle(job)}',
                      ),
                      subtitle: entry.note.isEmpty && tags.isEmpty
                          ? null
                          : Text([if (entry.note.isNotEmpty) entry.note, ...tags].join(' · ')),
                      trailing: Text(
                        formatDuration(entry.duration(now.toUtc())),
                        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                      onTap: () => showEntryDialog(context, c, entry: entry),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Edits [entry], or creates a manual entry for [jobId].
Future<void> showEntryDialog(BuildContext context, AppController controller, {TimeEntry? entry, int? jobId}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _EntryDialog(controller: controller, entry: entry, jobId: entry?.jobId ?? jobId!),
    );

class _EntryDialog extends StatefulWidget {
  const _EntryDialog({required this.controller, required this.entry, required this.jobId});
  final AppController controller;
  final TimeEntry? entry;
  final int jobId;

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late int _jobId = widget.jobId;
  late DateTime _start;
  late DateTime _end;
  late final TextEditingController _note = TextEditingController(text: widget.entry?.note ?? '');
  String? _error;

  bool get _running => widget.entry?.running ?? false;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    final now = DateTime.now();
    _start = entry?.start.toLocal() ?? DateTime(now.year, now.month, now.day, now.hour).subtract(const Duration(hours: 1));
    _end = entry?.end?.toLocal() ?? DateTime(now.year, now.month, now.day, now.hour, now.minute);
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final c = widget.controller;
    final entry = widget.entry;
    final error = c.track(() {
      if (entry == null) {
        c.tracker.addManualEntry(jobId: _jobId, start: _start, end: _end, note: _note.text);
      } else {
        c.tracker.updateEntry(entry.id, start: _start, end: _running ? null : _end, note: _note.text, jobId: _jobId);
      }
    });
    if (error != null) {
      setState(() => _error = c.strings.endBeforeStart);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.strings;
    final jobs = [...c.tracker.jobs(), ...c.tracker.jobs(archived: true)];
    Widget timeButton(String label, DateTime value, void Function(DateTime) onPicked) => Row(
          children: [
            SizedBox(width: 60, child: Text(label)),
            TextButton(
              onPressed: () async {
                final picked = await pickDateTime(context, value);
                if (picked != null) setState(() => onPicked(picked));
              },
              child: Text(formatDateTime(value)),
            ),
          ],
        );

    return AlertDialog(
      title: Text(widget.entry == null ? s.add : s.edit),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButton<int>(
              isExpanded: true,
              value: _jobId,
              items: [for (final job in jobs) DropdownMenuItem(value: job.id, child: Text(c.jobTitle(job)))],
              onChanged: _running ? null : (value) => setState(() => _jobId = value ?? _jobId),
            ),
            timeButton(s.from, _start, (v) => _start = v),
            if (_running)
              Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text('${s.to}: ${s.running}'))
            else
              timeButton(s.to, _end, (v) => _end = v),
            TextField(
              key: const Key('entry-note'),
              controller: _note,
              decoration: InputDecoration(labelText: s.note),
              maxLines: 2,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        if (widget.entry != null && !_running)
          TextButton(
            onPressed: () {
              c.tracker.deleteEntry(widget.entry!.id);
              Navigator.of(context).pop();
            },
            child: Text(s.delete),
          ),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.cancel)),
        FilledButton(key: const Key('entry-save'), onPressed: _save, child: Text(s.save)),
      ],
    );
  }
}
