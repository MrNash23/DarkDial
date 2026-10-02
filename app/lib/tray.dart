import 'dart:io';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:tray_manager/tray_manager.dart';

import 'app_controller.dart';

/// Menu-bar icon with the connection state and the menu.
class Tray with TrayListener {
  Tray(this.controller, {required this.onOpen, required this.onQuit});

  final AppController controller;

  /// Opens the window on a section: 0 device, 1 time tracking.
  final void Function(int section) onOpen;
  final void Function() onQuit;

  String? _icon;
  String? _menuSignature;
  String? _title;

  Future<void> init() async {
    trayManager.addListener(this);
    controller.addListener(_update);
    // The running time next to the icon changes once a minute.
    controller.clockTick.addListener(_update);
    await _update();
  }

  Future<void> _update() async {
    if (!controller.ready) return;
    final state = controller.state;
    final s = controller.strings;
    final deviceOk = state.device == DeviceLinkState.connected;
    final both = deviceOk && state.lightroomConnected;
    final icon = both ? 'ok' : (deviceOk || state.lightroomConnected ? 'partial' : 'off');
    if (icon != _icon) {
      _icon = icon;
      await trayManager.setIcon('assets/tray/tray_$icon.png', isTemplate: true);
    }

    final deviceText = switch (state.device) {
      DeviceLinkState.connected => controller.useSimulator ? s.simulator : s.connected,
      DeviceLinkState.incompatible => s.versionConflict,
      DeviceLinkState.disconnected => s.notConnected,
    };
    final lightroomText = state.lightroomConflict
        ? s.versionConflict
        : (state.lightroomConnected ? s.connected : s.notConnected);
    final active = state.slots.isEmpty ? '–' : state.slots[state.activeSlot].slot.label;

    // Time tracking: running time and job next to the icon.
    final tracker = controller.tracker;
    final clock = tracker.running;
    final elapsed = clock == null ? '' : formatDuration(clock.elapsed(DateTime.now().toUtc()));
    final title = clock == null ? '' : ' $elapsed ${tracker.displayLabel(clock.job)}';
    if (title != _title) {
      _title = title;
      if (Platform.isMacOS) await trayManager.setTitle(title);
    }
    final recent = tracker.jobs().take(6).toList();
    final unnamed = controller.unnamedJobs.length;

    // Rebuilding the menu while it is open closes it; only do it on change.
    final signature = '$deviceText|$lightroomText|$active|${controller.launchAtLogin}|${s.language}|$title|$unnamed|'
        '${recent.map((j) => '${j.id}${controller.jobTitle(j)}').join(',')}';
    if (signature == _menuSignature) return;
    _menuSignature = signature;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(label: '${s.device}: $deviceText', disabled: true),
      MenuItem(label: '${s.lightroom}: $lightroomText', disabled: true),
      MenuItem(label: '${s.activeControl}: $active', disabled: true),
      MenuItem.separator(),
      if (clock != null)
        MenuItem(key: 'stop', label: '${s.stop}: ${controller.jobTitle(clock.job)} ($elapsed)')
      else
        MenuItem(label: s.noClock, disabled: true),
      MenuItem.submenu(
        label: s.start,
        submenu: Menu(items: [
          MenuItem(key: 'start:new', label: s.newJob),
          if (recent.isNotEmpty) MenuItem.separator(),
          for (final job in recent)
            MenuItem(key: 'start:${job.id}', label: controller.jobTitle(job), disabled: job.id == clock?.job.id),
        ]),
      ),
      if (unnamed > 0) MenuItem(key: 'time', label: s.unnamedHint(unnamed)),
      MenuItem(key: 'time', label: s.timeTracking),
      MenuItem.separator(),
      MenuItem(key: 'configure', label: s.configure),
      if (Platform.isMacOS) MenuItem.checkbox(key: 'login', label: s.launchAtLogin, checked: controller.launchAtLogin),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: s.quit),
    ]));
  }

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final key = menuItem.key ?? '';
    if (key.startsWith('start:')) {
      final id = int.tryParse(key.substring(6));
      controller.track(
        () => id == null ? controller.tracker.startNew(origin: 'app') : controller.tracker.start(id, origin: 'app'),
      );
      return;
    }
    switch (key) {
      case 'stop':
        controller.tracker.stop();
      case 'time':
        onOpen(1);
      case 'configure':
        onOpen(0);
      case 'login':
        controller.setLaunchAtLogin(!controller.launchAtLogin);
      case 'quit':
        onQuit();
    }
  }
}
