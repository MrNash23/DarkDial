// Unit tests of the portable firmware core. Build and run: firmware/host/build.sh
#include <stdio.h>

#include <string>
#include <utility>
#include <vector>

#include "../darkdial/src/core/ble_midi.h"
#include "../darkdial/src/core/encoder.h"
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

  // A service of protocol 1.5 gets the raw detents and the speed instead.
  feed(device, frame(0x41, {1, 5, 0, 8, 0}), 1500);
  host.sent.clear();
  device.rotate(1, 2000);
  device.rotate(1, 2040);
  device.rotate(-1, 2060);
  device.rotate(1, 2070);
  device.rotate(1, 2300);
  // Two detents in one report count per detent: 70 ms for two is fast.
  device.rotate(2, 2370);
  device.rotate(2, 2500);
  CHECK(host.sent.size() == 7);
  CHECK(host.sent[0] == Bytes({0xB0, 0x10, 65}));
  CHECK(host.sent[1] == Bytes({0xB0, 0x11, 65}));
  CHECK(host.sent[2] == Bytes({0xB0, 0x12, 63}));
  CHECK(host.sent[3] == Bytes({0xB0, 0x13, 65}));
  CHECK(host.sent[4] == Bytes({0xB0, 0x10, 65}));
  CHECK(host.sent[5] == Bytes({0xB0, 0x11, 66}));
  CHECK(host.sent[6] == Bytes({0xB0, 0x10, 66}));

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

static void testLongPress() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto), 0);

  // A short press is a click, decided on release.
  device.buttonDown(1000);
  device.tick(1300);
  CHECK(device.mode() == dd::Mode::Select && !device.menuOpen());
  const uint32_t half = 1000 + dd::kLongPressMs / 2;
  CHECK(device.holdProgress(half) > 0.49f && device.holdProgress(half) < 0.51f);
  device.buttonUp(1400);
  CHECK(device.mode() == dd::Mode::Edit && !device.menuOpen());
  CHECK(device.holdProgress(1500) == 0);

  // Held just below the threshold: still a click.
  device.buttonDown(2000);
  device.tick(2000 + dd::kLongPressMs - 1);
  CHECK(!device.menuOpen());
  device.buttonUp(2000 + dd::kLongPressMs - 1);
  CHECK(device.mode() == dd::Mode::Select);

  // Held past the threshold: the menu opens while still holding, from edit
  // mode too, and the release is not a click.
  device.click();
  CHECK(device.mode() == dd::Mode::Edit);
  host.sent.clear();
  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto), 5000);  // heartbeat
  device.buttonDown(5000);
  device.tick(5000 + dd::kLongPressMs);
  CHECK(device.menuOpen() && device.screen() == dd::Screen::JobMenu);
  CHECK(host.sent.size() == 1 && host.sent[0][5] == 0x06);
  CHECK(device.holdProgress(5000 + dd::kLongPressMs + 50) == 0);
  device.tick(5000 + dd::kLongPressMs + 500);  // holding on does nothing more
  device.buttonUp(6500);
  CHECK(device.menuOpen() && host.sent.size() == 1);
  CHECK(device.mode() == dd::Mode::Edit);  // the state behind the menu is untouched

  // A second long press closes the menu without any action.
  device.buttonDown(7000);
  device.tick(7000 + dd::kLongPressMs);
  device.buttonUp(8000);
  CHECK(!device.menuOpen() && device.screen() == dd::Screen::Slot && device.mode() == dd::Mode::Edit);
  CHECK(host.sent.size() == 2 && host.sent[1][5] == 0x08);  // it only says that it closed
}

static void openMenu(dd::Device &device, uint32_t &now) {
  device.buttonDown(now);
  now += dd::kLongPressMs;
  device.tick(now);
  device.buttonUp(now);
}

// Page and index of a MenuSelect message.
static void selected(const Bytes &message, uint8_t &page, uint8_t &index) {
  uint8_t p[4];
  dd::unpack7(message.data() + 6, message.size() - 7, p);
  page = p[0];
  index = p[1];
}

