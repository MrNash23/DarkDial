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
  List<String> labels() => [for (final item in model().menu) item.label];

  /// Long press, then wait for the first page.
  Future<void> openMenu() async {
    model().longPress();
    await until(() => model().menu.isNotEmpty, 'menu page');
  }

  /// Turns to the line with [label] and clicks it.
  Future<void> choose(String label) async {
    await until(() => labels().contains(label), 'line "$label" in ${labels()}');
    model().rotate(labels().indexOf(label) - model().menuIndex);
    model().click();
  }

  setUp(() async {
    plugin = FakePlugin();
    await plugin.start(toService: 0, fromService: 0);
    device = SimulatedDevice();
    db = TimeDatabase.inMemory();
    tracker = TimeTracker(db);
    engine = Engine(
      transport: SimulatedTransport(device),
      lightroom: LightroomLink(
        appVersion: '0.3.0',
        fromPluginPort: plugin.toServicePort,
        toPluginPort: plugin.fromServicePort,
        retryInterval: const Duration(milliseconds: 50),
      ),
      config: AppConfig.defaults(Language.de),
      appVersion: const [0, 3, 0],
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

  test('long press opens the start page; new job starts the clock and appears unnamed', () async {
    await openMenu();
    expect(model().menuTitle, 'Zeiterfassung');
    expect(labels(), ['Neuer Job', 'Neuer Kunde', 'Schließen']);

    await choose('Neuer Job');
    await until(() => tracker.running != null, 'clock');
    await until(() => model().timerRunning, 'clock on the device');
    expect(model().menuOpen, isFalse);
    expect(model().notice?.code, TimerResult.started);
    expect(tracker.jobs().single.unnamed, isTrue);
    expect(tracker.running!.entry.origin, 'device');
    expect(model().timerLabel, tracker.displayLabel(tracker.jobs().single));
    expect(model().mode, DeviceMode.select, reason: 'back where the long press came from');
  });

  test('client, then job on the device; switching stops the other clock in the same step', () async {
    final wedding = tracker.createJob(name: 'Hochzeit', client: 'Fam. Müller');
    final catalogue = tracker.createJob(name: 'Katalog', client: 'Verlag');
    await pause(5);
    tracker.start(catalogue.id, origin: 'app');
    await until(() => model().timerRunning && model().timerJobId == catalogue.id, 'clock on the device');

    await openMenu();
    expect(labels().first, 'Stopp');
    expect(model().menu.first.running, isTrue);

    await choose('Kunden');
    await until(() => model().menuTitle == 'Kunden', 'client list');
    expect(model().menuIndex, 0, reason: 'a new page starts at its first line');
    await choose('Fam. Müller');
    await until(() => model().menuTitle == 'Fam. Müller', 'jobs of the client');
    expect(labels(), ['Hochzeit', 'Neuer Job', 'Zurück']);

    await choose('Hochzeit');
    await until(() => tracker.running?.job.id == wedding.id, 'switch');
    await until(() => model().timerJobId == wedding.id && !model().menuOpen, 'device follows');
    final entries = tracker.entries();
    expect(entries, hasLength(2));
    expect(entries.where((e) => e.running), hasLength(1));
    expect(entries.firstWhere((e) => e.jobId == catalogue.id).end, entries.firstWhere((e) => e.jobId == wedding.id).start);
  });

  test('back goes up one level; close and a second long press end the menu without action', () async {
    tracker.createJob(name: 'Katalog', client: 'Verlag');
    await openMenu();
    await choose('Kunden');
    await until(() => model().menuTitle == 'Kunden', 'client list');
    await choose('Zurück');
    await until(() => model().menuTitle == 'Zeiterfassung', 'start page again');

    await choose('Schließen');
    expect(model().menuOpen, isFalse);
    await pause();
    expect(tracker.running, isNull);

    await openMenu();
    model().rotate(1);
    model().longPress();
    await pause();
    expect(model().menuOpen, isFalse);
    expect(tracker.running, isNull);
    expect(tracker.jobs(), hasLength(1));
  });

  test('new client from the device: unnamed client and job, clock running', () async {
    await openMenu();
    await choose('Neuer Kunde');
    await until(() => tracker.running != null, 'clock');
    expect(tracker.clients().single.unnamed, isTrue);
    expect(tracker.running!.job.clientId, tracker.clients().single.id);
    await until(() => model().notice?.code == TimerResult.started, 'confirmation');
  });

  test('stop from the device', () async {
    tracker.startNew(origin: 'app');
    await until(() => model().timerRunning, 'clock on the device');
    await openMenu();
    await choose('Stopp');
    await until(() => tracker.running == null, 'stopped');
    await until(() => !model().timerRunning, 'device follows');
    expect(model().notice?.code, TimerResult.stopped);
  });

  test('the Lightroom collection in use puts its job on top, highlighted, while the menu is open', () async {
    final wedding = tracker.createJob(name: 'Hochzeit');
    await pause(5);
    tracker.createJob(name: 'Anderes');
    tracker.assignSource(wedding.id, const LrSource(kind: 'collection', key: '77', name: 'Hochzeit Auswahl'));

    await openMenu();
    expect(labels().first, 'Anderes');
    expect(model().menu.any((item) => item.highlighted), isFalse);

    plugin.userOpensSource('collection', 'Hochzeit Auswahl', '77');
    await until(() => model().menu.isNotEmpty && model().menu.first.highlighted, 'suggestion on the device');
    expect(labels().first, 'Hochzeit');
    expect(labels().where((l) => l == 'Hochzeit'), hasLength(1));
    expect(tracker.currentSource!.name, 'Hochzeit Auswahl');

    plugin.userOpensSource('folder', '2026', '/Fotos/2026');
    await until(() => !model().menu.any((item) => item.highlighted), 'suggestion gone');
  });

  test('a rename in the app reaches the open menu; a start from the app reaches the device', () async {
    final job = tracker.createJob(name: 'Erst');
    await openMenu();
    expect(labels().first, 'Erst');
    tracker.updateJob(job.id, name: 'Erst', short: 'Kürzel', client: '', color: null);
    await until(() => labels().first == 'Kürzel', 'new label');

    tracker.start(job.id, origin: 'app');
    await until(() => model().timerRunning && model().timerLabel == 'Kürzel', 'clock from the app');
    await until(() => labels().first == 'Stopp', 'stop line appears');
  });

  test('a click on a page that was replaced meanwhile is ignored', () async {
    tracker.createJob(name: 'A');
    await openMenu();
    final stalePage = MenuSelect(0, 0); // page numbers start above 0
    device.model.emit(stalePage);
    await pause();
    expect(tracker.running, isNull);
    expect(model().menuOpen, isTrue);
  });

  test('starting an archived job from a stale page reports an error', () async {
    final job = tracker.createJob(name: 'Alt');
    await openMenu();
    // Archive behind the device's back: no change event, the page is stale.
    db.setArchived(job.id, true);
    await choose('Alt');
    await until(() => model().notice != null, 'result');
    expect(model().notice!.code, TimerResult.error);
    expect(model().notice!.text, 'Archiviert');
    expect(tracker.running, isNull);
    expect(model().menuOpen, isFalse);
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
