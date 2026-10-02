// Wire format of the device link, docs/PROTOCOL.md section 1.
// Portable C++: no Arduino or LVGL includes, also built and tested on the host.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace dd {

constexpr uint8_t kProtocolMajor = 1;
constexpr uint8_t kProtocolMinor = 1;
constexpr uint8_t kMaxSlots = 48;
constexpr uint8_t kMaxLabelBytes = 20;
constexpr uint8_t kMaxTextBytes = 8;
constexpr size_t kMaxSysexBytes = 64;
// Longest unpacked payload: a TimerState with a full label.
constexpr size_t kMaxPayloadBytes = 10 + kMaxLabelBytes;
// Lines in one page of the time tracking menu.
constexpr uint8_t kMaxMenuItems = 16;
constexpr uint16_t kPositionMax = 16383;
constexpr uint16_t kPositionCentre = 8192;
constexpr uint8_t kRotationController = 0x10;

/// Packs 8-bit bytes into 7-bit bytes. `out` needs n + (n + 6) / 7 bytes.
size_t pack7(const uint8_t *in, size_t n, uint8_t *out);
/// Inverse of pack7. `out` needs n bytes at most.
size_t unpack7(const uint8_t *in, size_t n, uint8_t *out);
/// CRC-16/CCITT-FALSE.
uint16_t crc16(const uint8_t *data, size_t n, uint16_t crc = 0xFFFF);

struct Slot {
  uint8_t paramId = 0;
  uint8_t iconId = 0;
  bool bipolar = true;
  uint8_t r = 0, g = 0, b = 0;  // accent colour, all 0 = none
  char label[kMaxLabelBytes + 1] = {0};

  bool hasColor() const { return r || g || b; }
};

struct SlotValue {
  uint16_t position = 0;
  bool valid = false;
  char text[kMaxTextBytes + 1] = {0};
};

/// One line of a menu page. The service decides what it does.
struct MenuItem {
  uint8_t icon = 0;
  bool highlighted = false;  // stands out, e.g. the job matching Lightroom
  bool running = false;      // show the running time with it
  bool submenu = false;      // leads to another page
  bool closes = false;       // choosing it closes the menu on the device
  bool info = false;         // help line: show the built-in text instead of the label
  char label[kMaxLabelBytes + 1] = {0};
};

enum class MessageType : uint8_t {
  None,
  IdentityRequest,
  HelloRequest,
  ConfigBegin,
  ConfigSlot,
  ConfigEnd,
  Value,
  Status,
  MenuBegin,
  MenuItem,
  MenuEnd,
  TimerState,
  TimerResult,
};

/// A decoded message from the service. Only the fields of `type` are set.
struct Message {
  MessageType type = MessageType::None;
  // ConfigBegin
  uint8_t slotCount = 0;
  uint8_t language = 0;
  // ConfigSlot; `index` is also the slot of a Value
  uint8_t index = 0;
  Slot slot;
  // ConfigEnd
  uint16_t crc = 0;
  // Value
  SlotValue value;
  // Status
  uint8_t statusFlags = 0;
  uint8_t notice = 0;
  // MenuBegin: `text` is the title.
  uint8_t menuPage = 0;
  uint8_t menuCount = 0;
  uint8_t menuSelected = 0;
  // MenuItem (with `index`)
  MenuItem item;
  // TimerState: `text` is the job label. TimerResult: `text` is the error text.
  bool timerRunning = false;
  uint32_t timerJobId = 0;
  uint32_t timerElapsed = 0;
  uint8_t resultCode = 0;
  char text[kMaxLabelBytes + 1] = {0};
  // Unpacked payload, needed for the configuration CRC.
  uint8_t payload[kMaxPayloadBytes] = {0};
  size_t payloadSize = 0;
};

/// Decodes one complete MIDI message (F0 … F7). False for anything that is
/// not a known Darkdial message; those are ignored by specification.
bool decodeMessage(const uint8_t *bytes, size_t n, Message &out);

/// Parses the unpacked payload of a ConfigSlot (also the stored format).
bool parseSlotPayload(const uint8_t *p, size_t n, uint8_t &index, Slot &slot);
/// Writes the ConfigSlot payload of a slot; returns its size.
size_t writeSlotPayload(uint8_t index, const Slot &slot, uint8_t *out);

// Builders for device -> service messages. `out` needs kMaxSysexBytes.
size_t buildIdentityReply(uint8_t *out, uint8_t fwMajor, uint8_t fwMinor, uint8_t fwPatch);
size_t buildHello(uint8_t *out, uint8_t fwMajor, uint8_t fwMinor, uint8_t fwPatch, const uint8_t serial[6],
                  uint16_t configCrc);
size_t buildSlotSelect(uint8_t *out, uint8_t slot);
size_t buildSlotLeave(uint8_t *out, uint8_t slot);
size_t buildSlotFocus(uint8_t *out, uint8_t slot);
size_t buildConfigAck(uint8_t *out, uint8_t result, uint16_t crc);
size_t buildMenuOpen(uint8_t *out);
size_t buildMenuSelect(uint8_t *out, uint8_t page, uint8_t index);
size_t buildMenuClosed(uint8_t *out);
size_t buildSlotReset(uint8_t *out, uint8_t slot);
/// Relative CC; `delta` is clamped to -63 … 63 and must not be 0.
size_t buildRotation(uint8_t *out, int delta);

/// Collects the bytes of USB-MIDI event packets into complete SysEx messages.
class SysexAssembler {
 public:
  /// Feeds one 4-byte USB-MIDI event packet. Returns true when a complete
  /// SysEx message is available in data()/size().
  bool feedPacket(const uint8_t packet[4]);
  const uint8_t *data() const { return buffer_; }
  size_t size() const { return size_; }

 private:
  void append(const uint8_t *bytes, size_t n);
  uint8_t buffer_[kMaxSysexBytes];
  size_t size_ = 0;
  bool overflow_ = false;
  bool done_ = false;
};

/// Splits a complete SysEx message into USB-MIDI event packets (cable 0).
/// `emit` is called once per 4-byte packet.
template <typename Emit>
void sysexToPackets(const uint8_t *bytes, size_t n, Emit emit) {
  size_t i = 0;
  while (i < n) {
    const size_t left = n - i;
    uint8_t packet[4] = {0, 0, 0, 0};
    if (left > 3) {
      packet[0] = 0x04;  // SysEx starts or continues
      packet[1] = bytes[i];
      packet[2] = bytes[i + 1];
      packet[3] = bytes[i + 2];
      i += 3;
    } else {
      packet[0] = static_cast<uint8_t>(0x04 + left);  // SysEx ends with 1, 2 or 3 bytes
      for (size_t k = 0; k < left; k++) packet[1 + k] = bytes[i + k];
      i = n;
    }
    emit(packet);
  }
}

}  // namespace dd
