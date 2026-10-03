// MIDI over Bluetooth Low Energy (the BLE-MIDI specification): framing of
// complete MIDI messages into BLE packets and back. Portable, tested on the
// host; the radio itself lives in board.cpp.
//
// A packet starts with a header byte (bit 7 set, bits 5..0 the high part of
// a 13-bit millisecond timestamp). Every status byte is preceded by a
// timestamp byte (bit 7 set, the low 7 bits). A SysEx may span packets: the
// continuation packets carry only the header and data, and the closing F7 is
// preceded by a timestamp byte.
#pragma once
#include <stddef.h>
#include <stdint.h>

#include "protocol.h"

namespace dd {

/// Writes [message] (one complete MIDI message) as BLE-MIDI packets of at
/// most [maxPacket] bytes; `emit(packet, size)` is called for each.
template <typename Emit>
void bleMidiEncode(const uint8_t *message, size_t n, uint32_t nowMs, size_t maxPacket, Emit emit) {
  if (n == 0 || maxPacket < 5) return;
  const uint8_t header = static_cast<uint8_t>(0x80 | ((nowMs >> 7) & 0x3F));
  const uint8_t stamp = static_cast<uint8_t>(0x80 | (nowMs & 0x7F));
  uint8_t packet[kMaxSysexBytes + 8];
  if (maxPacket > sizeof(packet)) maxPacket = sizeof(packet);
  const bool sysex = message[0] == 0xF0 && message[n - 1] == 0xF7;
  if (!sysex) {
    size_t size = 0;
    packet[size++] = header;
    packet[size++] = stamp;
    for (size_t i = 0; i < n && size < maxPacket; i++) packet[size++] = message[i];
    emit(packet, size);
    return;
  }
  // F0 … data … [stamp] F7, split where needed.
  size_t size = 0;
  packet[size++] = header;
  packet[size++] = stamp;
  for (size_t i = 0; i + 1 < n; i++) {  // all but the closing F7
    if (size == maxPacket) {
      emit(packet, size);
      size = 0;
      packet[size++] = header;
    }
    packet[size++] = message[i];
  }
  if (size + 2 > maxPacket) {
    emit(packet, size);
    size = 0;
    packet[size++] = header;
  }
  packet[size++] = stamp;
  packet[size++] = 0xF7;
  emit(packet, size);
}

/// Collects complete MIDI messages from BLE-MIDI packets.
class BleMidiDecoder {
 public:
  /// Feeds one packet; `deliver(message, size)` is called for every message
  /// it completes. Packets that do not start with a header are dropped.
  template <typename Deliver>
  void feed(const uint8_t *packet, size_t n, Deliver deliver) {
    if (n < 2 || (packet[0] & 0xC0) != 0x80) return;
    bool stampSeen = false;
    for (size_t i = 1; i < n; i++) {
      const uint8_t b = packet[i];
      if (inSysex_) {
        if (b < 0x80) {
          append(b);
          continue;
        }
        if (!stampSeen) {  // the timestamp before F7 (or before a real-time byte)
          stampSeen = true;
          continue;
        }
        stampSeen = false;
        if (b == 0xF7) {
          append(b);
          if (!overflow_) deliver(buffer_, size_);
          inSysex_ = false;
          size_ = 0;
          continue;
        }
        if (b >= 0xF8) continue;  // real-time inside a SysEx
        inSysex_ = false;          // a new status: the SysEx was cut off
        size_ = 0;
      }
      if (b >= 0x80) {
        if (!stampSeen) {
          stampSeen = true;  // timestamp
          continue;
        }
        stampSeen = false;
        if (b == 0xF0) {
          inSysex_ = true;
          overflow_ = false;
          size_ = 0;
          append(b);
          continue;
        }
        if (b >= 0xF8) continue;  // real-time: not used by Darkdial
        running_ = b;
        size_ = 0;
        append(b);
        need_ = expectedLength(b);
        if (need_ == 1) {
          deliver(buffer_, size_);
          size_ = 0;
        }
        continue;
      }
      // Data byte: the current message, or a new one with running status.
      stampSeen = false;
      if (running_ == 0) continue;
      if (size_ == 0) append(running_);
      append(b);
      if (size_ >= need_) {
        deliver(buffer_, size_);
        size_ = 0;
      }
    }
  }

 private:
  static size_t expectedLength(uint8_t status) {
    switch (status & 0xF0) {
      case 0xC0:
      case 0xD0:
        return 2;
      case 0xF0:
        return 1;  // other system common messages: not used, kept short
      default:
        return 3;
    }
  }

  void append(uint8_t b) {
    if (size_ < sizeof(buffer_)) {
      buffer_[size_++] = b;
    } else {
      overflow_ = true;
    }
  }

  uint8_t buffer_[kMaxSysexBytes];
  size_t size_ = 0;
  size_t need_ = 0;
  uint8_t running_ = 0;
  bool inSysex_ = false;
  bool overflow_ = false;
};

}  // namespace dd