static void testMenu() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  uint32_t now = 1000;
  const uint8_t all = dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto;
  feed(device, status(all), now);

  // Long press: MenuOpen goes out; the menu is open but empty until the page arrives.
  openMenu(device, now);
  CHECK(device.menuOpen() && device.menuCount() == 0);
  CHECK(host.sent.size() == 1 && host.sent[0][5] == 0x06);
  host.sent.clear();
  device.click();
  device.rotate(1, now);
  CHECK(host.sent.empty() && device.menuOpen());  // nothing to choose yet

  sendMenu(device, 5, "Zeiterfassung",
           {{29, 1, "M\xC3\xBCller"}, {29, 0, "Katalog"}, {32, 4, "Kunden"}, {30, 0, "Neuer Job"}, {34, 8, "Schlie\xC3\x9F" "en"}},
           now);
  CHECK(device.menuCount() == 5 && device.menuIndex() == 0 && strcmp(device.menuTitle(), "Zeiterfassung") == 0);
  CHECK(device.menuItem(0).highlighted && !device.menuItem(0).submenu);
  CHECK(device.menuItem(2).submenu && device.menuItem(4).closes && !device.menuItem(4).info);
  CHECK(strcmp(device.menuItem(0).label, "M\xC3\xBCller") == 0);

  // Turning moves through the page, wrapping, without touching the carousel.
  const uint8_t slotIndex = device.index();
  device.rotate(-1, now);
  CHECK(device.menuIndex() == 4);
  device.rotate(3, now);
  CHECK(device.menuIndex() == 2 && device.index() == slotIndex && host.sent.empty());

  // Click reports page and line; the menu stays open and waits for the answer.
  device.click();
  uint8_t page = 0, index = 0;
  CHECK(host.sent.size() == 1 && host.sent[0][5] == 0x07);
  selected(host.sent[0], page, index);
  CHECK(page == 5 && index == 2 && device.menuOpen());

  // The answer is another page: it starts at the line the service names.
  sendMenu(device, 6, "Kunden", {{32, 4, "Fam. M\xC3\xBCller"}, {32, 4, "Verlag"}, {33, 0, "Zur\xC3\xBC" "ck"}}, now, 1);
  CHECK(device.menuCount() == 3 && device.menuIndex() == 1 && strcmp(device.menuTitle(), "Kunden") == 0);

  // The same page sent again (a rename underneath) keeps the line.
  device.rotate(1, now);
  sendMenu(device, 7, "Kunden", {{32, 4, "Fam. M\xC3\xBCller"}, {32, 4, "Verlag GmbH"}, {33, 0, "Zur\xC3\xBC" "ck"}}, now);
  CHECK(device.menuIndex() == 2 && strcmp(device.menuItem(1).label, "Verlag GmbH") == 0);
  host.sent.clear();
  device.click();
  selected(host.sent[0], page, index);
  CHECK(page == 7 && index == 2);

  // A result ends the menu and shows the confirmation; the slider state is as before.
  feed(device, timerResult(0), now);
  feed(device, timerState(true, 70000, 0, "M\xC3\xBCller"), now);
  CHECK(!device.menuOpen() && device.screen() == dd::Screen::TimerNotice && device.noticeCode() == 0);
  now += dd::kTimerNoticeMs + 1;
  device.tick(now);
  CHECK(device.screen() == dd::Screen::Slot && device.mode() == dd::Mode::Select);
  CHECK(device.timerRunning() && strcmp(device.timerLabel(), "M\xC3\xBCller") == 0);

  // "Close" is handled by the device: the menu closes and says so.
  feed(device, status(all), now);
  openMenu(device, now);
  sendMenu(device, 8, "Zeiterfassung", {{31, 2, "Stopp"}, {34, 8, "Schlie\xC3\x9F" "en"}}, now);
  CHECK(device.menuItem(0).running);
  host.sent.clear();
  device.rotate(1, now);
  device.click();
  CHECK(!device.menuOpen() && host.sent.size() == 1 && host.sent[0][5] == 0x08);

  // The help line is flagged as such and closes on click.
  openMenu(device, now);
  sendMenu(device, 20, "Kunde w\xC3\xA4hlen", {{32, 4, "Verlag"}, {32, 8 | 16, ""}}, now);
  CHECK(!device.menuItem(0).info && device.menuItem(1).info && device.menuItem(1).closes);
  host.sent.clear();
  device.rotate(1, now);
  device.click();
  CHECK(!device.menuOpen() && host.sent.size() == 1 && host.sent[0][5] == 0x08);

  // A second long press closes too.
  openMenu(device, now);
  sendMenu(device, 9, "Zeiterfassung", {{31, 2, "Stopp"}}, now);
  host.sent.clear();
  openMenu(device, now);
  CHECK(!device.menuOpen() && host.sent.size() == 1 && host.sent[0][5] == 0x08);

  // A page that arrives while the menu is closed is not shown later.
  sendMenu(device, 10, "Sp\xC3\xA4t", {{29, 0, "x"}}, now);
  feed(device, status(all), now);
  openMenu(device, now);
  CHECK(device.menuOpen() && device.menuCount() == 0);

  // A broken page (line missing) keeps what is shown.
  sendMenu(device, 11, "Zeiterfassung", {{30, 0, "Neuer Job"}}, now);
  feed(device, menuBegin(12, 3, 0, "Kaputt"), now);
  feed(device, menuItem(0, 29, 0, "x"), now);
  feed(device, menuEnd(), now);
  CHECK(device.menuCount() == 1 && strcmp(device.menuTitle(), "Zeiterfassung") == 0);

  // An error from the service is shown with its text.
  feed(device, timerResult(2, "Archiviert"), now);
  CHECK(!device.menuOpen() && device.screen() == dd::Screen::TimerNotice && strcmp(device.noticeText(), "Archiviert") == 0);

  // Left alone, the menu closes after the timeout; input keeps it open.
  now += 2000;
  feed(device, status(all), now);
  openMenu(device, now);
  sendMenu(device, 13, "Zeiterfassung", {{30, 0, "Neuer Job"}, {34, 8, "x"}}, now);
  now += dd::kMenuTimeoutMs - 1000;
  feed(device, status(all), now);
  device.rotate(1, now);
  now += dd::kMenuTimeoutMs - 1000;
  feed(device, status(all), now);
  device.tick(now);
  CHECK(device.menuOpen());
  host.sent.clear();
  now += 2000;
  feed(device, status(all), now);
  device.tick(now);
  CHECK(!device.menuOpen() && host.sent.size() == 1 && host.sent[0][5] == 0x08);

  // Without service the menu opens but has nothing to choose.
  now += dd::kHeartbeatTimeoutMs + 1;
  device.tick(now);
  openMenu(device, now);
  CHECK(device.menuOpen() && !device.serviceConnected() && device.menuCount() == 0);
  host.sent.clear();
  device.click();
  CHECK(device.menuOpen() && host.sent.empty());
}

