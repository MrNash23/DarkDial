import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int portFromPlugin = 54770;
const int portToPlugin = 54771;
const String lrProtocolVersion = '1.3';

/// Connection to the Lightroom plugin, PROTOCOL.md section 2. Connects to the
/// plugin's two ports and keeps trying for as long as it runs: Lightroom may
/// be started or quit at any time.
class LightroomLink {
  LightroomLink({
    required this.appVersion,
    this.host = '127.0.0.1',
    this.fromPluginPort = portFromPlugin,
    this.toPluginPort = portToPlugin,
    this.retryInterval = const Duration(seconds: 1),
    this.pingInterval = const Duration(seconds: 2),
    this.deadAfter = const Duration(seconds: 6),
  });

  final String appVersion;
  final String host;
  final int fromPluginPort;
  final int toPluginPort;
  final Duration retryInterval;
  final Duration pingInterval;
  final Duration deadAfter;

  final StreamController<Map<String, dynamic>> _messages = StreamController.broadcast();
  final StreamController<void> _changes = StreamController.broadcast();

  Socket? _rx;
  Socket? _tx;
  StreamSubscription<String>? _rxLines;
  Timer? _helloTimer;
  Timer? _pingTimer;
  Timer? _retryTimer;
  DateTime _lastReceived = DateTime.now();
  bool _running = false;
  bool _connecting = false;

  /// True once the plugin answered hello with a compatible version.
  bool connected = false;

  /// True if the plugin answered with another protocol major version.
  bool versionConflict = false;
  String? pluginVersion;
  String? lightroomVersion;

  /// Minor protocol version of the plugin; newer features depend on it.
  int pluginProtocolMinor = 0;

  /// Messages from the plugin except `hello` and `pong`.
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  /// Fires when [connected], [versionConflict] or the versions change.
  Stream<void> get changes => _changes.stream;

  void start() {
    if (_running) return;
    _running = true;
    _connect();
  }

  Future<void> stop() async {
    _running = false;
    _retryTimer?.cancel();
    await _drop(notify: false);
    await _messages.close();
    await _changes.close();
  }

  /// Sends a message; silently dropped while not connected.
  void send(Map<String, dynamic> message) {
    if (connected) _write(message);
  }

  void _write(Map<String, dynamic> message) {
    try {
      _tx?.write('${jsonEncode(message)}\n');
    } on Object {
      // The socket died; the done handler reconnects.
    }
  }

  Future<void> _connect() async {
    if (!_running || _connecting) return;
    _connecting = true;
    Socket? rx;
    Socket? tx;
    try {
      rx = await Socket.connect(host, fromPluginPort, timeout: retryInterval);
      tx = await Socket.connect(host, toPluginPort, timeout: retryInterval);
    } on Object {
      rx?.destroy();
      tx?.destroy();
      _connecting = false;
      _scheduleRetry();
      return;
    }
    _connecting = false;
    if (!_running) {
      rx.destroy();
      tx.destroy();
      return;
    }
    rx.setOption(SocketOption.tcpNoDelay, true);
    tx.setOption(SocketOption.tcpNoDelay, true);
    _rx = rx;
    _tx = tx;
    _lastReceived = DateTime.now();
    _rxLines = utf8.decoder.bind(rx).transform(const LineSplitter()).listen(
          _onLine,
          onError: (_) => _reconnect(),
          onDone: _reconnect,
        );
    // Errors on the write side surface on done; without a listener they
    // would be unhandled.
    unawaited(tx.done.then((_) => _reconnect(), onError: (_) => _reconnect()));
    tx.listen((_) {}, onError: (_) {}, onDone: _reconnect);

    // The plugin drops its answer while its own send socket is still
    // connecting, so hello is repeated until it is answered.
    _sendHello();
    _helloTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (connected || versionConflict) {
        _helloTimer?.cancel();
      } else {
        _sendHello();
      }
    });
    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (DateTime.now().difference(_lastReceived) > deadAfter) {
        _reconnect();
      } else if (connected) {
        _write({'t': 'ping'});
      }
    });
  }

  void _sendHello() => _write({'t': 'hello', 'app': appVersion, 'proto': lrProtocolVersion});

  void _onLine(String line) {
    _lastReceived = DateTime.now();
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    switch (decoded['t']) {
      case 'hello':
        pluginVersion = decoded['plugin'] as String?;
        lightroomVersion = decoded['lr'] as String?;
        final proto = decoded['proto'];
        final compatible = proto is String && proto.split('.').first == lrProtocolVersion.split('.').first;
        final parts = proto is String ? proto.split('.') : const <String>[];
        pluginProtocolMinor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
        versionConflict = !compatible;
        final wasConnected = connected;
        connected = compatible;
        if (connected != wasConnected || versionConflict) _changes.add(null);
      case 'pong':
        break;
      default:
        if (connected) _messages.add(decoded);
    }
  }

  void _reconnect() {
    if (_rx == null && _tx == null) return;
    _drop(notify: true).then((_) => _scheduleRetry());
  }

  void _scheduleRetry() {
    if (!_running) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(retryInterval, _connect);
  }

  Future<void> _drop({required bool notify}) async {
    _helloTimer?.cancel();
    _pingTimer?.cancel();
    final rx = _rx;
    final tx = _tx;
    _rx = null;
    _tx = null;
    await _rxLines?.cancel();
    _rxLines = null;
    rx?.destroy();
    tx?.destroy();
    final changed = connected || versionConflict;
    connected = false;
    versionConflict = false;
    if (notify && changed && !_changes.isClosed) _changes.add(null);
  }
}
