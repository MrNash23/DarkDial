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
  arduino-cli upload --fqbn "$FQBN" --input-dir "$BUILD" -p "$1" "$ROOT/firmware/darkdial"
fi
