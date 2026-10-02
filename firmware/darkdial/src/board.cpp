#include "board.h"

#include <Arduino.h>
#include <LovyanGFX.hpp>
#include <Preferences.h>
#include <USB.h>
#include <USBMIDI.h>
#include <Wire.h>
#include <esp_heap_caps.h>
#include <esp_timer.h>
#include <lvgl.h>

#include "core/protocol.h"
#include "panel_crowpanel.h"

#if ARDUINO_USB_MODE
#error "Select Tools > USB Mode > USB-OTG (TinyUSB): USB-MIDI needs the OTG stack."
#endif

namespace {

// Pins, from Elecrow's example for the CrowPanel 1.46" Rotary V1.0.
constexpr int kPinLcdSclk = 10;
constexpr int kPinLcdMosi = 11;
constexpr int kPinLcdDc = 3;
constexpr int kPinLcdCs = 9;
constexpr int kPinLcdReset = 14;
constexpr int kPinLcdPower1 = 1;  // both rails must be on before the LCD takes data
constexpr int kPinLcdPower2 = 2;
constexpr int kPinBacklight = 46;
constexpr int kPinTouchSda = 6;
constexpr int kPinTouchScl = 7;
constexpr int kPinTouchReset = 5;
constexpr int kPinEncoderA = 45;
constexpr int kPinEncoderB = 42;
constexpr int kPinSwitch = 41;      // active low
constexpr int kPinLedData = 48;
constexpr int kPinLedPower = 17;
constexpr int kPinPowerLight = 40;  // active low

constexpr int kDisplaySize = 360;
constexpr int kBufferLines = 60;
constexpr int kLedCount = 8;
constexpr uint8_t kTouchAddress = 0x15;  // CST816T
// +1 or -1: which way of turning counts up. To be confirmed on the device.
constexpr int kEncoderDirection = 1;
constexpr uint32_t kSwitchDebounceMs = 30;

class Display : public lgfx::LGFX_Device {
 public:
  Display() {
    {
      auto cfg = bus_.config();
      cfg.spi_host = SPI2_HOST;
      cfg.spi_mode = 0;
      cfg.freq_write = 80000000;
      cfg.freq_read = 20000000;
      cfg.spi_3wire = true;
      cfg.use_lock = true;
      cfg.dma_channel = SPI_DMA_CH_AUTO;
      cfg.pin_sclk = kPinLcdSclk;
      cfg.pin_mosi = kPinLcdMosi;
      cfg.pin_miso = -1;
      cfg.pin_dc = kPinLcdDc;
      bus_.config(cfg);
      panel_.setBus(&bus_);
    }
    {
      auto cfg = panel_.config();
      cfg.pin_cs = kPinLcdCs;
      cfg.pin_rst = kPinLcdReset;
      cfg.pin_busy = -1;
      cfg.memory_width = kDisplaySize;
      cfg.memory_height = kDisplaySize;
      cfg.panel_width = kDisplaySize;
      cfg.panel_height = kDisplaySize;
      cfg.readable = false;
      cfg.invert = false;
      cfg.rgb_order = true;
      cfg.bus_shared = false;
      panel_.config(cfg);
    }
    setPanel(&panel_);
  }