static void testClock() {
  char text[12];
  dd::formatElapsed(0, text);
  CHECK(strcmp(text, "00:00") == 0);
  dd::formatElapsed(59 * 60 + 59, text);
  CHECK(strcmp(text, "59:59") == 0);
  dd::formatElapsed(3600, text);
  CHECK(strcmp(text, "1:00") == 0);
  dd::formatElapsed(12 * 3600 + 5 * 60 + 59, text);
  CHECK(strcmp(text, "12:05") == 0);

  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  feed(device, status(dd::kStatusLightroom), 10000);
  feed(device, timerState(true, 4, 125, "Job"), 10000);
  CHECK(device.timerSeconds(10000) == 125 && device.timerSeconds(10999) == 125 && device.timerSeconds(11000) == 126);

  // The display is refreshed once per second, not more often.
  device.tick(10100);
  const uint32_t revision = device.revision();
  device.tick(10900);
  CHECK(device.revision() == revision);
  feed(device, status(dd::kStatusLightroom), 11000);
  const uint32_t afterStatus = device.revision();
  device.tick(11000);
  CHECK(device.revision() == afterStatus + 1);

  // A later TimerState corrects drift.
  feed(device, status(dd::kStatusLightroom), 70000);
  feed(device, timerState(true, 4, 190, "Job"), 70000);
  CHECK(device.timerSeconds(70500) == 190);

  // Without service the clock is not shown; the service sends it again later.
  device.tick(70000 + dd::kHeartbeatTimeoutMs + 1);
  CHECK(!device.timerRunning());
}

static void testDoubleTap() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto), 0);
  device.rotate(2, 0);

  // In the carousel a tap is a click, once it is clear that no press of the
  // knob comes with it.
  device.tap(100);
  device.tick(100 + dd::kTapConfirmMs);
  CHECK(device.mode() == dd::Mode::Select);
  device.tick(101 + dd::kTapConfirmMs);
  CHECK(device.mode() == dd::Mode::Edit);

  // In edit mode a single tap waits for a possible second one, then clicks.
  host.sent.clear();
  device.tap(1000);
  device.tick(1000 + dd::kDoubleTapMs);
  CHECK(device.mode() == dd::Mode::Edit && host.sent.empty());
  device.tick(1000 + dd::kDoubleTapMs + 1);
  CHECK(device.mode() == dd::Mode::Select && host.sent.size() == 1 && host.sent[0][5] == 0x03);

  // Two taps in edit mode reset the slot and stay in edit mode.
  device.tap(2000);
  device.tick(2001 + dd::kTapConfirmMs);
  CHECK(device.mode() == dd::Mode::Edit);
  host.sent.clear();
  device.tap(3000);
  device.tap(3200);
  const uint8_t expected[] = {0xF0, 0x7D, 0x44, 0x44, 1, 0x09, 0x00, 0x02, 0xF7};
  CHECK(host.sent.size() == 1 && host.sent[0] == Bytes(expected, expected + sizeof(expected)));
  device.tick(4000);
  CHECK(device.mode() == dd::Mode::Edit && host.sent.size() == 1);

  // Two slow taps are two clicks.
  device.tap(4500);
  device.tick(4500 + dd::kDoubleTapMs + 1);
  CHECK(device.mode() == dd::Mode::Select);
}

static void testTouchWithKnob() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto), 0);

  // Pressing the knob puts a finger on the glass: the tap that comes with a
  // click must not count as a second click.
  device.buttonDown(1000);
  CHECK(!device.tap(1050));
  device.buttonUp(1100);
  CHECK(!device.tap(1150));
  CHECK(device.mode() == dd::Mode::Edit);
  device.tick(1100 + dd::kDoubleTapMs + 100);
  CHECK(device.mode() == dd::Mode::Edit);

  // The menu survives the release of the long press and the tap it causes.
  feed(device, status(dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto), 3000);
  host.sent.clear();
  device.buttonDown(3000);
  device.tick(3000 + dd::kLongPressMs);
  CHECK(device.menuOpen());
  device.buttonUp(3900);
  CHECK(!device.tap(3950));
  CHECK(!device.longTouch(3950));
  device.tick(4100);
  CHECK(device.menuOpen() && host.sent.size() == 1);  // only MenuOpen
  sendMenu(device, 1, "Zeiterfassung", {{30, 0, "Neuer Job"}, {34, 8, "Schlie\xC3\x9F"}}, 4100);

  // Once the knob has been left alone, a tap selects as before.
  CHECK(device.tap(3900 + dd::kTouchGuardMs));
  device.tick(3901 + dd::kTouchGuardMs + dd::kTapConfirmMs);
  CHECK(device.menuOpen() && host.sent.size() == 2 && host.sent[1][5] == 0x07);
  feed(device, timerResult(0), 4500);
  CHECK(!device.menuOpen());

  // Long touch in edit mode resets the slot; elsewhere it does nothing.
  host.sent.clear();
  CHECK(device.mode() == dd::Mode::Edit);
  CHECK(device.longTouch(6000));
  CHECK(host.sent.size() == 1 && host.sent[0][5] == 0x09);
  device.click();
  CHECK(device.mode() == dd::Mode::Select && !device.longTouch(7000));
}

