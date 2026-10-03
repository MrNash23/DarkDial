// Drives the real configuration window against the simulated device and a
// fake Lightroom plugin. Set DARKDIAL_SCREENSHOT=/some/file.png to also get a
// rendering of the window.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:darkdial/app_controller.dart';
import 'package:darkdial/firmware/firmware_updater.dart';
import 'package:darkdial/main.dart';
import 'package:darkdial/plugin_installer.dart';
import 'package:darkdial/ui/config_window.dart';
import 'package:darkdial/ui/device_window.dart';
import 'package:darkdial/ui/dial_preview.dart';
import 'package:darkdial/ui/info_window.dart';
import 'package:darkdial/ui/library_window.dart';
import 'package:darkdial/ui/time/time_window.dart';
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

  /// Tracker changes reach the UI through a stream that runs on real time.
  Future<void> sync(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }

  Future<void> start(
    WidgetTester tester, {
    Map<String, dynamic>? settings,
    bool timeWindow = false,
    bool infoWindow = false,
    bool libraryWindow = false,
    bool deviceWindow = false,
    FirmwareUpdater? firmware,
  }) async {
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
        firmware: firmware,
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
      home: RepaintBoundary(
        key: const Key('shot'),
        child: timeWindow
            ? TimeWindow(controller: controller)
            : infoWindow
                ? InfoWindow(controller: controller)
                : libraryWindow
                    ? LibraryWindow(controller: controller)
                    : deviceWindow
                        ? DeviceWindow(controller: controller)
                        : ConfigWindow(controller: controller),
      ),
    ));
    // Asset images decode on real time.
    await tester.runAsync(() async {
      for (final element in find.byType(Image).evaluate()) {
        await precacheImage((element.widget as Image).image, element);
      }
    });
    await tester.pump();
  }

  Future<void> screenshot(WidgetTester tester, [String suffix = '']) async {
    final base = Platform.environment['DARKDIAL_SCREENSHOT'];
    if (base == null) return;
    final path = suffix.isEmpty ? base : base.replaceFirst('.png', '_$suffix.png');
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
    // Two sliders while turning through them: the other one shows beside it.
    expect(find.byKey(const Key('preview-neighbours')), findsOneWidget);

    // Click the knob (tap on the preview), then turn it with the scroll wheel.
    await tester.tap(find.byType(DialPreview));
    await tester.pump(const Duration(milliseconds: 400)); // a single tap waits for a possible second one
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

    // Double click on the preview resets the slider to the Lightroom default.
    await tester.tap(find.byType(DialPreview));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.byType(DialPreview));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester, () => plugin.values['Exposure'] == 0, 'reset in Lightroom');
    expect(controller.state.editing, isTrue);

    // Long press opens the time tracking menu; a click starts a new job, and
    // the running time appears in the gap of the ring.
    final dial = find.byType(DialPreview);
    await tester.longPress(dial);
    // Without clients the menu only has the help line.
    await settle(tester, () => find.byKey(const Key('preview-menu-info')).evaluate().isNotEmpty, 'help line');
    expect(find.textContaining('Keinen passenden Kunden gefunden?'), findsOneWidget);
    expect(find.text('Kunde wählen'), findsOneWidget);
    await screenshot(tester, 'menu_help');
    await tester.tap(dial); // closes the menu
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.simulatorModel!.menuOpen, isFalse);
    expect(controller.tracker.running, isNull);

    // With a client: choose it, then "Neuer Job" starts the clock, and the
    // running time appears in the gap of the ring.
    controller.tracker.createClient('Verlag');
    await sync(tester);
    await tester.longPress(dial);
    await settle(tester, () => find.descendant(of: dial, matching: find.text('Verlag »')).evaluate().isNotEmpty, 'client');
    await tester.tap(dial);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester, () => find.descendant(of: dial, matching: find.text('Neuer Job')).evaluate().isNotEmpty, 'new job');
    await tester.tap(dial);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester, () => controller.tracker.running != null, 'clock started from the device');
    await settle(tester, () => find.byKey(const Key('preview-gap-time')).evaluate().isNotEmpty, 'time in the ring gap');
    expect(controller.unnamedJobs, hasLength(1));
    expect(controller.unnamedJobs.single.client, 'Verlag');
    await screenshot(tester, 'clock');
    await tester.runAsync(controller.shutdown);
  });

  testWidgets('a switch in the list puts the control on the device', (tester) async {
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

    // Timers started from taps live in the test's fake clock; stopping the
    // engine cancels them before the framework checks for leftovers.
    await tester.runAsync(controller.shutdown);
  });

  testWidgets('slider editor: a step of its own for fast turning', (tester) async {
    await start(tester, settings: {
      'simulator': true,
      'config': {
        'language': 'de',
        'slots': [
          {'param': 4, 'enabled': true},
        ],
      },
    });
    await settle(tester, () => controller.state.device == DeviceLinkState.connected, 'device');
    await settle(tester, () => controller.state.lightroomConnected, 'lightroom');
    final model = controller.simulatorModel!;

    await tester.ensureVisible(find.byKey(const Key('fast-turn')));
    await tester.pump();
    expect(find.textContaining('×2 bis ×8'), findsOneWidget, reason: 'automatic by default');
    await tester.tap(find.text('Eigene Schrittweite'));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('fast-step')), '10');
    await settle(
      tester,
      () => File(p.join(temp.path, 'settings.json')).readAsStringSync().contains('"fastStep": 10'),
      'setting saved',
    );
    expect(controller.config.slots.firstWhere((s) => s.paramId == 4).fast, FastTurn.step);

    // One slider only: no neighbours beside it in the preview.
    expect(find.byKey(const Key('preview-neighbours')), findsNothing);

    // Slow detents are steps of 1, a fast one is a step of 10.
    model.tap();
    await settle(tester, () => controller.state.editing, 'edit mode');
    model.rotate(1);
    await settle(tester, () => plugin.values['Contrast'] == 1, 'slow step');
    model.rotate(1, speed: 2);
    await settle(tester, () => plugin.values['Contrast'] == 11, 'fast step');
    await screenshot(tester, 'fast');

    await tester.runAsync(controller.shutdown);
  });

  testWidgets('device section: language and following Lightroom', (tester) async {
    await start(tester, deviceWindow: true, settings: {
      'simulator': true,
      'config': {
        'language': 'de',
        'slots': [
          {'param': 4, 'enabled': true},
        ],
      },
    });
    await settle(tester, () => controller.state.device == DeviceLinkState.connected, 'device');
    final model = controller.simulatorModel!;
    await settle(tester, () => model.slots.length == 1 && model.slots.first.label == 'Kontrast', 'slot on device');

    // Connected over USB (the simulator); Bluetooth is on by default.
    expect(find.text('USB'), findsOneWidget);
    expect(controller.config.useBluetooth, isTrue);
    expect(find.byKey(const Key('firmware-needs-cable')), findsNothing);

    await tester.ensureVisible(find.text('EN'));
    await tester.pump();
    await tester.tap(find.text('EN'));
    await settle(tester, () => model.slots.first.label == 'Contrast', 'English label on device');
    expect(find.text('Display'.toUpperCase()), findsOneWidget);

    // Following Lightroom is on by default and can be switched off.
    expect(controller.config.followLightroom, isTrue);
    await tester.tap(find.byKey(const Key('follow-lightroom')));
    await tester.pump();
    expect(controller.config.followLightroom, isFalse);
    await settle(
      tester,
      () => File(p.join(temp.path, 'settings.json')).readAsStringSync().contains('"follow": false'),
      'setting saved',
    );

    // The choice survives a restart.
    final stored = jsonDecode(File(p.join(temp.path, 'settings.json')).readAsStringSync()) as Map<String, dynamic>;
    final restored = AppConfig.fromJson(stored['config'] as Map<String, dynamic>);
    expect(restored.language, Language.en);
    expect(restored.activeSlots.single.param.lr, 'Contrast');
    expect(restored.followLightroom, isFalse);
    expect(controller.state.device, DeviceLinkState.connected);
    expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Send to device')).onPressed, isNotNull);
    await screenshot(tester, 'device');

    // Idle times: logo after 5 minutes, dark never; the device gets them.
    await tester.ensureVisible(find.byKey(const Key('logo-after')));
    await tester.pump();
    await tester.tap(find.descendant(of: find.byKey(const Key('logo-after')), matching: find.byType(DropdownButton<int>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 minutes').last);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('sleep-after')), matching: find.byType(DropdownButton<int>)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('never').last);
    await tester.pumpAndSettle();
    expect(controller.config.logoMinutes, 5);
    expect(controller.config.sleepMinutes, 0);
    await settle(tester, () => model.idleAfter == const Duration(minutes: 5) && model.sleepAfter == null, 'times on device');

    // Bluetooth can be switched off; the choice is saved.
    await tester.scrollUntilVisible(find.byKey(const Key('use-bluetooth')), -150,
        scrollable: find.descendant(of: find.byKey(const Key('device-settings')), matching: find.byType(Scrollable)).first);
    await tester.pump();
    await tester.tap(find.byKey(const Key('use-bluetooth')));
    await settle(tester, () => !controller.config.useBluetooth, 'bluetooth off');
    await settle(
      tester,
      () => File(p.join(temp.path, 'settings.json')).readAsStringSync().contains('"bluetooth": false'),
      'setting saved',
    );

    await tester.runAsync(controller.shutdown);
  });

  testWidgets('firmware: versions, confirmation, progress, failure and retry', (tester) async {
    final steps = StreamController<FlashProgress>.broadcast();
    final finish = Completer<void>();
    var fail = true;
    final updater = FirmwareUpdater(
      load: () async => BundledFirmware('9.9.9', Uint8List(16)),
      flash: (image, onProgress) async {
        expect(image, hasLength(16));
        final sub = steps.stream.listen(onProgress);
        await finish.future;
        await sub.cancel();
        if (fail) throw FlashException('no answer to command 0x3', FlashFailure.connectionLost);
      },
    );
    await start(tester, deviceWindow: true, firmware: updater, settings: simulatorSettings);
    await settle(tester, () => controller.state.device == DeviceLinkState.connected, 'device');
    expect(find.text('9.9.9'), findsOneWidget);
    expect(controller.firmwareOutdated, isFalse, reason: 'the simulator is never updated');

    await tester.ensureVisible(find.byKey(const Key('firmware-update')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('firmware-update')));
    await tester.pumpAndSettle();
    expect(find.textContaining('30 Sekunden'), findsOneWidget);
    await tester.tap(find.byKey(const Key('firmware-confirm')));
    await tester.pump();
    expect(find.byKey(const Key('firmware-progress')), findsOneWidget);

    steps.add(const FlashProgress(FlashStage.writing, 0.4));
    await settle(tester, () => find.text('Firmware wird geschrieben …').evaluate().isNotEmpty, 'writing shown');
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(0.4, 1e-9));

    finish.complete();
    await settle(tester, () => find.byKey(const Key('firmware-error')).evaluate().isNotEmpty, 'failure shown');
    expect(find.text('Erneut versuchen'), findsOneWidget);
    expect(find.textContaining('Die Verbindung brach ab'), findsOneWidget);
    await screenshot(tester, 'firmware');

    // The retry goes through.
    fail = false;
    await tester.tap(find.byKey(const Key('firmware-update')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('firmware-confirm')));
    await settle(tester, () => updater.state.value.done, 'done');
    expect(find.textContaining('Firmware aufgespielt'), findsOneWidget);

    await steps.close();
    await tester.runAsync(controller.shutdown);
  });

  test('version comparison', () {
    expect(isOlderVersion('0.6.0', '0.6.1'), isTrue);
    expect(isOlderVersion('0.6.1', '0.6.1'), isFalse);
    expect(isOlderVersion('0.10.0', '0.9.9'), isFalse);
    expect(isOlderVersion('0.5.9', '0.6.0'), isTrue);
    expect(isOlderVersion(null, '0.6.0'), isFalse);
  });

  testWidgets('orientation: the knob turns the picture, the app saves or cancels', (tester) async {
    await start(tester, settings: {
      'simulator': true,
      'config': {
        'language': 'de',
        'slots': [
          {'param': 4, 'enabled': true},
        ],
      },
    }, deviceWindow: true);
    await settle(tester, () => controller.state.device == DeviceLinkState.connected, 'device');
    final model = controller.simulatorModel!;
    await settle(tester, () => controller.state.displayAngle == 0, 'angle known');
    Future<void> show(String key, [double _ = 0]) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pump();
    }

    await show('orientation-rotate');
    expect(find.textContaining('aufrecht'), findsOneWidget);
    expect(find.byKey(const Key('orientation-upright')), findsNothing);

    // "Drehen …" hands the knob over to the picture.
    await tester.tap(find.byKey(const Key('orientation-rotate')));
    await settle(tester, () => model.adjustingRotation, 'device adjusting');
    await settle(tester, () => find.byKey(const Key('orientation-save')).evaluate().isNotEmpty, 'save offered');
    model.rotate(6);
    await settle(tester, () => controller.state.displayAngle == 30, '30 degrees');
    expect(find.textContaining('30°'), findsOneWidget);
    await show('preview-rotate', -120);
    // The preview shows the angle but is not turned itself.
    expect(find.descendant(of: find.byType(DialPreview), matching: find.text('30')), findsOneWidget);
    expect(find.descendant(of: find.byType(DialPreview), matching: find.byType(Transform)), findsNothing);
    await screenshot(tester, 'rotate');

    // Cancel: back to upright, nothing stored.
    await show('orientation-cancel');
    await tester.tap(find.byKey(const Key('orientation-cancel')));
    await settle(tester, () => !model.adjustingRotation && controller.state.displayAngle == 0, 'cancelled');
    expect(model.rotation, 0);

    // Again, and save.
    await settle(tester, () => find.byKey(const Key('orientation-rotate')).evaluate().isNotEmpty, 'button back');
    await show('orientation-rotate');
    await tester.tap(find.byKey(const Key('orientation-rotate')));
    await settle(tester, () => model.adjustingRotation, 'device adjusting');
    model.rotate(-3);
    await settle(tester, () => controller.state.displayAngle == 345, '345 degrees');
    await show('orientation-save');
    await tester.tap(find.byKey(const Key('orientation-save')));
    await settle(tester, () => !model.adjustingRotation && model.rotation == 345, 'saved on the device');
    await settle(tester, () => find.byKey(const Key('orientation-upright')).evaluate().isNotEmpty, 'upright offered');
    expect(find.textContaining('345°'), findsOneWidget);

    // "Aufrecht" sets it back without the knob.
    await show('orientation-upright');
    await tester.tap(find.byKey(const Key('orientation-upright')));
    await settle(tester, () => model.rotation == 0 && controller.state.displayAngle == 0, 'upright again');

    await tester.runAsync(controller.shutdown);
  });

  testWidgets('Library: tap actions are chosen in the settings; the preview shows the photo', (tester) async {
    await start(tester, settings: {
      'simulator': true,
      'config': {
        'language': 'de',
        'slots': [
          {'param': 4, 'enabled': true},
        ],
      },
    }, libraryWindow: true);
    await settle(tester, () => controller.state.device == DeviceLinkState.connected, 'device');
    await settle(tester, () => controller.state.lightroomConnected, 'lightroom');
    final model = controller.simulatorModel!;
    expect(controller.config.library.enabled, isTrue);
    expect(controller.config.library.tap, LibraryMark.pick);

    // Choose "3 Sterne" for the double tap and switch the tap off.
    Future<void> choose(String key, String label) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pump();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await choose('library-double-tap', '3 Sterne');
    await choose('library-tap', 'Aus');
    expect(controller.config.library.doubleTap, LibraryMark.star3);
    expect(controller.config.library.tap, LibraryMark.none);
    await settle(
      tester,
      () {
        final saved = File(p.join(temp.path, 'settings.json')).readAsStringSync();
        return saved.contains('"doubleTap": "star3"') && saved.contains('"tap": "none"');
      },
      'settings saved',
    );

    // Lightroom shows the Library: the preview shows the photo, turning browses.
    plugin.userSwitchesModule('library');
    await settle(tester, () => model.libraryActive && !model.library.tapEnabled, 'library on the device');
    expect(model.library.doubleTapEnabled, isTrue);
    expect(find.byKey(const Key('preview-library')), findsOneWidget);
    expect(find.text('IMG_0001.CR3'), findsOneWidget);
    model.rotate(1);
    await settle(tester, () => plugin.photoId == 2, 'next photo');
    await settle(tester, () => find.text('IMG_0002.CR3').evaluate().isNotEmpty, 'name in the preview');

    model.doubleTap();
    await settle(tester, () => plugin.mark.rating == 3, 'three stars in Lightroom');
    model.tap();
    await sync(tester);
    expect(plugin.mark.flag, 0, reason: 'the tap is switched off');

    // "Then go to the next photo" for the double tap; the switched-off tap
    // cannot have it.
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('library-tap-advances'))).onChanged, isNull);
    await tester.ensureVisible(find.byKey(const Key('library-double-tap-advances')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('library-double-tap-advances')));
    await settle(tester, () => controller.config.library.doubleTapAdvances, 'advance switched on');
    await settle(
      tester,
      () => File(p.join(temp.path, 'settings.json')).readAsStringSync().contains('"doubleTapAdvances": true'),
      'setting saved',
    );
    await sync(tester);
    model.rotate(1);
    await settle(tester, () => plugin.photoId == 3, 'photo 3');
    model.doubleTap();
    await settle(tester, () => plugin.marks[3]?.rating == 3 && plugin.photoId == 4, 'marked and moved on');
    await settle(tester, () => find.text('IMG_0004.CR3').evaluate().isNotEmpty, 'next photo in the preview');
    expect(tester.widget<CheckboxListTile>(find.byKey(const Key('library-double-tap-advances'))).value, isTrue);
    await screenshot(tester, 'library');

    // Switched off, the device leaves the Library mode.
    await tester.ensureVisible(find.byKey(const Key('library-enabled')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('library-enabled')));
    await settle(tester, () => !model.libraryActive, 'library mode off');
    expect(find.byKey(const Key('preview-library')), findsNothing);

    await tester.runAsync(controller.shutdown);
  });

  testWidgets('time tracking window: name a job, stop, edit an entry, overview, export', (tester) async {
    await start(tester, settings: simulatorSettings, timeWindow: true);
    final tracker = controller.tracker;
    expect(find.text('Keine Uhr läuft'), findsOneWidget);

    // A job started on the device shows up unnamed, with the hint.
    final started = tracker.startNew(origin: 'device');
    final earlier = tracker.createJob(name: 'Katalog Verlag', client: 'Verlag');
    final dayStart = DateTime.now().subtract(const Duration(hours: 5));
    tracker.addManualEntry(jobId: earlier.id, start: dayStart, end: dayStart.add(const Duration(hours: 2, minutes: 30)));
    await sync(tester);
    expect(find.textContaining('unbenannter Eintrag'), findsOneWidget);
    expect(find.byKey(const Key('clock-time')), findsOneWidget);

    // Overview: the manual entry counts with 2:30.
    expect(find.text('Katalog Verlag'), findsOneWidget);
    expect(find.text('2:30'), findsWidgets);

    // Jobs tab: name the unnamed job.
    await tester.tap(find.text('Jobs'));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('job-${started.job.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('job-name')), 'Hochzeit Müller, Potsdam');
    await tester.enterText(find.byKey(const Key('job-short')), 'Müller');
    await tester.tap(find.byKey(const Key('job-save')));
    await tester.pumpAndSettle();
    await sync(tester);
    expect(tracker.db.job(started.job.id)!.name, 'Hochzeit Müller, Potsdam');
    expect(tracker.displayLabel(tracker.db.job(started.job.id)!), 'Müller');
    expect(find.textContaining('unbenannter Eintrag'), findsNothing);

    // A client created in the app is what the device offers to choose from.
    await tester.tap(find.byKey(const Key('new-client')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('client-name')), 'Fam. Müller');
    await tester.tap(find.byKey(const Key('client-save')));
    await tester.pumpAndSettle();
    await sync(tester);
    expect(tracker.clients().map((client) => client.name), contains('Fam. Müller'));
    expect(find.text('Fam. Müller'), findsOneWidget);

    // Jobs are grouped by client; renaming the client applies to all its jobs.
    expect(find.text('Verlag'), findsOneWidget);
    expect(find.text('Ohne Kunde'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('client-rename-${earlier.clientId}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('client-name')), 'Verlag Berlin');
    await tester.tap(find.byKey(const Key('client-save')));
    await tester.pumpAndSettle();
    await sync(tester);
    expect(tracker.db.job(earlier.id)!.client, 'Verlag Berlin');
    expect(find.text('Verlag Berlin'), findsOneWidget);
    await screenshot(tester, 'jobs');

    // Archiving the running job is refused.
    expect(controller.track(() => tracker.archive(started.job.id)), isNotNull);

    // Stop from the clock bar.
    await tester.tap(find.byKey(const Key('clock-stop')));
    await sync(tester);
    expect(tracker.running, isNull);
    expect(find.text('Keine Uhr läuft'), findsOneWidget);

    // Entries tab: add a note to the manual entry.
    await tester.tap(find.text('Einträge'));
    await tester.pump();
    final manual = tracker.entries(jobId: earlier.id).single;
    await tester.tap(find.byKey(ValueKey('entry-${manual.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('entry-note')), 'Retusche Titelbild');
    await tester.tap(find.byKey(const Key('entry-save')));
    await tester.pumpAndSettle();
    await sync(tester);
    final edited = tracker.entries(jobId: earlier.id).single;
    expect(edited.note, 'Retusche Titelbild');
    expect(edited.edited, isTrue);
    expect(edited.duration(DateTime.now()), const Duration(hours: 2, minutes: 30));
    await screenshot(tester, 'entries');

    // Search finds the entry by its note and the job by its client.
    await tester.enterText(find.byKey(const Key('time-search')), 'titelbild');
    await tester.pump();
    expect(find.byKey(ValueKey('entry-${manual.id}')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('time-search')), 'berlin');
    await tester.pump();
    expect(find.byKey(ValueKey('job-${earlier.id}')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('time-search')), '');
    await tester.pump();

    // Export with rounding to quarters of an hour.
    final target = p.join(temp.path, 'export.csv');
    controller.savePathPicker = (_) async => target;
    final path = await tester.runAsync(
      () => controller.exportCsv(jobIds: {earlier.id}, rounding: Rounding.quarterUp),
    );
    expect(path, target);
    final csv = File(target).readAsStringSync();
    expect(csv, contains('Job;Kunde;Start;Ende;Dauer;Notiz'));
    expect(csv, contains('Katalog Verlag;Verlag Berlin;'));
    expect(csv, contains(';2:30;Retusche Titelbild'));

    // Overview screenshot.
    await tester.tap(find.text('Übersicht'));
    await tester.pump();
    expect(find.byKey(const Key('overview-total')), findsOneWidget);
    await screenshot(tester, 'overview');

    // Deleting a job asks first and says what is lost; then job and times are gone.
    await tester.tap(find.text('Jobs'));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('job-menu-${earlier.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen …'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1 Eintrag, zusammen 2:30 Stunden'), findsOneWidget);
    expect(tracker.db.job(earlier.id), isNotNull, reason: 'nothing happens before the confirmation');
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    await sync(tester);
    expect(tracker.db.job(earlier.id), isNull);
    expect(tracker.entries(jobId: earlier.id), isEmpty);
    expect(tracker.db.job(started.job.id), isNotNull);
    await tester.runAsync(controller.shutdown);
  });

  testWidgets('info section: versions, licence with the attribution term, factory reset', (tester) async {
    await start(tester, infoWindow: true, settings: {
      'simulator': true,
      'config': {
        'language': 'de',
        'slots': [
          {'param': 4, 'enabled': true, 'label': 'Mein K'},
        ],
      },
    });
    expect(find.textContaining('GNU General Public License Version 3'), findsOneWidget);
    expect(find.byKey(const Key('license-condition')), findsOneWidget);
    expect(find.textContaining('Der Hinweis auf meine-belichtungszeit.de muss'), findsOneWidget);
    expect(find.text('powered by meine-belichtungszeit.de'), findsOneWidget);
    await screenshot(tester, 'info');
    await settle(tester, () => controller.state.device == DeviceLinkState.connected, 'device');
    final model = controller.simulatorModel!;
    await settle(tester, () => model.slots.length == 1, 'custom configuration on the device');
    final tracker = controller.tracker;
    final job = tracker.createJob(name: 'Hochzeit', client: 'Fam. Müller');
    final t = DateTime.now().subtract(const Duration(hours: 3));
    tracker.addManualEntry(jobId: job.id, start: t, end: t.add(const Duration(hours: 1)));
    await sync(tester);

    final button = find.byKey(const Key('factory-reset'));
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find.descendant(of: find.byKey(const Key('info-page')), matching: find.byType(Scrollable)).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('factory-reset-confirm')), findsOneWidget);
    expect(find.textContaining('alle 1 Jobs mit 1 Zeiteinträgen'), findsOneWidget);
    expect(tracker.jobs(), hasLength(1), reason: 'nothing happens before the confirmation');

    await tester.tap(find.byKey(const Key('factory-reset-confirm')));
    await tester.pump();
    await settle(tester, () => model.slots.length == 13, 'default controls back on the device');
    expect(tracker.jobs(), isEmpty);
    expect(tracker.clients(), isEmpty);
    expect(tracker.entries(), isEmpty);
    expect(controller.config.activeSlots, hasLength(13));
    expect(controller.config.activeSlots.every((slot) => slot.label == null), isTrue);
    final stored = jsonDecode(File(p.join(temp.path, 'settings.json')).readAsStringSync()) as Map<String, dynamic>;
    expect(AppConfig.fromJson(stored['config'] as Map<String, dynamic>).activeSlots, hasLength(13));
    await tester.pump(const Duration(seconds: 5)); // let the confirmation message disappear
    await tester.runAsync(controller.shutdown);
  });

  testWidgets('a clock left running by a crash asks what to do', (tester) async {
    // First session: start a clock, then "crash" (no shutdown).
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('darkdial_test');
      final db = TimeDatabase.open(p.join(temp.path, 'time.sqlite'));
      var now = DateTime.now().subtract(const Duration(hours: 3));
      final tracker = TimeTracker(db, now: () => now);
      tracker.createJob(name: 'Hochzeit');
      tracker.start(tracker.jobs().single.id, origin: 'device');
      now = now.add(const Duration(minutes: 40));
      tracker.beat();
      db.close();
      await File(p.join(temp.path, 'settings.json')).writeAsString(jsonEncode(simulatorSettings));
      plugin = FakePlugin();
      await plugin.start(toService: 0, fromService: 0);
      controller = AppController(
        installer: PluginInstaller(modulesDir: Directory(p.join(temp.path, 'Modules'))),
        settingsDirectory: temp,
        lightroom: () => LightroomLink(
          appVersion: '0.2.0',
          fromPluginPort: plugin.toServicePort,
          toPluginPort: plugin.fromServicePort,
          retryInterval: const Duration(milliseconds: 50),
        ),
      );
      await controller.init();
    });
    addTearDown(() async {
      await plugin.stop();
      await temp.delete(recursive: true);
    });
    tester.view.physicalSize = const Size(1040, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: darkdialTheme(), home: TimeWindow(controller: controller)));

    expect(controller.tracker.running, isNotNull, reason: 'no time is lost');
    expect(controller.tracker.pendingRecovery, isNotNull);
    expect(find.textContaining('lief noch'), findsOneWidget);

    await tester.tap(find.byKey(const Key('recovery-stop')));
    await sync(tester);
    expect(controller.tracker.running, isNull);
    expect(controller.tracker.entries().single.duration(DateTime.now()), const Duration(minutes: 40));
    expect(find.textContaining('lief noch'), findsNothing);
    await tester.runAsync(controller.shutdown);
  });
}
