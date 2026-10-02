# Darkdial protocol

Protocol version **1.2** (1.1 added time tracking, sections 1.7 and 2.4; 1.2 lets the device follow the slider moved in Lightroom). Two links, both bidirectional:

```
Device  ⇄  USB-MIDI  ⇄  Service (desktop app)  ⇄  LrSocket / TCP localhost  ⇄  Plugin
```

The service owns all logic (step sizes, units, formatting, configuration).
Firmware and plugin are translators and stay small.

## Versioning

- The version is `major.minor`. Both links carry it in their hello message.
- A different **major** means incompatible: the service does not use the peer
  and shows a version conflict in its UI.
- A different **minor** is compatible. New message types and new trailing
  fields may be added in a minor version.
- **Unknown message types are ignored** by every party, without an error.
- **Unknown trailing bytes / unknown JSON keys are ignored.**

---

## 1. Device ⇄ Service (MIDI)

The device is a USB-MIDI device with the product name `Darkdial`.

### 1.1 Rotation (device → service)

Rotation in edit mode is sent as a relative Control Change:

| Byte | Value |
| --- | --- |
| Status | `0xB0` (CC, channel 1) |
| Controller | `0x10` (16) |
| Value | `64 + delta`, `delta` in −63 … +63, never 0 |

`delta` is in detents with the firmware's speed acceleration already applied.
The service multiplies it by the slot's step size. Rotation in selection mode
moves the carousel on the device and is not sent.

### 1.2 Device identification (standard MIDI)

Request (service → device): `F0 7E 7F 06 01 F7`

Reply (device → service):

```
F0 7E 7F 06 02  7D  44 44  01 00  <fw major> <fw minor> <fw patch> 00  F7
                │   │      │      └ software revision
                │   │      └ family member (model) 1 = CrowPanel 1.46" Rotary
                │   └ device family "DD"
                └ manufacturer 0x7D (non-commercial)
```

### 1.3 Darkdial SysEx frame

```
F0 7D 44 44 <major> <type> <packed payload …> F7
```

- `7D` non-commercial manufacturer ID, `44 44` = ASCII `DD` project signature.
- `<major>` protocol major version (1).
- `<type>` message type, see below. Types `0x01–0x3F` go device → service,
  `0x40–0x7F` go service → device.
- The payload is a sequence of 8-bit bytes, **packed 7-in-8** for transport.

**7-in-8 packing.** The payload is split into groups of up to 7 bytes. Each
group is sent as one byte holding the most significant bits (bit *i* = MSB of
byte *i* of the group, bit 0 first), followed by the group's bytes with their
MSB cleared. A final group of *n* < 7 bytes is sent as 1 + *n* bytes.

**Field types inside the (unpacked) payload**

| Type | Encoding |
| --- | --- |
| `u8` | one byte |
| `u16` | two bytes, big-endian |
| `str` | `u8` length in bytes, then UTF-8 bytes, no terminator |

A SysEx message is at most 64 bytes on the wire including `F0` and `F7`.

### 1.4 Messages device → service

| Type | Name | Payload | Meaning |
| --- | --- | --- | --- |
| `0x01` | Hello | `8 bytes "DARKDIAL"`, `u8 major`, `u8 minor`, `u8 fwMajor`, `u8 fwMinor`, `u8 fwPatch`, `6 bytes serial`, `u16 configCrc` | Reply to HelloRequest. Serial is the MAC address. `configCrc` is the CRC of the stored configuration, 0 if none. |
| `0x02` | SlotSelect | `u8 slot` | Edit mode entered on this slot. |
| `0x03` | SlotLeave | `u8 slot` | Back in selection mode, on this slot. |
| `0x04` | SlotFocus | `u8 slot` | Carousel moved to this slot in selection mode. |
| `0x05` | ConfigAck | `u8 result`, `u16 crc` | Reply to ConfigEnd. Result: 0 ok, 1 CRC mismatch, 2 too many slots, 3 bad sequence. |
| `0x06` | MenuOpen | – | *1.1.* Long press: the time tracking menu was opened; service answers with the start page and TimerState. |
| `0x07` | MenuSelect | `u8 page`, `u8 index` | *1.1.* The line `index` of page `page` was clicked. Service answers with another page or a TimerResult. |
| `0x08` | MenuClosed | – | *1.1.* The device closed the menu itself: long press, timeout, or a line with the "closes" flag. |
| `0x09` | SlotReset | `u8 slot` | *1.1.* Double tap or long touch on the display in edit mode: reset this slot to Lightroom's default. |

