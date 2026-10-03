#!/bin/sh
# Builds the firmware and puts it into the app, which can then update the
# device by itself:   tools/bundle_firmware.sh
#
# Writes app/assets/firmware/darkdial-firmware.bin (the merged image written
# at 0, trailing erased flash cut off) and firmware.json with its version.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/tools/build_firmware.sh" > /dev/null
OUT="$ROOT/app/assets/firmware"
mkdir -p "$OUT"
python3 - "$ROOT" "$OUT" <<'PY'
import json, re, sys
root, out = sys.argv[1], sys.argv[2]
data = open(f"{root}/firmware/build/darkdial.ino.merged.bin", "rb").read()
end = len(data)
while end > 0 and data[end - 1] == 0xFF:
    end -= 1
end = (end + 3) & ~3
open(f"{out}/darkdial-firmware.bin", "wb").write(data[:end])
header = open(f"{root}/firmware/darkdial/version.h").read()
parts = [re.search(rf"DD_FW_{k} (\d+)", header).group(1) for k in ("MAJOR", "MINOR", "PATCH")]
json.dump({"version": ".".join(parts)}, open(f"{out}/firmware.json", "w"))
print(f"bundled firmware {'.'.join(parts)} ({end} bytes)")
PY
