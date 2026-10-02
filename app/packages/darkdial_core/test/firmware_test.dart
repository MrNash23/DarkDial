// Runs the engine against the real firmware state machine: the C++ core
// built for the host (firmware/host/build.sh --core-only) as a process.
// Catches any disagreement between the Dart and the C++ side of the protocol.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:darkdial_core/src/fake_plugin.dart';
import 'package:test/test.dart';

const _binary = '../../../firmware/host/build/dd_sim';

/// The firmware core behind stdin/stdout, see firmware/host/dd_sim.cpp.
class FirmwareProcess implements MidiConnection {
  FirmwareProcess._(this._process) {
    _process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith('M ')) {
        _input.add(_fromHex(line.substring(2)));
      } else if (line.startsWith('S ')) {
        _state?.complete(line.substring(2));
        _state = null;
      }
    });
  }

  static Future<FirmwareProcess> start() async => FirmwareProcess._(await Process.start(_binary, const []));

  final Process _process;
  final StreamController<Uint8List> _input = StreamController<Uint8List>();
  Completer<String>? _state;

  static Uint8List _fromHex(String hex) => Uint8List.fromList([
        for (var i = 0; i + 1 < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
      ]);

  @override
  String get name => 'Darkdial';

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  void send(Uint8List message) {
    _process.stdin.writeln('M ${message.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
  }

  void rotate(int detents) => _process.stdin.writeln('R $detents');
  void click() => _process.stdin.writeln('C');
  void advance(int ms) => _process.stdin.writeln('T $ms');

  /// mode, index, slot count, screen, then label|text|position|valid.
  Future<({bool editing, int index, int slots, int screen, String label, String text, int position, bool valid})>
      state() async {
    final completer = _state = Completer<String>();
    _process.stdin.writeln('?');
    final line = await completer.future.timeout(const Duration(seconds: 2));
    final head = line.split(' ');
    final rest = head.sublist(4).join(' ').split('|');
    return (
      editing: head[0] == '1',
      index: int.parse(head[1]),
      slots: int.parse(head[2]),
      screen: int.parse(head[3]),
      label: rest[0],
      text: rest[1],
      position: int.parse(rest[2]),
      valid: rest[3] == '1',
    );
  }

  @override
  Future<void> close() async {
    _process.kill();
    if (!_input.isClosed) await _input.close();
  }
}

class _OneDevice implements MidiTransport {
  _OneDevice(this.device);
  final MidiConnection device;
  final StreamController<MidiConnection> _connections = StreamController<MidiConnection>();

  @override
  Stream<MidiConnection> get connections => _connections.stream;
  @override
  Future<void> start() async => _connections.add(device);
  @override
  Future<void> dispose() async {
    await device.close();
    await _connections.close();
  }
}

Future<void> until(FutureOr<bool> Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  final available = File(_binary).existsSync();

  test('engine drives the C++ firmware core end to end', () async {
    final plugin = FakePlugin();
    await plugin.start(toService: 0, fromService: 0);
    final firmware = await FirmwareProcess.start();
    final engine = Engine(
      transport: _OneDevice(firmware),
      lightroom: LightroomLink(
        appVersion: '0.1.0',
        fromPluginPort: plugin.toServicePort,
        toPluginPort: plugin.fromServicePort,
        retryInterval: const Duration(milliseconds: 50),
      ),
      config: AppConfig.defaults(Language.de),
      appVersion: const [0, 1, 0],
      options: const EngineOptions(flushInterval: Duration(milliseconds: 5)),
    );
    addTearDown(() async {
      await engine.dispose();
      await plugin.stop();
    });
    await engine.start();

    // Handshake: identity, hello, configuration with German labels.
    await until(() => engine.state.device == DeviceLinkState.connected, 'handshake');
    expect(engine.state.firmwareVersion, '0.1.0');
    expect(engine.state.deviceSerial, '0200514D0002');
    await until(() async => (await firmware.state()).label == 'Temperatur', 'German configuration');
    expect((await firmware.state()).slots, 13);

    // Status and values arrive: slot screen (4) with the Kelvin text at the centre.
    await until(() async => (await firmware.state()).valid, 'values');
    firmware.advance(1500); // the "loaded" notice passes
    var state = await firmware.state();
    expect(state.screen, 4);
    expect(state.text, '5500K');
    expect(state.position, positionCentre);

    // Carousel: two detents to Belichtung; the engine follows the focus.
    firmware.rotate(2);
    await until(() => engine.state.activeSlot == 2, 'focus');
    state = await firmware.state();
    expect(state.label, 'Belichtung');
    expect(state.text, '0.00');

    // Edit: slow detents are single steps of 0.05 EV.
    firmware.click();
    await until(() => engine.state.editing, 'edit mode');
    for (var i = 0; i < 4; i++) {
      firmware.advance(200);
      firmware.rotate(1);
    }
    await until(() => (plugin.values['Exposure']! - 0.20).abs() < 1e-9, 'Exposure in Lightroom');
    await until(() async => (await firmware.state()).text == '+0.20', 'text on the device');
    expect((await firmware.state()).position, greaterThan(positionCentre));

    // A change made in Lightroom reaches the device.
    plugin.userSets('Exposure', -2.0);
    await until(() async => (await firmware.state()).text == '-2.00', 'mouse change on the device');
    expect((await firmware.state()).position, lessThan(positionCentre));

    // Leaving edit mode and a new configuration with an umlaut and a colour.
    firmware.click();
    await until(() => !engine.state.editing, 'selection mode');
    final config = AppConfig.defaults(Language.de);
    final slots = [for (final s in config.slots) s.copyWith(enabled: s.param.lr == 'SaturationAdjustmentBlue')];
    expect(await engine.updateConfig(config.copyWith(slots: slots)), isTrue);
    state = await firmware.state();
    expect(state.slots, 1);
    expect(state.label, 'Sättigung');

    // No photo: the device shows the status screen (3).
    plugin.userSelectsPhoto(null);
    firmware.advance(1500);
    await until(() async => (await firmware.state()).screen == 3, 'no-photo screen');
  }, skip: available ? false : 'firmware core not built: run firmware/host/build.sh --core-only');
}
