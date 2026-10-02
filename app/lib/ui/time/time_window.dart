import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../dial_preview.dart' show accentColor;
import 'entries_view.dart';
import 'format.dart';
import 'jobs_view.dart';

enum _Tab { overview, jobs, entries, archive }

/// The time tracking section: clock, overview, jobs, entries, archive, search
/// and export.
class TimeWindow extends StatefulWidget {
  const TimeWindow({super.key, required this.controller});
  final AppController controller;

  @override
  State<TimeWindow> createState() => _TimeWindowState();
}

class _TimeWindowState extends State<TimeWindow> {
  _Tab _tab = _Tab.overview;
  Period _period = Period.week(DateTime.now());
  final TextEditingController _search = TextEditingController();

  AppController get c => widget.controller;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _pickPeriod() async {
    final now = DateTime.now();
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1, 12, 31),
    );
    if (range != null) setState(() => _period = Period.custom(range));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.strings;
        final query = _search.text.trim();
        final unnamed = c.unnamedCount;

        Widget content;
        if (query.isNotEmpty) {
          content = _SearchResults(controller: c, query: query, period: _period);
        } else {
          content = switch (_tab) {
            _Tab.overview => _Overview(controller: c, period: _period),
            _Tab.jobs => JobsView(controller: c, archived: false),
            _Tab.entries => EntriesView(controller: c),
            _Tab.archive => JobsView(controller: c, archived: true),
          };
        }

        return Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ClockBar(controller: c),
              if (c.tracker.pendingRecovery != null) _RecoveryBanner(controller: c),
              if (c.tracker.pendingPause != null) _PauseBanner(controller: c),
              if (unnamed > 0)
                Material(
                  color: accentColor.withValues(alpha: 0.14),
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.edit_note, size: 20),
                    title: Text(s.unnamedHint(unnamed)),
                    onTap: () => setState(() {
                      _search.clear();
                      _tab = _Tab.jobs;
                    }),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    SegmentedButton<_Tab>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(value: _Tab.overview, label: Text(s.overview)),
                        ButtonSegment(value: _Tab.jobs, label: Text(s.jobs)),
                        ButtonSegment(value: _Tab.entries, label: Text(s.entries)),
                        ButtonSegment(value: _Tab.archive, label: Text(s.archive)),
                      ],
                      selected: {_tab},
                      onSelectionChanged: (value) => setState(() {
                        _search.clear();
                        _tab = value.first;
                      }),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: const Key('time-search'),
                        controller: _search,
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search, size: 18),
                          hintText: s.search,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (_tab == _Tab.jobs && query.isEmpty)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: Text(s.newJob),
                        onPressed: () => showJobDialog(context, c, null),
                      )
                    else
                      OutlinedButton.icon(
                        icon: const Icon(Icons.download, size: 18),
                        label: Text(s.export),
                        onPressed: () => showDialog<void>(
                          context: context,
                          builder: (_) => _ExportDialog(controller: c, period: _period),
                        ),
                      ),
                  ],
                ),
              ),
              if (_tab == _Tab.overview || query.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: Row(
                    children: [
                      SegmentedButton<PeriodKind>(
                        showSelectedIcon: false,
                        segments: [
                          ButtonSegment(value: PeriodKind.week, label: Text(s.week)),
                          ButtonSegment(value: PeriodKind.month, label: Text(s.month)),
                          ButtonSegment(value: PeriodKind.all, label: Text(s.allTime)),
                          ButtonSegment(value: PeriodKind.custom, label: Text(s.range)),
                        ],
                        selected: {_period.kind},
                        onSelectionChanged: (value) {
                          final now = DateTime.now();
                          switch (value.first) {
                            case PeriodKind.week:
                              setState(() => _period = Period.week(now));
                            case PeriodKind.month:
                              setState(() => _period = Period.month(now));
                            case PeriodKind.all:
                              setState(() => _period = Period.all);
                            case PeriodKind.custom:
                              _pickPeriod();
                          }
                        },
                      ),
                      const SizedBox(width: 12),
                      Text(_period.label, style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              Expanded(child: content),
            ],
          ),
        );
      },
    );
  }
}

