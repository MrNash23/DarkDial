// Unit tests of the portable firmware core. Build and run: firmware/host/build.sh
#include <stdio.h>

#include "testing.h"

using namespace testing;

static int checks = 0;
static int failures = 0;

#define CHECK(condition)                                              \
  do {                                                                \
    checks++;                                                         \
    if (!(condition)) {                                               \
      failures++;                                                     \
      printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #condition);     \
    }                                                                 \
  } while (0)

static const uint8_t kSerial[6] = {0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0xFF};

static void testCodec() {
  // Same vectors as app/packages/darkdial_core/test/codec_test.dart.
  const uint8_t in[] = {0x80, 0x01, 0xFF};
  uint8_t packed[8];
  CHECK(dd::pack7(in, 3, packed) == 4);
  CHECK(packed[0] == 0x05 && packed[1] == 0x00 && packed[2] == 0x01 && packed[3] == 0x7F);
  for (size_t length = 0; length <= 30; length++) {
    uint8_t data[30], wire[40], back[30];
    for (size_t i = 0; i < length; i++) data[i] = static_cast<uint8_t>(i * 37 + 200);
    const size_t n = dd::pack7(data, length, wire);
    bool sevenBit = true;
    for (size_t i = 0; i < n; i++) sevenBit = sevenBit && wire[i] < 0x80;
    CHECK(sevenBit);
    CHECK(dd::unpack7(wire, n, back) == length);
    CHECK(memcmp(data, back, length) == 0);
  }
  CHECK(dd::crc16(reinterpret_cast<const uint8_t *>("123456789"), 9) == 0x29B1);

  uint8_t out[dd::kMaxSysexBytes];
  CHECK(dd::buildRotation(out, 3) == 3 && out[0] == 0xB0 && out[1] == 0x10 && out[2] == 67);
  dd::buildRotation(out, -200);
  CHECK(out[2] == 1);
  const size_t n = dd::buildSlotSelect(out, 5);
  const uint8_t expected[] = {0xF0, 0x7D, 0x44, 0x44, 1, 0x02, 0x00, 0x05, 0xF7};
  CHECK(n == sizeof(expected) && memcmp(out, expected, n) == 0);
  CHECK(dd::buildHello(out, 0, 1, 0, kSerial, 0xBEEF) <= dd::kMaxSysexBytes);
}

static void testDecode() {
  dd::Message m;
  const Bytes slot = configSlot(slotPayload(12, 13, 13, true, 0xFA3A31, "S\xC3\xA4ttigung"));
  CHECK(slot.size() <= dd::kMaxSysexBytes);
  CHECK(dd::decodeMessage(slot.data(), slot.size(), m) && m.type == dd::MessageType::ConfigSlot);
  CHECK(m.index == 12 && m.slot.paramId == 13 && m.slot.bipolar && m.slot.r == 0xFA && m.slot.b == 0x31);
  CHECK(strcmp(m.slot.label, "S\xC3\xA4ttigung") == 0);

  const Bytes full = configSlot(slotPayload(0, 1, 1, false, 0, "12345678901234567890"));
  CHECK(full.size() <= dd::kMaxSysexBytes);
  CHECK(dd::decodeMessage(full.data(), full.size(), m) && strlen(m.slot.label) == 20);

  const Bytes v = value(3, 16383, true, "+1.35");
  CHECK(dd::decodeMessage(v.data(), v.size(), m) && m.type == dd::MessageType::Value);
  CHECK(m.index == 3 && m.value.position == 16383 && m.value.valid && strcmp(m.value.text, "+1.35") == 0);

  const Bytes s = status(dd::kStatusLightroom | dd::kStatusPhoto, 1);
  CHECK(dd::decodeMessage(s.data(), s.size(), m) && m.statusFlags == 5 && m.notice == 1);

  // Ignored: unknown type, other manufacturer, other major, truncated, too short.
  const Bytes unknown = frame(0x7A, {});
  CHECK(!dd::decodeMessage(unknown.data(), unknown.size(), m));
  const Bytes foreign = {0xF0, 0x41, 0x10, 0x00, 0x00, 0x00, 0xF7};
  CHECK(!dd::decodeMessage(foreign.data(), foreign.size(), m));
  Bytes otherMajor = status(1);
  otherMajor[4] = 2;
  CHECK(!dd::decodeMessage(otherMajor.data(), otherMajor.size(), m));
  const Bytes truncated = frame(0x45, {1});
  CHECK(!dd::decodeMessage(truncated.data(), truncated.size(), m));
  const Bytes tiny = {0xF0, 0x7D, 0x44, 0x44, 1, 0xF7};
  CHECK(!dd::decodeMessage(tiny.data(), tiny.size(), m));
  const Bytes longLabel = configSlot(slotPayload(0, 1, 1, false, 0, "123456789012345678901"));
  CHECK(!dd::decodeMessage(longLabel.data(), longLabel.size(), m));
}

