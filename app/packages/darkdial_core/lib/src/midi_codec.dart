/// Wire format of the device link, see docs/PROTOCOL.md section 1.
library;

import 'dart:convert';
import 'dart:typed_data';

const int protocolMajor = 1;
const int protocolMinor = 1;

const int _sysexStart = 0xF0;
const int _sysexEnd = 0xF7;
const int _manufacturer = 0x7D;
const int _signature = 0x44; // 'D', sent twice
const int rotationController = 0x10;
const String helloSignature = 'DARKDIAL';
const int maxSlots = 48;
const int maxLabelBytes = 20;
const int maxValueTextBytes = 8;
const int positionMax = 16383;
const int positionCentre = 8192;

/// Jobs in one job list (the device adds "Stop" and "New job" itself).
const int maxDeviceJobs = 13;

/// TimerStart with this id creates a new, unnamed job.
const int newJobId = 0xFFFFFFFF;

/// Packs 8-bit bytes into 7-bit bytes: per group of up to 7 bytes one byte
/// with the MSBs, then the bytes without their MSB.
Uint8List pack7(List<int> data) {
  final out = BytesBuilder();
  for (var i = 0; i < data.length; i += 7) {
    final end = i + 7 < data.length ? i + 7 : data.length;
    var msbs = 0;
    for (var j = i; j < end; j++) {
      if (data[j] & 0x80 != 0) msbs |= 1 << (j - i);
    }
    out.addByte(msbs);
    for (var j = i; j < end; j++) {
      out.addByte(data[j] & 0x7F);
    }
  }
  return out.toBytes();
}

/// Inverse of [pack7].
Uint8List unpack7(List<int> data) {
  final out = BytesBuilder();
  for (var i = 0; i < data.length; i += 8) {
    final msbs = data[i];
    for (var j = 1; j < 8 && i + j < data.length; j++) {
      out.addByte(data[i + j] | ((msbs >> (j - 1)) & 1) << 7);
    }
  }
  return out.toBytes();
}

/// CRC-16/CCITT-FALSE.
int crc16(List<int> data, [int crc = 0xFFFF]) {
  for (final byte in data) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) & 0xFFFF : (crc << 1) & 0xFFFF;
    }
  }
  return crc;
}

/// Splits a raw MIDI byte stream into complete messages. Transports may
/// deliver several messages in one chunk or one SysEx in several chunks.
class MidiStreamParser {
  final List<int> _buffer = [];
  bool _inSysex = false;

  /// Feeds [chunk] and returns the messages completed by it.
  List<Uint8List> add(List<int> chunk) {
    final messages = <Uint8List>[];
    for (final byte in chunk) {
      if (byte >= 0xF8) continue; // real-time, may appear anywhere
      if (byte == _sysexStart) {
        _buffer
          ..clear()
          ..add(byte);
        _inSysex = true;
      } else if (_inSysex) {
        if (byte == _sysexEnd) {
          _buffer.add(byte);
          messages.add(Uint8List.fromList(_buffer));
          _buffer.clear();
          _inSysex = false;
        } else if (byte & 0x80 != 0) {
          // A status byte aborts an unfinished SysEx.
          _inSysex = false;
          _buffer
            ..clear()
            ..add(byte);
        } else {
          _buffer.add(byte);
        }
      } else if (byte & 0x80 != 0) {
        _buffer
          ..clear()
          ..add(byte);
      } else if (_buffer.isNotEmpty) {
        _buffer.add(byte);
        if (_buffer.length == _channelMessageLength(_buffer[0])) {
          messages.add(Uint8List.fromList(_buffer));
          _buffer.clear();
        }
      }
    }
    return messages;
  }

  static int _channelMessageLength(int status) {
    final kind = status & 0xF0;
    return (kind == 0xC0 || kind == 0xD0) ? 2 : 3;
  }
}

/// A decoded message of the device link.
sealed class DeviceMessage {
  const DeviceMessage();
}

// Device -> service ------------------------------------------------------------

class Rotation extends DeviceMessage {
  const Rotation(this.delta);

  /// Detents, sign gives the direction, −63 … +63.
  final int delta;
}

class IdentityReply extends DeviceMessage {
  const IdentityReply(this.model, this.fwMajor, this.fwMinor, this.fwPatch);
  final int model;
  final int fwMajor;
  final int fwMinor;
  final int fwPatch;
}

