// USB and Bluetooth: the engine takes USB when the same device is on both.
import 'dart:async';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:darkdial_core/src/fake_plugin.dart';
import 'package:test/test.dart';

Future<void> until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The simulated device, reached over Bluetooth.
class WirelessSimulatedDevice extends SimulatedDevice implements WirelessMidiConnection {
  WirelessSimulatedDevice({super.serial});
  @override
  String get name => 'Darkdial (Bluetooth)';
}

/// A transport whose ports the test adds and removes.
class ManualTransport implements MidiTransport {
  final StreamController<MidiConnection> _connections = StreamController<MidiConnection>();
  @override
  Stream<MidiConnection> get connections => _connections.stream;
  void add(SimulatedDevice device) {
    device.open();
    _connections.add(device);
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> dispose() => _connections.close();
}

void main() {
  late FakePlugin plugin;
  late ManualTransport transport;
  late Engine engine;

  setUp(() async {
    plugin = FakePlugin();
    await plugin.start(toService: 0, fromService: 0);
    transport = ManualTransport();
    engine = Engine(
      transport: transport,
      lightroom: LightroomLink(
        appVersion: '0.9.0',
        fromPluginPort: plugin.toServicePort,
        toPluginPort: plugin.fromServicePort,
        retryInterval: const Duration(milliseconds: 50),
      ),
      config: AppConfig.defaults(Language.de),
      appVersion: const [0, 9, 0],
      options: const EngineOptions(flushInterval: Duration(milliseconds: 5)),
    );
    await engine.start();
    await until(() => engine.state.lightroomConnected, 'lightroom');
  });

  tearDown(() async {
    await engine.dispose();
    await plugin.stop();
  });

  test('Bluetooth works like USB', () async {
    final air = WirelessSimulatedDevice();
    transport.add(air);
    await until(() => engine.state.device == DeviceLinkState.connected, 'connected');
    expect(engine.state.deviceWireless, isTrue);
    await until(() => air.model.values.every((v) => v.valid), 'values over the air');
    air.model.tap();
    await until(() => engine.state.editing, 'edit mode');
    air.model.rotate(3);
    await until(() => plugin.values['Temperature'] != 5500 || plugin.received.any((m) => m['t'] == 'set'), 'value set');
  });

  test('a cable takes over from Bluetooth, and Bluetooth takes over again when it is pulled', () async {
    final air = WirelessSimulatedDevice();
    transport.add(air);
    await until(() => engine.state.deviceWireless, 'on Bluetooth');

    final cable = SimulatedDevice();
    transport.add(cable);
    await until(() => engine.state.device == DeviceLinkState.connected && !engine.state.deviceWireless, 'on USB');
    await until(() => cable.model.values.every((v) => v.valid), 'values over USB');

    // The transport finds the Bluetooth device again; it waits as a spare.
    transport.add(air);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.state.deviceWireless, isFalse, reason: 'USB keeps priority');

    // Cable pulled: back to Bluetooth.
    await cable.close();
    await until(() => engine.state.device == DeviceLinkState.connected && engine.state.deviceWireless, 'Bluetooth again');
  });

  test('a second cable while on USB just waits', () async {
    final first = SimulatedDevice();
    transport.add(first);
    await until(() => engine.state.device == DeviceLinkState.connected, 'first');
    final second = SimulatedDevice(serial: const [9, 9, 9, 9, 9, 9]);
    transport.add(second);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.state.deviceSerial, isNot('090909090909'));
    await first.close();
    await until(() => engine.state.device == DeviceLinkState.connected && engine.state.deviceSerial != null, 'second');
  });
}
