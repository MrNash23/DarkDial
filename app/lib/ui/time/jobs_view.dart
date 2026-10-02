import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../dial_preview.dart' show accentColor;
import 'format.dart';

Color jobColor(Job job) => Color(0xFF000000 | (job.color ?? 0x8A8A90));

/// Active jobs grouped by client (unnamed ones first), or the archive.
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
    final clients = c.tracker.clients();
    final totals = c.reports.totals();
    final runningId = c.tracker.running?.job.id;

    // Groups in this order: unnamed clients (they want a name), named
    // clients, then jobs without client. Inside a group unnamed jobs first.
    final groups = <(Client?, List<Job>)>[];
    List<Job> sorted(Iterable<Job> list) => [...list.where((j) => j.unnamed), ...list.where((j) => !j.unnamed)];
    for (final client in [...clients.where((cl) => cl.unnamed), ...clients.where((cl) => !cl.unnamed)]) {
      final own = all.where((j) => j.clientId == client.id);
      // A client without jobs still shows in the full list, so it can be renamed or removed.
      if (own.isNotEmpty || (jobs == null && !archived)) groups.add((client, sorted(own)));
    }
    final without = all.where((j) => j.clientId == null);
    if (without.isNotEmpty) groups.add((null, sorted(without)));

    if (groups.isEmpty) {
      return Center(child: Text(archived ? s.noArchived : s.noJobs));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final (client, list) in groups) ...[
          _ClientHeader(controller: c, client: client, empty: list.isEmpty),
          for (final job in list) _JobTile(controller: c, job: job, total: totals[job.id], running: job.id == runningId),
        ],
      ],
    );
  }
}

class _ClientHeader extends StatelessWidget {
  const _ClientHeader({required this.controller, required this.client, required this.empty});
  final AppController controller;
  final Client? client;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final client = this.client;
    return Material(
      color: client != null && client.unnamed ? accentColor.withValues(alpha: 0.10) : const Color(0xFF1B1B1F),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            const Icon(Icons.person_outline, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                client == null ? s.noClient : c.clientTitle(client),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (client != null) ...[
              IconButton(
                key: ValueKey('client-rename-${client.id}'),
                tooltip: s.renameClient,
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => _showRenameClient(context, c, client),
              ),
              if (empty)
                IconButton(
                  tooltip: s.delete,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => c.tracker.deleteClient(client.id),
                ),
            ] else
              const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.controller, required this.job, required this.total, required this.running});
  final AppController controller;
  final Job job;
  final Duration? total;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final details = [
      if (job.short.isNotEmpty) job.short,
      '${s.lastUsed} ${formatDate(job.lastUsedAt.toLocal())}',
      if (job.sources.isNotEmpty) '${job.sources.length} × Lightroom',
    ].join(' · ');
    return ListTile(
      key: ValueKey('job-${job.id}'),
      contentPadding: const EdgeInsets.only(left: 40, right: 8),
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
              formatDuration(total ?? Duration.zero),
              style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          if (!job.archived) ...[
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
          ],
          PopupMenuButton<String>(
            key: ValueKey('job-menu-${job.id}'),
            itemBuilder: (_) => [
              if (job.archived)
                PopupMenuItem(value: 'unarchive', child: Text(s.reactivate))
              else ...[
                PopupMenuItem(value: 'merge', child: Text(s.merge)),
                PopupMenuItem(value: 'archive', child: Text(s.archiveJob)),
              ],
              PopupMenuItem(value: 'delete', child: Text(s.deleteJob)),
            ],
            onSelected: (action) {
              switch (action) {
                case 'merge':
                  _showMergeDialog(context, c, job);
                case 'unarchive':
                  c.tracker.unarchive(job.id);
                case 'archive':
                  if (c.track(() => c.tracker.archive(job.id)) != null) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.cannotArchiveRunning)));
                  }
                case 'delete':
                  _confirmDeleteJob(context, c, job);
              }
            },
          ),
        ],
      ),
      onTap: job.archived ? null : () => showJobDialog(context, c, job),
    );
  }
}

/// Deleting removes the job with all its recorded times, so it asks first and
/// says how much would be lost.
void _confirmDeleteJob(BuildContext context, AppController controller, Job job) {
  final s = controller.strings;
  if (controller.tracker.running?.job.id == job.id) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s.cannotArchiveRunning)));
    return;
  }
  final entries = controller.tracker.entries(jobId: job.id);
  final total = entries.fold(Duration.zero, (sum, e) => sum + e.duration(DateTime.now().toUtc()));
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.deleteJobTitle(controller.jobTitle(job))),
      content: Text(s.deleteJobWarning(entries.length, formatDuration(total))),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.cancel)),
        FilledButton(
          key: const Key('confirm-delete'),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () {
            controller.track(() => controller.tracker.deleteJob(job.id));
            Navigator.of(context).pop();
          },
          child: Text(s.deleteForever),
        ),
      ],
    ),
  );
}

void _showRenameClient(BuildContext context, AppController controller, Client client) {
  final s = controller.strings;
  final name = TextEditingController(text: client.name);
  void save(BuildContext context) {
    controller.tracker.renameClient(client.id, name.text);
    Navigator.of(context).pop();
  }

  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.renameClient),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('client-name'),
              controller: name,
              autofocus: true,
              decoration: InputDecoration(labelText: s.client),
              onSubmitted: (_) => save(context),
            ),
            const SizedBox(height: 8),
            Text(s.renameClientHint, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.cancel)),
        FilledButton(key: const Key('client-save'), onPressed: () => save(context), child: Text(s.save)),
      ],
    ),
  );
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

  /// The job belongs to a client that has no name yet.
  bool get _unnamedClient => widget.job?.clientId != null && widget.job!.client.isEmpty;

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
    } else if (_unnamedClient && _client.text.trim().isNotEmpty) {
      // Typing a name here names the unnamed client, for all its jobs.
      tracker.renameClient(job.clientId!, _client.text);
      tracker.updateJob(job.id, name: _name.text, short: _short.text, client: null, color: _color);
    } else {
      // An empty field keeps a still unnamed client instead of dropping it.
      tracker.updateJob(job.id,
          name: _name.text, short: _short.text, client: _unnamedClient ? null : _client.text, color: _color);
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
    final known = [for (final client in c.tracker.clients()) if (!client.unnamed) client.name];

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
              TextField(
                key: const Key('job-client'),
                controller: _client,
                decoration: InputDecoration(
                  labelText: s.client,
                  hintText: _unnamedClient ? s.unnamedClientHint : null,
                ),
              ),
              if (known.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final name in known.take(8))
                        ActionChip(
                          label: Text(name),
                          visualDensity: VisualDensity.compact,
                          onPressed: () => setState(() => _client.text = name),
                        ),
                    ],
                  ),
                ),
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
