// Helpers for the host programs: the service side of the protocol and a Host
// that records what the device sends.
#pragma once
#include <string.h>

#include <string>
#include <vector>

#include "../darkdial/src/core/device.h"

namespace testing {

using Bytes = std::vector<uint8_t>;

inline Bytes frame(uint8_t type, const Bytes &payload) {
  Bytes out = {0xF0, 0x7D, 0x44, 0x44, dd::kProtocolMajor, type};
  uint8_t packed[128];
  const size_t n = dd::pack7(payload.data(), payload.size(), packed);
  out.insert(out.end(), packed, packed + n);
  out.push_back(0xF7);
  return out;
}

inline Bytes identityRequest() { return {0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7}; }
inline Bytes helloRequest() { return frame(0x41, {1, 0, 0, 1, 0}); }
inline Bytes configBegin(uint8_t count, uint8_t language) { return frame(0x42, {count, language}); }

inline Bytes slotPayload(uint8_t index, uint8_t paramId, uint8_t iconId, bool bipolar, uint32_t rgb,
                         const std::string &label) {
  Bytes p = {index, paramId, iconId, static_cast<uint8_t>(bipolar ? 1 : 0), static_cast<uint8_t>(rgb >> 16),
             static_cast<uint8_t>(rgb >> 8), static_cast<uint8_t>(rgb), static_cast<uint8_t>(label.size())};
  p.insert(p.end(), label.begin(), label.end());
  return p;
}

inline Bytes configSlot(const Bytes &payload) { return frame(0x43, payload); }
inline Bytes configEnd(uint16_t crc) {
  return frame(0x44, {static_cast<uint8_t>(crc >> 8), static_cast<uint8_t>(crc & 0xFF)});
}

inline Bytes value(uint8_t slot, uint16_t position, bool valid, const std::string &text) {
  Bytes p = {slot, static_cast<uint8_t>(position >> 8), static_cast<uint8_t>(position & 0xFF),
             static_cast<uint8_t>(valid ? 1 : 0), static_cast<uint8_t>(text.size())};
  p.insert(p.end(), text.begin(), text.end());
  return frame(0x45, p);
}

inline Bytes status(uint8_t flags, uint8_t notice = 0) { return frame(0x46, {flags, notice}); }

inline void appendU32(Bytes &p, uint32_t v) {
  p.push_back(static_cast<uint8_t>(v >> 24));
  p.push_back(static_cast<uint8_t>(v >> 16));
  p.push_back(static_cast<uint8_t>(v >> 8));
  p.push_back(static_cast<uint8_t>(v));
}

inline Bytes jobListBegin(uint8_t count) { return frame(0x47, {count}); }
inline Bytes jobItem(uint8_t index, uint32_t id, bool suggested, bool running, const std::string &label) {
  Bytes p = {index};
  appendU32(p, id);
  p.push_back(static_cast<uint8_t>((suggested ? 1 : 0) | (running ? 2 : 0)));
  p.push_back(static_cast<uint8_t>(label.size()));
  p.insert(p.end(), label.begin(), label.end());
  return frame(0x48, p);
}
inline Bytes jobListEnd() { return frame(0x49, {}); }

inline Bytes timerState(bool running, uint32_t jobId, uint32_t elapsed, const std::string &label) {
  Bytes p = {static_cast<uint8_t>(running ? 1 : 0)};
  appendU32(p, jobId);
  appendU32(p, elapsed);
  p.push_back(static_cast<uint8_t>(label.size()));
  p.insert(p.end(), label.begin(), label.end());
  return frame(0x4A, p);
}

inline Bytes timerResult(uint8_t code, const std::string &text = "") {
  Bytes p = {code, static_cast<uint8_t>(text.size())};
  p.insert(p.end(), text.begin(), text.end());
  return frame(0x4B, p);
}

struct SlotSpec {
  uint8_t paramId;
  uint8_t iconId;
  bool bipolar;
  uint32_t rgb;
  std::string label;
};

class RecordingHost : public dd::Host {
 public:
  void send(const uint8_t *bytes, size_t n) override { sent.emplace_back(bytes, bytes + n); }
  void saveConfig(const uint8_t *blob, size_t n) override { stored.assign(blob, blob + n); }
  std::vector<Bytes> sent;
  Bytes stored;
};

inline void feed(dd::Device &device, const Bytes &message, uint32_t nowMs) {
  device.onMessage(message.data(), message.size(), nowMs);
}

/// Transfers a complete configuration.
inline void configure(dd::Device &device, const std::vector<SlotSpec> &slots, uint8_t language, uint32_t nowMs) {
  feed(device, configBegin(static_cast<uint8_t>(slots.size()), language), nowMs);
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < slots.size(); i++) {
    const Bytes p = slotPayload(static_cast<uint8_t>(i), slots[i].paramId, slots[i].iconId, slots[i].bipolar,
                                slots[i].rgb, slots[i].label);
    crc = dd::crc16(p.data(), p.size(), crc);
    feed(device, configSlot(p), nowMs);
  }
  feed(device, configEnd(crc), nowMs);
}

}  // namespace testing