 private:
  PanelCrowPanel146 panel_;
  lgfx::Bus_SPI bus_;
};

Display display;
USBMIDI midi("Darkdial");
Preferences preferences;

// Quadrature decoder, sampled.
//
// The first run on hardware showed the two encoder lines to be noisy: a slow
// turn in one direction produced bursts of steps in both directions within
// milliseconds, far more than contact bounce explains. Edge interrupts count
// every one of those. So the lines are sampled at a fixed rate instead and
// each must hold its level for kDebounceSamples samples in a row before the
// change is believed. The debounced levels go through the usual transition
// table; the knob has a detent every two transitions.
constexpr uint32_t kSamplePeriodUs = 500;
constexpr int8_t kDebounceSamples = 4;  // 2 ms of a steady level

portMUX_TYPE encoderMux = portMUX_INITIALIZER_UNLOCKED;
int32_t encoderCount = 0;          // detents, guarded by encoderMux
uint32_t encoderRawA = 0;          // raw level changes seen, for diagnostics
uint32_t encoderRawB = 0;

void sampleEncoder(void *) {
  // Index: previous state << 2 | new state, state = A << 1 | B.
  static const int8_t kStep[16] = {0, -1, 1, 0, 1, 0, 0, -1, -1, 0, 0, 1, 0, 1, -1, 0};
  static int8_t levelA = kDebounceSamples, levelB = kDebounceSamples;  // integrators
  static bool rawA = true, rawB = true, a = true, b = true;
  static uint8_t state = 3;
  static int8_t steps = 0;        // transitions not yet turned into a detent
  static int8_t lastStep = 0;
  static uint16_t quietSamples = 0;

  const bool nowA = digitalRead(kPinEncoderA);
  const bool nowB = digitalRead(kPinEncoderB);
  if (nowA != rawA) { rawA = nowA; encoderRawA++; }
  if (nowB != rawB) { rawB = nowB; encoderRawB++; }

  // Integrate: a level only counts once it has been there long enough.
  levelA = nowA ? (levelA < kDebounceSamples ? levelA + 1 : levelA) : (levelA > 0 ? levelA - 1 : 0);
  levelB = nowB ? (levelB < kDebounceSamples ? levelB + 1 : levelB) : (levelB > 0 ? levelB - 1 : 0);
  if (levelA == kDebounceSamples) a = true; else if (levelA == 0) a = false;
  if (levelB == kDebounceSamples) b = true; else if (levelB == 0) b = false;

  const uint8_t next = static_cast<uint8_t>((a << 1) | b);
  if (next == state) {
    // At rest for 150 ms a leftover half step is dropped, so counting stays
    // aligned with the detents.
    if (quietSamples < 300) quietSamples++; else steps = 0;
    return;
  }
  int8_t step = kStep[(state << 2) | next];
  // Both lines switched within one debounce period: a full detent, in the
  // direction the knob was already moving.
  if (step == 0 && quietSamples < 300) step = static_cast<int8_t>(2 * lastStep);
  state = next;
  quietSamples = 0;
  if (step == 0) return;
  lastStep = step > 0 ? 1 : -1;
  steps += step;
  int detents = 0;
  while (steps >= 2) { detents += kEncoderDirection; steps -= 2; }
  while (steps <= -2) { detents -= kEncoderDirection; steps += 2; }
  if (detents) {
    portENTER_CRITICAL(&encoderMux);
    encoderCount += detents;
    portEXIT_CRITICAL(&encoderMux);
  }
}

void flushDisplay(lv_display_t *lvDisplay, const lv_area_t *area, uint8_t *pixels) {
  const int32_t width = area->x2 - area->x1 + 1;
  const int32_t height = area->y2 - area->y1 + 1;
  display.startWrite();
  display.pushImageDMA(area->x1, area->y1, width, height, reinterpret_cast<lgfx::rgb565_t *>(pixels));
  display.waitDMA();
  display.endWrite();
  lv_display_flush_ready(lvDisplay);
}

// CST816T: register 0x02 is the finger count, 0x03 … 0x06 are X and Y. The
// controller sleeps while nothing touches it and then does not answer.
void readTouch(lv_indev_t *, lv_indev_data_t *data) {
  data->state = LV_INDEV_STATE_RELEASED;
  Wire.beginTransmission(kTouchAddress);
  Wire.write(0x02);
  if (Wire.endTransmission(false) != 0) return;
  if (Wire.requestFrom(kTouchAddress, static_cast<uint8_t>(5)) != 5) return;
  const uint8_t fingers = Wire.read();
  const uint8_t xh = Wire.read();
  const uint8_t xl = Wire.read();
  const uint8_t yh = Wire.read();
  const uint8_t yl = Wire.read();
  if (fingers == 0) return;
  data->point.x = ((xh & 0x0F) << 8) | xl;
  data->point.y = ((yh & 0x0F) << 8) | yl;
  data->state = LV_INDEV_STATE_PRESSED;
}

uint32_t tick() { return millis(); }

}  // namespace