### 1.5 Messages service → device

| Type | Name | Payload | Meaning |
| --- | --- | --- | --- |
| `0x41` | HelloRequest | `u8 major`, `u8 minor`, `u8 appMajor`, `u8 appMinor`, `u8 appPatch` | Third detection stage; device answers with Hello. |
| `0x42` | ConfigBegin | `u8 slotCount`, `u8 language` | Starts a configuration transfer. Language 0 = de, 1 = en (informative). `slotCount` 1 … 48. |
| `0x43` | ConfigSlot | `u8 index`, `u8 paramId`, `u8 iconId`, `u8 flags`, `u8 r`, `u8 g`, `u8 b`, `str label` | One slot. Flags bit 0: bipolar ring. `r g b` is the accent colour of the HSL dot, `0 0 0` = none. Label ≤ 20 bytes. Sent in index order. |
| `0x44` | ConfigEnd | `u16 crc` | CRC over all ConfigSlot payloads. Device answers ConfigAck and, on success, stores the configuration and shows "loaded". |
| `0x45` | Value | `u8 slot`, `u16 position`, `u8 flags`, `str text` | Current value of a slot. `position` 0 … 16383 is the ring position; for bipolar slots 8192 is the centre (top). Flags bit 0: value valid. `text` is the formatted number, ≤ 8 bytes ASCII, e.g. `+1.35`, `5600K`. |
| `0x46` | Status | `u8 flags`, `u8 notice` | Flags bit 0: Lightroom connected, bit 1: Develop module active, bit 2: photo selected. Notice: 0 none, 1 switching to Develop. Sent on every change and at least every 2 s as heartbeat. |
| `0x47` | MenuBegin | `u8 page`, `u8 count`, `u8 selected`, `str title` | *1.1.* Starts a menu page with `count` 0 … 16 lines. `page` is echoed in MenuSelect. `selected` is the line to start on. Title ≤ 20 bytes. |
| `0x48` | MenuItem | `u8 index`, `u8 icon`, `u8 flags`, `str label` | *1.1.* One line. Flags bit 0: highlighted, bit 1: show the running time with it, bit 2: leads to another page, bit 3: choosing it closes the menu on the device, bit 4: help line – the device shows its built-in text "no matching client? create it in the desktop app" instead of the label. Label ≤ 20 bytes. Sent in index order. |
| `0x49` | MenuEnd | – | *1.1.* The page is complete and replaces the one shown. |
| `0x4A` | TimerState | `u8 running`, `u32 jobId`, `u32 elapsedSeconds`, `str label` | *1.1.* State of the clock. `elapsedSeconds` is the time of the running entry so far; the device counts on from there. |
| `0x4C` | SlotGoto | `u8 slot` | *1.2.* The slider of this slot was just moved in Lightroom: the device goes to the slot and into edit mode, and answers with SlotLeave (if it was editing another slot) and SlotSelect. Ignored while the menu is open. |
| `0x4B` | TimerResult | `u8 code`, `str text` | *1.1.* The chosen action is done: the device closes the menu and shows the result briefly. Code 0 started, 1 stopped, ≥ 2 error with `text` (≤ 20 bytes) to show. |

**CRC.** CRC-16/CCITT-FALSE (poly `0x1021`, init `0xFFFF`, no reflection, no
final XOR) over the concatenation of the unpacked payloads of all ConfigSlot
messages in index order.

### 1.6 Sequences

**Detection** (service, for every MIDI port that appears):

1. Port name contains `Darkdial`, otherwise ignore the port.
2. Send Identity Request; expect the reply from 1.2 within 1 s.
3. Send HelloRequest; expect Hello with signature `DARKDIAL` and the same
   major version within 1 s.
4. Send the configuration (always, even if `configCrc` matches — it is cheap
   and keeps the device authoritative-free), then Status and a Value for every
   slot.

**Heartbeat.** If the device receives no Status for 5 s it shows
"not connected" and keeps working from its stored configuration.

**Values.** The service sends a Value for every configured slot whenever the
value changes in Lightroom, not only for the active slot, so the carousel shows
current numbers while browsing. The device never computes values itself: after
a rotation it waits for the Value message.

### 1.7 Time tracking (1.1)

The service owns jobs and times; the device has no real-time clock and only
displays and selects.

- A device announces time tracking by `minor ≥ 1` in Hello. The service sends
  the 1.1 messages only to such devices.
