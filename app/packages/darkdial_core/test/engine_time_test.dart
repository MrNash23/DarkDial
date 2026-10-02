// Time tracking and double-tap reset through the whole chain: simulated
// device, engine, tracker with an in-memory database, fake Lightroom plugin.
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
  late TimeDatabase db;
  late TimeTracker tracker;
  late Engine engine;

  DeviceModel model() => device.model;

  setUp(() async {
    plugin = FakePlugin();
    await plugin.start(toService: 0, fromService: 0);
    device = SimulatedDevice();
    db = TimeDatabase.inMemory();
    tracker = TimeTracker(db);
    engine = Engine(
      transport: SimulatedTransport(device),
      lightroom: LightroomLink(
        appVersion: '0.2.0',
        fromPluginPort: plugin.toServicePort,
        toPluginPort: plugin.fromServicePort,
        retryInterval: const Duration(milliseconds: 50),
      ),
      config: AppConfig.defaults(Language.de),
      appVersion: const [0, 2, 0],
      options: const EngineOptions(flushInterval: Duration(milliseconds: 5)),
      timeTracker: tracker,
    );
    await engine.start();
    await until(() => engine.state.device == DeviceLinkState.connected, 'device');
    await until(() => engine.state.lightroomConnected, 'lightroom');
    await until(() => model().values.every((v) => v.valid), 'values');
  });

  tearDown(() async {
    await engine.dispose();
    await tracker.dispose();
    db.close();
    await plugin.stop();
  });

  test('new job from the device starts the clock and appears unnamed', () async {
    model().longPress();
    expect(model().menuOpen, isTrue);
    expect(model().menu.map((l) => l.kind), [MenuKind.newJob]);

    model().click();
    await until(() => tracker.running != null, 'clock');
    await until(() => model().timerRunning, 'clock on the device');
    expect(model().menuOpen, isFalse);
    expect(model().notice?.code, TimerResult.started);
    expect(tracker.jobs().single.unnamed, isTrue);
    expect(tracker.running!.entry.origin, 'device');
    expect(model().timerLabel, tracker.displayLabel(tracker.jobs().single));
    expect(model().mode, DeviceMode.select, reason: 'back where the long press came from');
  });

  test('switching jobs on the device stops one and starts the other in one step', () async {
    final a = tracker.createJob(name: 'Hochzeit Müller', short: 'Müller');
    final b = tracker.createJob(name: 'Katalog');
    await pause(5); // "last used" has millisecond resolution
    tracker.start(a.id, origin: 'app');
    await until(() => model().timerRunning && model().timerJobId == a.id, 'clock on the device');

    model().longPress();
    await until(() => model().jobs.length == 2, 'job list');
    expect(model().menu.map((l) => l.kind), [MenuKind.stop, MenuKind.newJob, MenuKind.job, MenuKind.job]);
    expect(model().jobs.first.label, 'Müller', reason: 'most recently used first');
    expect(model().jobs.first.running, isTrue);

    model().rotate(3); // Katalog
    expect(model().menu[model().menuIndex].job!.id, b.id);
    model().click();
    await until(() => tracker.running?.job.id == b.id, 'switch');
    await until(() => model().timerJobId == b.id, 'device follows');
    final entries = tracker.entries();
    expect(entries, hasLength(2));
    expect(entries.where((e) => e.running), hasLength(1));
    expect(entries.firstWhere((e) => e.jobId == a.id).end, entries.firstWhere((e) => e.jobId == b.id).start);
  });

  test('stop from the device', () async {
    tracker.startNew(origin: 'app');
    await until(() => model().timerRunning, 'clock on the device');
    model().longPress();
    expect(model().menu.first.kind, MenuKind.stop);
    model().click();
    await until(() => tracker.running == null, 'stopped');
    await until(() => !model().timerRunning, 'device follows');
    expect(model().notice?.code, TimerResult.stopped);
  });

  test('a second long press closes the menu without any action', () async {
    model().longPress();
    model().rotate(1);
    model().longPress();
    await pause();
    expect(model().menuOpen, isFalse);
    expect(tracker.running, isNull);
    expect(tracker.jobs(), isEmpty);
  });

  test('the Lightroom collection in use puts its job on top as suggestion', () async {
    final wedding = tracker.createJob(name: 'Hochzeit');
    final other = tracker.createJob(name: 'Anderes');
    await pause(5);
    tracker.start(other.id, origin: 'app');
    tracker.stop();
    tracker.assignSource(wedding.id, const LrSource(kind: 'collection', key: '77', name: 'Hochzeit Auswahl'));

    model().longPress();
    await until(() => model().jobs.length == 2, 'job list');
    expect(model().jobs.first.id, other.id);
    expect(model().jobs.any((j) => j.suggested), isFalse);

    plugin.userOpensSource('collection', 'Hochzeit Auswahl', '77');
    await until(() => model().jobs.first.suggested, 'suggestion on the device');
    expect(model().jobs.first.id, wedding.id);
    expect(tracker.currentSource!.name, 'Hochzeit Auswahl');

    plugin.userOpensSource('folder', '2026', '/Fotos/2026');
    await until(() => !model().jobs.any((j) => j.suggested), 'suggestion gone');
  });

  test('a change in the app reaches the device: rename and start from the menu bar', () async {
    final job = tracker.createJob(name: 'Erst');
    model().longPress();
    await until(() => model().jobs.length == 1, 'job list');
    tracker.updateJob(job.id, name: 'Erst', short: 'Kürzel', client: '', color: null);
    await until(() => model().jobs.single.label == 'Kürzel', 'new label');

    tracker.start(job.id, origin: 'app');
    await until(() => model().timerRunning && model().timerLabel == 'Kürzel', 'clock from the app');
    expect(model().menu.first.kind, MenuKind.stop);
  });

  test('starting an archived job from a stale list reports an error', () async {
    final job = tracker.createJob(name: 'Alt');
    model().longPress();
    await until(() => model().jobs.length == 1, 'job list');
    // Archive behind the device's back: the change event is still on its way.
    db.setArchived(job.id, true);
    model().rotate(1);
    model().click();
    await until(() => model().notice != null, 'result');
    expect(model().notice!.code, TimerResult.error);
    expect(model().notice!.text, 'Archiviert');
    expect(tracker.running, isNull);
    await until(() => model().jobs.isEmpty, 'fresh list');
  });

  test('the device keeps counting between clock messages', () async {
    tracker.startNew(origin: 'app');
    await until(() => model().timerRunning, 'clock on the device');
    final first = model().timerSeconds;
    await pause(1100);
    expect(model().timerSeconds, greaterThan(first));
    expect((model().timerSeconds - tracker.running!.elapsed(DateTime.now()).inSeconds).abs(), lessThanOrEqualTo(1));
  });

  test('double tap in edit mode resets the slot to the Lightroom default', () async {
    final slot = engine.state.slots.indexWhere((s) => s.settings.param.lr == 'Contrast');
    model().rotate(slot - model().index);
    model().click();
    await until(() => engine.state.editing, 'edit mode');
    model().rotate(7);
    await until(() => plugin.values['Contrast'] == 7, 'Contrast 7');

    model().doubleTap();
    await until(() => plugin.values['Contrast'] == 0, 'reset in Lightroom');
    await until(() => model().values[slot].text == '0', 'reset on the device');
    expect(model().mode, DeviceMode.edit);

    // Outside edit mode a double tap does nothing.
    model().click();
    model().rotate(0);
    final resets = plugin.received.where((m) => m['t'] == 'reset').length;
    model().doubleTap();
    await pause();
    expect(plugin.received.where((m) => m['t'] == 'reset').length, resets);
  });

  test('sliders work unchanged while a clock runs', () async {
    tracker.startNew(origin: 'device');
    await until(() => model().timerRunning, 'clock');
    final slot = engine.state.slots.indexWhere((s) => s.settings.param.lr == 'Exposure');
    model().rotate(slot - model().index);
    model().click();
    await until(() => engine.state.editing, 'edit mode');
    model().rotate(2);
    await until(() => (plugin.values['Exposure']! - 0.10).abs() < 1e-9, 'Exposure');
    expect(tracker.running, isNotNull);
  });
}