static void testSleep() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  const uint8_t all = dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto;
  auto heartbeat = [&](uint32_t from, uint32_t to) {
    for (uint32_t t = from; t <= to; t += 2000) {
      feed(device, status(all), t);
      device.tick(t);
    }
  };

  // Defaults: the logo after 3 minutes, dark after 10.
  device.rotate(1, 1000);
  heartbeat(1000, 1000 + dd::kIdleMs);
  CHECK(device.idle() && !device.asleep());
  heartbeat(1000 + dd::kIdleMs, 1000 + dd::kSleepMs);
  CHECK(device.asleep() && !device.idle() && device.screen() == dd::Screen::Idle);
  // A touch wakes it and does nothing else.
  host.sent.clear();
  CHECK(device.tap(1000 + dd::kSleepMs + 500));
  device.tick(1000 + dd::kSleepMs + 1500);
  CHECK(!device.asleep() && !device.idle() && host.sent.empty() && device.mode() == dd::Mode::Select);

  // From the app: logo after 1 minute, dark after 2.
  uint32_t now = 1000 + dd::kSleepMs + 2000;
  feed(device, idleTimes(60, 120), now);
  device.rotate(1, now);
  heartbeat(now, now + 60000);
  CHECK(device.idle());
  heartbeat(now + 60000, now + 120000);
  CHECK(device.asleep());
  device.rotate(1, now + 121000);  // the knob wakes it too
  CHECK(!device.asleep());

  // Never: no logo, no dark display.
  now += 130000;
  feed(device, idleTimes(0, 0), now);
  heartbeat(now, now + 2 * dd::kSleepMs);
  CHECK(!device.idle() && !device.asleep());
  // Only dark, no logo before.
  feed(device, idleTimes(0, 300), now + 2 * dd::kSleepMs);
  device.rotate(1, now + 2 * dd::kSleepMs);
  heartbeat(now + 2 * dd::kSleepMs, now + 2 * dd::kSleepMs + 290000);
  CHECK(!device.idle() && !device.asleep());
  heartbeat(now + 2 * dd::kSleepMs + 290000, now + 2 * dd::kSleepMs + 302000);
  CHECK(device.asleep());
}

static void testIdle() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  const uint8_t all = dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto;
  // The service keeps talking; that alone does not count as use.
  auto heartbeat = [&](uint32_t from, uint32_t to) {
    for (uint32_t t = from; t <= to; t += 2000) {
      feed(device, status(all), t);
      device.tick(t);
    }
  };

  device.rotate(1, 1000);
  heartbeat(1000, 1000 + dd::kIdleMs - 2000);
  CHECK(!device.idle() && device.screen() == dd::Screen::Slot);
  feed(device, value(0, 100, true, "+1"), 100000);  // a change in Lightroom is not use either
  uint32_t now = 1000 + dd::kIdleMs;
  feed(device, status(all), now);
  device.tick(now);
  CHECK(device.idle() && device.screen() == dd::Screen::Idle);

  // Turning brings the display back and does nothing else.
  const uint8_t index = device.index();
  host.sent.clear();
  device.rotate(1, now + 1000);
  CHECK(!device.idle() && device.index() == index && host.sent.empty());
  device.rotate(1, now + 1100);
  CHECK(device.index() == index + 1);

  // A press wakes without clicking - however long it is held - and the tap
  // that comes with it is ignored too.
  heartbeat(now + 2000, now + 2000 + dd::kIdleMs);
  now += 2000 + dd::kIdleMs;
  CHECK(device.idle());
  device.buttonDown(now);
  CHECK(!device.idle());
  feed(device, status(all), now + 600);
  device.tick(now + 900);
  CHECK(!device.tap(now + 950));
  device.buttonUp(now + 1000);
  CHECK(device.mode() == dd::Mode::Select && !device.menuOpen());
  // The next press works as usual.
  device.buttonDown(now + 3000);
  device.buttonUp(now + 3100);
  CHECK(device.mode() == dd::Mode::Edit);

  // A tap wakes without clicking; edit mode is still there afterwards.
  heartbeat(now + 4000, now + 4000 + dd::kIdleMs);
  now += 4000 + dd::kIdleMs;
  CHECK(device.idle());
  host.sent.clear();
  CHECK(device.tap(now));
  CHECK(!device.idle() && device.mode() == dd::Mode::Edit && host.sent.empty());
  CHECK(device.screen() == dd::Screen::Slot);

  // A long touch wakes without resetting the slot.
  heartbeat(now + 2000, now + 2000 + dd::kIdleMs);
  now += 2000 + dd::kIdleMs;
  CHECK(device.idle());
  CHECK(device.longTouch(now) && !device.idle() && host.sent.empty());

  // Holding the knob does not let the display fall asleep under the finger.
  device.buttonDown(now + 1000);
  feed(device, status(all), now + 1000 + dd::kIdleMs);
  device.tick(now + 1000 + dd::kIdleMs + 10);
  CHECK(!device.idle());
}

static void testFollowLightroom() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  const uint8_t all = dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto;
  feed(device, status(all), 0);

  // From the carousel: go to the slot and into edit mode, and say so.
  feed(device, slotGoto(4), 100);
  CHECK(device.index() == 4 && device.mode() == dd::Mode::Edit);
  CHECK(host.sent.size() == 1 && host.sent[0][5] == 0x02);

  // Already there: nothing happens.
  feed(device, slotGoto(4), 200);
  CHECK(host.sent.size() == 1);

  // From another slot in edit mode: leave that one, select the new one.
  host.sent.clear();
  feed(device, slotGoto(1), 300);
  CHECK(device.index() == 1 && device.mode() == dd::Mode::Edit);
  CHECK(host.sent.size() == 2 && host.sent[0][5] == 0x03 && host.sent[1][5] == 0x02);
  // The knob continues on the new slot.
  host.sent.clear();
  device.rotate(1, 1000);
  CHECK(host.sent.size() == 1 && host.sent[0][0] == 0xB0);

  // Out of range and while the menu is open: ignored.
  host.sent.clear();
  feed(device, slotGoto(40), 1100);
  CHECK(device.index() == 1 && host.sent.empty());
  device.buttonDown(2000);
  device.tick(2000 + dd::kLongPressMs);
  device.buttonUp(2600);
  host.sent.clear();
  feed(device, slotGoto(3), 2700);
  CHECK(device.menuOpen() && device.index() == 1 && host.sent.empty());
}

