// The firmware core as a process, driven over stdin/stdout. Lets the Dart
// engine tests talk to the real C++ state machine instead of its Dart twin.
//
// Input lines:            Output lines:
//   M <hex>   MIDI in       M <hex>   MIDI out
//   R <n>     rotate        S <mode> <index> <slots> <screen> <label>|<text>|<position>|<valid>
//   C         click                   (answer to ?)
//   P         tap on the display
//   D / U     knob down / up          then: J <menuOpen> <menuIndex> <menuCount> <running> <seconds> <notice>|<label>
//   T <ms>    advance time
//   ?         report state
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "testing.h"

class StdoutHost : public dd::Host {
 public:
  void send(const uint8_t *bytes, size_t n) override {
    printf("M ");
    for (size_t i = 0; i < n; i++) printf("%02x", bytes[i]);
    printf("\n");
    fflush(stdout);
  }
  void saveConfig(const uint8_t *, size_t) override {}
};

int main() {
  StdoutHost host;
  const uint8_t serial[6] = {0x02, 0x00, 0x51, 0x4D, 0x00, 0x02};
  dd::Device device(host, 0, 1, 0, serial);
  uint32_t nowMs = 0;
  char line[512];
  while (fgets(line, sizeof(line), stdin)) {
    switch (line[0]) {
      case 'M': {
        uint8_t bytes[dd::kMaxSysexBytes * 2];
        size_t n = 0;
        for (const char *p = line + 2; p[0] && p[1] && p[0] != '\n' && n < sizeof(bytes); p += 2) {
          unsigned value = 0;
          sscanf(p, "%2x", &value);
          bytes[n++] = static_cast<uint8_t>(value);
        }
        device.onMessage(bytes, n, nowMs);
        break;
      }
      case 'R':
        device.rotate(atoi(line + 2), nowMs);
        break;
      case 'C':
        device.click();
        break;
      case 'P':
        device.tap(nowMs);
        break;
      case 'L':
        device.longTouch(nowMs);
        break;
      case 'D':
        device.buttonDown(nowMs);
        break;
      case 'U':
        device.buttonUp(nowMs);
        break;
      case 'T':
        nowMs += static_cast<uint32_t>(atoi(line + 2));
        device.tick(nowMs);
        break;
      case '?': {
        const uint8_t i = device.index();
        printf("S %d %d %d %d %s|%s|%d|%d\n", device.mode() == dd::Mode::Edit ? 1 : 0, i, device.slotCount(),
               static_cast<int>(device.screen()), device.slot(i).label, device.value(i).text,
               device.value(i).position, device.value(i).valid ? 1 : 0);
        const char *menuLabel = "";
        if (device.menuOpen()) {
          const dd::MenuEntry entry = device.menuEntry(device.menuIndex());
          menuLabel = entry.kind == dd::MenuKind::Stop ? "<stop>" : entry.kind == dd::MenuKind::NewJob ? "<new>" : entry.job->label;
        }
        printf("J %d %d %d %d %u %d|%s\n", device.menuOpen() ? 1 : 0, device.menuIndex(), device.menuCount(),
               device.timerRunning() ? 1 : 0, static_cast<unsigned>(device.timerSeconds(nowMs)),
               device.screen() == dd::Screen::TimerNotice ? device.noticeCode() : -1, menuLabel);
        fflush(stdout);
        break;
      }
      default:
        break;
    }
  }
  return 0;
}
