import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../dial_preview.dart' show accentColor;
import 'format.dart';

Color jobColor(Job job) => Color(0xFF000000 | (job.color ?? 0x8A8A90));

/// Active jobs (unnamed ones first) or the archive.
class JobsView extends StatelessWidget {
  const JobsView({super.key, required this.controller, required this.archived, this.jobs});

  final AppController controller;
  final bool archived;

  /// Shows these instead of all jobs (search results).
  final List<Job>? jobs;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final all = jobs ?? c.tracker.jobs(archived: archived);
    // Unnamed jobs come from the device and want a name: keep them on top.
    final list = [...all.where((j) => j.unnamed), ...all.where((j) => !j.unnamed)];
    final totals = c.reports.totals();
    final runningId = c.tracker.running?.job.id;

    if (list.isEmpty) {
      return Center(child: Text(archived ? s.noArchived : s.noJobs));
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: list.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final job = list[index];
        final running = job.id == runningId;
        final details = [
          if (job.short.isNotEmpty) job.short,
          if (job.client.isNotEmpty) job.client,
          '${s.lastUsed} ${formatDate(job.lastUsedAt.toLocal())}',
          if (job.sources.isNotEmpty) '${job.sources.length} × Lightroom',
        ].join(' · ');
        return ListTile(
          key: ValueKey('job-${job.id}'),
          tileColor: job.unnamed ? accentColor.withValues(alpha: 0.10) : null,
          leading: CircleAvatar(radius: 7, backgroundColor: jobColor(job)),
          title: Text(c.jobTitle(job)),
          subtitle: Text(details),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  formatDuration(totals[job.id] ?? Duration.zero),
                  style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                ),
              ),
              if (job.archived)
                TextButton(onPressed: () => c.tracker.unarchive(job.id), child: Text(s.reactivate))
              else ...[
                IconButton(
                  tooltip: running ? s.stop : s.start,
                  icon: Icon(running ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                  onPressed: () => running ? c.tracker.stop() : c.track(() => c.tracker.start(job.id, origin: 'app')),
                ),
                IconButton(
                  tooltip: s.edit,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: () => showJobDialog(context, c, job),
                ),
                PopupMenuButton<String>(
                  itemBuilder: (_) => [
                    PopupMenuItem(value: 'merge', child: Text(s.merge)),
                    PopupMenuItem(value: 'archive', child: Text(s.archiveJob)),
                  ],
                  onSelected: (action) {
                    if (action == 'merge') {
                      _showMergeDialog(context, c, job);
                    } else if (c.track(() => c.tracker.archive(job.id)) != null) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.cannotArchiveRunning)));
                    }
                  },
                ),
              ],
            ],
          ),
          onTap: job.archived ? null : () => showJobDialog(context, c, job),
        );
      },
    );
  }
}

/// Creates a job ([job] null) or edits one: name, short name, client, colour
/// and the Lightroom sources.
Future<void> showJobDialog(BuildContext context, AppController controller, Job? job) =>
    showDialog<void>(context: context, builder: (_) => _JobDialog(controller: controller, job: job));

class _JobDialog extends StatefulWidget {
  const _JobDialog({required this.controller, required this.job});
  final AppController controller;
  final Job? job;

  @override
  State<_JobDialog> createState() => _JobDialogState();
}

class _JobDialogState extends State<_JobDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.job?.name ?? '');
  late final TextEditingController _short = TextEditingController(text: widget.job?.short ?? '');
  late final TextEditingController _client = TextEditingController(text: widget.job?.client ?? '');
  late int? _color = widget.job?.color;

  @override
  void dispose() {
    _name.dispose();
    _short.dispose();
    _client.dispose();
    super.dispose();
  }

  void _save() {
    final tracker = widget.controller.tracker;
    final job = widget.job;
    if (job == null) {
      tracker.createJob(name: _name.text, short: _short.text, client: _client.text, color: _color);
    } else {
      tracker.updateJob(job.id, name: _name.text, short: _short.text, client: _client.text, color: _color);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.strings;
    // Read again on every build: sources change while the dialog is open.
    final job = widget.job == null ? null : c.tracker.db.job(widget.job!.id);
    final current = c.tracker.currentSource;
    final canAssign = job != null && current != null && !job.sources.contains(current);

    return AlertDialog(
      title: Text(job == null ? s.newJob : c.jobTitle(job)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const Key('job-name'),
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(labelText: s.name),
                onSubmitted: (_) => _save(),
              ),
              TextField(
                key: const Key('job-short'),
                controller: _short,
                maxLength: TimeTracker.maxShortLength,
                decoration: InputDecoration(labelText: s.shortName),
              ),
              TextField(controller: _client, decoration: InputDecoration(labelText: s.client)),
              const SizedBox(height: 16),
              Text(s.color, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                children: [
                  for (final color in jobColors)
                    InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => setState(() => _color = _color == color ? null : color),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: Color(0xFF000000 | color),
                          shape: BoxShape.circle,
                          border: Border.all(color: _color == color ? Colors.white : Colors.transparent, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              if (job != null) ...[
                const SizedBox(height: 16),
                Text(s.lightroomSources, style: Theme.of(context).textTheme.bodySmall),
                if (job.sources.isEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(s.noSources)),
                for (final source in job.sources)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(source.kind == 'folder' ? Icons.folder_outlined : Icons.collections_outlined, size: 18),
                    title: Text(source.name),
                    subtitle: Text(source.kind == 'folder' ? s.folder : s.collection),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => c.tracker.removeSource(job.id, source)),
                    ),
                  ),
                if (canAssign)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.add_link, size: 18),
                    label: Text(s.assignCurrent(current.name)),
                    onPressed: () => setState(() => c.tracker.assignSource(job.id, current)),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.cancel)),
        FilledButton(key: const Key('job-save'), onPressed: _save, child: Text(s.save)),
      ],
    );
  }
}

void _showMergeDialog(BuildContext context, AppController controller, Job job) {
  final s = controller.strings;
  final others = controller.tracker.jobs().where((j) => j.id != job.id).toList();
  showDialog<void>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(s.mergeInto(controller.jobTitle(job))),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(s.mergeHint, style: Theme.of(context).textTheme.bodySmall),
        ),
        for (final other in others)
          SimpleDialogOption(
            onPressed: () {
              // The clock of the job that disappears moves along with its entries.
              controller.tracker.merge(from: job.id, into: other.id);
              Navigator.of(context).pop();
            },
            child: Text(controller.jobTitle(other)),
          ),
      ],
    ),
  );
}
