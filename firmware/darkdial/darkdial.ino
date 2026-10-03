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
  void send(const uint8_t *bytes, size_t n) override {
    board::midiSend(bytes, n);
    // Diagnostics: which Library action a tap or a press turned into
    // (1 tap, 2 double tap, 3 knob).
    if (n > 7 && bytes[0] == 0xF0 && bytes[5] == 0x0A) {
      Serial.printf("[%lu] library action %u\n", millis(), bytes[7]);
    }
  }
  void saveConfig(const uint8_t *blob, size_t n) override { board::saveConfig(blob, n); }
  void saveRotation(uint16_t degrees) override { board::saveRotation(degrees); }
};

BoardHost host;
dd::Device *device = nullptr;
dd::SysexAssembler assembler;
volatile bool tapped = false;
volatile bool longTouched = false;

void onTap() { tapped = true; }
void onLongTouch() { longTouched = true; }

// Diagnostics on the serial port: what opened or closed the time tracking
// menu, and which touches were ignored because they came with a knob press.
const char *lastInput = "boot";
void reportMenu() {
  static bool wasOpen = false;
  if (device->menuOpen() == wasOpen) return;
  wasOpen = device->menuOpen();
  Serial.printf("[%lu] menu %s after: %s\n", millis(), wasOpen ? "opened" : "closed", lastInput);
}

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
  device->setRotation(board::loadRotation());

  ui_init(onTap, onLongTouch, millis());
  lv_timer_handler();
  board::setBacklight(80);
  Serial.printf("Darkdial %d.%d.%d, protocol %d.%d\n", DD_FW_MAJOR, DD_FW_MINOR, DD_FW_PATCH, dd::kProtocolMajor,
                dd::kProtocolMinor);
}

uint32_t loopNow = 0;
void onBleMessage(const uint8_t *message, size_t size) { device->onMessage(message, size, loopNow); }

void loop() {
  const uint32_t now = millis();
  loopNow = now;
  board::bleUpdate(onBleMessage);

  uint8_t packet[4];
  while (board::midiRead(packet)) {
    if (assembler.feedPacket(packet)) device->onMessage(assembler.data(), assembler.size(), now);
  }

  const int detents = board::readDetents();
  if (detents) {
    lastInput = "turn";
    device->rotate(detents, now);
  }
  // The knob reports down and up; the core decides between click and long
  // press. Taps on the display go through tap(), which also detects the
  // double tap that resets a slot.
  static bool wasPressed = false;
  const bool pressed = board::buttonPressed();
  if (pressed != wasPressed) {
    wasPressed = pressed;
    if (pressed) {
      lastInput = "knob down";
      device->buttonDown(now);
    } else {
      lastInput = "knob up";
      device->buttonUp(now);
    }
    Serial.printf("[%lu] %s\n", millis(), lastInput);
  }
  if (tapped) {
    tapped = false;
    const bool used = device->tap(now);
    if (used) lastInput = "tap";
    Serial.printf("[%lu] tap %s\n", millis(), used ? "used" : "ignored (knob in use)");
  }
  if (longTouched) {
    longTouched = false;
    const bool used = device->longTouch(now);
    if (used) lastInput = "long touch";
    Serial.printf("[%lu] long touch %s\n", millis(), used ? "used: reset" : "ignored");
  }

  device->tick(now);
  reportMenu();
  ui_update(*device, now);
  updateLeds();
  lv_timer_handler();
  delay(2);
}
