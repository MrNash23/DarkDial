# Darkdial

A dedicated rotary controller for Adobe Lightroom Classic, built on the
Elecrow CrowPanel 1.46″ Rotary (ESP32-S3, 360×360 round display, encoder with
click, 8 WS2812 LEDs).

Turn to pick a slider, click, turn to change it. The ring on the display shows
the value and follows Lightroom live, also when you move a slider with the
mouse.

> **Status:** early development. Nothing here is released yet, and the firmware
> has not run on real hardware so far.

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

## Platforms

macOS 13 or newer first. Windows is planned and follows after the macOS MVP.

## License

Firmware, plugin and app are licensed under the
[GNU General Public License v3.0](LICENSE).

**The name "Darkdial" and the Darkdial logo are not covered by the GPL.**
You are welcome to fork and use the code under the terms of the license, but
forks may not be distributed under the name Darkdial or with this logo.

Darkdial is not affiliated with or endorsed by Adobe. Adobe and Lightroom are
trademarks of Adobe Inc.
