import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../version.dart';

class _InfoTitle extends StatelessWidget {
  const _InfoTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
    ),
  );
}

/// The "Infos" section: versions and connection state, plugin installation,
/// simulator, factory reset, licence and who is behind the project.
class InfoWindow extends StatelessWidget {
  const InfoWindow({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return Scaffold(
      body: ListenableBuilder(listenable: c, builder: (context, _) => _page(context)),
    );
  }

  Widget _page(BuildContext context) {
    final c = controller;
    final s = c.strings;
    final state = c.state;
    final small = Theme.of(context).textTheme.bodySmall;
    final warning = small?.copyWith(color: Theme.of(context).colorScheme.error);

    Widget row(String name, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 120, child: Text(name)),
          Expanded(child: Text(value)),
        ],
      ),
    );

    final deviceText = switch (state.device) {
      DeviceLinkState.connected =>
        '${state.firmwareVersion}${c.useSimulator ? ' (${s.simulator})' : ' · ${state.deviceSerial}'}'
            '${state.deviceWireless ? ' · ${s.viaBluetooth}' : ''}',
      DeviceLinkState.incompatible => s.versionConflict,
      DeviceLinkState.disconnected => s.notConnected,
    };
    final pluginText = c.installedPluginVersion == null
        ? s.notInstalled
        : '${c.installedPluginVersion}${state.lightroomConnected ? ' · ${s.connected}' : ''}';

    return ListView(
      key: const Key('info-page'),
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Image.asset('assets/logo.png', width: 64, height: 64),
            const SizedBox(width: 16),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Darkdial', style: Theme.of(context).textTheme.headlineSmall),
                Text(s.tagline, style: small),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        _InfoTitle(s.versions),
        row(s.app, appVersionText),
        row(s.firmware, deviceText),
        row(s.plugin, pluginText),
        row(s.lightroom, state.lightroomConnected ? (state.lightroomVersion ?? '') : s.notConnected),
        if (state.device == DeviceLinkState.incompatible) Text(s.conflictDevice, style: warning),
        if (state.lightroomConflict) Text(s.conflictPlugin, style: warning),
        if (c.pluginJustInstalled && !state.lightroomConnected) Text(s.restartLightroom, style: small),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: c.installPlugin,
              child: Text(c.installedPluginVersion == null ? s.installPlugin : s.updatePlugin),
            ),
            Tooltip(
              message: s.uninstallHint,
              child: OutlinedButton(
                onPressed: c.installedPluginVersion == null && !c.launchAtLogin ? null : c.uninstall,
                child: Text(s.uninstall),
              ),
            ),
          ],
        ),
        // The simulator is a development aid: only offered in debug builds.
        if (kDebugMode)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(s.useSimulator),
            value: c.useSimulator,
            onChanged: c.setUseSimulator,
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('factory-reset'),
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => _confirmFactoryReset(context, c),
            child: Text(s.factoryReset),
          ),
        ),
        const SizedBox(height: 24),
        _InfoTitle(s.license),
        Text(s.licenseText),
        const SizedBox(height: 8),
        Text(s.licenseCondition, key: const Key('license-condition')),
        const SizedBox(height: 8),
        Text(s.licenseMarks, style: small),
        const SizedBox(height: 8),
        const SelectableText('https://github.com/MrNash23/DarkDial'),
        const SizedBox(height: 24),
        Row(
          children: [
            Image.asset('assets/powered_by.png', width: 56, height: 56),
            const SizedBox(width: 14),
            Text(s.poweredBy, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      ],
    );
  }
}

/// Factory reset deletes all recorded times, so it spells out what is lost.
void _confirmFactoryReset(BuildContext context, AppController controller) {
  final s = controller.strings;
  final tracker = controller.tracker;
  final jobs = tracker.jobs().length + tracker.jobs(archived: true).length;
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(s.factoryResetTitle),
      content: SizedBox(width: 460, child: Text(s.factoryResetWarning(jobs, tracker.entries().length))),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(s.cancel)),
        FilledButton(
          key: const Key('factory-reset-confirm'),
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            Navigator.of(context).pop();
            await controller.factoryReset();
            messenger.showSnackBar(SnackBar(content: Text(s.factoryResetDone)));
          },
          child: Text(s.factoryResetConfirm),
        ),
      ],
    ),
  );
}
