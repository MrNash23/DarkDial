# Darkdial

A dedicated rotary controller for Adobe Lightroom Classic, built on the
Elecrow CrowPanel 1.46″ Rotary (ESP32-S3, 360×360 round display, encoder with
click, 8 WS2812 LEDs).

Turn to pick a slider, click, turn to change it. The ring on the display shows
the value and follows Lightroom live, also when you move a slider with the
mouse. A double tap on the display resets the slider.

A long press opens time tracking: choose a client, then one of its jobs or
a new one, and the clock runs; the job that belongs to the collection open in
Lightroom is offered first. Clients are created in the desktop app. The desktop app keeps the books (overview, entries, archive,
search, CSV export); see [docs/darkdial-upgrade-zeiterfassung.md](docs/darkdial-upgrade-zeiterfassung.md).

> **Status:** early development. Nothing here is released yet.

## Parts

| Folder | What | Language |
| --- | --- | --- |
| `firmware/` | Device firmware: carousel UI, value ring, USB-MIDI | C++ (Arduino core 3.x, LVGL 9) |
| `plugin/` | Lightroom Classic plugin: reads and sets Develop sliders | Lua |
| `app/` | Menu-bar service: connects device and plugin, configuration | Dart (Flutter) |
| `protocol/` | `params.json`, the single source of truth for all sliders | JSON |
| `tools/` | Code generators and test tools | Python |
| `docs/` | Developer plan, protocol specification, hardware bring-up | Markdown |

```
Device  ⇄  USB-MIDI  ⇄  Desktop service  ⇄  LrSocket (localhost)  ⇄  Lightroom plugin
```

The protocol is specified in [docs/PROTOCOL.md](docs/PROTOCOL.md), the overall
design in [docs/Developer-Plan.md](docs/Developer-Plan.md) (German).

## Development

Everything can be built and tested without the device and without Lightroom:

```sh
tools/check.sh          # all automated checks
```

| Task | Command |
| --- | --- |
| Run the app | `cd app && flutter run -d macos` |
| Try it without hardware | switch on "Simulator" in the app's info section; the preview is the device (scroll = turn, click = press) |
| Try the real MIDI path without hardware | `swift tools/virtual_device.swift` creates a macOS MIDI device "Darkdial" backed by the firmware core |
| Try it without Lightroom | `cd app/packages/darkdial_core && dart run darkdial_core:fake_lr` |
| Install the plugin for development | `tools/install_plugin.sh`, then restart Lightroom |
| Talk to the plugin directly | `tools/lr_cli.py status` |
| Build / flash the firmware | `tools/build_firmware.sh [port]` |
| Signed macOS release (DMG) | `tools/package_macos.sh`, with `NOTARY_PROFILE=<name>` also notarised |
| See the device screens | `firmware/host/build.sh`, images in `firmware/host/snapshots/` |
| Regenerate tables, icons, fonts | `tools/gen_params.py`, `tools/gen_icons.py`, `tools/gen_fonts.sh` |

Needed: Flutter 3.44+, arduino-cli with the esp32 core 3.x and the libraries
lvgl 9.6 and LovyanGFX, Python 3 (`tools/.venv` with Pillow for the icons),
LuaJIT for the plugin tests.

The first session with real hardware follows [docs/BRINGUP.md](docs/BRINGUP.md).

## Platforms

macOS 13 or newer first. Windows is planned and follows after the macOS MVP.

## License

Firmware, plugin and app are licensed under the
[GNU General Public License v3.0](LICENSE), with one additional term under its
section 7(b), see [ADDITIONAL-TERMS.md](ADDITIONAL-TERMS.md):

**The notice "powered by [meine-belichtungszeit.de](https://meine-belichtungszeit.de)"
must be kept** in every copy and modified version – on the device at start-up,
in the app's info section and in the Lightroom plug-in.

**The name "Darkdial", the Darkdial logo and the meine-Belichtungszeit logo
are not covered by the GPL.** You are welcome to fork and use the code under
the terms of the license, but forks may not be distributed under the name
Darkdial or with these logos as their own.

The firmware fonts are generated from Montserrat (SIL Open Font License 1.1).

Darkdial is not affiliated with or endorsed by Adobe. Adobe and Lightroom are
trademarks of Adobe Inc.