- **Menu.** The service builds the menu, page by page; the device shows one
  line at a time and reports which one was clicked. What a line means (start
  a job, open the clients, go back) is known to the service only, so menus
  can change without new firmware. On a long press the device sends MenuOpen
  and shows the page once MenuEnd arrives.
- **Pages.** After MenuSelect the service sends either another page or a
  TimerResult. A page with the same title as the one shown is an update and
  keeps the selected line; any other page starts on its `selected` line. A
  MenuSelect whose `page` is not the page last sent is ignored.
- **Closing.** A second long press, 20 s without input, or a line with the
  "closes" flag close the menu on the device, which then sends MenuClosed.
- **Clock.** The service sends TimerState after every change, when a device
  connects, and once a minute to correct drift. Between two messages the
  device counts locally.
- Without service the menu shows "offline" and allows no action.
- **Touch.** The knob is the display: pressing it puts a finger on the glass.
  The device ignores touch input while the knob is down and for 500 ms after
  it moved.
- `u32` is four bytes, big-endian.

---

## 2. Service ⇄ Plugin (LrSocket)

`LrSocket` only listens on localhost and each socket carries one direction.
The plugin opens two listening ports; the service connects to both.

| Port | Direction |
| --- | --- |
| 54770 | plugin → service |
| 54771 | service → plugin |

Messages are UTF-8 JSON objects, one per line, terminated by `\n`. The key `t`
holds the message type. Parameters are identified by their Lightroom SDK name
(`Exposure`, `Temperature`, `ParametricHighlights`, `HueAdjustmentRed`, …).

### 2.1 Service → plugin

| `t` | Keys | Meaning |
| --- | --- | --- |
| `hello` | `app` (version string), `proto` (`"1.0"`) | Sent after connecting. Plugin answers `hello`, then `status`. |
| `watch` | `p` (array of parameter names) | Replaces the list of observed parameters. Plugin answers with `range` and `value` for each. |
| `set` | `p`, `v` (number), `s` (sequence number, optional) | Set an absolute value. Plugin clamps to the range, applies it and answers `value` with the same `s`. |
| `delta` | `p`, `d` (number), `s` (optional) | Add `d` to the current value; otherwise like `set`. |
| `get` | `p` | Plugin answers `value`. |
| `reset` | `p`, `s` (optional) | *1.1.* Reset the parameter to Lightroom's default (for white balance: as shot); otherwise like `set`. |
| `track` | `p` (name, or `""` to stop) | Calls `startTracking` / `stopTracking` for smoother continuous changes. |
| `ping` | – | Plugin answers `pong`. |

If `set`, `delta` or `reset` arrives outside the Develop module, the plugin switches to
Develop first, sends `status`, then applies the change.

### 2.2 Plugin → service

| `t` | Keys | Meaning |
| --- | --- | --- |
| `hello` | `plugin` (version string), `proto`, `lr` (Lightroom version string) | Answer to `hello`. |
| `status` | `module` (string), `photo` (bool), `photoId` (number, optional) | Sent on connect and whenever module or target photo changes. |
| `range` | `p`, `min`, `max` | Range for the current photo. Sent after `watch` and after a photo change (Temperature differs between raw and JPEG). |
| `value` | `p`, `v`, `s` (only when answering `set`/`delta`) | Current value. Without `s`: the value changed inside Lightroom (mouse, keyboard, preset, photo change). |
| `pong` | – | Answer to `ping`. |
| `touched` | `p` | *1.2.* Exactly one watched parameter was changed in Lightroom by the user (not by a `set`, and not because another photo was selected). Sent after its `value`. |
| `source` | `kind` (`"collection"`, `"folder"` or `""`), `name`, `id` | *1.1.* Where the photos on screen come from: the active collection or folder, otherwise the folder of the target photo. Sent after `hello` and whenever it changes. `id` is stable for the catalog (collection identifier or folder path). |

### 2.3 Rules

- The service sends `ping` every 2 s. No `pong` or other message for 6 s means
  the connection is dead: the service closes both sockets and reconnects.
- Both sides reconnect in a loop; Lightroom may be started or quit at any time.
- The service bundles rotation into at most one `set` per parameter per flush
  interval and uses the sequence number to ignore stale echoes: a `value` with
  `s` older than the last `set` it sent for that parameter is dropped.
- The plugin reports a `value` without `s` only when the value differs from
  the last one it reported, so its own `set` does not echo twice.

### 2.4 Time tracking (1.1)

The plugin only reports `source`. Matching a source to a job, and everything
else about time tracking, happens in the service.