// The last message the device sent is a LibraryAction with this action.
static bool sentAction(const RecordingHost &host, uint8_t action) {
  if (host.sent.empty()) return false;
  const Bytes &m = host.sent.back();
  uint8_t payload[8];
  return m.size() > 7 && m[5] == 0x0A && dd::unpack7(m.data() + 6, m.size() - 7, payload) == 1 && payload[0] == action;
}

static void testLibrary() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  const uint8_t all = dd::kStatusLightroom | dd::kStatusPhoto;
  feed(device, status(all), 0);
  CHECK(device.screen() == dd::Screen::Slot);

  // Without the Library mode the knob selects a slot, as a tap does.
  device.buttonDown(1000);
  device.buttonUp(1050);
  CHECK(device.mode() == dd::Mode::Edit && host.sent.size() == 1 && host.sent[0][5] == 0x02);
  device.buttonDown(2000);
  device.buttonUp(2050);
  CHECK(device.mode() == dd::Mode::Select);

  // The service offers the Library mode: in Develop the knob now asks for
  // the Library and leaves the slot alone; a tap selects it.
  feed(device, library(dd::kLibraryKnob), 3000);
  CHECK(device.screen() == dd::Screen::Slot);
  host.sent.clear();
  device.buttonDown(3000);
  device.buttonUp(3050);
  CHECK(host.sent.size() == 1 && sentAction(host, dd::kActionToggleModule) && device.mode() == dd::Mode::Select);
  host.sent.clear();
  CHECK(device.tap(4000));
  device.tick(4001 + dd::kTapConfirmMs);
  CHECK(device.mode() == dd::Mode::Edit && host.sent.size() == 1 && host.sent[0][5] == 0x02);
  device.buttonDown(4600);
  device.buttonUp(4650);
  CHECK(sentAction(host, dd::kActionToggleModule) && device.mode() == dd::Mode::Edit);
  // In edit mode a tap waits for a second one (the reset) before it leaves.
  feed(device, status(all), 5000);
  device.tap(5200);
  device.tick(5201 + dd::kDoubleTapMs);
  CHECK(device.mode() == dd::Mode::Select);

  // The service says Lightroom shows the Library.
  const uint8_t both = dd::kLibraryActive | dd::kLibraryKnob | dd::kLibraryTap | dd::kLibraryDoubleTap;
  feed(device, library(both | dd::kLibraryPicked, 3, 2, "IMG_0042.CR3"), 6000);
  CHECK(device.screen() == dd::Screen::Library);
  CHECK(device.libraryPicked() && !device.libraryRejected() && device.libraryRating() == 3);
  CHECK(device.libraryColor() == 2 && strcmp(device.libraryName(), "IMG_0042.CR3") == 0);

  // Turning browses: plain rotation, never accelerated, and no slot changes.
  host.sent.clear();
  const uint8_t index = device.index();
  device.rotate(1, 6100);
  device.rotate(1, 6105);
  device.rotate(-2, 6110);
  CHECK(host.sent.size() == 3 && host.sent[0][0] == 0xB0 && host.sent[0][2] == 65 && host.sent[1][2] == 65 &&
        host.sent[2][2] == 62);
  CHECK(device.index() == index && device.mode() == dd::Mode::Select);

  // A click of the knob asks for Develop and is no slot click.
  feed(device, status(all), 7000);
  device.buttonDown(7000);
  device.buttonUp(7050);
  CHECK(sentAction(host, dd::kActionToggleModule) && device.mode() == dd::Mode::Select);

  // A tap waits for a second one; alone it is the tap action.
  host.sent.clear();
  CHECK(device.tap(8000));
  device.tick(8000 + dd::kDoubleTapMs);
  CHECK(host.sent.empty());
  device.tick(8001 + dd::kDoubleTapMs);
  CHECK(host.sent.size() == 1 && sentAction(host, dd::kActionTap));
  // Two taps are the double-tap action, and only that.
  host.sent.clear();
  feed(device, status(all), 9000);
  device.tap(9000);
  device.tap(9200);
  device.tick(9200 + 2 * dd::kDoubleTapMs);
  CHECK(host.sent.size() == 1 && sentAction(host, dd::kActionDoubleTap));
  // A long touch does nothing here.
  host.sent.clear();
  CHECK(!device.longTouch(10000) && host.sent.empty());

  // Without a double-tap action a tap acts at once; without a tap action it
  // does nothing.
  feed(device, status(all), 11000);
  feed(device, library(dd::kLibraryActive | dd::kLibraryTap), 11000);
  device.tap(11100);
  CHECK(host.sent.empty());
  device.tick(11101 + dd::kTapConfirmMs);
  CHECK(host.sent.size() == 1 && sentAction(host, dd::kActionTap));

  // A finger that touches the glass on its way to pressing the knob: the tap
  // is dropped, in the Library (no mark) and in Develop (no slot selected).
  host.sent.clear();
  feed(device, status(all), 11500);
  device.tap(11600);
  device.buttonDown(11700);
  device.tick(11800);
  device.buttonUp(11850);
  CHECK(!device.tap(11900));
  device.tick(12500);
  CHECK(host.sent.size() == 1 && sentAction(host, dd::kActionToggleModule));
  feed(device, library(dd::kLibraryKnob), 12600);
  host.sent.clear();
  device.tap(12700);
  device.buttonDown(12800);
  device.buttonUp(12900);
  CHECK(!device.tap(12950));
  device.tick(13500);
  CHECK(host.sent.size() == 1 && sentAction(host, dd::kActionToggleModule) && device.mode() == dd::Mode::Select);
  host.sent.clear();
  host.sent.clear();
  feed(device, status(all), 13600);
  feed(device, library(dd::kLibraryActive | dd::kLibraryDoubleTap), 13600);
  device.tap(13700);
  device.tick(13700 + 2 * dd::kDoubleTapMs);
  CHECK(host.sent.empty());
  device.tap(14500);
  device.tap(14600);
  CHECK(sentAction(host, dd::kActionDoubleTap));
  feed(device, status(all), 15000);
  feed(device, library(dd::kLibraryActive), 15000);
  host.sent.clear();
  device.tap(15100);
  device.tick(15900);
  CHECK(host.sent.empty());

  // The time tracking menu works from the Library as from anywhere.
  feed(device, status(all), 16000);
  feed(device, library(both), 16000);
  device.buttonDown(16000);
  device.tick(16000 + dd::kLongPressMs);
  device.buttonUp(16700);
  CHECK(device.menuOpen() && device.screen() == dd::Screen::JobMenu);
  feed(device, status(all), 18000);
  device.buttonDown(18000);
  device.tick(18000 + dd::kLongPressMs);
  device.buttonUp(18700);
  CHECK(!device.menuOpen() && device.screen() == dd::Screen::Library);

  // In the menu the knob chooses lines; it does not switch the module.
  feed(device, status(all), 19000);
  device.buttonDown(19000);
  device.tick(19000 + dd::kLongPressMs);
  device.buttonUp(19700);
  sendMenu(device, 1, "Kunde", {{32, 0, "A"}, {33, 0, "B"}}, 19800);
  host.sent.clear();
  device.buttonDown(19900);
  device.buttonUp(19950);
  CHECK(host.sent.size() == 1 && host.sent[0][5] == 0x07);
  feed(device, timerResult(0), 19960);
  device.tick(19961 + dd::kTimerNoticeMs);

  // Back in Develop the device is where it was.
  feed(device, status(all), 20000);
  feed(device, library(dd::kLibraryKnob), 20000);
  CHECK(device.screen() == dd::Screen::Slot && device.index() == index);
  // A lost service ends the Library, too.
  feed(device, library(both), 21000);
  feed(device, status(all), 21000);
  device.tick(21000 + dd::kHeartbeatTimeoutMs + 1);
  CHECK(!device.libraryActive() && device.screen() == dd::Screen::Offline);
}