/// The running clock with stop, or a way to start one.
class _ClockBar extends StatelessWidget {
  const _ClockBar({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final clock = c.tracker.running;
    final source = c.tracker.currentSource;
    final suggestion = c.tracker.suggestion;

    return Material(
      color: const Color(0xFF1B1B1F),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
        child: Row(
          children: [
            Icon(Icons.timer_outlined, color: clock == null ? Colors.white38 : accentColor),
            const SizedBox(width: 12),
            if (clock == null)
              Text(s.noClock, style: Theme.of(context).textTheme.titleMedium)
            else ...[
              Text(c.jobTitle(clock.job), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 16),
              // Repaints once a second without rebuilding the whole window.
              ValueListenableBuilder<int>(
                valueListenable: c.clockTick,
                builder: (context, _, _) => Text(
                  formatDuration(clock.elapsed(DateTime.now().toUtc()), seconds: true),
                  key: const Key('clock-time'),
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ],
            const Spacer(),
            // One click ties what is open in Lightroom to the running job.
            if (clock != null && source != null && !clock.job.sources.contains(source))
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.add_link, size: 18),
                  label: Text(s.assignCurrent(source.name)),
                  onPressed: () => c.tracker.assignSource(clock.job.id, source),
                ),
              ),
            if (clock == null && suggestion != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(c.jobTitle(suggestion)),
                  onPressed: () => c.track(() => c.tracker.start(suggestion.id, origin: 'app')),
                ),
              ),
            if (clock != null)
              FilledButton.icon(
                key: const Key('clock-stop'),
                icon: const Icon(Icons.stop, size: 18),
                label: Text(s.stop),
                onPressed: c.tracker.stop,
              )
            else
              PopupMenuButton<int>(
                key: const Key('clock-start'),
                tooltip: s.start,
                itemBuilder: (_) => [
                  PopupMenuItem(value: -1, child: Text(s.newJob)),
                  const PopupMenuDivider(),
                  for (final job in c.tracker.jobs().take(12)) PopupMenuItem(value: job.id, child: Text(c.jobTitle(job))),
                ],
                onSelected: (id) => c.track(
                  () => id == -1 ? c.tracker.startNew(origin: 'app') : c.tracker.start(id, origin: 'app'),
                ),
                child: IgnorePointer(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(s.start),
                    onPressed: () {},
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A clock was still running when the app last ended: ask what to do.
class _RecoveryBanner extends StatelessWidget {
  const _RecoveryBanner({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final recovery = c.tracker.pendingRecovery!;
    return MaterialBanner(
      leading: const Icon(Icons.history),
      content: Text(s.recoveryText(c.jobTitle(recovery.clock.job), formatDateTime(recovery.lastAlive.toLocal()))),
      actions: [
        TextButton(onPressed: c.tracker.recoverContinue, child: Text(s.recoveryContinue)),
        TextButton(
          onPressed: () async {
            final end = await pickDateTime(context, recovery.lastAlive.toLocal());
            if (end != null) c.tracker.recoverStopAt(end);
          },
          child: Text(s.recoveryManual),
        ),
        FilledButton(key: const Key('recovery-stop'), onPressed: c.tracker.recoverStopAt, child: Text(s.recoveryStop)),
      ],
    );
  }
}

/// The computer slept while a clock ran: offer to take the pause out.
class _PauseBanner extends StatelessWidget {
  const _PauseBanner({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final pause = c.tracker.pendingPause!;
    return MaterialBanner(
      leading: const Icon(Icons.bedtime_outlined),
      content: Text(s.pauseText(formatDuration(pause.length))),
      actions: [
        TextButton(onPressed: c.tracker.keepPause, child: Text(s.pauseKeep)),
        FilledButton(onPressed: c.tracker.deductPause, child: Text(s.pauseDeduct)),
      ],
    );
  }
}

/// Hours per job in the period, with a bar each, and the sum.
class _Overview extends StatelessWidget {
  const _Overview({required this.controller, required this.period});
  final AppController controller;
  final Period period;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final totals = c.reports.totals(from: period.from, to: period.to);
    if (totals.isEmpty) return Center(child: Text(s.nothingRecorded));

    final jobs = {for (final job in [...c.tracker.jobs(), ...c.tracker.jobs(archived: true)]) job.id: job};
    final rows = totals.entries.where((e) => jobs.containsKey(e.key)).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final longest = rows.first.value.inSeconds;
    final sum = rows.fold(Duration.zero, (total, row) => total + row.value);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 240,
                  child: Text(c.jobTitle(jobs[row.key]!), overflow: TextOverflow.ellipsis),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: longest == 0 ? 0 : (row.value.inSeconds / longest).clamp(0.01, 1.0),
                      child: Container(
                        height: 14,
                        decoration: BoxDecoration(
                          color: jobColor(jobs[row.key]!),
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 80,
                  child: Text(
                    formatDuration(row.value),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: 32),
        Row(
          children: [
            Expanded(child: Text(s.total, style: Theme.of(context).textTheme.titleSmall)),
            Text(
              formatDuration(sum),
              key: const Key('overview-total'),
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ],
        ),
      ],
    );
  }
}

/// Jobs by name, short name and client; entries by note, within the period.
class _SearchResults extends StatelessWidget {
  const _SearchResults({required this.controller, required this.query, required this.period});
  final AppController controller;
  final String query;
  final Period period;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final result = c.reports.search(query, from: period.from, to: period.to);
    if (result.jobs.isEmpty && result.entries.isEmpty) return Center(child: Text(s.noResults));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.jobs.isNotEmpty)
          Flexible(child: JobsView(controller: c, archived: false, jobs: result.jobs)),
        if (result.jobs.isNotEmpty && result.entries.isNotEmpty) const Divider(height: 1),
        if (result.entries.isNotEmpty) Flexible(child: EntriesView(controller: c, entries: result.entries)),
      ],
    );
  }
}

/// CSV export: jobs and rounding; the period is the one chosen in the overview.
class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.controller, required this.period});
  final AppController controller;
  final Period period;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  Rounding _rounding = Rounding.exact;

  /// Empty = all jobs.
  final Set<int> _jobs = {};
  String? _message;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final s = c.strings;
    final jobs = [...c.tracker.jobs(), ...c.tracker.jobs(archived: true)];
    return AlertDialog(
      title: Text(s.export),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${s.exportPeriod}: ${widget.period.label.isEmpty ? s.allTime : widget.period.label}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                FilterChip(
                  label: Text(s.allJobs),
                  selected: _jobs.isEmpty,
                  onSelected: (_) => setState(_jobs.clear),
                ),
                for (final job in jobs)
                  FilterChip(
                    label: Text(c.jobTitle(job)),
                    selected: _jobs.contains(job.id),
                    onSelected: (on) => setState(() => on ? _jobs.add(job.id) : _jobs.remove(job.id)),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(s.rounding, style: Theme.of(context).textTheme.bodySmall),
            DropdownButton<Rounding>(
              key: const Key('export-rounding'),
              isExpanded: true,
              value: _rounding,
              items: [
                DropdownMenuItem(value: Rounding.exact, child: Text(s.roundExact)),
                DropdownMenuItem(value: Rounding.minute, child: Text(s.roundMinute)),
                DropdownMenuItem(value: Rounding.quarterUp, child: Text(s.roundQuarter)),
              ],
              onChanged: (value) => setState(() => _rounding = value ?? _rounding),
            ),
            if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.cancel)),
        FilledButton(
          key: const Key('export-save'),
          onPressed: () async {
            final path = await c.exportCsv(
              from: widget.period.from,
              to: widget.period.to,
              jobIds: _jobs.isEmpty ? null : Set.of(_jobs),
              rounding: _rounding,
            );
            if (path != null && mounted) setState(() => _message = s.exported(path));
          },
          child: Text(s.save),
        ),
      ],
    );
  }
}
