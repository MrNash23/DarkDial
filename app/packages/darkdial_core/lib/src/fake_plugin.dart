import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'lightroom_link.dart';
import 'params.g.dart';

/// Stand-in for the Lightroom plugin: same ports, same messages, values kept
/// in memory. Used by the tests and by `dart run darkdial_core:fake_lr` to run
/// the app without Lightroom.
class FakePlugin {
  FakePlugin({this.module = 'develop', this.photoId = 1, this.proto = lrProtocolVersion}) {
    for (final p in kParams) {
      ranges[p.lr] = [p.min, p.max];
      values[p.lr] = p.lr == 'Temperature' ? 5500 : (p.min < 0 ? 0 : p.min);
    }
    defaults.addAll(values);
  }

  String module;
  int? photoId;
  final String proto;
  final Map<String, double> values = {};

  /// What `reset` restores.
  final Map<String, double> defaults = {};

  /// The collection or folder on screen: kind, name, id. Null = none.
  ({String kind, String name, String id})? source;
  final Map<String, List<double>> ranges = {};
  List<String> watched = [];

  /// Every message received from the service, for assertions.
  final List<Map<String, dynamic>> received = [];

  /// Called for every received message, e.g. for logging.
  void Function(Map<String, dynamic> message)? onReceived;

  /// Delay before a set is applied and answered, to imitate a busy Lightroom.
  Duration setDelay = Duration.zero;

  ServerSocket? _toService;
  ServerSocket? _fromService;
  Socket? _out;
  final List<Socket> _sockets = [];

  int get toServicePort => _toService!.port;
  int get fromServicePort => _fromService!.port;

  /// Pass 0 to get free ports (tests); the defaults are the real ones.
  Future<void> start({int toService = portFromPlugin, int fromService = portToPlugin}) async {
    _toService = await ServerSocket.bind(InternetAddress.loopbackIPv4, toService);
    _fromService = await ServerSocket.bind(InternetAddress.loopbackIPv4, fromService);
    _toService!.listen((socket) {
      _sockets.add(socket);
      _out = socket;
      socket.listen((_) {}, onError: (_) {}, onDone: () {
        if (_out == socket) _out = null;
      });
    });
    _fromService!.listen((socket) {
      _sockets.add(socket);
      utf8.decoder.bind(socket).transform(const LineSplitter()).listen(_onLine, onError: (_) {});
    });
  }

  Future<void> stop() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
    _out = null;
    await _toService?.close();
    await _fromService?.close();
  }

  /// Drops the service's connections but keeps listening, like a plugin
  /// reload.
  void disconnectClients() {
    for (final socket in _sockets) {
      socket.destroy();
    }
    _sockets.clear();
    _out = null;
  }

  void _send(Map<String, dynamic> message) {
    message.removeWhere((_, value) => value == null);
    _out?.write('${jsonEncode(message)}\n');
  }

  bool get _canEdit => module == 'develop' && photoId != null;

  void _status() => _send({'t': 'status', 'module': module, 'photo': photoId != null, 'photoId': photoId});

  void _source() =>
      _send({'t': 'source', 'kind': source?.kind ?? '', 'name': source?.name ?? '', 'id': source?.id ?? ''});

  /// Reports a slider as moved by the user, without a new value - what a
  /// late observer call in Lightroom looks like to the service.
  void reportsTouched(String param) => _send({'t': 'touched', 'p': param});

  /// Clicks a collection or folder in the Library.
  void userOpensSource(String kind, String name, String id) {
    source = (kind: kind, name: name, id: id);
    _source();
  }

  void _report(String param, {int? seq}) {
    _send({'t': 'value', 'p': param, 'v': values[param], 's': seq});
  }

  void _reportAll() {
    if (!_canEdit) return;
    for (final param in watched) {
      if (!values.containsKey(param)) continue;
      _send({'t': 'range', 'p': param, 'min': ranges[param]![0], 'max': ranges[param]![1]});
      _report(param);
    }
  }

  // What a user does in Lightroom ----------------------------------------------

  /// Moves a slider with the mouse.
  void userSets(String param, double value) {
    values[param] = value;
    if (_canEdit && watched.contains(param)) {
      _report(param);
      _send({'t': 'touched', 'p': param});
    }
  }

  void userSwitchesModule(String name) {
    module = name;
    _status();
    _reportAll();
  }

  void userSelectsPhoto(int? id, {Map<String, List<double>> newRanges = const {}}) {
    photoId = id;
    ranges.addAll(newRanges);
    _status();
    _reportAll();
  }

  // Protocol -------------------------------------------------------------------

  void _onLine(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    received.add(decoded);
    onReceived?.call(decoded);
    final param = decoded['p'];
    switch (decoded['t']) {
      case 'hello':
        _send({'t': 'hello', 'plugin': '0.1.0', 'proto': proto, 'lr': 'fake'});
        _status();
        _source();
      case 'ping':
        _send({'t': 'pong'});
      case 'watch':
        watched = [for (final p in decoded['p'] as List) p as String];
        _reportAll();
      case 'get':
        if (param is String && _canEdit && values.containsKey(param)) {
          _send({'t': 'range', 'p': param, 'min': ranges[param]![0], 'max': ranges[param]![1]});
          _report(param);
        }
      case 'set' || 'delta' || 'reset':
        if (param is! String || !values.containsKey(param) || photoId == null) return;
        final seq = (decoded['s'] as num?)?.toInt();
        final isDelta = decoded['t'] == 'delta';
        final isReset = decoded['t'] == 'reset';
        final amount = isReset ? defaults[param]! : ((isDelta ? decoded['d'] : decoded['v']) as num).toDouble();
        void apply() {
          if (module != 'develop') {
            module = 'develop';
            _status();
          }
          final target = isDelta ? values[param]! + amount : amount;
          values[param] = target.clamp(ranges[param]![0], ranges[param]![1]).toDouble();
          _report(param, seq: seq);
        }
        if (setDelay == Duration.zero) {
          apply();
        } else {
          Timer(setDelay, apply);
        }
    }
  }
}
