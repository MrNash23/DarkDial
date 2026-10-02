#!/bin/sh
# Compiles the firmware with arduino-cli; with a port as argument it also
# uploads:   tools/build_firmware.sh [/dev/cu.usbmodemXXXX]
#
# Needs the esp32 core 3.x and the libraries lvgl (9.6) and LovyanGFX.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FQBN="esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=16M,PartitionScheme=app3M_fat9M_16MB,PSRAM=opi"
BUILD="$ROOT/firmware/build"
arduino-cli compile --fqbn "$FQBN" --build-path "$BUILD" --warnings default "$ROOT/firmware/darkdial"
if [ -n "$1" ]; then
  # A board already running Darkdial does not react to esptool's reset; opening
  # its serial port at 1200 baud sends it into the bootloader, where it comes
  # back under another port name.
  python3 - "$1" <<'PY'
import fcntl, os, struct, sys, termios, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
attrs = termios.tcgetattr(fd)
attrs[4] = attrs[5] = termios.B1200
termios.tcsetattr(fd, termios.TCSANOW, attrs)
fcntl.ioctl(fd, termios.TIOCMBIC, struct.pack("I", termios.TIOCM_DTR))
time.sleep(0.3)
os.close(fd)
PY
  sleep 3
  PORT="$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)"
  arduino-cli upload --fqbn "$FQBN" --input-dir "$BUILD" -p "${PORT:-$1}" "$ROOT/firmware/darkdial"
fi
