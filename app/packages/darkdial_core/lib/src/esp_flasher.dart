/// Writes firmware to the ESP32-S3 through its built-in serial bootloader
/// (the protocol esptool speaks), so the desktop app can update the device
/// without Python or esptool.
///
/// The bootloader lives in the chip's ROM: an interrupted update leaves a
/// device that can always be flashed again.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A serial connection to the bootloader. The app implements it with
/// libserialport; the tests with a simulated ROM.
abstract class SerialLink {
  Future<void> write(List<int> bytes);

  /// Bytes that arrived, waiting at most [timeout] for the first one. Empty
  /// if none came.
  Future<List<int>> read(Duration timeout);

  /// Sets the modem lines; on the chip's USB port RTS resets it.
  Future<void> setSignals({required bool dtr, required bool rts});
}

/// Why an update did not finish, for a message in the user's language.
enum FlashFailure { notFound, portBusy, noBootloader, connectionLost, verifyFailed, other }

class FlashException implements Exception {
  FlashException(this.message, [this.failure = FlashFailure.other]);
  final String message;
  final FlashFailure failure;
  @override
  String toString() => 'FlashException: $message';
}

/// One stretch of flash to write.
class FlashRegion {
  const FlashRegion(this.offset, this.data);
  final int offset;
  final Uint8List data;
}

/// Splits a merged image (written at 0) into the regions an update writes.
/// The NVS partition, where the device keeps its configuration and the angle
/// of its picture, is left out so an update does not reset them. Trailing
/// 0xFF of each region (erased flash anyway) is not sent.
List<FlashRegion> updateRegions(Uint8List merged, {int nvsOffset = 0x9000, int nvsEnd = 0xE000}) {
  Uint8List trim(Uint8List data) {
    var end = data.length;
    while (end > 0 && data[end - 1] == 0xFF) {
      end--;
    }
    // Writes go in blocks; keep whole 4-byte words.
    end = (end + 3) & ~3;
    return Uint8List.sublistView(data, 0, end.clamp(0, data.length));
  }

  final regions = <FlashRegion>[];
  if (merged.isNotEmpty) {
    regions.add(FlashRegion(0, trim(Uint8List.sublistView(merged, 0, merged.length.clamp(0, nvsOffset)))));
  }
  if (merged.length > nvsEnd) {
    regions.add(FlashRegion(nvsEnd, trim(Uint8List.sublistView(merged, nvsEnd))));
  }
  return [for (final r in regions) if (r.data.isNotEmpty) r];
}

/// What the flasher is doing, for a progress display.
enum FlashStage { connecting, erasing, writing, verifying, restarting, done }

class FlashProgress {
  const FlashProgress(this.stage, [this.fraction = 0]);
  final FlashStage stage;

  /// 0 … 1 over the whole write.
  final double fraction;
}

class EspFlasher {
  EspFlasher(this.link, {this.blockSize = 0x400});

  final SerialLink link;

  /// Bytes per FLASH_DATA; the ROM loader takes 1 KB.
  final int blockSize;

  static const int _sync = 0x08;
  static const int _flashBegin = 0x02;
  static const int _flashData = 0x03;
  static const int _spiSetParams = 0x0B;
  static const int _spiAttach = 0x0D;
  static const int _spiFlashMd5 = 0x13;
  static const int _writeReg = 0x09;

  // ESP32-S3 registers used to leave the bootloader (as esptool does).
  static const int _rtcOption1 = 0x6000812C; // bit 0: force download boot
  static const int _rtcWdtConfig0 = 0x60008098;
  static const int _rtcWdtConfig1 = 0x6000809C;
  static const int _rtcWdtProtect = 0x600080B0;
  static const int _rtcWdtKey = 0x50D83AA1;

  static const Duration _timeout = Duration(seconds: 3);

  final List<int> _buffer = [];

  // SLIP ---------------------------------------------------------------------------

  static List<int> slip(List<int> data) {
    final out = <int>[0xC0];
    for (final b in data) {
      if (b == 0xC0) {
        out.addAll([0xDB, 0xDC]);
      } else if (b == 0xDB) {
        out.addAll([0xDB, 0xDD]);
      } else {
        out.add(b);
      }
    }
    out.add(0xC0);
    return out;
  }

  /// The next complete SLIP frame, or null if none came within [timeout].
  Future<List<int>?> _readFrame(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final start = _buffer.indexOf(0xC0);
      if (start >= 0) {
        final end = _buffer.indexOf(0xC0, start + 1);
        if (end > start + 1) {
          final raw = _buffer.sublist(start + 1, end);
          _buffer.removeRange(0, end + 1);
          final frame = <int>[];
          for (var i = 0; i < raw.length; i++) {
            if (raw[i] == 0xDB && i + 1 < raw.length) {
              frame.add(raw[++i] == 0xDC ? 0xC0 : 0xDB);
            } else {
              frame.add(raw[i]);
            }
          }
          return frame;
        } else if (end == start + 1) {
          // Two delimiters in a row: an empty frame, or the end of one and the
          // start of the next.
          _buffer.removeRange(0, start + 1);
          continue;
        }
        if (start > 0) _buffer.removeRange(0, start);
      } else {
        _buffer.clear();
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return null;
      _buffer.addAll(await link.read(left < const Duration(milliseconds: 100) ? left : const Duration(milliseconds: 100)));
    }
  }

  // Commands -------------------------------------------------------------------------

