# Hardware bring-up

The firmware has never run on the CrowPanel. Everything that does not touch
hardware is tested on the Mac (state machine, protocol, the LVGL screens, the
link to the desktop engine). What is listed here is what the first session
with the real board has to prove.

## What is already known to work

| Part | How it was checked |
| --- | --- |
| State machine, protocol, configuration storage format | `firmware/host/build.sh`, 174 checks |
| C++ core against the Dart engine, over the real wire format | `dart test` in `app/packages/darkdial_core` (`firmware_test.dart`) |
| App over real CoreMIDI: detection, SysEx configuration, rotation | app against `tools/virtual_device.swift` (a virtual MIDI device backed by the C++ core) |
| LVGL screens | rendered headless into `firmware/host/snapshots/` |
| Firmware compiles for the ESP32-S3 | `tools/build_firmware.sh`, 1.74 MB of 3 MB |

## Assumptions taken from Elecrow's example

Source: Elecrow's Core 3 / LVGL 9 example for the CrowPanel 1.46″ Rotary V1.0.
Only facts (pins, bus settings) were taken over; the code in
`firmware/darkdial/src/board.cpp` is written for Darkdial.

| Function | Assumption |
| --- | --- |
| LCD | ST77961, SPI2, 3-wire, 80 MHz, SCLK 10, MOSI 11, DC 3, CS 9, RST 14 |
| LCD power | GPIO 1 and GPIO 2 high |
| Backlight | GPIO 46, PWM 5 kHz, 8 bit |
| Touch | CST816T at I²C 0x15, SDA 6, SCL 7, RST 5 |
| Encoder | A 45, B 42, one detent per full cycle of A; switch 41, active low |
| LED ring | 8 × WS2812 on GPIO 48 (GRB), power enable GPIO 17 |
| Power light | GPIO 40, active low |
| Flash / PSRAM | 16 MB flash, OPI PSRAM (the firmware itself does not need PSRAM) |

## Checklist

Flash with `tools/build_firmware.sh /dev/cu.usbmodem…`. If the port is not
there, hold BOOT, press RESET, release BOOT.

1. **Display and USB together (Phase 0, spike A).** After flashing, the boot
   logo appears and the Mac shows a MIDI device named `Darkdial` in
   Audio-MIDI-Setup, plus a serial port. If the display stays dark while USB
   works (or the other way round), note which. Fallback from the developer
   plan: Arduino core 2.0.14 with Adafruit TinyUSB.
2. **Colours.** The logo is neutral grey on black, the thermometer icon goes
   from orange to blue. Swapped red/blue → `cfg.rgb_order`; inverted →
   `cfg.invert`; wrong byte order (noisy colours) → the pixel type in
   `flushDisplay`.
3. **Orientation.** "Offline" reads upright with the USB socket where it
   belongs. Otherwise `display.setRotation()`.
4. **Encoder direction.** In the carousel, turning clockwise should go to the
   next slot. If reversed, flip `kEncoderDirection`.
5. **Encoder quality.** One click of the knob = one slot. Skipped or doubled
   steps → `kEncoderDebounceUs`, or decode both edges.
6. **Knob press** toggles select/edit; no double triggers
   (`kSwitchDebounceMs`).
7. **Touch.** A tap anywhere does the same as the knob press. If nothing
   happens, check the I²C address with a scanner and the reset pin.
8. **LED ring.** Off while no app is connected, dim white in the carousel,
   orange in edit mode. Wrong colours → colour order in `setLeds`.
9. **Backlight** at 80 %, no flicker.
10. **Detection by the app.** With the desktop app running (simulator off) the
    tray icon changes and the info section shows firmware version and serial
    number. The slots of the app's configuration appear on the device, with
    umlauts.
11. **Hot-plug (Phase 0, spike C).** Unplug and replug several times: the app
    reconnects each time without a restart.
12. **Stored configuration.** After replugging, the device shows its slots
    right away, before the app has connected.
13. **End to end.** Lightroom in Develop with a photo: turning in edit mode
    moves the slider, the ring follows; moving the slider with the mouse
    moves the ring.
14. **Acceleration.** Slow turning gives single steps, a quick spin covers a
    large range. Thresholds are in `Accelerator::apply`
    (`firmware/darkdial/src/core/device.cpp`).

## Debug output

The serial port (USB CDC) prints one line at boot. Early boot messages and
crash dumps only appear on the UART pins; keep a USB-TTL adapter at hand.