class Hello extends DeviceMessage {
  const Hello({
    required this.major,
    required this.minor,
    required this.fwMajor,
    required this.fwMinor,
    required this.fwPatch,
    required this.serial,
    required this.configCrc,
  });
  final int major;
  final int minor;
  final int fwMajor;
  final int fwMinor;
  final int fwPatch;

  /// Six bytes, the MAC address.
  final List<int> serial;
  final int configCrc;

  String get firmwareVersion => '$fwMajor.$fwMinor.$fwPatch';

  String get serialText =>
      serial.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
}

class SlotSelect extends DeviceMessage {
  const SlotSelect(this.slot);
  final int slot;
}

class SlotLeave extends DeviceMessage {
  const SlotLeave(this.slot);
  final int slot;
}

class SlotFocus extends DeviceMessage {
  const SlotFocus(this.slot);
  final int slot;
}

class ConfigAck extends DeviceMessage {
  const ConfigAck(this.result, this.crc);

  /// 0 ok, 1 CRC mismatch, 2 too many slots, 3 bad sequence.
  final int result;
  final int crc;
}

/// Double tap in edit mode: reset the slot to Lightroom's default.
class SlotReset extends DeviceMessage {
  const SlotReset(this.slot);
  final int slot;
}

/// The job menu was opened.
class JobListRequest extends DeviceMessage {
  const JobListRequest();
}

class TimerStart extends DeviceMessage {
  const TimerStart(this.jobId);

  /// [newJobId] creates a new job.
  final int jobId;
}

class TimerStop extends DeviceMessage {
  const TimerStop();
}

// Service -> device ------------------------------------------------------------

class IdentityRequest extends DeviceMessage {
  const IdentityRequest();
}

class HelloRequest extends DeviceMessage {
  const HelloRequest(this.major, this.minor, this.appMajor, this.appMinor, this.appPatch);
  final int major;
  final int minor;
  final int appMajor;
  final int appMinor;
  final int appPatch;
}

class ConfigBegin extends DeviceMessage {
  const ConfigBegin(this.slotCount, this.language);
  final int slotCount;
  final int language;
}

/// One slot as the device knows it.
class ConfigSlot extends DeviceMessage {
  const ConfigSlot({
    required this.index,
    required this.paramId,
    required this.iconId,
    required this.bipolar,
    required this.color,
    required this.label,
  });
  final int index;
  final int paramId;
  final int iconId;
  final bool bipolar;

  /// `0xRRGGBB`, 0 = no colour dot.
  final int color;
  final String label;

  /// Unpacked payload; also the input of the configuration CRC.
  Uint8List payload() {
    final text = _truncateUtf8(label, maxLabelBytes);
    return Uint8List.fromList([
      index,
      paramId,
      iconId,
      bipolar ? 1 : 0,
      (color >> 16) & 0xFF,
      (color >> 8) & 0xFF,
      color & 0xFF,
      text.length,
      ...text,
    ]);
  }
}

class ConfigEnd extends DeviceMessage {
  const ConfigEnd(this.crc);
  final int crc;
}

class Value extends DeviceMessage {
  const Value({required this.slot, required this.position, required this.valid, required this.text});
  final int slot;

  /// Ring position 0 … 16383.
  final int position;
  final bool valid;
  final String text;
}

class Status extends DeviceMessage {
  const Status({
    required this.lightroomConnected,
    required this.developActive,
    required this.photoSelected,
    this.notice = 0,
  });
  final bool lightroomConnected;
  final bool developActive;
  final bool photoSelected;

  /// 0 none, 1 switching to Develop.
  final int notice;

  int get flags => (lightroomConnected ? 1 : 0) | (developActive ? 2 : 0) | (photoSelected ? 4 : 0);
}

class JobListBegin extends DeviceMessage {
  const JobListBegin(this.count);
  final int count;
}

class JobItem extends DeviceMessage {
  const JobItem({
    required this.index,
    required this.id,
    required this.suggested,
    required this.running,
    required this.label,
  });
  final int index;
  final int id;

  /// Matches what is open in Lightroom.
  final bool suggested;
  final bool running;
  final String label;
}

class JobListEnd extends DeviceMessage {
  const JobListEnd();
}

class TimerState extends DeviceMessage {
  const TimerState({required this.running, this.jobId = 0, this.elapsedSeconds = 0, this.label = ''});
  final bool running;
  final int jobId;

  /// Time of the running entry so far; the device counts on from here.
  final int elapsedSeconds;
  final String label;
}

