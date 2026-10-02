// Drives the real configuration window against the simulated device and a
// fake Lightroom plugin. Set DARKDIAL_SCREENSHOT=/some/file.png to also get a
// rendering of the window.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:darkdial/app_controller.dart';
import 'package:darkdial/main.dart';
import 'package:darkdial/plugin_installer.dart';
import 'package:darkdial/ui/config_window.dart';
import 'package:darkdial/ui/dial_preview.dart';
import 'package:darkdial_core/darkdial_core.dart';
import 'package:darkdial_core/src/fake_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Real fonts instead of the test font, so the screenshot is readable.
Future<String?> loadFonts() async {
  final fonts = Directory(p.join(p.dirname(Platform.resolvedExecutable), '..', '..', 'material_fonts'));
  final roboto = File(p.join(fonts.path, 'Roboto-Regular.ttf'));
  final icons = File(p.join(fonts.path, 'MaterialIcons-Regular.otf'));
  if (!roboto.existsSync() || !icons.existsSync()) return null;
  Future<ByteData> bytes(File f) async => ByteData.view((await f.readAsBytes()).buffer);
  await (FontLoader('Roboto')
        ..addFont(bytes(roboto))
        ..addFont(bytes(File(p.join(fonts.path, 'Roboto-Medium.ttf')))))
      .load();
  await (FontLoader('MaterialIcons')..addFont(bytes(icons))).load();
  return 'Roboto';
}

void main() {
  late Directory temp;
  late FakePlugin plugin;
  late AppController controller;

  Future<void> settle(WidgetTester tester, bool Function() condition, String what) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(condition(), isTrue, reason: 'timed out waiting for $what');
    await tester.pump();
  }

  Future<void> start(WidgetTester tester, {Map<String, dynamic>? settings}) async {
    tester.view.physicalSize = const Size(1040, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final font = await tester.runAsync(loadFonts);

    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('darkdial_test');
      if (settings != null) {
        await File(p.join(temp.path, 'settings.json')).writeAsString(jsonEncode(settings));
      }
      plugin = FakePlugin();
      await plugin.start(toService: 0, fromService: 0);
      controller = AppController(
        installer: PluginInstaller(modulesDir: Directory(p.join(temp.path, 'Modules'))),
        settingsDirectory: temp,
        lightroom: () => LightroomLink(
          appVersion: '0.1.0',
          fromPluginPort: plugin.toServicePort,
          toPluginPort: plugin.fromServicePort,
          retryInterval: const Duration(milliseconds: 50),
        ),
      );
      await controller.init();
    });
    addTearDown(() async {
      await controller.shutdown();
      await plugin.stop();
      await temp.delete(recursive: true);
    });

    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: darkdialTheme(fontFamily: font),
      home: RepaintBoundary(key: const Key('shot'), child: ConfigWindow(controller: controller)),
    ));
    // Asset images decode on real time.
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    await tester.pump();
  }

  Future<void> screenshot(WidgetTester tester) async {
    final path = Platform.environment['DARKDIAL_SCREENSHOT'];
    if (path == null) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('shot')));
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(data!.buffer.asUint8List());
    });
  }

  const simulatorSettings = {
    'simulator': true,
    'config': {'language': 'de', 'slots': <Object>[]},
  };

  testWidgets('first run offers the setup, which installs the plugin', (tester) async {
    await start(tester);
    expect(controller.firstRun, isTrue);
    expect(find.text('Einrichten'), findsOneWidget);
    expect(controller.installedPluginVersion, isNull);

    await tester.runAsync(controller.setUp);
    await tester.pump();

    expect(controller.installedPluginVersion, controller.bundledPluginVersion);
    final installed = Directory(p.join(temp.path, 'Modules', 'Darkdial.lrplugin'));
    expect(File(p.join(installed.path, 'Info.lua')).existsSync(), isTrue);
    expect(File(p.join(installed.path, 'Client.lua')).existsSync(), isTrue);
    expect(find.text('Einrichten'), findsNothing, reason: 'banner is gone after setup');
    expect(File(p.join(temp.path, 'settings.json')).existsSync(), isTrue);

    await tester.runAsync(controller.uninstall);
    expect(installed.existsSync(), isFalse);
  });

  testWidgets('simulated knob changes Lightroom and the preview follows', (tester) async {
    // Only Exposure and Contrast enabled, in this order.
    await start(tester, settings: {
      'simulator': true,
      'config': {
        'language': 'de',
        'slots': [
          {'param': 3, 'enabled': true},
          {'param': 4, 'enabled': true},
        ],
      },
    });
    await settle(tester, () => controller.state.lightroomConnected, 'Lightroom');
    await settle(tester, () => controller.state.slots.every((s) => s.value != null), 'values');

    expect(find.text('Einrichten'), findsNothing);
    expect(find.descendant(of: find.byType(DialPreview), matching: find.text('Belichtung')), findsOneWidget);
    expect(find.descendant(of: find.byType(DialPreview), matching: find.text('0.00')), findsOneWidget);

    // Click the knob (tap on the preview), then turn it with the scroll wheel.
    await tester.tap(find.byType(DialPreview));
    await settle(tester, () => controller.state.editing, 'edit mode');
    final pointer = TestPointer(1, ui.PointerDeviceKind.mouse);
    final centre = tester.getCenter(find.byType(DialPreview));
    await tester.sendEventToBinding(pointer.hover(centre));
    for (var i = 0; i < 3; i++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 20)));
    }
    await settle(tester, () => (plugin.values['Exposure']! - 0.15).abs() < 1e-9, 'Exposure in Lightroom');
    await settle(tester, () => find.text('+0.15').evaluate().isNotEmpty, 'preview text');

    // A change in Lightroom shows up in the preview.
    plugin.userSets('Exposure', -1.0);
    await settle(tester, () => find.text('-1.00').evaluate().isNotEmpty, 'mouse change');
    await screenshot(tester);
    await tester.runAsync(controller.shutdown);
  });

  testWidgets('switches and language change the device configuration', (tester) async {
    await start(tester, settings: simulatorSettings);
    await settle(tester, () => controller.state.device == DeviceLinkState.connected, 'device');
    final model = controller.simulatorModel!;
    await settle(tester, () => model.slots.isEmpty || model.slots.length == 13, 'defaults');
    expect(controller.config.activeSlots, isEmpty, reason: 'settings file had no slot enabled');

    // Enable "Kontrast" in the list of available controls.
    final tile = find.widgetWithText(SwitchListTile, 'Kontrast');
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await settle(tester, () => model.slots.length == 1 && model.slots.first.label == 'Kontrast', 'slot on device');

    await tester.tap(find.text('EN'));
    await settle(tester, () => model.slots.first.label == 'Contrast', 'English label on device');
    expect(find.text('On the device'.toUpperCase()), findsOneWidget);

    // The choice survives a restart.
    final stored = jsonDecode(File(p.join(temp.path, 'settings.json')).readAsStringSync()) as Map<String, dynamic>;
    final restored = AppConfig.fromJson(stored['config'] as Map<String, dynamic>);
    expect(restored.language, Language.en);
    expect(restored.activeSlots.single.param.lr, 'Contrast');

    // Timers started from taps live in the test's fake clock; stopping the
    // engine cancels them before the framework checks for leftovers.
    await tester.runAsync(controller.shutdown);
  });
}