static void testBleMidi() {
  // Encodes, decodes and compares; returns the number of packets.
  auto roundTrip = [](const Bytes &message, size_t maxPacket, uint32_t nowMs) {
    std::vector<Bytes> packets;
    dd::bleMidiEncode(message.data(), message.size(), nowMs, maxPacket,
                      [&](const uint8_t *p, size_t n) { packets.emplace_back(p, p + n); });
    dd::BleMidiDecoder decoder;
    std::vector<Bytes> out;
    for (const Bytes &p : packets) {
      CHECK(p.size() <= maxPacket && (p[0] & 0xC0) == 0x80);
      decoder.feed(p.data(), p.size(), [&](const uint8_t *m, size_t n) { out.emplace_back(m, m + n); });
    }
    CHECK(out.size() == 1 && out[0] == message);
    return packets.size();
  };

  // A rotation CC: header, timestamp, the three bytes.
  std::vector<Bytes> packets;
  const Bytes cc = {0xB0, 0x11, 66};
  dd::bleMidiEncode(cc.data(), cc.size(), 0x1234, 20, [&](const uint8_t *p, size_t n) { packets.emplace_back(p, p + n); });
  CHECK(packets.size() == 1 && packets[0] == Bytes({static_cast<uint8_t>(0x80 | ((0x1234 >> 7) & 0x3F)),
                                                     static_cast<uint8_t>(0x80 | (0x1234 & 0x7F)), 0xB0, 0x11, 66}));
  CHECK(roundTrip(cc, 20, 5) == 1);

  // Every message the service and the device exchange survives, in one
  // packet when the MTU allows, split over several when it does not.
  const Bytes messages[] = {
      helloRequest(), value(3, 12000, true, "+1.35"), status(7),
      menuItem(2, 32, 4, "Fam. M\xC3\xBCller"), timerState(true, 7, 754, "Hochzeit 2026 Juni"),
      library(dd::kLibraryActive | dd::kLibraryTap, 3, 2, "IMG_0042.CR3"), displayRotation(3, 270),
  };
  for (const Bytes &m : messages) {
    CHECK(roundTrip(m, 244, 77) == 1);
    CHECK(roundTrip(m, 20, 77) >= (m.size() + 4 + 19) / 20);
  }
  uint8_t hello[dd::kMaxSysexBytes];
  const size_t helloSize = dd::buildHello(hello, 0, 7, 0, kSerial, 0xBEEF);
  CHECK(helloSize == 31 && roundTrip(Bytes(hello, hello + helloSize), 20, 1000) == 2);

  // Running status, two messages in one packet, and a packet without header.
  dd::BleMidiDecoder decoder;
  std::vector<Bytes> out;
  auto collect = [&](const uint8_t *m, size_t n) { out.emplace_back(m, m + n); };
  const uint8_t twice[] = {0x80, 0x81, 0xB0, 0x10, 65, 0x82, 0xB0, 0x10, 63, 0x10, 66};
  decoder.feed(twice, sizeof(twice), collect);
  CHECK(out.size() == 3 && out[0] == Bytes({0xB0, 0x10, 65}) && out[1] == Bytes({0xB0, 0x10, 63}) &&
        out[2] == Bytes({0xB0, 0x10, 66}));
  out.clear();
  const uint8_t junk[] = {0x10, 0xB0, 0x10, 65};
  decoder.feed(junk, sizeof(junk), collect);
  CHECK(out.empty());
  // A SysEx cut off by a new message is dropped; the new message counts.
  const uint8_t cut[] = {0x80, 0x81, 0xF0, 0x7D, 0x44, 0x82, 0xB0, 0x10, 65};
  decoder.feed(cut, sizeof(cut), collect);
  CHECK(out.size() == 1 && out[0] == Bytes({0xB0, 0x10, 65}));
}

