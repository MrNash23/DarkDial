/// A Darkdial in software. [DeviceModel] is the same state machine the
/// firmware runs (firmware/darkdial/src/core/state.*); [SimulatedDevice] puts
/// it behind the real MIDI wire format so the service cannot tell it from
/// hardware.
library;

import 'dart:async';
import 'dart:typed_data';

import 'device_session.dart';
import 'midi_codec.dart';
import 'params.g.dart';

enum DeviceMode { select, edit }

class SlotValue {
  const SlotValue({this.position = 0, this.valid = false, this.text = ''});
  final int position;
  final bool valid;
  final String text;
}

/// State machine of the device: carousel, edit mode, configuration transfer.
class DeviceModel {
  DeviceModel() {
    _loadDefaults();
  }

  static const Duration heartbeatTimeout = Duration(seconds: 5);

  List<ConfigSlot> slots = [];
  List<SlotValue> values = [];
  DeviceMode mode = DeviceMode.select;
  int index = 0;
  Status status = const Status(lightroomConnected: false, developActive: false, photoSelected: false);

  /// False until a Status arrives, and again when the heartbeat stops.
  bool serviceConnected = false;

  List<ConfigSlot>? _incoming;
  int _incomingCount = 0;

  /// Messages the device wants to send; set by the owner.
  void Function(DeviceMessage message) emit = (_) {};

  /// Called after every state change, for repainting.
  void Function() onChanged = () {};

  void _loadDefaults() {
    final defaults = kParams.where((p) => p.defaultActive).toList();
    slots = [
      for (var i = 0; i < defaults.length; i++)
        ConfigSlot(
          index: i,
          paramId: defaults[i].id,
          iconId: defaults[i].icon,
          bipolar: defaults[i].bipolar,
          color: defaults[i].color ?? 0,
          label: defaults[i].en,
        ),
    ];
    values = List.filled(slots.length, const SlotValue());
  }

  /// Turns the knob by [detents].
  void rotate(int detents) {
    if (detents == 0 || slots.isEmpty) return;
    if (mode == DeviceMode.select) {
      index = (index + detents) % slots.length;
      emit(SlotFocus(index));
      onChanged();
    } else {
      emit(Rotation(detents.clamp(-63, 63)));
    }
  }

  /// Knob click or tap on the display.
  void click() {
    if (slots.isEmpty) return;
    if (mode == DeviceMode.select) {
      mode = DeviceMode.edit;
      emit(SlotSelect(index));
    } else {
      mode = DeviceMode.select;
      emit(SlotLeave(index));
    }
    onChanged();
  }

  void heartbeatLost() {
    serviceConnected = false;
    onChanged();
  }

  /// Handles a message from the service.
  void handle(DeviceMessage message, {List<int> serial = const [0, 0, 0, 0, 0, 0]}) {
    switch (message) {
      case IdentityRequest():
        emit(const IdentityReply(1, 0, 1, 0));
      case HelloRequest():
        emit(Hello(
          major: protocolMajor,
          minor: protocolMinor,
          fwMajor: 0,
          fwMinor: 1,
          fwPatch: 0,
          serial: serial,
          configCrc: configCrc(slots),
        ));
      case ConfigBegin(:final slotCount):
        if (slotCount < 1 || slotCount > maxSlots) {
          _incoming = null;
          emit(const ConfigAck(2, 0));
        } else {
          _incoming = [];
          _incomingCount = slotCount;
        }
      case ConfigSlot():
        final incoming = _incoming;
        if (incoming == null) return;
        if (message.index != incoming.length || incoming.length >= _incomingCount) {
          _incoming = null;
          emit(const ConfigAck(3, 0));
        } else {
          incoming.add(message);
        }
      case ConfigEnd(:final crc):
        final incoming = _incoming;
        _incoming = null;
        if (incoming == null || incoming.length != _incomingCount) {
          emit(const ConfigAck(3, 0));
          return;
        }
        final actual = configCrc(incoming);
        if (actual != crc) {
          emit(ConfigAck(1, actual));
          return;
        }
        // Stay on the same parameter if it is still there.
        final previous = slots.isEmpty ? -1 : slots[index].paramId;
        slots = incoming;
        values = List.filled(slots.length, const SlotValue());
        final kept = slots.indexWhere((s) => s.paramId == previous);
        index = kept < 0 ? 0 : kept;
        if (kept < 0 && mode == DeviceMode.edit) mode = DeviceMode.select;
        emit(ConfigAck(0, actual));
        onChanged();
      case Value():
        if (message.slot < values.length) {
          values[message.slot] = SlotValue(position: message.position, valid: message.valid, text: message.text);
          onChanged();
        }
      case Status():
        status = message;
        serviceConnected = true;
        onChanged();
      default:
        break;
    }
  }
}

/// [DeviceModel] behind an in-process MIDI connection.
class SimulatedDevice implements MidiConnection {
  SimulatedDevice({this.serial = const [0x02, 0x00, 0x51, 0x4D, 0x00, 0x01]}) {
    model.emit = (message) {
      if (_opened && !_input.isClosed) _input.add(encodeMessage(message));
    };
  }

  final DeviceModel model = DeviceModel();
  final List<int> serial;
  final MidiStreamParser _parser = MidiStreamParser();
  StreamController<Uint8List> _input = StreamController<Uint8List>();
  Timer? _heartbeat;
  bool _opened = false;

  @override
  String get name => 'Darkdial (Simulator)';

  @override
  Stream<Uint8List> get input => _input.stream;

  /// Makes the device usable for a new session, like plugging it in again.
  void open() {
    if (_input.isClosed || _input.hasListener) _input = StreamController<Uint8List>();
    _opened = true;
  }

  @override
  void send(Uint8List message) {
    if (!_opened) return;
    for (final raw in _parser.add(message)) {
      final decoded = decodeMessage(raw);
      if (decoded == null) continue;
      if (decoded is Status) {
        _heartbeat?.cancel();
        _heartbeat = Timer(DeviceModel.heartbeatTimeout, model.heartbeatLost);
      }
      model.handle(decoded, serial: serial);
    }
  }

  @override
  Future<void> close() async {
    _opened = false;
    _heartbeat?.cancel();
    model.heartbeatLost();
    if (!_input.isClosed) await _input.close();
  }
}

/// Transport that offers exactly one [SimulatedDevice].
class SimulatedTransport implements MidiTransport {
  SimulatedTransport(this.device);

  final SimulatedDevice device;
  final StreamController<MidiConnection> _connections = StreamController<MidiConnection>();

  @override
  Stream<MidiConnection> get connections => _connections.stream;

  @override
  Future<void> start() async {
    device.open();
    _connections.add(device);
  }

  @override
  Future<void> dispose() async {
    await device.close();
    await _connections.close();
  }
}
