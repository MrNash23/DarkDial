#!/bin/sh
# Builds and runs the firmware on the host:
#   test_core   unit tests of the portable core
#   dd_sim      the core as a process (used by the Dart engine tests)
#   snapshot    the LVGL UI rendered into firmware/host/snapshots/*.png
#
# Needs a C/C++ compiler and the LVGL 9 sources (LVGL_DIR, default: the
# Arduino library). PNG conversion needs tools/.venv with Pillow.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SRC="$HERE/../darkdial/src"
OPTS="$HERE/../darkdial/build_opt.h"
LVGL_DIR="${LVGL_DIR:-$HOME/Documents/Arduino/libraries/lvgl}"
BUILD="$HERE/build"
mkdir -p "$BUILD/lvgl" "$HERE/snapshots"

CXXFLAGS="-std=c++17 -O1 -Wall -Wextra"

c++ $CXXFLAGS -o "$BUILD/test_core" "$HERE/test_core.cpp" "$SRC/core/protocol.cpp" "$SRC/core/device.cpp"
"$BUILD/test_core"
c++ $CXXFLAGS -o "$BUILD/dd_sim" "$HERE/dd_sim.cpp" "$SRC/core/protocol.cpp" "$SRC/core/device.cpp"

[ "$1" = "--core-only" ] && exit 0

# LVGL itself, with the firmware's configuration; rebuilt when that changes.
if [ ! -f "$BUILD/liblvgl.a" ] || [ "$OPTS" -nt "$BUILD/liblvgl.a" ]; then
  echo "building LVGL from $LVGL_DIR ..."
  rm -f "$BUILD"/lvgl/*.o
  cd "$LVGL_DIR"
  find src -name '*.c' | while read -r file; do
    printf '%s\0%s\0' "$file" "$BUILD/lvgl/$(echo "$file" | tr '/' '_').o"
  done | xargs -0 -n 2 -P 8 sh -c 'cc -O1 -w "@$0" -I"$1" -c "$2" -o "$3"' "$OPTS" "$LVGL_DIR"
  cd "$HERE"
  ar rcs "$BUILD/liblvgl.a" "$BUILD"/lvgl/*.o
fi

for file in "$SRC/icons.c" "$SRC/fonts/dd_font_label.c" "$SRC/fonts/dd_font_value.c"; do
  cc -O1 -w "@$OPTS" -I"$LVGL_DIR" -c "$file" -o "$BUILD/$(basename "$file").o"
done
c++ $CXXFLAGS "@$OPTS" -I"$LVGL_DIR" -o "$BUILD/snapshot" "$HERE/snapshot.cpp" "$SRC/ui.cpp" \
  "$SRC/core/protocol.cpp" "$SRC/core/device.cpp" "$BUILD"/icons.c.o "$BUILD"/dd_font_*.c.o "$BUILD/liblvgl.a"

rm -f "$HERE"/snapshots/*.ppm "$HERE"/snapshots/*.png
"$BUILD/snapshot" "$HERE/snapshots"

PYTHON="$ROOT/tools/.venv/bin/python"
if [ -x "$PYTHON" ]; then
  "$PYTHON" "$HERE/ppm_to_png.py" "$HERE/snapshots"
else
  echo "tools/.venv missing: snapshots stay as .ppm"
fi
