#include "board.h"

#include <Arduino.h>
#include <LovyanGFX.hpp>
#include <Preferences.h>
#include <USB.h>
#include <USBMIDI.h>
#include <Wire.h>
#include <esp_heap_caps.h>
#include <lvgl.h>

#include "core/protocol.h"

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
constexpr uint32_t kEncoderDebounceUs = 1000;
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
  lgfx::Panel_ST77961 panel_;
  lgfx::Bus_SPI bus_;
};

Display display;
USBMIDI midi("Darkdial");
Preferences preferences;

volatile int32_t encoderCount = 0;
volatile int encoderLastA = HIGH;
volatile uint32_t encoderLastEdgeUs = 0;

// One detent is one full cycle of phase A; direction is phase B at the rising edge.
void IRAM_ATTR onEncoderEdge() {
  const uint32_t now = micros();
  const int a = digitalRead(kPinEncoderA);
  if (a == encoderLastA || now - encoderLastEdgeUs < kEncoderDebounceUs) return;
  encoderLastA = a;
  encoderLastEdgeUs = now;
  if (a == HIGH) {
    encoderCount += (digitalRead(kPinEncoderB) != a) ? kEncoderDirection : -kEncoderDirection;
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

  pinMode(kPinEncoderA, INPUT);
  pinMode(kPinEncoderB, INPUT);
  pinMode(kPinSwitch, INPUT_PULLUP);
  encoderLastA = digitalRead(kPinEncoderA);
  attachInterrupt(digitalPinToInterrupt(kPinEncoderA), onEncoderEdge, CHANGE);

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

  preferences.begin("darkdial", false);
  midi.begin();
}

int readDetents() {
  noInterrupts();
  const int32_t count = encoderCount;
  encoderCount = 0;
  interrupts();
  return count;
}

bool readClick() {
  static bool stable = false;
  static bool last = false;
  static uint32_t changedMs = 0;
  const bool pressed = digitalRead(kPinSwitch) == LOW;
  const uint32_t now = millis();
  if (pressed != last) {
    last = pressed;
    changedMs = now;
  }
  if (pressed != stable && now - changedMs >= kSwitchDebounceMs) {
    stable = pressed;
    return pressed;
  }
  return false;
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