// The last message the device sent is a DisplayAngle with these values.
static bool sentAngle(const RecordingHost &host, int degrees, bool adjusting) {
  if (host.sent.empty()) return false;
  const Bytes &m = host.sent.back();
  uint8_t p[8];
  return m.size() > 7 && m[5] == 0x0B && dd::unpack7(m.data() + 6, m.size() - 7, p) == 3 &&
         ((p[0] << 8) | p[1]) == degrees && (p[2] != 0) == adjusting;
}

static void testDisplayRotation() {
  RecordingHost host;
  dd::Device device(host, 0, 1, 0, kSerial);
  const uint8_t all = dd::kStatusLightroom | dd::kStatusDevelop | dd::kStatusPhoto;
  feed(device, status(all), 0);
  CHECK(device.displayAngle() == 0);

  // The stored angle is set at start-up and reported when asked.
  device.setRotation(90);
  feed(device, displayRotation(dd::kRotationQuery), 100);
  CHECK(device.displayAngle() == 90 && sentAngle(host, 90, false));

  // The app starts the adjustment: the knob turns the picture in steps,
  // around the full circle, and nothing else.
  feed(device, displayRotation(dd::kRotationBegin), 200);
  CHECK(device.adjustingRotation() && device.screen() == dd::Screen::Rotate && sentAngle(host, 90, true));
  const uint8_t index = device.index();
  host.sent.clear();
  device.rotate(2, 300);
  CHECK(device.displayAngle() == 100 && host.sent.size() == 1 && sentAngle(host, 100, true));
  device.rotate(-21, 400);
  CHECK(device.displayAngle() == 355 && sentAngle(host, 355, true));
  device.rotate(2, 500);
  CHECK(device.displayAngle() == 5 && device.index() == index);

  // Cancelled from the app: back to the stored angle, nothing saved.
  feed(device, displayRotation(dd::kRotationCancel), 600);
  CHECK(!device.adjustingRotation() && device.displayAngle() == 90 && host.rotationSaves == 0);
  CHECK(sentAngle(host, 90, false) && device.screen() == dd::Screen::Slot);

  // Saved from the app.
  feed(device, displayRotation(dd::kRotationBegin), 700);
  device.rotate(-3, 800);
  feed(device, displayRotation(dd::kRotationSave), 900);
  CHECK(!device.adjustingRotation() && device.displayAngle() == 75 && host.rotation == 75 && host.rotationSaves == 1);
  CHECK(sentAngle(host, 75, false));

  // Saved by pressing the knob, or by a tap; neither selects a slot or
  // switches the module.
  feed(device, displayRotation(dd::kRotationBegin), 1000);
  device.rotate(1, 1100);
  host.sent.clear();
  device.buttonDown(1200);
  device.buttonUp(1250);
  CHECK(host.rotation == 80 && host.sent.size() == 1 && sentAngle(host, 80, false) && device.mode() == dd::Mode::Select);
  feed(device, displayRotation(dd::kRotationBegin), 2000);
  device.rotate(1, 2100);
  host.sent.clear();
  CHECK(device.tap(2800));
  device.tick(3400);
  CHECK(host.rotation == 85 && host.sent.size() == 1 && device.mode() == dd::Mode::Select);

  // An unchanged angle is not written again; the long press does nothing
  // while adjusting.
  feed(device, status(all), 4000);
  feed(device, displayRotation(dd::kRotationBegin), 4000);
  device.buttonDown(4100);
  device.tick(4100 + dd::kLongPressMs);
  device.buttonUp(4800);
  CHECK(device.adjustingRotation() && !device.menuOpen());
  feed(device, displayRotation(dd::kRotationSave), 4900);
  CHECK(host.rotationSaves == 3);

  // Set from the app (e.g. back to upright), without the knob.
  feed(device, displayRotation(dd::kRotationSet, 0), 5000);
  CHECK(device.displayAngle() == 0 && host.rotation == 0 && sentAngle(host, 0, false));
  feed(device, displayRotation(dd::kRotationSet, 725), 5100);
  CHECK(device.displayAngle() == 5);

  // A lost service ends the adjustment without saving.
  feed(device, status(all), 6000);
  feed(device, displayRotation(dd::kRotationBegin), 6000);
  device.rotate(4, 6100);
  device.tick(6000 + dd::kHeartbeatTimeoutMs + 1);
  CHECK(!device.adjustingRotation() && device.displayAngle() == 5 && host.rotation == 5);
}

