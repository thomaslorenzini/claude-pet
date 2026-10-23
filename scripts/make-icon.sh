#!/bin/sh
# Regenerates Resources/AppIcon.icns from the pet's sprite (AppIcon.swift, `--export-icon`).
# Run it after changing the sprite; the .icns is committed, so bundle.sh doesn't need it.
set -e
cd "$(dirname "$0")/.."
swift build
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p build Resources
.build/debug/ClaudePet --export-icon "$ICONSET"
iconutil -c icns -o Resources/AppIcon.icns "$ICONSET"
echo "OK : Resources/AppIcon.icns  (PNG : $ICONSET)"
