// Darkdial firmware for the Elecrow CrowPanel 1.46" Rotary (ESP32-S3).
//
// Board settings (Tools menu, or tools/build_firmware.sh):
//   Board            ESP32S3 Dev Module
//   USB Mode         USB-OTG (TinyUSB)
//   USB CDC On Boot  Enabled
//   Flash Size       16MB, Partition Scheme: 16M Flash (3MB APP/9.9MB FATFS)
// Libraries: lvgl 9.6, LovyanGFX. LVGL is configured in build_opt.h; no
// lv_conf.h is needed or read.
//
// This file is part of Darkdial, licensed under the GNU General Public
// License v3.0 or later. See LICENSE.

#include "src/board.h"
#include "src/core/device.h"
#include "src/ui.h"
#include "version.h"

#include <Arduino.h>
#include <lvgl.h>

namespace {

class BoardHost : public dd::Host {
 public:
  void send(const uint8_t *bytes, size_t n) override { board::midiSend(bytes, n); }
  void saveConfig(const uint8_t *blob, size_t n) override { board::saveConfig(blob, n); }
};

BoardHost host;
dd::Device *device = nullptr;
dd::SysexAssembler assembler;
volatile bool tapped = false;

void onTap() { tapped = true; }

// Ring LEDs show the mode: off without service, white while browsing, the
// accent (or the slot's colour) while editing.
void updateLeds() {
  static uint32_t shown = 0xFFFFFFFF;
  uint32_t color = 0x000000;
  if (device->serviceConnected()) {
    color = 0x0C0C0C;
    if (device->mode() == dd::Mode::Edit && device->slotCount()) {
      const dd::Slot &slot = device->slot(device->index());
      // A quarter of full brightness is plenty next to the display.
      color = slot.hasColor() ? ((slot.r / 4) << 16 | (slot.g / 4) << 8 | (slot.b / 4)) : 0x402802;
    }
  }
  if (color == shown) return;
  shown = color;
  board::setLeds(color >> 16, (color >> 8) & 0xFF, color & 0xFF);
}

}  // namespace

void setup() {
  Serial.begin(115200);
  board::begin();

  uint8_t serial[6];
  board::serial(serial);
  static dd::Device instance(host, DD_FW_MAJOR, DD_FW_MINOR, DD_FW_PATCH, serial);
  device = &instance;

  static uint8_t stored[dd::kMaxStoredConfigBytes];
  const size_t size = board::loadConfig(stored, sizeof(stored));
  if (size) device->loadStored(stored, size);

  ui_init(onTap, millis());
  lv_timer_handler();
  board::setBacklight(80);
  Serial.printf("Darkdial %d.%d.%d, protocol %d.%d\n", DD_FW_MAJOR, DD_FW_MINOR, DD_FW_PATCH, dd::kProtocolMajor,
                dd::kProtocolMinor);
}

void loop() {
  const uint32_t now = millis();

  uint8_t packet[4];
  while (board::midiRead(packet)) {
    if (assembler.feedPacket(packet)) device->onMessage(assembler.data(), assembler.size(), now);
  }

  const int detents = board::readDetents();
  if (detents) device->rotate(detents, now);
  // The knob reports down and up; the core decides between click and long
  // press. Taps on the display go through tap(), which also detects the
  // double tap that resets a slot.
  static bool wasPressed = false;
  const bool pressed = board::buttonPressed();
  if (pressed != wasPressed) {
    wasPressed = pressed;
    if (pressed) {
      device->buttonDown(now);
    } else {
      device->buttonUp(now);
    }
  }
  if (tapped) {
    tapped = false;
    device->tap(now);
  }

  device->tick(now);
  ui_update(*device, now);
  updateLeds();
  lv_timer_handler();
  delay(2);
}
