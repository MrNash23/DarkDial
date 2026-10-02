import 'dart:io';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:tray_manager/tray_manager.dart';

import 'app_controller.dart';

/// Menu-bar icon with the connection state and the menu.
class Tray with TrayListener {
  Tray(this.controller, {required this.onConfigure, required this.onQuit});

  final AppController controller;
  final void Function() onConfigure;
  final void Function() onQuit;

  String? _icon;
  String? _menuSignature;

  Future<void> init() async {
    trayManager.addListener(this);
    controller.addListener(_update);
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

    // Rebuilding the menu while it is open closes it; only do it on change.
    final signature = '$deviceText|$lightroomText|$active|${controller.launchAtLogin}|${s.language}';
    if (signature == _menuSignature) return;
    _menuSignature = signature;
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(label: '${s.device}: $deviceText', disabled: true),
      MenuItem(label: '${s.lightroom}: $lightroomText', disabled: true),
      MenuItem(label: '${s.activeControl}: $active', disabled: true),
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
    switch (menuItem.key) {
      case 'configure':
        onConfigure();
      case 'login':
        controller.setLaunchAtLogin(!controller.launchAtLogin);
      case 'quit':
        onQuit();
    }
  }
}
