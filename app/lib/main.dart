import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_controller.dart';
import 'tray.dart';
import 'ui/config_window.dart';
import 'ui/dial_preview.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final controller = AppController();
  await controller.init();

  // The app is a menu-bar service: the window only opens on demand, except on
  // the very first start, where it offers the setup.
  final window = _Window(controller);
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1040, 720),
      minimumSize: Size(960, 600),
      center: true,
      title: 'Darkdial',
      skipTaskbar: true,
    ),
    () async {
      await windowManager.setPreventClose(true);
      if (controller.firstRun) {
        await window.show();
      } else {
        await windowManager.hide();
      }
    },
  );
  windowManager.addListener(window);

  final tray = Tray(controller, onConfigure: window.show, onQuit: () => _quit(controller));
  await tray.init();

  runApp(DarkdialApp(controller: controller));
}

Future<void> _quit(AppController controller) async {
  await controller.shutdown();
  await windowManager.destroy();
  exit(0);
}

class _Window with WindowListener {
  _Window(this.controller);
  final AppController controller;

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Closing the window hides it; the service keeps running.
  @override
  void onWindowClose() => windowManager.hide();
}

ThemeData darkdialTheme({String? fontFamily}) => ThemeData(
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: accentColor, brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF121214),
      visualDensity: VisualDensity.compact,
      fontFamily: fontFamily,
    );

class DarkdialApp extends StatelessWidget {
  const DarkdialApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Darkdial',
      debugShowCheckedModeBanner: false,
      theme: darkdialTheme(),
      home: ConfigWindow(controller: controller),
    );
  }
}
