import 'dart:async';
import 'dart:typed_data';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter_midi_command/flutter_midi_command.dart' as fmc;
import 'package:flutter_midi_command_ble/flutter_midi_command_ble.dart';

/// USB-MIDI, and with [bluetooth] BLE-MIDI, through flutter_midi_command.
/// Only ports that may be a Darkdial are opened (detection stage 1, see
/// [mayBeDarkdial]); other MIDI devices are never touched.
class FlutterMidiTransport implements MidiTransport {
  FlutterMidiTransport({this.bluetooth = false})
      : _midi = fmc.MidiCommand(bleTransport: bluetooth ? UniversalBleMidiTransport() : null) {
    if (!bluetooth) _midi.configureBleTransport(null);
  }

  final bool bluetooth;
  final fmc.MidiCommand _midi;
  Timer? _bluetoothScan;
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
    if (bluetooth) unawaited(_startBluetooth());
  }

  /// Scans for BLE-MIDI devices; found ones show up in the device list.
  /// macOS asks for permission the first time.
  Future<void> _startBluetooth() async {
    try {
      await _midi.startBluetooth();
      await _midi.waitUntilBluetoothIsInitialized();
      await _midi.startScanningForBluetoothDevices();
    } on Object {
      return; // no Bluetooth, or not allowed: USB keeps working
    }
    // The device list does not always announce Bluetooth devices; look again
    // now and then.
    _bluetoothScan = Timer.periodic(const Duration(seconds: 3), (_) => _scan());
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
        final port = device.type == fmc.MidiDeviceType.ble ? _WirelessPort(this, device) : _Port(this, device);
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
    _bluetoothScan?.cancel();
    if (bluetooth) {
      try {
        _midi.stopScanningForBluetoothDevices();
      } on Object {
        // Bluetooth never started.
      }
    }
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

/// A Darkdial reached over Bluetooth.
class _WirelessPort extends _Port implements WirelessMidiConnection {
  _WirelessPort(super.transport, super.device);
}
