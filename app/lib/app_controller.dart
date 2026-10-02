import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'plugin_installer.dart';
import 'real_midi_transport.dart';
import 'strings.dart';
import 'version.dart';

/// Position of the colour dot inside the HSL icons, relative to the icon size.
class HslDot {
  const HslDot(this.x, this.y, this.radius);
  final double x;
  final double y;
  final double radius;
}

/// Everything the UI binds to: settings, the running engine and its state,
/// plugin installation and the login item.
/// Sections of the main window, in the order of the navigation rail.
const int sectionSliders = 0;
const int sectionLibrary = 1;
const int sectionTime = 2;
const int sectionInfo = 3;

class AppController extends ChangeNotifier {
  static const MethodChannel _loginItem = MethodChannel('darkdial/login_item');

  /// The optional arguments replace the real environment in tests.
  AppController({PluginInstaller? installer, Directory? settingsDirectory, LightroomLink Function()? lightroom})
      : installer = installer ?? PluginInstaller(),
        _settingsDirectory = settingsDirectory, // ignore: prefer_initializing_formals
        _lightroom = lightroom ?? (() => LightroomLink(appVersion: appVersionText));

  final PluginInstaller installer;
  final Directory? _settingsDirectory;
  final LightroomLink Function() _lightroom;

  AppConfig config = AppConfig.defaults();
  bool useSimulator = false;

  /// True until the first settings file has been written.
  bool firstRun = false;

  /// Jobs and the clock. Lives as long as the app, across engine restarts.
  late final TimeDatabase _timeDatabase;
  late final TimeTracker tracker;
  late final Reports reports;
  StreamSubscription<void>? _trackerChanges;
  Timer? _secondTimer;

  /// Counts up once a second while a clock runs, for widgets that show it.
  final ValueNotifier<int> clockTick = ValueNotifier<int>(0);

  /// Section of the window: 0 device, 1 time tracking, 2 info.
  final ValueNotifier<int> section = ValueNotifier<int>(sectionSliders);

  Engine? _engine;
  SimulatedDevice? _simulator;
  StreamSubscription<EngineState>? _states;
  File? _settingsFile;

  String? installedPluginVersion;
  String bundledPluginVersion = '';
  bool launchAtLogin = false;
  bool pluginJustInstalled = false;
  HslDot hslDot = const HslDot(0.5, 0.11, 0.07);

  Strings get strings => Strings(config.language);
  EngineState get state => _engine!.state;
  bool get ready => _engine != null;

  /// The simulated device while the simulator is in use, for knob input.
  DeviceModel? get simulatorModel => _simulator?.model;

  /// True if an installed plugin is older than the bundled one. A newer one
  /// (development install) is left alone.
  bool get pluginOutdated {
    final installed = installedPluginVersion;
    if (installed == null) return false;
    List<int> parts(String v) => [for (final p in v.split('.')) int.tryParse(p) ?? 0];
    final a = parts(installed);
    final b = parts(bundledPluginVersion);
    for (var i = 0; i < 3; i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }

  Future<void> init() async {
    final directory = _settingsDirectory ?? await getApplicationSupportDirectory();
    _settingsFile = File(p.join(directory.path, 'settings.json'));
    await _load();

    await directory.create(recursive: true);
    _timeDatabase = TimeDatabase.open(p.join(directory.path, 'time.sqlite'));
    tracker = TimeTracker(_timeDatabase)..startHeartbeat();
    reports = Reports(tracker);
    _trackerChanges = tracker.changes.listen((_) => notifyListeners());
    _secondTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (tracker.running != null) clockTick.value++;
    });

    try {
      final dot = jsonDecode(await rootBundle.loadString('assets/icons/hsl_dot.json')) as Map<String, dynamic>;
      hslDot = HslDot(
        (dot['x'] as num).toDouble(),
        (dot['y'] as num).toDouble(),
        (dot['radius'] as num).toDouble(),
      );
    } on Object {
      // Keep the built-in position.
    }

    bundledPluginVersion = await installer.bundledVersion();
    installedPluginVersion = await installer.installedVersion();
    // An installed plugin is kept current; installing it the first time is
    // the user's decision in the setup dialog.
    if (pluginOutdated) await installPlugin();
    launchAtLogin = await _queryLoginItem();

