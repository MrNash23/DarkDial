import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app_controller.dart';
import 'tray.dart';
import 'ui/config_window.dart';
import 'ui/dial_preview.dart';
import 'ui/info_window.dart';
import 'ui/library_window.dart';
import 'ui/time/time_window.dart';

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
      size: Size(1140, 740),
      minimumSize: Size(1060, 600),
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

  final tray = Tray(
    controller,
    onOpen: (section) {
      controller.section.value = section;
      window.show();
    },
    onQuit: () => _quit(controller),
  );
  // A clock left open by a crash needs a decision: bring the question up.
  if (controller.tracker.pendingRecovery != null) {
    controller.section.value = sectionTime;
    await window.show();
  }
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
      home: MainWindow(controller: controller),
    );
  }
}

/// The window: sliders, Library mode, time tracking and info side by side.
class MainWindow extends StatelessWidget {
  const MainWindow({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, controller.section]),
      builder: (context, _) {
        final s = controller.strings;
        final section = controller.section.value;
        return Scaffold(
          body: Row(
            children: [
              NavigationRail(
                selectedIndex: section,
                onDestinationSelected: (index) => controller.section.value = index,
                labelType: NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Image.asset('assets/logo.png', width: 44, height: 44),
                ),
                destinations: [
                  NavigationRailDestination(icon: const Icon(Icons.tune), label: Text(s.sectionSliders)),
                  NavigationRailDestination(
                    icon: const Icon(Icons.photo_library_outlined),
                    label: Text(s.sectionLibrary),
                  ),
                  NavigationRailDestination(
                    icon: Badge(
                      isLabelVisible: controller.ready && controller.unnamedCount > 0,
                      child: const Icon(Icons.timer_outlined),
                    ),
                    label: Text(s.sectionTime),
                  ),
                  NavigationRailDestination(icon: const Icon(Icons.info_outline), label: Text(s.sectionInfo)),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: IndexedStack(
                  index: section,
                  children: [
                    ConfigWindow(controller: controller),
                    LibraryWindow(controller: controller),
                    TimeWindow(controller: controller),
                    InfoWindow(controller: controller),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
