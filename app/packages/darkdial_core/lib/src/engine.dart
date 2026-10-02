import 'dart:async';

import 'config.dart';
import 'device_session.dart';
import 'lightroom_link.dart';
import 'midi_codec.dart';
import 'param_def.dart';
import 'value_mapping.dart';

class EngineOptions {
  const EngineOptions({
    this.flushInterval = const Duration(milliseconds: 25),
    this.useTracking = false,
    this.heartbeatInterval = const Duration(seconds: 2),
    this.echoGuard = const Duration(seconds: 1),
  });

  /// Rotation is bundled into one `set` per interval (40 Hz).
  final Duration flushInterval;

  /// Ask Lightroom for tracking mode while a slot is edited.
  final bool useTracking;

  /// Status is repeated to the device at this interval.
  final Duration heartbeatInterval;

  /// How long an unanswered `set` shields a value from older reports.
  final Duration echoGuard;
}

enum DeviceLinkState { disconnected, connected, incompatible }

/// One active slot with its live value.
class SlotState {
  const SlotState({
    required this.settings,
    required this.slot,
    required this.value,
    required this.position,
    required this.text,
  });

  final SlotSettings settings;
  final ConfigSlot slot;

  /// Null while Lightroom has not reported it.
  final double? value;
  final int position;
  final String text;
}

/// Snapshot of everything the UI shows.
class EngineState {
  const EngineState({
    required this.device,
    required this.firmwareVersion,
    required this.deviceSerial,
    required this.lightroomConnected,
    required this.lightroomConflict,
    required this.pluginVersion,
    required this.lightroomVersion,
    required this.module,
    required this.photoSelected,
    required this.activeSlot,
    required this.editing,
    required this.slots,
  });

  final DeviceLinkState device;
  final String? firmwareVersion;
  final String? deviceSerial;
  final bool lightroomConnected;
  final bool lightroomConflict;
  final String? pluginVersion;
  final String? lightroomVersion;
  final String module;
  final bool photoSelected;
  final int activeSlot;
  final bool editing;
  final List<SlotState> slots;

  bool get developActive => module == 'develop';
}

/// The logic between device and plugin: turns detents into values, keeps the
/// device display in sync with Lightroom, pushes the configuration.
class Engine {
  Engine({
    required this.transport,
    required this.lightroom,
    required this._config,
    required this.appVersion,
    this.options = const EngineOptions(),
  });

  final MidiTransport transport;
  final LightroomLink lightroom;
  final List<int> appVersion;
  final EngineOptions options;

  AppConfig _config;
  List<SlotSettings> _active = [];
  List<ConfigSlot> _deviceSlots = [];

  DeviceSession? _session;
  DeviceLinkState _deviceState = DeviceLinkState.disconnected;
  bool _opening = false;
  bool _disposed = false;

  final Map<String, double> _values = {};
  final Map<String, ValueRange> _ranges = {};
  final Map<String, int> _lastSetSeq = {};
  final Map<String, DateTime> _unanswered = {};

  /// What each slot of the device currently shows, to skip repeats.
  final Map<int, String> _shown = {};
  int _seq = 0;

  String _module = '';
  bool _photo = false;
  bool _switchingToDevelop = false;
  int _activeSlot = 0;
  bool _editing = false;
  double _pendingDetents = 0;

  final StreamController<EngineState> _states = StreamController.broadcast();
  final List<StreamSubscription<void>> _subscriptions = [];
  Timer? _flushTimer;
  Timer? _heartbeatTimer;

  Stream<EngineState> get states => _states.stream;

  AppConfig get config => _config;

  EngineState get state => EngineState(
        device: _deviceState,
        firmwareVersion: _session?.hello.firmwareVersion,
        deviceSerial: _session?.hello.serialText,
        lightroomConnected: lightroom.connected,
        lightroomConflict: lightroom.versionConflict,
        pluginVersion: lightroom.pluginVersion,
        lightroomVersion: lightroom.lightroomVersion,
        module: _module,
        photoSelected: _photo,
        activeSlot: _activeSlot,
        editing: _editing,
        slots: [for (var i = 0; i < _active.length; i++) _slotState(i)],
      );

