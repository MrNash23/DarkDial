// The flasher against a simulated ROM bootloader that checks every packet
// the way the chip does.
import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:darkdial_core/src/esp_flasher.dart';
import 'package:test/test.dart';

/// ROM loader of an ESP32-S3 with 16 MB of flash, behind a serial line.
class FakeRom implements SerialLink {
  FakeRom({this.syncAfter = 0, this.corruptAt}) {
    flash.fillRange(0, flash.length, 0xAA); // old content everywhere
  }

  final Uint8List flash = Uint8List(1 << 24);

  /// SYNCs ignored before the first answer (the chip is still starting).
  int syncAfter;

  /// Flips a byte in this block number while writing, to test verification.
  final int? corruptAt;

  final List<int> _in = [];
  final List<int> _out = [];
  final List<int> commands = [];
  bool attached = false;
  int? _writeOffset;
  int _blocks = 0;
  int _blockSize = 0;
  int _nextSeq = 0;
  bool rts = false;
  int resets = 0;
  bool bootedApp = false;
  final Map<int, int> registers = {0x6000812C: 0x1}; // entered with force download boot

  @override
  Future<void> write(List<int> bytes) async {
    _in.addAll(bytes);
    while (true) {
      final start = _in.indexOf(0xC0);
      if (start < 0) return;
      final end = _in.indexOf(0xC0, start + 1);
      if (end < 0) return;
      final raw = _in.sublist(start + 1, end);
      _in.removeRange(0, end + 1);
      if (raw.isEmpty) continue;
      final packet = <int>[];
      for (var i = 0; i < raw.length; i++) {
        packet.add(raw[i] == 0xDB ? (raw[++i] == 0xDC ? 0xC0 : 0xDB) : raw[i]);
      }
      _handle(packet);
    }
  }

  int _u32(List<int> d, int at) => d[at] | (d[at + 1] << 8) | (d[at + 2] << 16) | (d[at + 3] << 24);

  void _answer(int op, {List<int> data = const [], int status = 0, int error = 0}) {
    final body = [...data, status, error, 0, 0];
    final frame = [0x01, op, body.length & 0xFF, body.length >> 8, 0, 0, 0, 0, ...body];
    _out.addAll(EspFlasher.slip(frame));
  }

  void _handle(List<int> p) {
    expect(p[0], 0x00, reason: 'direction');
    final op = p[1];
    final size = p[2] | (p[3] << 8);
    final checksum = _u32(p, 4);
    final data = p.sublist(8);
    expect(data.length, size, reason: 'size field of command 0x${op.toRadixString(16)}');
    commands.add(op);
    switch (op) {
      case 0x08:
        if (syncAfter > 0) {
          syncAfter--;
          return;
        }
        for (var i = 0; i < 4; i++) {
          _answer(op);
        }
      case 0x0D:
        attached = true;
        _answer(op);
      case 0x0B:
        expect(_u32(data, 4), 16 << 20);
        _answer(op);
      case 0x02:
        expect(attached, isTrue, reason: 'SPI_ATTACH before FLASH_BEGIN');
        expect(data.length, 20, reason: 'the S3 ROM wants the encryption word');
        final eraseSize = _u32(data, 0);
        _blocks = _u32(data, 4);
        _blockSize = _u32(data, 8);
        _writeOffset = _u32(data, 12);
        flash.fillRange(_writeOffset!, _writeOffset! + ((eraseSize + 0xFFF) & ~0xFFF), 0xFF);
        _nextSeq = 0;
        _answer(op);
      case 0x03:
        final length = _u32(data, 0);
        final seq = _u32(data, 4);
        final block = data.sublist(16);
        var sum = 0xEF;
        for (final b in block) {
          sum ^= b;
        }
        if (sum != checksum || length != _blockSize || seq != _nextSeq || seq >= _blocks) {
          _answer(op, status: 1, error: 0x07);
          return;
        }
        final at = _writeOffset! + seq * _blockSize;
        flash.setRange(at, at + block.length, block);
        if (corruptAt == seq) flash[at] ^= 0xFF;
        _nextSeq++;
        _answer(op);
      case 0x09:
        final address = _u32(data, 0);
        final mask = _u32(data, 8);
        registers[address] = ((registers[address] ?? 0) & ~mask) | (_u32(data, 4) & mask);
        // Arming the RTC watchdog resets the chip, into the app only if the
        // force download flag is clear.
        if (address == 0x60008098 && (registers[address]! & (1 << 31)) != 0) {
          resets++;
          bootedApp = (registers[0x6000812C]! & 1) == 0;
          return;
        }
        _answer(op);
      case 0x13:
        final at = _u32(data, 0);
        final length = _u32(data, 4);
        final digest = md5.convert(flash.sublist(at, at + length)).toString();
        _answer(op, data: digest.codeUnits);
      default:
        _answer(op, status: 1, error: 0x05);
    }
  }

