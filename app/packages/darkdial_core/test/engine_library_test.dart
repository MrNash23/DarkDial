// The Library mode through the whole chain: simulated device, engine, fake
// Lightroom plugin.
import 'dart:async';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:darkdial_core/src/fake_plugin.dart';
import 'package:test/test.dart';

Future<void> until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> pause([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakePlugin plugin;
  late SimulatedDevice device;
  late Engine engine;

  DeviceModel model() => device.model;

  Future<void> boot({LibrarySettings library = const LibrarySettings(), String proto = lrProtocolVersion}) async {
    plugin = FakePlugin(proto: proto);
    await plugin.start(toService: 0, fromService: 0);
    device = SimulatedDevice();
    engine = Engine(
      transport: SimulatedTransport(device),
      lightroom: LightroomLink(
        appVersion: '0.5.0',
        fromPluginPort: plugin.toServicePort,
        toPluginPort: plugin.fromServicePort,
        retryInterval: const Duration(milliseconds: 50),
      ),
      config: AppConfig.defaults(Language.de).copyWith(library: library),
      appVersion: const [0, 5, 0],
      options: const EngineOptions(flushInterval: Duration(milliseconds: 5)),
    );
    await engine.start();
    await until(() => engine.state.device == DeviceLinkState.connected, 'device');
    await until(() => engine.state.lightroomConnected, 'lightroom');
    await until(() => model().values.every((v) => v.valid), 'values');
  }

  tearDown(() async {
    await engine.dispose();
    await plugin.stop();
  });

  test('in the Library the knob browses and the display shows the photo', () async {
    await boot();
    expect(model().libraryActive, isFalse);
    plugin.userSwitchesModule('library');
    await until(() => model().libraryActive, 'library on the device');
    expect(model().library.name, 'IMG_0001.CR3');
    expect(model().library.tapEnabled && model().library.doubleTapEnabled, isTrue);

    model().rotate(2);
    await until(() => plugin.photoId == 3, 'two photos on');
    await until(() => model().library.name == 'IMG_0003.CR3', 'name on the device');
    model().rotate(-1);
    await until(() => plugin.photoId == 2, 'one back');
    expect(plugin.module, 'library', reason: 'turning no longer switches to Develop');
    expect(plugin.received.where((m) => m['t'] == 'set'), isEmpty);
  });

  test('tap and double tap mark the photo; the same again takes it back', () async {
    await boot(library: const LibrarySettings(tap: LibraryMark.pick, doubleTap: LibraryMark.star3));
    plugin.userSwitchesModule('library');
    await until(() => model().libraryActive, 'library on the device');

    model().tap();
    await until(() => plugin.mark.flag == 1, 'picked in Lightroom');
    await until(() => model().library.flag == 1, 'picked on the device');
    model().doubleTap();
    await until(() => plugin.mark.rating == 3, 'three stars');
    await until(() => model().library.rating == 3, 'stars on the device');
    expect(plugin.mark.flag, 1, reason: 'the flag stays');

    model().tap();
    await until(() => plugin.mark.flag == 0, 'flag removed');
    model().doubleTap();
    await until(() => plugin.mark.rating == 0, 'stars removed');
    await until(() => model().library.rating == 0 && model().library.flag == 0, 'device follows');

    // Each photo keeps its own marks.
    model().tap();
    await until(() => plugin.mark.flag == 1, 'picked again');
    model().rotate(1);
    await until(() => model().library.name == 'IMG_0002.CR3', 'next photo');
    expect(model().library.flag, 0);
  });

  test('reject and colour labels', () async {
    await boot(library: const LibrarySettings(tap: LibraryMark.reject, doubleTap: LibraryMark.green));
    plugin.userSwitchesModule('library');
    await until(() => model().libraryActive, 'library on the device');
    model().tap();
    await until(() => plugin.mark.flag == -1 && model().library.flag == -1, 'rejected');
    model().doubleTap();
    await until(() => plugin.mark.label == 'green' && model().library.color == 3, 'green');
    model().doubleTap();
    await until(() => plugin.mark.label == '' && model().library.color == 0, 'label removed');
  });

  test('an action that is switched off does nothing and is not offered', () async {
    await boot(library: const LibrarySettings(tap: LibraryMark.none, doubleTap: LibraryMark.star5));
    plugin.userSwitchesModule('library');
    await until(() => model().libraryActive, 'library on the device');
    expect(model().library.tapEnabled, isFalse);
    expect(model().library.doubleTapEnabled, isTrue);
    model().tap();
    await pause();
    expect(plugin.received.where((m) => m['t'] == 'mark'), isEmpty);
    model().doubleTap();
    await until(() => plugin.mark.rating == 5, 'five stars');
  });

  test('the knob toggles between Library and Develop', () async {
    await boot();
    // Develop: a double click goes to the Library, the device is where it was.
    final index = model().index;
    model().doubleClick();
    await until(() => plugin.module == 'library', 'library');
    await until(() => model().libraryActive, 'device in the library');
    // Library: a single click goes back.
    model().click();
    await until(() => plugin.module == 'develop', 'develop');
    await until(() => !model().libraryActive, 'device back');
    expect(model().index, index);
    expect(model().mode, DeviceMode.select);
  });

  test('a change made in Lightroom reaches the device', () async {
    await boot();
    plugin.userSwitchesModule('library');
    await until(() => model().libraryActive, 'library on the device');
    plugin.marks[1] = (rating: 4, flag: 1, label: 'red');
    plugin.userSelectsPhoto(1);
    await until(() => model().library.rating == 4 && model().library.flag == 1 && model().library.color == 1, 'marks');
  });

  test('switched off in the app: turning in the Library edits as before', () async {
    await boot(library: const LibrarySettings(enabled: false));
    plugin.userSwitchesModule('library');
    await pause(100);
    expect(model().libraryActive, isFalse);
    model().doubleClick();
    await pause();
    expect(plugin.received.where((m) => m['t'] == 'module'), isEmpty);

    // Switching it on in the app takes effect at once.
    await engine.updateConfig(engine.config.copyWith(library: const LibrarySettings()));
    await until(() => model().libraryActive, 'library on the device');
  });

  test('an older plugin does not get the Library mode', () async {
    await boot(proto: '1.2');
    plugin.userSwitchesModule('library');
    await pause(100);
    expect(model().libraryActive, isFalse);
  });

  test('no photo selected: the Library shows nothing to mark', () async {
    await boot();
    plugin.userSwitchesModule('library');
    await until(() => model().libraryActive, 'library on the device');
    plugin.userSelectsPhoto(null);
    await until(() => model().library.name.isEmpty, 'no name');
    model().tap();
    await pause();
    expect(plugin.received.where((m) => m['t'] == 'mark'), isEmpty);
  });
}