    await _startEngine();
  }

  Future<void> _load() async {
    final file = _settingsFile!;
    if (!await file.exists()) {
      firstRun = true;
      return;
    }
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // The simulator replaces the real device, so a released app never uses
      // it, whatever an old settings file says.
      useSimulator = kDebugMode && json['simulator'] == true;
      final stored = json['config'];
      if (stored is Map<String, dynamic>) config = AppConfig.fromJson(stored);
    } on Object {
      // A damaged file falls back to the defaults and is overwritten on the
      // next change.
    }
  }

  Future<void> _save() async {
    final file = _settingsFile!;
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString(encoder.convert({'simulator': useSimulator, 'config': config.toJson()}));
    firstRun = false;
  }

  Future<void> _startEngine() async {
    await _states?.cancel();
    await _engine?.dispose();
    _simulator = useSimulator ? SimulatedDevice() : null;
    // Menu and notices exist only on the device; repaint the preview for them.
    _simulator?.model.onChanged = notifyListeners;
    final engine = Engine(
      transport: useSimulator ? SimulatedTransport(_simulator!) : FlutterMidiTransport(),
      lightroom: _lightroom(),
      config: config,
      appVersion: appVersion,
      timeTracker: tracker,
    );
    _engine = engine;
    _states = engine.states.listen((_) => notifyListeners());
    await engine.start();
    notifyListeners();
  }

  /// Applies an edited configuration: saved, watched in Lightroom and
  /// transferred to the device.
  Future<void> setConfig(AppConfig next) async {
    config = next;
    notifyListeners();
    await _save();
    // Two changes in quick succession may finish saving in either order; the
    // engine always gets the latest one.
    await _engine?.updateConfig(config);
  }

  /// "Send to device": true if the device confirmed.
  Future<bool> sendToDevice() async => await _engine?.pushConfig() ?? false;

  Future<void> setUseSimulator(bool value) async {
    if (value == useSimulator) return;
    useSimulator = value;
    await _save();
    await _startEngine();
  }

  // Slot editing -----------------------------------------------------------------

  void setEnabled(int paramId, bool enabled) {
    final slots = [
      for (final s in config.slots) s.paramId == paramId ? s.copyWith(enabled: enabled) : s,
    ];
    setConfig(config.copyWith(slots: slots));
  }

  void updateSlot(SlotSettings slot) {
    final slots = [for (final s in config.slots) s.paramId == slot.paramId ? slot : s];
    setConfig(config.copyWith(slots: slots));
  }

  /// Moves an enabled slot from position [from] to position [to] in the list
  /// of enabled slots.
  void reorderActive(int from, int to) {
    final active = config.slots.where((s) => s.enabled).toList();
    final inactive = config.slots.where((s) => !s.enabled).toList();
    active.insert(to, active.removeAt(from));
    setConfig(config.copyWith(slots: [...active, ...inactive]));
  }

  void setLanguage(Language language) => setConfig(config.copyWith(language: language));

  // Plugin and login item -------------------------------------------------------

  Future<void> installPlugin() async {
    await installer.install();
    installedPluginVersion = await installer.installedVersion();
    pluginJustInstalled = true;
    notifyListeners();
  }

  /// First-run setup: plugin and login item.
  Future<void> setUp() async {
    await installPlugin();
    await setLaunchAtLogin(true);
    await _save();
    notifyListeners();
  }

  void dismissSetup() {
    _save().then((_) => notifyListeners());
  }

  /// Removes the plugin and the login item again.
  Future<void> uninstall() async {
    await installer.uninstall();
    installedPluginVersion = null;
    pluginJustInstalled = false;
    await setLaunchAtLogin(false);
    notifyListeners();
  }

  Future<bool> _queryLoginItem() async {
    try {
      return await _loginItem.invokeMethod<bool>('isEnabled') ?? false;
    } on Object {
      return false; // no login item support on this platform yet
    }
  }

  Future<void> setLaunchAtLogin(bool enabled) async {
    try {
      launchAtLogin = await _loginItem.invokeMethod<bool>('setEnabled', enabled) ?? false;
    } on Object {
      launchAtLogin = await _queryLoginItem();
    }
    notifyListeners();
  }

  // Time tracking ----------------------------------------------------------------

  /// Runs a tracker action; a rule violation comes back as its message.
  String? track(void Function() action) {
    try {
      action();
      return null;
    } on TimeTrackingError catch (error) {
      return error.message;
    }
  }

  /// Asks where to save a file; replaced in tests.
  Future<String?> Function(String suggestedName) savePathPicker = (suggestedName) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    return location?.path;
  };

  /// Writes the CSV export to a file the user picks. Returns its path, null
  /// if cancelled.
  Future<String?> exportCsv({DateTime? from, DateTime? to, Set<int>? jobIds, required Rounding rounding}) async {
    final path = await savePathPicker('darkdial-zeiten.csv');
    if (path == null) return null;
    final csv = reports.exportCsv(from: from, to: to, jobIds: jobIds, rounding: rounding, header: strings.csvHeader);
    await File(path).writeAsString(csv);
    return path;
  }

  /// Unnamed jobs created on the device, waiting for a name.
  List<Job> get unnamedJobs => tracker.jobs().where((job) => job.unnamed).toList();

  /// Jobs and clients without a name, together.
  int get unnamedCount => unnamedJobs.length + tracker.clients().where((client) => client.unnamed).length;

  String clientTitle(Client client) => client.unnamed
      ? '${strings.unnamed} · ${tracker.clientLabel(client, word: strings.client)}'
      : client.name;

  /// Back to how the app was on its first start: no jobs, clients or times,
  /// the default controls. Plugin and login item are left alone.
  Future<void> factoryReset() async {
    tracker.wipe();
    config = AppConfig.defaults(config.language);
    notifyListeners();
    await _save();
    await _engine?.updateConfig(config);
  }

  String jobTitle(Job job) => job.unnamed ? '${strings.unnamed} · ${tracker.displayLabel(job)}' : job.name;

  bool _shutDown = false;

  Future<void> shutdown() async {
    if (_shutDown) return;
    _shutDown = true;
    _secondTimer?.cancel();
    await _trackerChanges?.cancel();
    await _states?.cancel();
    await _engine?.dispose();
    await tracker.dispose();
    _timeDatabase.close();
  }
}
