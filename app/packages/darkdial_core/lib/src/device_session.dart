import 'dart:async';
import 'dart:typed_data';

import 'midi_codec.dart';
import 'param_def.dart';

/// One opened MIDI port, whatever is behind it.
abstract class MidiConnection {
  /// Port name as reported by the system.
  String get name;

  /// Raw incoming bytes in arbitrary chunks. Closes when the port disappears.
  Stream<Uint8List> get input;

  /// Sends one complete MIDI message.
  void send(Uint8List message);

  Future<void> close();
}

/// Source of MIDI ports that might be a Darkdial.
abstract class MidiTransport {
  /// Emits every port that appears, already opened. Ports present at
  /// [start] are emitted too.
  Stream<MidiConnection> get connections;

  Future<void> start();

  Future<void> dispose();
}

enum HandshakeResult {
  ok,

  /// Not a Darkdial: wrong name or no identity reply.
  notDarkdial,

  /// A Darkdial, but it speaks another protocol major version.
  incompatible,
}

/// A device that passed the three-stage detection of PROTOCOL.md 1.6.
class DeviceSession {
  DeviceSession._(this._connection, this._messages, this._subscription);

  final MidiConnection _connection;
  final StreamController<DeviceMessage> _messages;
  final StreamSubscription<Uint8List> _subscription;

  late final IdentityReply identity;
  late final Hello hello;

  /// Messages from the device after the handshake. Closes when the device is
  /// unplugged.
  Stream<DeviceMessage> get messages => _messages.stream;

  /// Runs the detection on [connection]. On [HandshakeResult.ok] the session
  /// is returned and owns the connection; otherwise the connection is closed.
  static Future<(HandshakeResult, DeviceSession?)> open(
    MidiConnection connection, {
    required List<int> appVersion,
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (!connection.name.toLowerCase().contains('darkdial')) {
      await connection.close();
      return (HandshakeResult.notDarkdial, null);
    }
    final parser = MidiStreamParser();
    final messages = StreamController<DeviceMessage>.broadcast();
    final subscription = connection.input.listen(
      (chunk) {
        for (final raw in parser.add(chunk)) {
          final message = decodeMessage(raw);
          if (message != null) messages.add(message);
        }
      },
      onDone: messages.close,
    );
    final session = DeviceSession._(connection, messages, subscription);

    Future<T?> ask<T extends DeviceMessage>(DeviceMessage request) async {
      final reply = messages.stream.where((m) => m is T).cast<T?>().first;
      connection.send(encodeMessage(request));
      return reply.timeout(timeout, onTimeout: () => null).catchError((_) => null);
    }

    final identity = await ask<IdentityReply>(const IdentityRequest());
    if (identity == null) {
      await session.close();
      return (HandshakeResult.notDarkdial, null);
    }
    final hello = await ask<Hello>(
      HelloRequest(protocolMajor, protocolMinor, appVersion[0], appVersion[1], appVersion[2]),
    );
    // A device with another major version frames its Hello differently, so it
    // does not decode: identity without Hello means incompatible.
    if (hello == null || hello.major != protocolMajor) {
      await session.close();
      return (HandshakeResult.incompatible, null);
    }
    session
      ..identity = identity
      ..hello = hello;
    return (HandshakeResult.ok, session);
  }

  void send(DeviceMessage message) => _connection.send(encodeMessage(message));

  /// Transfers the configuration and waits for the device to confirm it.
  Future<bool> sendConfig(
    List<ConfigSlot> slots,
    Language language, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final ack = messages.where((m) => m is ConfigAck).cast<ConfigAck?>().first;
    send(ConfigBegin(slots.length, language.index));
    slots.forEach(send);
    final crc = configCrc(slots);
    send(ConfigEnd(crc));
    final result = await ack.timeout(timeout, onTimeout: () => null).catchError((_) => null);
    return result != null && result.result == 0 && result.crc == crc;
  }

  Future<void> close() async {
    await _subscription.cancel();
    if (!_messages.isClosed) await _messages.close();
    await _connection.close();
  }
}