static void testUsbPackets() {
  const Bytes message = value(3, 9000, true, "+12");
  std::vector<Bytes> packets;
  dd::sysexToPackets(message.data(), message.size(), [&](const uint8_t *p) { packets.emplace_back(p, p + 4); });
  dd::SysexAssembler assembler;
  int complete = 0;
  for (const Bytes &packet : packets) {
    if (assembler.feedPacket(packet.data())) complete++;
  }
  CHECK(complete == 1);
  CHECK(assembler.size() == message.size() && memcmp(assembler.data(), message.data(), message.size()) == 0);

  // Every message length ends with the right packet type.
  for (size_t length = 4; length <= 9; length++) {
    Bytes m(length, 0x01);
    m.front() = 0xF0;
    m.back() = 0xF7;
    packets.clear();
    dd::sysexToPackets(m.data(), m.size(), [&](const uint8_t *p) { packets.emplace_back(p, p + 4); });
    dd::SysexAssembler a;
    bool done = false;
    for (const Bytes &packet : packets) done = a.feedPacket(packet.data());
    CHECK(done && a.size() == length);
  }

  // An over-long SysEx from some other device is dropped, the next one works.
  dd::SysexAssembler a;
  uint8_t start[4] = {0x04, 0xF0, 0x01, 0x02};
  uint8_t middle[4] = {0x04, 0x03, 0x04, 0x05};
  uint8_t end[4] = {0x05, 0xF7, 0, 0};
  a.feedPacket(start);
  for (int i = 0; i < 40; i++) a.feedPacket(middle);
  CHECK(!a.feedPacket(end));
  bool done = false;
  for (const Bytes &packet : packets) done = a.feedPacket(packet.data());
  CHECK(done);
  // A channel message does not disturb anything.
  uint8_t cc[4] = {0x0B, 0xB0, 0x10, 0x41};
  CHECK(!a.feedPacket(cc));
}

static void testHandshake() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 7, kSerial);
  feed(device, identityRequest(), 0);
  const Bytes expected = {0xF0, 0x7E, 0x7F, 0x06, 0x02, 0x7D, 0x44, 0x44, 0x01, 0x00, 0, 1, 7, 0x00, 0xF7};
  CHECK(host.sent.size() == 1 && host.sent[0] == expected);

  feed(device, helloRequest(), 0);
  CHECK(host.sent.size() == 2);
  const Bytes &hello = host.sent[1];
  CHECK(hello[5] == 0x01);
  uint8_t payload[32];
  const size_t n = dd::unpack7(hello.data() + 6, hello.size() - 7, payload);
  CHECK(n == 21 && memcmp(payload, "DARKDIAL", 8) == 0);
  CHECK(payload[8] == 1 && payload[12] == 7 && memcmp(payload + 13, kSerial, 6) == 0);
  CHECK(((payload[19] << 8) | payload[20]) == device.configCrc());
}

static void testCarouselAndEdit() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  CHECK(device.slotCount() == 13 && device.index() == 0 && device.mode() == dd::Mode::Select);
  CHECK(strcmp(device.slot(2).label, "Exposure") == 0);

  device.rotate(-1, 0);
  CHECK(device.index() == 12 && device.lastMove() == -1);
  device.rotate(2, 10);
  CHECK(device.index() == 1 && device.lastMove() == 1);
  uint8_t focus[dd::kMaxSysexBytes];
  const size_t n = dd::buildSlotFocus(focus, 1);
  CHECK(host.sent.size() == 2 && host.sent[1] == Bytes(focus, focus + n));

  device.click();
  CHECK(device.mode() == dd::Mode::Edit && host.sent.back()[5] == 0x02);

  // Slow turning: single detents.
  host.sent.clear();
  device.rotate(1, 1000);
  device.rotate(1, 1200);
  device.rotate(-1, 1400);
  CHECK(host.sent.size() == 3);
  CHECK(host.sent[0] == Bytes({0xB0, 0x10, 65}));
  CHECK(host.sent[1] == Bytes({0xB0, 0x10, 65}));
  CHECK(host.sent[2] == Bytes({0xB0, 0x10, 63}));
  // Fast turning: larger steps.
  device.rotate(1, 1440);
  CHECK(host.sent.back()[2] == 64 + 2);
  device.rotate(1, 1460);
  CHECK(host.sent.back()[2] == 64 + 4);
  device.rotate(1, 1470);
  CHECK(host.sent.back()[2] == 64 + 8);
  CHECK(device.index() == 1);  // the carousel does not move in edit mode

  device.click();
  CHECK(device.mode() == dd::Mode::Select && host.sent.back()[5] == 0x03);
}

