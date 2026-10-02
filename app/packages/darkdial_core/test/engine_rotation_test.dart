// Turning the picture of the device from the app, through simulated device
// and engine.
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

void main() {
  late FakePlugin plugin;
  late SimulatedDevice device;
  late Engine engine;

  DeviceModel model() => device.model;

  setUp(() async {
    plugin = FakePlugin();
    await plugin.start(toService: 0, fromService: 0);
    device = SimulatedDevice();
    engine = Engine(
      transport: SimulatedTransport(device),
      lightroom: LightroomLink(
        appVersion: '0.6.0',
        fromPluginPort: plugin.toServicePort,
        toPluginPort: plugin.fromServicePort,
        retryInterval: const Duration(milliseconds: 50),
      ),
      config: AppConfig.defaults(Language.de),
      appVersion: const [0, 6, 0],
      options: const EngineOptions(flushInterval: Duration(milliseconds: 5)),
    );
    await engine.start();
    await until(() => engine.state.device == DeviceLinkState.connected, 'device');
    await until(() => engine.state.lightroomConnected, 'lightroom');
  });

  tearDown(() async {
    await engine.dispose();
    await plugin.stop();
  });

  test('the device reports its angle on connect', () async {
    await until(() => engine.state.displayAngle == 0, 'angle known');
    expect(engine.state.displayAdjusting, isFalse);
  });

  test('begin, turn with the knob, save from the app', () async {
    await until(() => engine.state.displayAngle != null, 'angle known');
    engine.beginDisplayRotation();
    await until(() => engine.state.displayAdjusting, 'adjusting');
    final index = model().index;
    model().rotate(6);
    await until(() => engine.state.displayAngle == 30, '30 degrees');
    model().rotate(-8);
    await until(() => engine.state.displayAngle == 350, 'wraps around');
    expect(model().index, index, reason: 'the knob does nothing else meanwhile');
    expect(plugin.received.where((m) => m['t'] == 'set' || m['t'] == 'photo'), isEmpty);

    engine.saveDisplayRotation();
    await until(() => !engine.state.displayAdjusting, 'saved');
    expect(engine.state.displayAngle, 350);
    expect(model().rotation, 350);
  });

  test('cancel goes back to the stored angle; pressing the knob saves', () async {
    await until(() => engine.state.displayAngle != null, 'angle known');
    engine.beginDisplayRotation();
    await until(() => engine.state.displayAdjusting, 'adjusting');
    model().rotate(3);
    await until(() => engine.state.displayAngle == 15, '15 degrees');
    engine.cancelDisplayRotation();
    await until(() => !engine.state.displayAdjusting && engine.state.displayAngle == 0, 'cancelled');

    engine.beginDisplayRotation();
    await until(() => engine.state.displayAdjusting, 'adjusting again');
    model().rotate(18);
    model().click();
    await until(() => !engine.state.displayAdjusting && engine.state.displayAngle == 90, 'saved by the knob');
    expect(model().mode, DeviceMode.select);
    expect(plugin.received.where((m) => m['t'] == 'module'), isEmpty);

    engine.setDisplayRotation(0);
    await until(() => engine.state.displayAngle == 0 && model().rotation == 0, 'upright again');
  });
}
