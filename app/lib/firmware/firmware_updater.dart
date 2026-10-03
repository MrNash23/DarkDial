import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:darkdial_core/darkdial_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'flash_procedure.dart';

/// The firmware that came with the app.
class BundledFirmware {
  const BundledFirmware(this.version, this.image);
  final String version;
  final Uint8List image;
}

/// Where an update stands.
class FirmwareUpdateState {
  const FirmwareUpdateState.idle()
      : running = false,
        progress = null,
        done = false,
        error = null,
        failure = null;
  const FirmwareUpdateState.running(FlashProgress this.progress)
      : running = true,
        done = false,
        error = null,
        failure = null;
  const FirmwareUpdateState.done()
      : running = false,
        progress = null,
        done = true,
        error = null,
        failure = null;
  const FirmwareUpdateState.failed(String this.error, [this.failure = FlashFailure.other])
      : running = false,
        progress = null,
        done = false;

  final bool running;
  final FlashProgress? progress;
  final bool done;
  final String? error;
  final FlashFailure? failure;
}

typedef FlashFunction = Future<void> Function(Uint8List image, void Function(FlashProgress progress) onProgress);

/// Loads the bundled firmware and writes it to the device, in a background
/// isolate so the window keeps drawing.
class FirmwareUpdater {
  FirmwareUpdater({FlashFunction? flash, Future<BundledFirmware?> Function()? load})
      : _flash = flash ?? flashInIsolate,
        _load = load ?? _loadAsset;

  final FlashFunction _flash;
  final Future<BundledFirmware?> Function() _load;

  final ValueNotifier<FirmwareUpdateState> state = ValueNotifier(const FirmwareUpdateState.idle());
  BundledFirmware? bundled;

  /// Only macOS has a serial implementation so far.
  static bool get supported => Platform.isMacOS;

  Future<void> init() async {
    bundled = await _load();
  }

  Future<void> update() async {
    final firmware = bundled;
    if (firmware == null || state.value.running) return;
    state.value = const FirmwareUpdateState.running(FlashProgress(FlashStage.connecting));
    try {
      await _flash(firmware.image, (p) => state.value = FirmwareUpdateState.running(p));
      state.value = const FirmwareUpdateState.done();
    } on Object catch (e) {
      state.value = e is FlashException
          ? FirmwareUpdateState.failed(e.message, e.failure)
          : FirmwareUpdateState.failed('$e');
    }
  }

  static Future<BundledFirmware?> _loadAsset() async {
    try {
      final info = jsonDecode(await rootBundle.loadString('assets/firmware/firmware.json')) as Map<String, dynamic>;
      final image = await rootBundle.load('assets/firmware/darkdial-firmware.bin');
      return BundledFirmware(info['version'] as String, image.buffer.asUint8List(image.offsetInBytes, image.lengthInBytes));
    } on Object {
      return null; // a development build without bundled firmware
    }
  }

  /// Runs [flashDevice] in a background isolate and reports its progress here.
  static Future<void> flashInIsolate(Uint8List image, void Function(FlashProgress) onProgress) async {
    final messages = ReceivePort();
    final finished = Completer<void>();
    messages.listen((message) {
      if (message is List && message.length == 2 && message[0] is int) {
        onProgress(FlashProgress(FlashStage.values[message[0] as int], message[1] as double));
      } else if (message == 'done') {
        finished.complete();
      } else if (message is List && message.length == 3 && message[0] == 'error') {
        finished.completeError(FlashException(message[2] as String, FlashFailure.values[message[1] as int]));
      } else {
        finished.completeError(FlashException('$message'));
      }
    });
    await Isolate.spawn(_entry, (image, messages.sendPort), onError: messages.sendPort);
    try {
      await finished.future;
    } finally {
      messages.close();
    }
  }

  static Future<void> _entry((Uint8List, SendPort) args) async {
    final (image, reply) = args;
    try {
      await flashDevice(image, onProgress: (p) => reply.send([p.stage.index, p.fraction]));
      reply.send('done');
    } on FlashException catch (e) {
      reply.send(['error', e.failure.index, e.message]);
    } on Object catch (e) {
      reply.send(['error', FlashFailure.other.index, '$e']);
    }
  }
}

/// True if [a] is an older version than [b] ("0.6.0" < "0.6.1").
bool isOlderVersion(String? a, String? b) {
  if (a == null || b == null) return false;
  List<int> parts(String v) => [for (final p in v.split('.')) int.tryParse(p) ?? 0];
  final x = parts(a), y = parts(b);
  for (var i = 0; i < 3; i++) {
    final l = i < x.length ? x[i] : 0, r = i < y.length ? y[i] : 0;
    if (l != r) return l < r;
  }
  return false;
}