static void testConfiguration() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  const std::vector<SlotSpec> slots = {
      {2, 2, true, 0, "Tonung"},
      {3, 3, true, 0, "Belichtung"},
      {32, 22, true, 0xFA3A31, "Farbton"},
  };
  device.rotate(2, 0);  // on Exposure (param 3)
  device.click();
  host.sent.clear();

  configure(device, slots, 0, 100);
  CHECK(host.sent.size() == 1 && host.sent[0][5] == 0x05);
  uint8_t ack[4];
  dd::unpack7(host.sent[0].data() + 6, host.sent[0].size() - 7, ack);
  CHECK(ack[0] == 0 && ((ack[1] << 8) | ack[2]) == device.configCrc());
  CHECK(device.slotCount() == 3 && device.language() == 0);
  CHECK(device.index() == 1 && device.mode() == dd::Mode::Edit);  // stayed on Exposure
  CHECK(strcmp(device.slot(2).label, "Farbton") == 0 && device.slot(2).hasColor());
  CHECK(!host.stored.empty());

  // The stored blob restores the same configuration on the next boot.
  RecordingHost host2;
  dd::Device restored(host2, 0, 1, 0, kSerial);
  CHECK(restored.loadStored(host.stored.data(), host.stored.size()));
  CHECK(restored.slotCount() == 3 && restored.language() == 0 && restored.configCrc() == device.configCrc());
  CHECK(strcmp(restored.slot(1).label, "Belichtung") == 0);
  Bytes damaged = host.stored;
  damaged.resize(damaged.size() - 3);
  dd::Device fallback(host2, 0, 1, 0, kSerial);
  CHECK(!fallback.loadStored(damaged.data(), damaged.size()) && fallback.slotCount() == 13);

  // The same configuration again: acknowledged, but not written to flash.
  host.stored.clear();
  configure(device, slots, 0, 200);
  CHECK(host.stored.empty());

  // Wrong CRC: rejected, old configuration stays.
  host.sent.clear();
  feed(device, configBegin(1, 1), 300);
  feed(device, configSlot(slotPayload(0, 4, 4, true, 0, "Contrast")), 300);
  feed(device, configEnd(0x1234), 300);
  dd::unpack7(host.sent.back().data() + 6, host.sent.back().size() - 7, ack);
  CHECK(ack[0] == 1 && device.slotCount() == 3);

  // Missing slot and bad order: sequence error.
  feed(device, configBegin(2, 1), 300);
  feed(device, configSlot(slotPayload(0, 4, 4, true, 0, "Contrast")), 300);
  feed(device, configEnd(0), 300);
  dd::unpack7(host.sent.back().data() + 6, host.sent.back().size() - 7, ack);
  CHECK(ack[0] == 3 && device.slotCount() == 3);
  feed(device, configBegin(2, 1), 300);
  feed(device, configSlot(slotPayload(1, 4, 4, true, 0, "Contrast")), 300);
  dd::unpack7(host.sent.back().data() + 6, host.sent.back().size() - 7, ack);
  CHECK(ack[0] == 3);

  // Too many slots.
  feed(device, configBegin(49, 1), 300);
  dd::unpack7(host.sent.back().data() + 6, host.sent.back().size() - 7, ack);
  CHECK(ack[0] == 2 && device.slotCount() == 3);

  // The current parameter disappears: back to the first slot in selection mode.
  configure(device, {{4, 4, true, 0, "Contrast"}}, 1, 400);
  CHECK(device.slotCount() == 1 && device.index() == 0 && device.mode() == dd::Mode::Select);
}

static void testScreensAndHeartbeat() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  CHECK(device.screen() == dd::Screen::Offline);

  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto), 1000);
  CHECK(device.serviceConnected() && device.screen() == dd::Screen::Slot);

  feed(device, value(0, 9000, true, "5600K"), 1000);
  CHECK(device.value(0).valid && device.value(0).position == 9000 && strcmp(device.value(0).text, "5600K") == 0);
  feed(device, value(40, 1, true, "x"), 1000);  // slot out of range: ignored

  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop), 1100);
  CHECK(device.screen() == dd::Screen::NoPhoto);
  feed(device, status(dd::kStatusLightroom | dd::kStatusPhoto, 1), 1200);
  CHECK(device.screen() == dd::Screen::Switching);
  feed(device, status(0), 1300);
  CHECK(device.screen() == dd::Screen::Slot);  // Lightroom closed: slots with invalid values

  configure(device, {{4, 4, true, 0, "Contrast"}}, 1, 2000);
  CHECK(device.screen() == dd::Screen::Loaded);
  device.tick(2000 + dd::kLoadedNoticeMs + 1);
  CHECK(device.screen() == dd::Screen::Slot);

  // Heartbeat: fine just before the timeout, offline after it.
  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto), 5000);
  feed(device, value(0, 100, true, "+1"), 5000);
  device.click();
  const uint32_t revision = device.revision();
  device.tick(5000 + dd::kHeartbeatTimeoutMs);
  CHECK(device.serviceConnected() && device.revision() == revision);
  device.tick(5000 + dd::kHeartbeatTimeoutMs + 1);
  CHECK(!device.serviceConnected() && device.screen() == dd::Screen::Offline);
  CHECK(!device.value(0).valid && device.mode() == dd::Mode::Select && device.revision() != revision);
}

int main() {
  testCodec();
  testDecode();
  testUsbPackets();
  testHandshake();
  testCarouselAndEdit();
  testConfiguration();
  testScreensAndHeartbeat();
  printf("%d checks, %d failed\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
