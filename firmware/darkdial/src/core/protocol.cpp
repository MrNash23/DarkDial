#include "protocol.h"

#include <string.h>

namespace dd {

namespace {

constexpr uint8_t kSysexStart = 0xF0;
constexpr uint8_t kSysexEnd = 0xF7;
constexpr uint8_t kManufacturer = 0x7D;
constexpr uint8_t kSignature = 0x44;  // 'D', sent twice

// Message types, PROTOCOL.md 1.4 and 1.5.
constexpr uint8_t kTypeHello = 0x01;
constexpr uint8_t kTypeSlotSelect = 0x02;
constexpr uint8_t kTypeSlotLeave = 0x03;
constexpr uint8_t kTypeSlotFocus = 0x04;
constexpr uint8_t kTypeConfigAck = 0x05;
constexpr uint8_t kTypeMenuOpen = 0x06;
constexpr uint8_t kTypeMenuSelect = 0x07;
constexpr uint8_t kTypeMenuClosed = 0x08;
constexpr uint8_t kTypeSlotReset = 0x09;
constexpr uint8_t kTypeLibraryAction = 0x0A;
constexpr uint8_t kTypeDisplayAngle = 0x0B;
constexpr uint8_t kTypeHelloRequest = 0x41;
constexpr uint8_t kTypeConfigBegin = 0x42;
constexpr uint8_t kTypeConfigSlot = 0x43;
constexpr uint8_t kTypeConfigEnd = 0x44;
constexpr uint8_t kTypeValue = 0x45;
constexpr uint8_t kTypeStatus = 0x46;
constexpr uint8_t kTypeMenuBegin = 0x47;
constexpr uint8_t kTypeMenuItem = 0x48;
constexpr uint8_t kTypeMenuEnd = 0x49;
constexpr uint8_t kTypeTimerState = 0x4A;
constexpr uint8_t kTypeTimerResult = 0x4B;
constexpr uint8_t kTypeSlotGoto = 0x4C;
constexpr uint8_t kTypeLibrary = 0x4D;
constexpr uint8_t kTypeDisplayRotation = 0x4E;
constexpr uint8_t kTypeIdleTimes = 0x4F;

uint32_t readU32(const uint8_t *p) {
  return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | p[3];
}

size_t frame(uint8_t *out, uint8_t type, const uint8_t *payload, size_t n) {
  size_t i = 0;
  out[i++] = kSysexStart;
  out[i++] = kManufacturer;
  out[i++] = kSignature;
  out[i++] = kSignature;
  out[i++] = kProtocolMajor;
  out[i++] = type;
  i += pack7(payload, n, out + i);
  out[i++] = kSysexEnd;
  return i;
}

// Copies a length-prefixed string at p[at]; false if it does not fit.
bool readString(const uint8_t *p, size_t n, size_t at, char *out, size_t maxBytes) {
  if (at >= n) return false;
  const size_t length = p[at];
  if (at + 1 + length > n || length > maxBytes) return false;
  memcpy(out, p + at + 1, length);
  out[length] = 0;
  return true;
}

}  // namespace

size_t pack7(const uint8_t *in, size_t n, uint8_t *out) {
  size_t o = 0;
  for (size_t i = 0; i < n; i += 7) {
    const size_t end = i + 7 < n ? i + 7 : n;
    uint8_t msbs = 0;
    for (size_t j = i; j < end; j++) {
      if (in[j] & 0x80) msbs |= static_cast<uint8_t>(1 << (j - i));
    }
    out[o++] = msbs;
    for (size_t j = i; j < end; j++) out[o++] = in[j] & 0x7F;
  }
  return o;
}

size_t unpack7(const uint8_t *in, size_t n, uint8_t *out) {
  size_t o = 0;
  for (size_t i = 0; i < n; i += 8) {
    const uint8_t msbs = in[i];
    for (size_t j = 1; j < 8 && i + j < n; j++) {
      out[o++] = static_cast<uint8_t>(in[i + j] | (((msbs >> (j - 1)) & 1) << 7));
    }
  }
  return o;
}

uint16_t crc16(const uint8_t *data, size_t n, uint16_t crc) {
  for (size_t i = 0; i < n; i++) {
    crc ^= static_cast<uint16_t>(data[i] << 8);
    for (int bit = 0; bit < 8; bit++) {
      crc = (crc & 0x8000) ? static_cast<uint16_t>((crc << 1) ^ 0x1021) : static_cast<uint16_t>(crc << 1);
    }
  }
  return crc;
}

bool parseSlotPayload(const uint8_t *p, size_t n, uint8_t &index, Slot &slot) {
  if (n < 8) return false;
  index = p[0];
  slot.paramId = p[1];
  slot.iconId = p[2];
  slot.bipolar = (p[3] & 1) != 0;
  slot.r = p[4];
  slot.g = p[5];
  slot.b = p[6];
  return readString(p, n, 7, slot.label, kMaxLabelBytes);
}

size_t writeSlotPayload(uint8_t index, const Slot &slot, uint8_t *out) {
  const size_t length = strnlen(slot.label, kMaxLabelBytes);
  out[0] = index;
  out[1] = slot.paramId;
  out[2] = slot.iconId;
  out[3] = slot.bipolar ? 1 : 0;
  out[4] = slot.r;
  out[5] = slot.g;
  out[6] = slot.b;
  out[7] = static_cast<uint8_t>(length);
  memcpy(out + 8, slot.label, length);
  return 8 + length;
}

bool decodeMessage(const uint8_t *bytes, size_t n, Message &out) {
  out = Message();
  if (n < 6 || n > kMaxSysexBytes || bytes[0] != kSysexStart || bytes[n - 1] != kSysexEnd) return false;

  // Universal non-real-time: identity request.
  if (bytes[1] == 0x7E && bytes[3] == 0x06 && bytes[4] == 0x01) {
    out.type = MessageType::IdentityRequest;
    return true;
  }
  if (bytes[1] != kManufacturer || bytes[2] != kSignature || bytes[3] != kSignature) return false;
  if (n < 7 || bytes[4] != kProtocolMajor) return false;

  const size_t packed = n - 7;
  if (packed - (packed + 7) / 8 > kMaxPayloadBytes) return false;
  out.payloadSize = unpack7(bytes + 6, packed, out.payload);
  const uint8_t *p = out.payload;
  const size_t size = out.payloadSize;

  switch (bytes[5]) {
    case kTypeHelloRequest:
      if (size < 5) return false;
      out.serviceMinor = p[1];
      out.type = MessageType::HelloRequest;
      return true;
    case kTypeConfigBegin:
      if (size < 2) return false;
      out.type = MessageType::ConfigBegin;
      out.slotCount = p[0];
      out.language = p[1];
      return true;
    case kTypeConfigSlot:
      if (!parseSlotPayload(p, size, out.index, out.slot)) return false;
      out.type = MessageType::ConfigSlot;
      return true;
    case kTypeConfigEnd:
      if (size < 2) return false;
      out.type = MessageType::ConfigEnd;
      out.crc = static_cast<uint16_t>((p[0] << 8) | p[1]);
      return true;
    case kTypeValue:
      if (size < 5) return false;
      out.index = p[0];
      out.value.position = static_cast<uint16_t>((p[1] << 8) | p[2]);
      if (out.value.position > kPositionMax) out.value.position = kPositionMax;
      out.value.valid = (p[3] & 1) != 0;
      if (!readString(p, size, 4, out.value.text, kMaxTextBytes)) return false;
      out.type = MessageType::Value;
      return true;
    case kTypeStatus:
      if (size < 2) return false;
      out.type = MessageType::Status;
      out.statusFlags = p[0];
      out.notice = p[1];
      return true;
    case kTypeMenuBegin:
      if (size < 4) return false;
      out.menuPage = p[0];
      out.menuCount = p[1];
      out.menuSelected = p[2];
      if (!readString(p, size, 3, out.text, kMaxLabelBytes)) return false;
      out.type = MessageType::MenuBegin;
      return true;
    case kTypeMenuItem:
      if (size < 4) return false;
      out.index = p[0];
      out.item.icon = p[1];
      out.item.highlighted = (p[2] & 1) != 0;
      out.item.running = (p[2] & 2) != 0;
      out.item.submenu = (p[2] & 4) != 0;
      out.item.closes = (p[2] & 8) != 0;
      out.item.info = (p[2] & 16) != 0;
      if (!readString(p, size, 3, out.item.label, kMaxLabelBytes)) return false;
      out.type = MessageType::MenuItem;
      return true;
    case kTypeMenuEnd:
      out.type = MessageType::MenuEnd;
      return true;
    case kTypeTimerState:
      if (size < 10) return false;
      out.timerRunning = (p[0] & 1) != 0;
      out.timerJobId = readU32(p + 1);
      out.timerElapsed = readU32(p + 5);
      if (!readString(p, size, 9, out.text, kMaxLabelBytes)) return false;
      out.type = MessageType::TimerState;
      return true;
    case kTypeSlotGoto:
      if (size < 1) return false;
      out.index = p[0];
      out.type = MessageType::SlotGoto;
      return true;
    case kTypeLibrary:
      if (size < 4) return false;
      out.libraryFlags = p[0];
      out.libraryRating = p[1] > 5 ? 5 : p[1];
      out.libraryColor = p[2] > 5 ? 0 : p[2];
      if (!readString(p, size, 3, out.text, kMaxLabelBytes)) return false;
      out.type = MessageType::Library;
      return true;
    case kTypeIdleTimes:
      if (size < 4) return false;
      out.logoSeconds = static_cast<uint16_t>((p[0] << 8) | p[1]);
      out.sleepSeconds = static_cast<uint16_t>((p[2] << 8) | p[3]);
      out.type = MessageType::IdleTimes;
      return true;
    case kTypeDisplayRotation:
      if (size < 3) return false;
      out.rotationMode = p[0];
      out.rotationAngle = static_cast<uint16_t>(((p[1] << 8) | p[2]) % 360);
      out.type = MessageType::DisplayRotation;
      return true;
    case kTypeTimerResult:
      if (size < 2) return false;
      out.resultCode = p[0];
      if (!readString(p, size, 1, out.text, kMaxLabelBytes)) return false;
      out.type = MessageType::TimerResult;
      return true;
    default:
      return false;
  }
}

size_t buildIdentityReply(uint8_t *out, uint8_t fwMajor, uint8_t fwMinor, uint8_t fwPatch) {
  const uint8_t reply[] = {
      kSysexStart, 0x7E, 0x7F, 0x06, 0x02, kManufacturer, kSignature, kSignature, 0x01, 0x00,
      static_cast<uint8_t>(fwMajor & 0x7F), static_cast<uint8_t>(fwMinor & 0x7F),
      static_cast<uint8_t>(fwPatch & 0x7F), 0x00, kSysexEnd,
  };
  memcpy(out, reply, sizeof(reply));
  return sizeof(reply);
}

size_t buildHello(uint8_t *out, uint8_t fwMajor, uint8_t fwMinor, uint8_t fwPatch, const uint8_t serial[6],
                  uint16_t configCrc) {
  uint8_t p[21];
  memcpy(p, "DARKDIAL", 8);
  p[8] = kProtocolMajor;
  p[9] = kProtocolMinor;
  p[10] = fwMajor;
  p[11] = fwMinor;
  p[12] = fwPatch;
  memcpy(p + 13, serial, 6);
  p[19] = static_cast<uint8_t>(configCrc >> 8);
  p[20] = static_cast<uint8_t>(configCrc & 0xFF);
  return frame(out, kTypeHello, p, sizeof(p));
}

size_t buildSlotSelect(uint8_t *out, uint8_t slot) { return frame(out, kTypeSlotSelect, &slot, 1); }
size_t buildSlotLeave(uint8_t *out, uint8_t slot) { return frame(out, kTypeSlotLeave, &slot, 1); }
size_t buildSlotFocus(uint8_t *out, uint8_t slot) { return frame(out, kTypeSlotFocus, &slot, 1); }

size_t buildConfigAck(uint8_t *out, uint8_t result, uint16_t crc) {
  const uint8_t p[3] = {result, static_cast<uint8_t>(crc >> 8), static_cast<uint8_t>(crc & 0xFF)};
  return frame(out, kTypeConfigAck, p, sizeof(p));
}

size_t buildMenuOpen(uint8_t *out) { return frame(out, kTypeMenuOpen, nullptr, 0); }

size_t buildMenuSelect(uint8_t *out, uint8_t page, uint8_t index) {
  const uint8_t p[2] = {page, index};
  return frame(out, kTypeMenuSelect, p, sizeof(p));
}

size_t buildMenuClosed(uint8_t *out) { return frame(out, kTypeMenuClosed, nullptr, 0); }
size_t buildSlotReset(uint8_t *out, uint8_t slot) { return frame(out, kTypeSlotReset, &slot, 1); }
size_t buildLibraryAction(uint8_t *out, uint8_t action) { return frame(out, kTypeLibraryAction, &action, 1); }

size_t buildDisplayAngle(uint8_t *out, uint16_t degrees, bool adjusting) {
  const uint8_t p[3] = {static_cast<uint8_t>(degrees >> 8), static_cast<uint8_t>(degrees & 0xFF),
                        static_cast<uint8_t>(adjusting ? 1 : 0)};
  return frame(out, kTypeDisplayAngle, p, sizeof(p));
}

size_t buildRotation(uint8_t *out, int delta, int speed) {
  if (delta > 63) delta = 63;
  if (delta < -63) delta = -63;
  if (speed < 0) speed = 0;
  if (speed > 3) speed = 3;
  out[0] = 0xB0;
  out[1] = static_cast<uint8_t>(kRotationController + speed);
  out[2] = static_cast<uint8_t>(64 + delta);
  return 3;
}

void SysexAssembler::append(const uint8_t *bytes, size_t n) {
  for (size_t i = 0; i < n; i++) {
    if (size_ < kMaxSysexBytes) {
      buffer_[size_++] = bytes[i];
    } else {
      overflow_ = true;  // too long to be ours; dropped when it ends
    }
  }
}

bool SysexAssembler::feedPacket(const uint8_t packet[4]) {
  const uint8_t cin = packet[0] & 0x0F;
  if (done_) {  // the previous message has been consumed
    size_ = 0;
    done_ = false;
  }
  switch (cin) {
    case 0x04:  // SysEx starts or continues, 3 bytes
      if (packet[1] == kSysexStart) {
        size_ = 0;
        overflow_ = false;
      }
      append(packet + 1, 3);
      return false;
    case 0x05:  // SysEx ends with 1 byte
    case 0x06:  // … 2 bytes
    case 0x07: {  // … 3 bytes
      if (packet[1] == kSysexStart) {
        size_ = 0;
        overflow_ = false;
      }
      append(packet + 1, static_cast<size_t>(cin - 0x04));
      const bool complete = !overflow_ && size_ >= 2 && buffer_[0] == kSysexStart && buffer_[size_ - 1] == kSysexEnd;
      if (!complete) size_ = 0;
      overflow_ = false;
      done_ = complete;
      return complete;
    }
    default:  // channel messages are not part of the service -> device direction
      return false;
  }
}

}  // namespace dd
