import 'dart:async';
import 'dart:typed_data';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:darkdial_core/src/fake_plugin.dart';
import 'package:test/test.dart';

/// Polls until [condition] holds; fails the test after two seconds.
Future<void> until(bool Function() condition, [String what = 'condition']) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> pause([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

class Rig {
  late FakePlugin plugin;
  late SimulatedDevice device;
  late LightroomLink link;
  late Engine engine;

  DeviceModel get model => device.model;

  Future<void> start({
    AppConfig? config,
    FakePlugin? plugin,
    bool startPlugin = true,
    EngineOptions options = const EngineOptions(
      flushInterval: Duration(milliseconds: 5),
      followGuard: Duration(milliseconds: 150),
    ),
  }) async {
    this.plugin = plugin ?? FakePlugin();
    if (startPlugin) await this.plugin.start(toService: 0, fromService: 0);
    device = SimulatedDevice();
    link = LightroomLink(
      appVersion: '0.1.0',
      fromPluginPort: startPlugin ? this.plugin.toServicePort : 1,
      toPluginPort: startPlugin ? this.plugin.fromServicePort : 1,
      retryInterval: const Duration(milliseconds: 50),
    );
    engine = Engine(
      transport: SimulatedTransport(device),
      lightroom: link,
      config: config ?? AppConfig.defaults(Language.en),
      appVersion: const [0, 1, 0],
      options: options,
    );
    await engine.start();
  }

  Future<void> ready() async {
    await until(() => engine.state.device == DeviceLinkState.connected, 'device');
    await until(() => engine.state.lightroomConnected, 'lightroom');
    await until(() => engine.state.slots.every((s) => s.value != null), 'values');
    await until(() => model.values.every((v) => v.valid), 'device values');
  }

  Future<void> stop() async {
    await engine.dispose();
    await plugin.stop();
  }

  int slotOf(String lr) => engine.state.slots.indexWhere((s) => s.settings.param.lr == lr);

  /// Moves the carousel to [lr] and enters edit mode.
  Future<void> edit(String lr) async {
    final target = slotOf(lr);
    if (model.mode == DeviceMode.edit) model.tap();
    model.rotate(target - model.index);
    model.tap();
    await until(() => engine.state.editing && engine.state.activeSlot == target, 'edit $lr');
  }
}

void main() {
  group('engine', () => engineTests());
  group('detection and device model', () => deviceTests());
}

void engineTests() {
  late Rig rig;
  setUp(() => rig = Rig());
  tearDown(() => rig.stop());

  test('handshake, configuration and first values reach the device', () async {
    await rig.start();
    await rig.ready();

    final state = rig.engine.state;
    expect(state.firmwareVersion, '0.2.0');
    expect(state.deviceSerial, '0200514D0001');
    expect(state.pluginVersion, '0.1.0');
    expect(state.developActive, isTrue);
    expect(state.photoSelected, isTrue);

    expect(rig.model.slots, hasLength(13));
    expect(rig.model.slots[2].label, 'Exposure');
    expect(rig.model.serviceConnected, isTrue);
    expect(rig.model.status.lightroomConnected, isTrue);
    final temperature = rig.model.values[rig.slotOf('Temperature')];
    expect(temperature.text, '5500K');
    expect(temperature.position, positionCentre);
    expect(rig.plugin.watched, hasLength(13));
  });

  test('turning the knob in edit mode changes the Lightroom value', () async {
    await rig.start();
    await rig.ready();
    await rig.edit('Exposure');

    rig.model.rotate(4);
    await until(() => (rig.plugin.values['Exposure']! - 0.20).abs() < 1e-9, 'Exposure 0.20');
    final slot = rig.slotOf('Exposure');
    await until(() => rig.model.values[slot].text == '+0.20', 'device text');
    expect(rig.model.values[slot].position, greaterThan(positionCentre));
  });

  test('turning in selection mode only moves the carousel', () async {
    await rig.start();
    await rig.ready();
    final sets = rig.plugin.received.where((m) => m['t'] == 'set').length;

    rig.model.rotate(2);
    await until(() => rig.engine.state.activeSlot == 2, 'focus');
    await pause();
    expect(rig.engine.state.editing, isFalse);
    expect(rig.plugin.received.where((m) => m['t'] == 'set').length, sets);
  });

  test('fast rotation is bundled into few sets', () async {
    await rig.start(options: const EngineOptions(flushInterval: Duration(milliseconds: 40)));
    await rig.ready();
    await rig.edit('Contrast');

    for (var i = 0; i < 30; i++) {
      rig.model.rotate(1);
    }
    await until(() => rig.plugin.values['Contrast'] == 30, 'Contrast 30');
    final sets = rig.plugin.received.where((m) => m['t'] == 'set').length;
    expect(sets, lessThanOrEqualTo(3));
  });

  test('a change made in Lightroom reaches the device', () async {
    await rig.start();
    await rig.ready();

    rig.plugin.userSets('Contrast', -40);
    final slot = rig.slotOf('Contrast');
    await until(() => rig.model.values[slot].text == '-40', 'device text');
    expect(rig.model.values[slot].position, lessThan(positionCentre));
    expect(rig.engine.state.slots[slot].value, -40);
  });

  test('the device follows the slider moved in Lightroom and continues there', () async {
    await rig.start();
    await rig.ready();
    final contrast = rig.slotOf('Contrast');
    expect(rig.model.mode, DeviceMode.select);

    // Mouse on Contrast: the device jumps there, in edit mode.
    rig.plugin.userSets('Contrast', 20);
    await until(() => rig.model.index == contrast && rig.model.mode == DeviceMode.edit, 'device follows');
    await until(() => rig.engine.state.editing && rig.engine.state.activeSlot == contrast, 'engine follows');
    rig.model.rotate(2);
    await until(() => rig.plugin.values['Contrast'] == 22, 'knob continues on Contrast');

    // Mouse on another slider while editing: leave one, enter the other.
    await pause(200); // the knob was just used
    final shadows = rig.slotOf('Shadows');
    rig.plugin.userSets('Shadows', -10);
    await until(() => rig.model.index == shadows && rig.engine.state.activeSlot == shadows, 'second jump');
    expect(rig.model.mode, DeviceMode.edit);

    // A slider that is not on the device changes nothing.
    rig.plugin.userSets('Sharpness', 40);
    await pause();
    expect(rig.model.index, shadows);
  });

  test('while the knob is in use the device does not jump to a late report', () async {
    await rig.start();
    await rig.ready();
    await rig.edit('Contrast');
    rig.model.rotate(3);
    await until(() => rig.plugin.values['Contrast'] == 3, 'Contrast 3');

    // The user leaves Contrast and moves on in the carousel ...
    rig.model.tap();
    rig.model.rotate(2);
    final here = rig.model.index;
    // ... and only now Lightroom reports Contrast as moved: no jump back.
    rig.plugin.reportsTouched('Contrast');
    await pause(80);
    expect(rig.model.index, here);
    expect(rig.model.mode, DeviceMode.select);

    // Once the knob has been left alone, the mouse is followed again.
    await pause(200);
    rig.plugin.userSets('Contrast', 30);
    await until(() => rig.model.index == rig.slotOf('Contrast') && rig.model.mode == DeviceMode.edit, 'follows');
  });

  test('following can be switched off', () async {
    await rig.start(config: AppConfig.defaults(Language.en).copyWith(followLightroom: false));
    await rig.ready();
    rig.plugin.userSets('Contrast', 20);
    await until(() => rig.engine.state.slots[rig.slotOf('Contrast')].value == 20, 'value arrives');
    await pause();
    expect(rig.model.index, 0);
    expect(rig.model.mode, DeviceMode.select);
    final restored = AppConfig.fromJson(rig.engine.config.toJson());
    expect(restored.followLightroom, isFalse);
    expect(AppConfig.fromJson(const {'language': 'de'}).followLightroom, isTrue, reason: 'on unless switched off');
  });

  test('stale answers do not pull the ring back while turning', () async {
    await rig.start();
    await rig.ready();
    rig.plugin.setDelay = const Duration(milliseconds: 80);
    await rig.edit('Contrast');
    final slot = rig.slotOf('Contrast');

    final seen = <String>[];
    rig.model.onChanged = () => seen.add(rig.model.values[slot].text);
    for (var i = 0; i < 6; i++) {
      rig.model.rotate(2);
      await pause(20);
    }
    await until(() => rig.plugin.values['Contrast'] == 12, 'Contrast 12');
    await pause(150);

    // The display only ever moved forward: 0, +2, +4, … never back.
    final numbers = seen.map((t) => int.parse(t.replaceAll('+', ''))).toList();
    for (var i = 1; i < numbers.length; i++) {
      expect(numbers[i], greaterThanOrEqualTo(numbers[i - 1]), reason: '$numbers');
    }
    expect(rig.model.values[slot].text, '+12');
  });

  test('values clamp at the range end', () async {
    await rig.start();
    await rig.ready();
    rig.plugin.userSets('Contrast', 98);
    await until(() => rig.engine.state.slots[rig.slotOf('Contrast')].value == 98, 'Contrast 98');
    await rig.edit('Contrast');

    rig.model.rotate(10);
    await until(() => rig.plugin.values['Contrast'] == 100, 'Contrast 100');
    rig.model.rotate(5);
    await pause();
    expect(rig.plugin.values['Contrast'], 100);
  });

  test('sensitivity scales detents and keeps the remainder', () async {
    final config = AppConfig.defaults(Language.en);
    final slots = [
      for (final s in config.slots) s.param.lr == 'Contrast' ? s.copyWith(sensitivity: 0.5) : s,
    ];
    await rig.start(config: config.copyWith(slots: slots));
    await rig.ready();
    await rig.edit('Contrast');

    for (var i = 0; i < 6; i++) {
      rig.model.rotate(1);
      await pause(15);
    }
    await until(() => rig.plugin.values['Contrast'] == 3, 'Contrast 3');
  });

  test('outside Develop the device is told about the module switch', () async {
    await rig.start(plugin: FakePlugin(module: 'library'));
    await until(() => rig.engine.state.lightroomConnected, 'lightroom');
    await until(() => rig.engine.state.module == 'library', 'status');
    expect(rig.engine.state.slots.first.value, isNull);
    await until(() => rig.model.serviceConnected && !rig.model.status.developActive, 'device status');
    expect(rig.model.values.first.valid, isFalse);

    // The user switches to Develop by hand: values appear.
    rig.plugin.userSwitchesModule('develop');
    await rig.ready();
    expect(rig.model.status.developActive, isTrue);
  });

  test('first turn outside Develop and Library switches the module and shows the notice', () async {
    await rig.start();
    await rig.ready();
    // In the Library the knob browses (engine_library_test.dart); elsewhere
    // turning a slider brings Develop up.
    rig.plugin.userSwitchesModule('map');
    await until(() => !rig.model.status.developActive, 'map on device');
    rig.plugin.setDelay = const Duration(milliseconds: 80);
    await rig.edit('Contrast');

    rig.model.rotate(3);
    await until(() => rig.model.status.notice == 1, 'notice');
    await until(() => rig.plugin.module == 'develop' && rig.plugin.values['Contrast'] == 3, 'applied');
    await until(() => rig.model.status.notice == 0 && rig.model.status.developActive, 'notice cleared');
  });

  test('no photo: turning has no effect and the device knows', () async {
    await rig.start();
    await rig.ready();
    rig.plugin.userSelectsPhoto(null);
    await until(() => !rig.model.status.photoSelected, 'no photo on device');
    await until(() => !rig.model.values.first.valid, 'values invalid');
    await rig.edit('Contrast');
    final sets = rig.plugin.received.where((m) => m['t'] == 'set').length;

    rig.model.rotate(5);
    await pause();
    expect(rig.plugin.received.where((m) => m['t'] == 'set').length, sets);
  });

  test('photo change brings the new range: raw Kelvin to JPEG', () async {
    await rig.start();
    await rig.ready();
    final slot = rig.slotOf('Temperature');
    expect(rig.model.values[slot].text, '5500K');

    rig.plugin.values['Temperature'] = 10;
    rig.plugin.userSelectsPhoto(2, newRanges: {
      'Temperature': [-100, 100],
    });
    await until(() => rig.model.values[slot].text == '+10', 'JPEG temperature');
  });

  test('new configuration is transferred and watched', () async {
    await rig.start();
    await rig.ready();
    final config = AppConfig.defaults(Language.de);
    final slots = [for (final s in config.slots) s.copyWith(enabled: s.param.group == 'hsl' && s.param.icon == 22)];

    expect(await rig.engine.updateConfig(config.copyWith(slots: slots)), isTrue);
    expect(rig.model.slots, hasLength(8));
    expect(rig.model.slots.first.label, 'Farbton');
    expect(rig.model.slots.first.color, 0xFA3A31);
    await until(() => rig.plugin.watched.length == 8, 'watch');
    expect(rig.plugin.watched.first, 'HueAdjustmentRed');
    await until(() => rig.model.values.every((v) => v.valid), 'values');
  });

  test('Lightroom started later is picked up; quitting is noticed', () async {
    final plugin = FakePlugin();
    await plugin.start(toService: 0, fromService: 0);
    await rig.start(plugin: plugin);
    await rig.ready();

    plugin.disconnectClients();
    await until(() => !rig.engine.state.lightroomConnected, 'disconnect');
    await until(() => !rig.model.status.lightroomConnected, 'device status');
    expect(rig.model.values.first.valid, isFalse);

    await rig.ready(); // reconnects by itself
    expect(rig.model.status.lightroomConnected, isTrue);
  });

  test('plugin with another protocol major is reported, not used', () async {
    await rig.start(plugin: FakePlugin(proto: '2.0'));
    await until(() => rig.engine.state.lightroomConflict, 'conflict');
    expect(rig.engine.state.lightroomConnected, isFalse);
    expect(rig.engine.state.pluginVersion, '0.1.0');
  });

  test('disposing during the handshake is safe', () async {
    await rig.start();
  });
}

void deviceTests() {
  test('a MIDI port that is not a Darkdial is left alone', () async {
    final port = _SilentPort('Some Synth');
    final (result, session) = await DeviceSession.open(port, appVersion: const [0, 1, 0]);
    expect(result, HandshakeResult.notDarkdial);
    expect(session, isNull);
    expect(port.sent, isEmpty, reason: 'nothing is sent to foreign devices');

    final lookalike = _SilentPort('Darkdial');
    final (result2, _) = await DeviceSession.open(
      lookalike,
      appVersion: const [0, 1, 0],
      timeout: const Duration(milliseconds: 50),
    );
    expect(result2, HandshakeResult.notDarkdial);
  });

  test('a port with the generic name macOS gives an unnamed USB MIDI device is probed', () async {
    expect(mayBeDarkdial('Darkdial'), isTrue);
    expect(mayBeDarkdial('USB-MIDI-Gerät'), isTrue);
    expect(mayBeDarkdial('USB MIDI Device'), isTrue);
    expect(mayBeDarkdial('Some Synth'), isFalse);
    expect(mayBeDarkdial('MIDI2LR'), isFalse);

    // Probed with the identity request; without the Darkdial answer it is
    // left alone like any other device.
    final port = _SilentPort('USB-MIDI-Gerät');
    final (result, session) = await DeviceSession.open(
      port,
      appVersion: const [0, 1, 0],
      timeout: const Duration(milliseconds: 50),
    );
    expect(result, HandshakeResult.notDarkdial);
    expect(session, isNull);
    expect(port.sent, hasLength(1), reason: 'only the identity request');
  });

  test('device with another protocol major is incompatible', () async {
    final port = _IdentityOnlyPort();
    final (result, _) = await DeviceSession.open(
      port,
      appVersion: const [0, 1, 0],
      timeout: const Duration(milliseconds: 50),
    );
    expect(result, HandshakeResult.incompatible);
  });

  test('device model rejects a corrupted configuration and keeps the old one', () {
    final model = DeviceModel();
    final acks = <ConfigAck>[];
    model.emit = (m) {
      if (m is ConfigAck) acks.add(m);
    };
    const slot = ConfigSlot(index: 0, paramId: 3, iconId: 3, bipolar: true, color: 0, label: 'Exposure');

    model
      ..handle(const ConfigBegin(1, 1))
      ..handle(slot)
      ..handle(const ConfigEnd(0x1234));
    expect(acks.last.result, 1);
    expect(model.slots, hasLength(13));

    model
      ..handle(const ConfigBegin(2, 1))
      ..handle(slot)
      ..handle(ConfigEnd(configCrc([slot])));
    expect(acks.last.result, 3, reason: 'slot missing');

    model.handle(const ConfigBegin(49, 1));
    expect(acks.last.result, 2);

    model
      ..handle(const ConfigBegin(1, 1))
      ..handle(slot)
      ..handle(ConfigEnd(configCrc([slot])));
    expect(acks.last.result, 0);
    expect(model.slots.single.label, 'Exposure');
  });

  test('device model: after the idle time the first input only wakes the display', () async {
    final model = DeviceModel();
    final sent = <DeviceMessage>[];
    model.emit = sent.add;
    model.rotate(1);
    expect(model.index, 1);

    model.idle = true; // as the timer would set it after three minutes
    model.rotate(1);
    expect(model.idle, isFalse);
    expect(model.index, 1, reason: 'the waking turn is not acted on');
    model.rotate(1);
    expect(model.index, 2);

    model.idle = true;
    sent.clear();
    model.tap();
    expect(model.mode, DeviceMode.select);
    expect(sent, isEmpty);
    model.idle = true;
    model.longPress();
    expect(model.menuOpen, isFalse);
    model.dispose();
  });

  test('device model wraps around the carousel and stays on its parameter', () {
    final model = DeviceModel();
    model.rotate(-1);
    expect(model.index, 12);
    model.rotate(2);
    expect(model.index, 1);

    // Tint (id 2) moves to index 0 in the new configuration.
    const tint = ConfigSlot(index: 0, paramId: 2, iconId: 2, bipolar: true, color: 0, label: 'Tint');
    const exposure = ConfigSlot(index: 1, paramId: 3, iconId: 3, bipolar: true, color: 0, label: 'Exposure');
    model.tap();
    model
      ..handle(const ConfigBegin(2, 1))
      ..handle(tint)
      ..handle(exposure)
      ..handle(ConfigEnd(configCrc([tint, exposure])));
    expect(model.index, 0);
    expect(model.mode, DeviceMode.edit);
  });
}

class _SilentPort implements MidiConnection {
  _SilentPort(this.name);
  @override
  final String name;
  final List<Uint8List> sent = [];
  final StreamController<Uint8List> _input = StreamController();
  @override
  Stream<Uint8List> get input => _input.stream;
  @override
  void send(Uint8List message) => sent.add(message);
  @override
  Future<void> close() async {
    if (!_input.isClosed) unawaited(_input.close());
  }
}

/// Answers the identity request but frames everything else for protocol 2.
class _IdentityOnlyPort extends _SilentPort {
  _IdentityOnlyPort() : super('Darkdial');
  @override
  void send(Uint8List message) {
    if (decodeMessage(message) is IdentityRequest) {
      _input.add(encodeMessage(const IdentityReply(1, 2, 0, 0)));
    }
  }
}