  static List<int> _u32(int v) => [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  /// Sends a command and returns the data of its answer (without the status
  /// bytes). Throws if the bootloader reports a failure or does not answer.
  Future<List<int>> command(int op, List<int> data, {int checksum = 0, Duration timeout = _timeout}) async {
    final packet = [0x00, op, data.length & 0xFF, data.length >> 8, ..._u32(checksum), ...data];
    await link.write(slip(packet));
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final left = deadline.difference(DateTime.now());
      final frame = left <= Duration.zero ? null : await _readFrame(left);
      if (frame == null) {
        throw FlashException('no answer to command 0x${op.toRadixString(16)}', FlashFailure.connectionLost);
      }
      if (frame.length < 8 || frame[0] != 0x01 || frame[1] != op) continue; // not ours (e.g. a late sync reply)
      final size = frame[2] | (frame[3] << 8);
      final body = frame.sublist(8, (8 + size).clamp(8, frame.length));
      // The ROM ends its answer with 4 status bytes (the stub with 2); the
      // first is 0 on success, the second the error code.
      final statusLength = body.length >= 4 && body.length != 34 ? 4 : 2;
      if (body.length < 2) throw FlashException('short answer to command 0x${op.toRadixString(16)}');
      final status = body.sublist(body.length - statusLength);
      if (status[0] != 0) {
        throw FlashException('command 0x${op.toRadixString(16)} failed with error 0x${status[1].toRadixString(16)}');
      }
      return body.sublist(0, body.length - statusLength);
    }
  }

  /// Waits for the bootloader to answer SYNC.
  Future<void> connect({Duration within = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(within);
    final syncData = [0x07, 0x07, 0x12, 0x20, ...List.filled(32, 0x55)];
    while (DateTime.now().isBefore(deadline)) {
      try {
        await command(_sync, syncData, timeout: const Duration(milliseconds: 300));
        // The ROM answers a sync several times; let the rest go by.
        while (await _readFrame(const Duration(milliseconds: 100)) != null) {}
        return;
      } on FlashException {
        // Not yet: try again.
      }
    }
    throw FlashException('the bootloader does not answer', FlashFailure.noBootloader);
  }

  /// Writes [regions] and checks each with MD5.
  Future<void> flash(List<FlashRegion> regions, {void Function(FlashProgress progress)? onProgress}) async {
    onProgress?.call(const FlashProgress(FlashStage.connecting));
    await command(_spiAttach, List.filled(8, 0));
    await command(_spiSetParams, [..._u32(0), ..._u32(16 << 20), ..._u32(0x10000), ..._u32(0x1000), ..._u32(0x100), ..._u32(0xFFFF)]);

    final total = regions.fold<int>(0, (sum, r) => sum + r.data.length);
    var done = 0;
    for (final region in regions) {
      final size = region.data.length;
      final blocks = (size + blockSize - 1) ~/ blockSize;
      onProgress?.call(FlashProgress(FlashStage.erasing, total == 0 ? 0 : done / total));
      // Erasing happens here; it takes about 30 s per MB at worst.
      final eraseTime = Duration(milliseconds: (30000 * size / (1 << 20)).round() + 3000);
      await command(_flashBegin, [..._u32(size), ..._u32(blocks), ..._u32(blockSize), ..._u32(region.offset), ..._u32(0)],
          timeout: eraseTime);
      for (var seq = 0; seq < blocks; seq++) {
        final start = seq * blockSize;
        final block = Uint8List(blockSize)..fillRange(0, blockSize, 0xFF);
        final end = (start + blockSize).clamp(0, size);
        block.setRange(0, end - start, region.data, start);
        var checksum = 0xEF;
        for (final b in block) {
          checksum ^= b;
        }
        // A lost answer is tried again, as esptool does; the MD5 check at the
        // end catches anything that still went wrong.
        for (var attempt = 1;; attempt++) {
          try {
            await command(_flashData, [..._u32(blockSize), ..._u32(seq), ..._u32(0), ..._u32(0), ...block],
                checksum: checksum);
            break;
          } on FlashException catch (e) {
            if (attempt >= 3 || e.failure != FlashFailure.connectionLost) rethrow;
          }
        }
        done += end - start;
        onProgress?.call(FlashProgress(FlashStage.writing, done / total));
      }
    }

    onProgress?.call(const FlashProgress(FlashStage.verifying, 1));
    for (final region in regions) {
      final answer = await command(_spiFlashMd5, [..._u32(region.offset), ..._u32(region.data.length), ..._u32(0), ..._u32(0)],
          timeout: Duration(milliseconds: (8000 * region.data.length / (1 << 20)).round() + 3000));
      final expected = md5.convert(region.data).toString();
      final actual = answer.length >= 32 && answer.length < 64
          ? String.fromCharCodes(answer.sublist(0, 32)).toLowerCase()
          : [for (final b in answer.take(16)) b.toRadixString(16).padLeft(2, '0')].join();
      if (actual != expected) {
        throw FlashException('verification failed at 0x${region.offset.toRadixString(16)}', FlashFailure.verifyFailed);
      }
    }
  }

  Future<void> writeRegister(int address, int value, {int mask = 0xFFFFFFFF}) =>
      command(_writeReg, [..._u32(address), ..._u32(value), ..._u32(mask), ..._u32(0)]);

  /// Restarts the chip into the new firmware. The device was sent into the
  /// bootloader with "force download boot" set, which an ordinary reset keeps;
  /// so that flag is cleared first, then the RTC watchdog resets the chip.
  Future<void> restart() async {
    await writeRegister(_rtcOption1, 0, mask: 0x1);
    await writeRegister(_rtcWdtProtect, _rtcWdtKey);
    await writeRegister(_rtcWdtConfig1, 5000);
    // The chip resets as soon as the watchdog is armed: no answer to wait for.
    final config0 = (1 << 31) | (5 << 28) | (1 << 8) | 2;
    await link.write(slip([0x00, _writeReg, 16, 0, 0, 0, 0, 0, ..._u32(_rtcWdtConfig0), ..._u32(config0),
      ..._u32(0xFFFFFFFF), ..._u32(0)]));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}