// Feeds the decoder for a time with one state.
static int hold(dd::EncoderDecoder &decoder, uint8_t state, int ms) {
  int net = 0;
  for (int i = 0; i < ms * 1000 / static_cast<int>(dd::EncoderDecoder::kSamplePeriodUs); i++) {
    net += decoder.sample(state);
  }
  return net;
}

static void testEncoder() {
  // Clean signal: clockwise is 0 -> 2 -> 3 -> 1 -> 0, one step per rest state.
  dd::EncoderDecoder decoder;
  CHECK(hold(decoder, 0, 100) == 0);
  CHECK(hold(decoder, 2, 30) == 0);
  CHECK(hold(decoder, 3, 100) == 1);
  CHECK(hold(decoder, 1, 30) + hold(decoder, 0, 100) == 1);
  CHECK(hold(decoder, 1, 30) + hold(decoder, 3, 100) == -1);
  CHECK(hold(decoder, 2, 30) + hold(decoder, 0, 100) == -1);

  // A line that chatters while it settles, and dropouts at rest, add nothing.
  int net = 0;
  for (int i = 0; i < 20; i++) net += hold(decoder, i % 2 ? 0 : 2, 3);
  net += hold(decoder, 2, 20);
  for (int i = 0; i < 20; i++) net += hold(decoder, i % 2 ? 2 : 3, 3);
  net += hold(decoder, 3, 100);
  CHECK(net == 1);
  net = 0;
  for (int i = 0; i < 10; i++) net += hold(decoder, 3, 20) + hold(decoder, 1, 1) + hold(decoder, 3, 5) + hold(decoder, 2, 1);
  CHECK(net == 0);
  // Moving half way and back is no step.
  CHECK(hold(decoder, 1, 60) + hold(decoder, 3, 100) == 0);
  // Both contacts dropping out together at rest looks like a full cycle
  // (0 -> 1 -> 3 -> 2 -> 0) and must not count; neither does one contact
  // that stops conducting for a while.
  CHECK(hold(decoder, 1, 30) + hold(decoder, 0, 100) == 1);
  net = 0;
  for (int i = 0; i < 10; i++) net += hold(decoder, 1, 1) + hold(decoder, 3, 2) + hold(decoder, 2, 1) + hold(decoder, 0, 3);
  CHECK(net + hold(decoder, 0, 100) == 0);
  CHECK(hold(decoder, 2, 60) + hold(decoder, 0, 100) == 0);
  CHECK(hold(decoder, 2, 5) + hold(decoder, 3, 15) + hold(decoder, 2, 5) + hold(decoder, 0, 100) == 0);

  // At speed the knob does not rest: both-open counts in passing, together
  // with the both-closed that follows.
  net = 0;
  for (int i = 0; i < 5; i++) net += hold(decoder, 2, 15) + hold(decoder, 3, 15) + hold(decoder, 1, 15) + hold(decoder, 0, 15);
  CHECK(net == 10);
  net = 0;
  for (int i = 0; i < 5; i++) net += hold(decoder, 1, 15) + hold(decoder, 3, 15) + hold(decoder, 2, 15) + hold(decoder, 0, 15);
  CHECK(net == -10);
}

// Recordings of the real knob; see the head of the fixture for the format.
static void testEncoderRecording(const std::string &fixtures) {
  FILE *file = fopen((fixtures + "/encoder_raw.txt").c_str(), "r");
  CHECK(file != nullptr);
  if (!file) return;
  struct Run {
    int direction, least, most, mostWrong;
    std::vector<std::pair<unsigned long, unsigned>> changes;
  };
  std::vector<Run> runs;
  char line[160];
  while (fgets(line, sizeof(line), file)) {
    Run run;
    unsigned long us;
    unsigned state;
    if (sscanf(line, "run %d %d %d %d", &run.direction, &run.least, &run.most, &run.mostWrong) == 4) {
      runs.push_back(run);
    } else if (!runs.empty() && sscanf(line, "%lu %u", &us, &state) == 2) {
      runs.back().changes.emplace_back(us, state);
    }
  }
  fclose(file);
  CHECK(runs.size() == 8);
  for (const Run &run : runs) {
    dd::EncoderDecoder decoder;
    size_t next = 1;
    unsigned state = run.changes[0].second;
    int right = 0, wrong = 0;
    for (unsigned long us = 0; us < run.changes.back().first + 300000; us += dd::EncoderDecoder::kSamplePeriodUs) {
      while (next < run.changes.size() && run.changes[next].first <= us) state = run.changes[next++].second;
      const int step = decoder.sample(static_cast<uint8_t>(state));
      if (step * run.direction > 0) right += step * run.direction;
      else wrong -= step * run.direction;
    }
    CHECK(wrong <= run.mostWrong);
    CHECK(right >= run.least && right <= run.most);
  }
}

int main(int argc, char **argv) {
  testBleMidi();
  testDisplayRotation();
  testLibrary();
  testEncoder();
  if (argc > 1) testEncoderRecording(argv[1]);
  testFollowLightroom();
  testIdle();
  testSleep();
  testTouchWithKnob();
  testDoubleTap();
  testLongPress();
  testMenu();
  testClock();
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
