#!/bin/sh
# Generates the LVGL fonts of the firmware from Montserrat Medium (SIL Open
# Font License), which ships with the LVGL Arduino library.
#   label: Latin-1, for the short words (umlauts included)
#   value: digits and the few characters a value or a time can contain
#   small: the running time in the gap of the ring
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TTF="${MONTSERRAT_TTF:-$HOME/Documents/Arduino/libraries/lvgl/scripts/generators/built_in_font/Montserrat-Medium.ttf}"
OUT="$ROOT/firmware/darkdial/src/fonts"
mkdir -p "$OUT"
conv() { npx --yes lv_font_conv --font "$TTF" --format lvgl --bpp 4 --no-compress --lv-include lvgl.h "$@"; }
conv --size 28 -r 0x20-0x7E -r 0xA0-0xFF --lv-font-name dd_font_label -o "$OUT/dd_font_label.c"
conv --size 50 --symbols "0123456789+-.:K " --lv-font-name dd_font_value -o "$OUT/dd_font_value.c"
conv --size 24 --symbols "0123456789: " --lv-font-name dd_font_small -o "$OUT/dd_font_small.c"
# The converter records its command line, including local paths; drop it.
sed -i.bak '/^ \* Opts:/d' "$OUT"/dd_font_*.c && rm -f "$OUT"/*.bak
echo "fonts written to $OUT"