class TimerResult extends DeviceMessage {
  const TimerResult(this.code, [this.text = '']);

  static const int started = 0;
  static const int stopped = 1;
  static const int error = 2;

  final int code;
  final String text;
}

// Encoding -----------------------------------------------------------------------

List<int> _truncateUtf8(String text, int maxBytes) {
  var bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return bytes;
  // Cut on a character boundary.
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  bytes = bytes.sublist(0, end);
  return bytes;
}

Uint8List _frame(int type, List<int> payload) => Uint8List.fromList([
      _sysexStart,
      _manufacturer,
      _signature,
      _signature,
      protocolMajor,
      type,
      ...pack7(payload),
      _sysexEnd,
    ]);

List<int> _u16(int value) => [(value >> 8) & 0xFF, value & 0xFF];

List<int> _u32(int value) => [(value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF];

List<int> _str(String text, int maxBytes) {
  final bytes = _truncateUtf8(text, maxBytes);
  return [bytes.length, ...bytes];
}

/// Encodes [message] as one complete MIDI message.
Uint8List encodeMessage(DeviceMessage message) => switch (message) {
      Rotation(:final delta) => Uint8List.fromList([0xB0, rotationController, 64 + delta.clamp(-63, 63)]),
      IdentityRequest() => Uint8List.fromList([_sysexStart, 0x7E, 0x7F, 0x06, 0x01, _sysexEnd]),
      IdentityReply(:final model, :final fwMajor, :final fwMinor, :final fwPatch) => Uint8List.fromList([
          _sysexStart, 0x7E, 0x7F, 0x06, 0x02, _manufacturer, _signature, _signature, //
          model & 0x7F, 0, fwMajor & 0x7F, fwMinor & 0x7F, fwPatch & 0x7F, 0, _sysexEnd,
        ]),
      Hello() => _frame(0x01, [
          ...ascii.encode(helloSignature),
          message.major,
          message.minor,
          message.fwMajor,
          message.fwMinor,
          message.fwPatch,
          ...message.serial,
          ..._u16(message.configCrc),
        ]),
      SlotSelect(:final slot) => _frame(0x02, [slot]),
      SlotLeave(:final slot) => _frame(0x03, [slot]),
      SlotFocus(:final slot) => _frame(0x04, [slot]),
      ConfigAck(:final result, :final crc) => _frame(0x05, [result, ..._u16(crc)]),
      HelloRequest() => _frame(0x41, [
          message.major,
          message.minor,
          message.appMajor,
          message.appMinor,
          message.appPatch,
        ]),
      ConfigBegin(:final slotCount, :final language) => _frame(0x42, [slotCount, language]),
      ConfigSlot() => _frame(0x43, message.payload()),
      ConfigEnd(:final crc) => _frame(0x44, _u16(crc)),
      Value() => () {
          final text = _truncateUtf8(message.text, maxValueTextBytes);
          return _frame(0x45, [
            message.slot,
            ..._u16(message.position.clamp(0, positionMax)),
            message.valid ? 1 : 0,
            text.length,
            ...text,
          ]);
        }(),
      Status() => _frame(0x46, [message.flags, message.notice]),
      JobListRequest() => _frame(0x06, const []),
      TimerStart(:final jobId) => _frame(0x07, _u32(jobId)),
      TimerStop() => _frame(0x08, const []),
      SlotReset(:final slot) => _frame(0x09, [slot]),
      JobListBegin(:final count) => _frame(0x47, [count]),
      JobItem() => _frame(0x48, [
          message.index,
          ..._u32(message.id),
          (message.suggested ? 1 : 0) | (message.running ? 2 : 0),
          ..._str(message.label, maxLabelBytes),
        ]),
      JobListEnd() => _frame(0x49, const []),
      TimerState() => _frame(0x4A, [
          message.running ? 1 : 0,
          ..._u32(message.jobId),
          ..._u32(message.elapsedSeconds),
          ..._str(message.label, maxLabelBytes),
        ]),
      TimerResult(:final code, :final text) => _frame(0x4B, [code, ..._str(text, maxLabelBytes)]),
    };

/// Decodes one complete MIDI message. Returns null for anything that is not a
/// well-formed Darkdial message of a known type; the protocol says to ignore
/// those.
DeviceMessage? decodeMessage(List<int> bytes) {
  if (bytes.length == 3 && bytes[0] == 0xB0 && bytes[1] == rotationController) {
    final delta = bytes[2] - 64;
    return delta == 0 ? null : Rotation(delta);
  }
  if (bytes.length < 6 || bytes.first != _sysexStart || bytes.last != _sysexEnd) return null;

  if (bytes[1] == 0x7E && bytes[3] == 0x06) {
    if (bytes[4] == 0x01) return const IdentityRequest();
    if (bytes[4] == 0x02 &&
        bytes.length >= 15 &&
        bytes[5] == _manufacturer &&
        bytes[6] == _signature &&
        bytes[7] == _signature) {
      return IdentityReply(bytes[8], bytes[10], bytes[11], bytes[12]);
    }
    return null;
  }

  if (bytes[1] != _manufacturer || bytes[2] != _signature || bytes[3] != _signature) return null;
  if (bytes[4] != protocolMajor) return null;
  final type = bytes[5];
  final p = unpack7(bytes.sublist(6, bytes.length - 1));
  int u16(int at) => (p[at] << 8) | p[at + 1];
  int u32(int at) => (p[at] << 24) | (p[at + 1] << 16) | (p[at + 2] << 8) | p[at + 3];
  String? str(int at) {
    if (at >= p.length || at + 1 + p[at] > p.length) return null;
    return utf8.decode(p.sublist(at + 1, at + 1 + p[at]), allowMalformed: true);
  }

  switch (type) {
    case 0x01:
      if (p.length < 21 || ascii.decode(p.sublist(0, 8), allowInvalid: true) != helloSignature) return null;
      return Hello(
        major: p[8],
        minor: p[9],
        fwMajor: p[10],
        fwMinor: p[11],
        fwPatch: p[12],
        serial: p.sublist(13, 19),
        configCrc: u16(19),
      );
    case 0x02:
      return p.isEmpty ? null : SlotSelect(p[0]);
    case 0x03:
      return p.isEmpty ? null : SlotLeave(p[0]);
    case 0x04:
      return p.isEmpty ? null : SlotFocus(p[0]);
    case 0x05:
      return p.length < 3 ? null : ConfigAck(p[0], u16(1));
    case 0x41:
      return p.length < 5 ? null : HelloRequest(p[0], p[1], p[2], p[3], p[4]);
    case 0x42:
      return p.length < 2 ? null : ConfigBegin(p[0], p[1]);
    case 0x43:
      final label = p.length < 8 ? null : str(7);
      if (label == null) return null;
      return ConfigSlot(
        index: p[0],
        paramId: p[1],
        iconId: p[2],
        bipolar: p[3] & 1 != 0,
        color: (p[4] << 16) | (p[5] << 8) | p[6],
        label: label,
      );
    case 0x44:
      return p.length < 2 ? null : ConfigEnd(u16(0));
    case 0x45:
      final text = p.length < 5 ? null : str(4);
      if (text == null) return null;
      return Value(slot: p[0], position: u16(1), valid: p[3] & 1 != 0, text: text);
    case 0x46:
      if (p.length < 2) return null;
      return Status(
        lightroomConnected: p[0] & 1 != 0,
        developActive: p[0] & 2 != 0,
        photoSelected: p[0] & 4 != 0,
        notice: p[1],
      );
    case 0x06:
      return const JobListRequest();
    case 0x07:
      return p.length < 4 ? null : TimerStart(u32(0));
    case 0x08:
      return const TimerStop();
    case 0x09:
      return p.isEmpty ? null : SlotReset(p[0]);
    case 0x47:
      return p.isEmpty ? null : JobListBegin(p[0]);
    case 0x48:
      final label = p.length < 7 ? null : str(6);
      if (label == null) return null;
      return JobItem(index: p[0], id: u32(1), suggested: p[5] & 1 != 0, running: p[5] & 2 != 0, label: label);
    case 0x49:
      return const JobListEnd();
    case 0x4A:
      final label = p.length < 10 ? null : str(9);
      if (label == null) return null;
      return TimerState(running: p[0] & 1 != 0, jobId: u32(1), elapsedSeconds: u32(5), label: label);
    case 0x4B:
      final text = p.length < 2 ? null : str(1);
      return text == null ? null : TimerResult(p[0], text);
  }
  return null;
}

/// CRC over the ConfigSlot payloads in order, as sent in ConfigEnd.
int configCrc(Iterable<ConfigSlot> slots) {
  var crc = 0xFFFF;
  for (final slot in slots) {
    crc = crc16(slot.payload(), crc);
  }
  return crc;
}
