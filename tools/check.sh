#!/bin/sh
# Runs every automated check of the repository. None of them needs the
# device or Lightroom.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "== generated parameter tables"
python3 tools/gen_params.py --check

echo "== plugin (LuaJIT, fake Lightroom SDK)"
(cd plugin && luajit test/run.lua)

echo "== firmware core and UI snapshots (host build)"
firmware/host/build.sh > /dev/null
firmware/host/build/test_core

echo "== darkdial_core (Dart, incl. engine against the C++ firmware core)"
(cd app/packages/darkdial_core && dart analyze && dart test)

echo "== app (Flutter)"
(cd app && flutter analyze && flutter test)

echo "== firmware for the ESP32-S3"
tools/build_firmware.sh | tail -2

echo "all checks passed"
