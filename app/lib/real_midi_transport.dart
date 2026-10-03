import 'dart:async';
import 'dart:typed_data';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart' as fmc;

/// USB-MIDI through flutter_midi_command. Only ports that may be a Darkdial
/// are opened (detection stage 1, see [mayBeDarkdial]); other MIDI devices
/// are never touched.
class FlutterMidiTransport implements MidiTransport {
  final fmc.MidiCommand _midi = fmc.MidiCommand();
  final StreamController<MidiConnection> _connections = StreamController<MidiConnection>();
  final Map<String, _Port> _ports = {};
  StreamSubscription<fmc.MidiPacket>? _packets;
  StreamSubscription<fmc.MidiSetupChange>? _setup;
  bool _scanning = false;
  bool _rescan = false;

  @override
  Stream<MidiConnection> get connections => _connections.stream;

  @override
  Future<void> start() async {
    _packets = _midi.onMidiPacketReceived?.listen((packet) {
      _ports[packet.device.id]?._input.add(Uint8List.fromList(packet.data));
    });
    _setup = _midi.onMidiSetupChanged?.listen((_) => _scan());
    await _scan();
  }

  /// Opens new Darkdial ports and closes those that disappeared.
  Future<void> _scan() async {
    if (_scanning) {
      _rescan = true;
      return;
    }
    _scanning = true;
    try {
      final List<fmc.MidiDevice> devices;
      try {
        devices = await _midi.devices ?? [];
      } on Object {
        return; // no MIDI on this system right now; the next setup change retries
      }
      final present = <String>{};
      for (final device in devices) {
        if (!mayBeDarkdial(device.name)) continue;
        present.add(device.id);
        if (_ports.containsKey(device.id)) continue;
        try {
          await _midi.connectToDevice(device);
        } on Object {
          continue; // shows up again with the next setup change
        }
        final port = _Port(this, device);
        _ports[device.id] = port;
        _connections.add(port);
      }
      for (final id in _ports.keys.toList()) {
        if (!present.contains(id)) await _ports.remove(id)!._closeInput();
      }
    } finally {
      _scanning = false;
      if (_rescan) {
        _rescan = false;
        unawaited(_scan());
      }
    }
  }

  @override
  Future<void> dispose() async {
    await _packets?.cancel();
    await _setup?.cancel();
    for (final port in _ports.values.toList()) {
      await port.close();
    }
    await _connections.close();
  }
}

class _Port implements MidiConnection {
  _Port(this._transport, this._device);

  final FlutterMidiTransport _transport;
  final fmc.MidiDevice _device;
  final StreamController<Uint8List> _input = StreamController<Uint8List>();

  @override
  String get name => _device.name;

  @override
  Stream<Uint8List> get input => _input.stream;

  @override
  void send(Uint8List message) => _transport._midi.sendData(message, deviceId: _device.id);

  Future<void> _closeInput() async {
    if (!_input.isClosed) await _input.close();
  }

  @override
  Future<void> close() async {
    // Forgetting the port lets the next scan open it again, e.g. after a
    // failed handshake while the device was still booting.
    if (_transport._ports[_device.id] == this) _transport._ports.remove(_device.id);
    _transport._midi.disconnectDevice(_device);
    await _closeInput();
  }
}