namespace board {

void begin() {
  pinMode(kPinPowerLight, OUTPUT);
  digitalWrite(kPinPowerLight, LOW);
  pinMode(kPinLcdPower1, OUTPUT);
  digitalWrite(kPinLcdPower1, HIGH);
  pinMode(kPinLcdPower2, OUTPUT);
  digitalWrite(kPinLcdPower2, HIGH);
  pinMode(kPinLedPower, OUTPUT);
  digitalWrite(kPinLedPower, HIGH);

  // Reset pulse once the rails are up.
  pinMode(kPinLcdReset, OUTPUT);
  digitalWrite(kPinLcdReset, HIGH);
  delay(10);
  digitalWrite(kPinLcdReset, LOW);
  delay(10);
  digitalWrite(kPinLcdReset, HIGH);

  display.init();
  display.initDMA();
  display.fillScreen(TFT_BLACK);

  ledcAttach(kPinBacklight, 5000, 8);
  setBacklight(0);

  pinMode(kPinTouchReset, OUTPUT);
  digitalWrite(kPinTouchReset, LOW);
  delay(10);
  digitalWrite(kPinTouchReset, HIGH);
  delay(50);
  Wire.begin(kPinTouchSda, kPinTouchScl, 400000);

  // Internal pull-ups: harmless next to external ones, and they keep the
  // lines from floating if the board has none.
  pinMode(kPinEncoderA, INPUT_PULLUP);
  pinMode(kPinEncoderB, INPUT_PULLUP);
  pinMode(kPinSwitch, INPUT_PULLUP);
  const esp_timer_create_args_t sampler = {
      .callback = sampleEncoder,
      .arg = nullptr,
      .dispatch_method = ESP_TIMER_TASK,
      .name = "encoder",
      .skip_unhandled_events = true,
  };
  esp_timer_handle_t samplerHandle = nullptr;
  esp_timer_create(&sampler, &samplerHandle);
  esp_timer_start_periodic(samplerHandle, kSamplePeriodUs);

  lv_init();
  lv_tick_set_cb(tick);
  // A partial buffer in internal RAM: DMA-capable and no PSRAM needed.
  const size_t bufferSize = kDisplaySize * kBufferLines * 2;
  void *buffer = heap_caps_malloc(bufferSize, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL);
  lv_display_t *lvDisplay = lv_display_create(kDisplaySize, kDisplaySize);
  lv_display_set_color_format(lvDisplay, LV_COLOR_FORMAT_RGB565);
  lv_display_set_flush_cb(lvDisplay, flushDisplay);
  lv_display_set_buffers(lvDisplay, buffer, nullptr, bufferSize, LV_DISPLAY_RENDER_MODE_PARTIAL);

  lv_indev_t *touch = lv_indev_create();
  lv_indev_set_type(touch, LV_INDEV_TYPE_POINTER);
  lv_indev_set_read_cb(touch, readTouch);
  lv_indev_set_long_press_time(touch, 600);

  preferences.begin("darkdial", false);
  midi.begin();
}

int readDetents() {
  portENTER_CRITICAL(&encoderMux);
  const int32_t count = encoderCount;
  encoderCount = 0;
  portEXIT_CRITICAL(&encoderMux);
  return count;
}

void encoderRawChanges(uint32_t &a, uint32_t &b) {
  a = encoderRawA;
  b = encoderRawB;
}

bool buttonPressed() {
  static bool stable = false;
  static bool last = false;
  static uint32_t changedMs = 0;
  const bool pressed = digitalRead(kPinSwitch) == LOW;
  const uint32_t now = millis();
  if (pressed != last) {
    last = pressed;
    changedMs = now;
  }
  if (pressed != stable && now - changedMs >= kSwitchDebounceMs) stable = pressed;
  return stable;
}

void setLeds(uint8_t r, uint8_t g, uint8_t b) {
  // WS2812 over RMT at 10 MHz, same timing as the core's rgbLedWrite(), for
  // all LEDs of the ring in one frame. Colour order is GRB.
  static rmt_data_t symbols[kLedCount * 24];
  static bool ready = false;
  if (!ready) {
    ready = rmtInit(kPinLedData, RMT_TX_MODE, RMT_MEM_NUM_BLOCKS_1, 10000000);
    if (!ready) return;
  }
  const uint8_t grb[3] = {g, r, b};
  size_t i = 0;
  for (int led = 0; led < kLedCount; led++) {
    for (int channel = 0; channel < 3; channel++) {
      for (int bit = 7; bit >= 0; bit--) {
        const bool one = (grb[channel] >> bit) & 1;
        symbols[i].level0 = 1;
        symbols[i].duration0 = one ? 8 : 4;
        symbols[i].level1 = 0;
        symbols[i].duration1 = one ? 4 : 8;
        i++;
      }
    }
  }
  rmtWrite(kPinLedData, symbols, i, RMT_WAIT_FOR_EVER);
}

void setBacklight(uint8_t percent) {
  if (percent > 100) percent = 100;
  ledcWrite(kPinBacklight, percent * 255 / 100);
}

void serial(uint8_t out[6]) {
  const uint64_t mac = ESP.getEfuseMac();
  for (int i = 0; i < 6; i++) out[i] = static_cast<uint8_t>(mac >> (8 * i));
}

size_t loadConfig(uint8_t *buffer, size_t capacity) {
  const size_t size = preferences.getBytesLength("config");
  if (size == 0 || size > capacity) return 0;
  return preferences.getBytes("config", buffer, capacity);
}

void saveConfig(const uint8_t *blob, size_t size) { preferences.putBytes("config", blob, size); }

bool midiRead(uint8_t packet[4]) {
  midiEventPacket_t event;
  if (!midi.readPacket(&event)) return false;
  packet[0] = event.header;
  packet[1] = event.byte1;
  packet[2] = event.byte2;
  packet[3] = event.byte3;
  return true;
}

void midiSend(const uint8_t *bytes, size_t size) {
  if (size == 3 && (bytes[0] & 0xF0) == 0xB0) {
    midiEventPacket_t event = {0x0B, bytes[0], bytes[1], bytes[2]};  // control change
    midi.writePacket(&event);
    return;
  }
  dd::sysexToPackets(bytes, size, [](const uint8_t *packet) {
    midiEventPacket_t event = {packet[0], packet[1], packet[2], packet[3]};
    midi.writePacket(&event);
  });
}

}  // namespace board