  Future<void> start() async {
    _applyConfig();
    _subscriptions
      ..add(transport.connections.listen(_onConnection))
      ..add(lightroom.changes.listen((_) => _onLightroomChanged()))
      ..add(lightroom.messages.listen(_onLightroomMessage));
    _flushTimer = Timer.periodic(options.flushInterval, (_) => _flush());
    _heartbeatTimer = Timer.periodic(options.heartbeatInterval, (_) => _sendStatus());
    lightroom.start();
    await transport.start();
  }

  Future<void> dispose() async {
    _disposed = true;
    _flushTimer?.cancel();
    _heartbeatTimer?.cancel();
    for (final subscription in List.of(_subscriptions)) {
      await subscription.cancel();
    }
    await _session?.close();
    await transport.dispose();
    await lightroom.stop();
    await _states.close();
  }

  /// Replaces the configuration, re-registers the watched parameters and
  /// transfers the slots to the device.
  Future<bool> updateConfig(AppConfig config) async {
    _config = config;
    _applyConfig();
    _watch();
    final ok = await pushConfig();
    _notify();
    return ok;
  }

  /// Sends the current configuration to the device. False if no device is
  /// connected or it did not confirm.
  Future<bool> pushConfig() async {
    final session = _session;
    if (session == null) return false;
    final ok = await session.sendConfig(_deviceSlots, _config.language);
    if (ok) {
      _shown.clear(); // a new configuration resets the values on the device
      _sendStatus();
      for (var i = 0; i < _active.length; i++) {
        _sendValue(i);
      }
    }
    return ok;
  }

  void _applyConfig() {
    final previous = _activeSlot < _active.length ? _active[_activeSlot].paramId : null;
    _active = _config.activeSlots;
    _deviceSlots = _config.deviceSlots();
    // Same rule as on the device: stay on the parameter if it is still active.
    final kept = _active.indexWhere((s) => s.paramId == previous);
    _activeSlot = kept < 0 ? 0 : kept;
    if (kept < 0) _editing = false;
    _pendingDetents = 0;
  }

  // Device ---------------------------------------------------------------------

  Future<void> _onConnection(MidiConnection connection) async {
    // One device at a time; a second one stays untouched.
    if (_session != null || _opening) return;
    _opening = true;
    final (result, session) = await DeviceSession.open(connection, appVersion: appVersion);
    _opening = false;
    if (_disposed) {
      await session?.close();
      return;
    }
    if (result == HandshakeResult.notDarkdial) return;
    if (session == null) {
      _deviceState = DeviceLinkState.incompatible;
      _notify();
      return;
    }
    _session = session;
    _deviceState = DeviceLinkState.connected;
    _subscriptions.add(session.messages.listen(_onDeviceMessage, onDone: () => _onDeviceGone(session)));
    await pushConfig();
    _notify();
  }

  void _onDeviceGone(DeviceSession session) {
    if (_session != session) return;
    _session = null;
    _deviceState = DeviceLinkState.disconnected;
    _editing = false;
    _pendingDetents = 0;
    session.close();
    _notify();
  }

  void _onDeviceMessage(DeviceMessage message) {
    switch (message) {
      case Rotation(:final delta):
        if (_editing && _activeSlot < _active.length) {
          _pendingDetents += delta * _active[_activeSlot].sensitivity;
        }
      case SlotSelect(:final slot):
        if (slot >= _active.length) return;
        _activeSlot = slot;
        _editing = true;
        _pendingDetents = 0;
        if (options.useTracking) lightroom.send({'t': 'track', 'p': _active[slot].param.lr});
        _notify();
      case SlotLeave(:final slot):
        _flush();
        if (slot < _active.length) _activeSlot = slot;
        _editing = false;
        if (options.useTracking) lightroom.send({'t': 'track', 'p': ''});
        _notify();
      case SlotFocus(:final slot):
        if (slot >= _active.length) return;
        _activeSlot = slot;
        _notify();
      default:
        break;
    }
  }

