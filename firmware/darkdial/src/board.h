// Everything specific to the Elecrow CrowPanel 1.46" Rotary (ESP32-S3):
// display, touch, encoder, LED ring, backlight, storage and USB-MIDI.
//
// NOT YET VERIFIED ON HARDWARE. Pins and bus settings follow Elecrow's
// published example for this board; docs/BRINGUP.md lists what to check.
#pragma once
#include <stddef.h>
#include <stdint.h>

namespace board {

/// Powers the board up and starts display, LVGL, touch, encoder, LEDs.
void begin();

/// Detents turned since the last call; sign gives the direction.
int readDetents();
/// Debounced state of the knob switch: true while it is held down.
bool buttonPressed();

/// Sets all eight ring LEDs to one colour.
void setLeds(uint8_t r, uint8_t g, uint8_t b);
/// Backlight brightness 0 … 100.
void setBacklight(uint8_t percent);

/// Six-byte serial number (the MAC address).
void serial(uint8_t out[6]);

/// Stored configuration; returns its size, 0 if there is none.
size_t loadConfig(uint8_t *buffer, size_t capacity);
void saveConfig(const uint8_t *blob, size_t size);

/// Next USB-MIDI event packet from the host, false if none is waiting.
bool midiRead(uint8_t packet[4]);
/// Sends one complete MIDI message (control change or SysEx).
void midiSend(const uint8_t *bytes, size_t size);

}  // namespace board