  @override
  Future<List<int>> read(Duration timeout) async {
    if (_out.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      return const [];
    }
    final chunk = List.of(_out.take(37)); // arrives in pieces
    _out.removeRange(0, chunk.length);
    return chunk;
  }

  @override
  Future<void> setSignals({required bool dtr, required bool rts}) async {
    if (this.rts && !rts && !dtr) resets++;
    this.rts = rts;
  }
}

Uint8List image(int length, {int fillFrom = -1}) {
  final data = Uint8List(length);
  for (var i = 0; i < length; i++) {
    data[i] = (i * 7 + (i >> 8)) & 0xFF;
  }
  if (fillFrom >= 0) data.fillRange(fillFrom, length, 0xFF);
  return data;
}

void main() {
  test('SLIP escapes the delimiter and the escape byte', () {
    expect(EspFlasher.slip([1, 0xC0, 2, 0xDB, 3]), [0xC0, 1, 0xDB, 0xDC, 2, 0xDB, 0xDD, 3, 0xC0]);
  });

  test('an update leaves the NVS partition out and drops trailing 0xFF', () {
    final merged = image(0x200000, fillFrom: 0x1F0001);
    final regions = updateRegions(merged);
    expect(regions.map((r) => r.offset), [0, 0xE000]);
    expect(regions[0].data.length, 0x9000);
    expect(regions[1].data.length, 0x1F0004 - 0xE000);
  });

  test('flashes, keeps NVS, verifies and restarts', () async {
    final rom = FakeRom(syncAfter: 3);
    final merged = image(0x30000 + 123);
    final flasher = EspFlasher(rom);
    final progress = <FlashProgress>[];
    await flasher.connect();
    await flasher.flash(updateRegions(merged), onProgress: progress.add);
    await flasher.restart();

    expect(rom.flash.sublist(0, 0x9000), merged.sublist(0, 0x9000));
    expect(rom.flash.sublist(0xE000, merged.length), merged.sublist(0xE000));
    expect(rom.flash.sublist(0x9000, 0xE000).every((b) => b == 0xAA), isTrue, reason: 'NVS untouched');
    expect(rom.resets, 1);
    expect(rom.bootedApp, isTrue, reason: 'force download boot cleared before the reset');
    expect(progress.first.stage, FlashStage.connecting);
    expect(progress.where((p) => p.stage == FlashStage.writing).last.fraction, closeTo(1, 1e-9));
    expect(progress.last.stage, FlashStage.verifying);
    expect(rom.commands.where((c) => c == 0x13), hasLength(2));
  });

  test('a write that does not verify is reported', () async {
    final rom = FakeRom(corruptAt: 5);
    final flasher = EspFlasher(rom);
    await flasher.connect();
    await expectLater(flasher.flash(updateRegions(image(0x20000))), throwsA(isA<FlashException>()));
  });

  test('a bootloader that never answers is reported', () async {
    final rom = FakeRom(syncAfter: 1 << 30);
    final flasher = EspFlasher(rom);
    await expectLater(flasher.connect(within: const Duration(milliseconds: 700)), throwsA(isA<FlashException>()));
  });
}
