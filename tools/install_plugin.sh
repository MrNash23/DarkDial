#!/bin/sh
# Copies the plugin into Lightroom's Modules folder (development install).
# Lightroom loads plugins from there at startup; restart it after installing.
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)/plugin/Darkdial.lrplugin"
DEST="$HOME/Library/Application Support/Adobe/Lightroom/Modules/Darkdial.lrplugin"
mkdir -p "$DEST"
rsync -a --delete "$SRC/" "$DEST/"
echo "installed $(cat "$DEST/version.txt") to $DEST"