  /// Turns the detents collected since the last flush into one `set`.
  void _flush() {
    final detents = _pendingDetents.truncate();
    if (detents == 0) return;
    _pendingDetents -= detents;
    if (!_editing || _activeSlot >= _active.length) return;
    final settings = _active[_activeSlot];
    final param = settings.param;
    final current = _values[param.lr];
    if (!lightroom.connected || !_photo || current == null) {
      _pendingDetents = 0;
      return;
    }
    final range = _rangeOf(param);
    final next = applyDetents(param, range, current, detents.toDouble(), stepOverride: settings.step);
    if (next == current) return;

    _values[param.lr] = next;
    final seq = ++_seq;
    _lastSetSeq[param.lr] = seq;
    _unanswered[param.lr] = DateTime.now();
    lightroom.send({'t': 'set', 'p': param.lr, 'v': next, 's': seq});
    if (_module != 'develop' && !_switchingToDevelop) {
      // The plugin switches modules before applying; tell the device why
      // nothing moves for a moment.
      _switchingToDevelop = true;
      _sendStatus();
    }
    _sendValue(_activeSlot);
    _notify();
  }

  void _sendStatus() {
    _session?.send(Status(
      lightroomConnected: lightroom.connected,
      developActive: _module == 'develop',
      photoSelected: _photo,
      notice: _switchingToDevelop ? 1 : 0,
    ));
  }

  void _sendValue(int index) {
    final session = _session;
    if (session == null) return;
    final slot = _slotState(index);
    // The answer to a set usually repeats what was already sent optimistically.
    final signature = '${slot.position}|${slot.value != null}|${slot.text}';
    if (_shown[index] == signature) return;
    _shown[index] = signature;
    session.send(Value(slot: index, position: slot.position, valid: slot.value != null, text: slot.text));
  }

  // Lightroom ------------------------------------------------------------------

  void _onLightroomChanged() {
    if (lightroom.connected) {
      _watch();
    } else {
      _values.clear();
      _ranges.clear();
      _unanswered.clear();
      _module = '';
      _photo = false;
      _switchingToDevelop = false;
      for (var i = 0; i < _active.length; i++) {
        _sendValue(i);
      }
    }
    _sendStatus();
    _notify();
  }

  void _watch() {
    lightroom.send({
      't': 'watch',
      'p': [for (final s in _active) s.param.lr],
    });
  }

  void _onLightroomMessage(Map<String, dynamic> message) {
    final name = message['p'];
    switch (message['t']) {
      case 'status':
        final module = message['module'];
        _module = module is String ? module : '';
        _photo = message['photo'] == true;
        if (_module == 'develop') _switchingToDevelop = false;
        if (!_photo) {
          _values.clear();
          for (var i = 0; i < _active.length; i++) {
            _sendValue(i);
          }
        }
        _sendStatus();
      case 'range':
        final min = message['min'];
        final max = message['max'];
        if (name is! String || min is! num || max is! num) return;
        _ranges[name] = ValueRange(min.toDouble(), max.toDouble());
        _sendValuesOf(name);
      case 'value':
        final value = message['v'];
        if (name is! String || value is! num) return;
        final seq = message['s'];
        if (seq is num) {
          // Answer to one of our sets: only the newest one counts.
          if (seq.toInt() != _lastSetSeq[name]) return;
          _unanswered.remove(name);
        } else {
          // Reported by Lightroom itself. While a set is on its way this is
          // older than what the knob already asked for.
          final pending = _unanswered[name];
          if (pending != null) {
            if (DateTime.now().difference(pending) < options.echoGuard) return;
            _unanswered.remove(name);
          }
        }
        _values[name] = value.toDouble();
        _sendValuesOf(name);
      default:
        return;
    }
    _notify();
  }

  void _sendValuesOf(String lrName) {
    for (var i = 0; i < _active.length; i++) {
      if (_active[i].param.lr == lrName) _sendValue(i);
    }
  }

  // State ----------------------------------------------------------------------

  ValueRange _rangeOf(ParamDef param) => _ranges[param.lr] ?? ValueRange(param.min, param.max);

  SlotState _slotState(int index) {
    final settings = _active[index];
    final param = settings.param;
    final value = _values[param.lr];
    final range = _rangeOf(param);
    return SlotState(
      settings: settings,
      slot: _deviceSlots[index],
      value: value,
      position: value == null ? (param.bipolar ? positionCentre : 0) : ringPosition(param, range, value),
      text: value == null ? '--' : formatValue(param, range, value),
    );
  }

  void _notify() {
    if (!_states.isClosed) _states.add(state);
  }
}
