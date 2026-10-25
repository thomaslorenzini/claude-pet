#!/bin/sh
# Signs build/ClaudePet.dmg for Sparkle and writes build/appcast/appcast.xml, to attach to the release next to
# the DMG (the app reads releases/latest/download/appcast.xml). Usage: scripts/make-appcast.sh vX.Y.Z [notes.html]
# The private EdDSA key comes from the login Keychain (account "claude-pet"): generate_appcast asks for it.
# Sparkle's tools: build/sparkle-<version>/bin, from the release that Package.swift pins.
set -e
cd "$(dirname "$0")/.."
TAG=$1
NOTES=$2
[ -n "$TAG" ] || { echo "usage : $0 vX.Y.Z [notes.html]" >&2; exit 1; }
SPARKLE=$(sed -n 's/.*Sparkle", exact: "\([0-9.]*\)".*/\1/p' Package.swift)
TOOLS=build/sparkle-$SPARKLE/bin
if [ ! -x "$TOOLS/generate_appcast" ]; then
  mkdir -p "build/sparkle-$SPARKLE"
  gh release download "$SPARKLE" --repo sparkle-project/Sparkle --pattern "Sparkle-$SPARKLE.tar.xz" --dir "build/sparkle-$SPARKLE" --clobber
  tar -xJf "build/sparkle-$SPARKLE/Sparkle-$SPARKLE.tar.xz" -C "build/sparkle-$SPARKLE"
fi
OUT=build/appcast
rm -rf "$OUT"
mkdir -p "$OUT"
cp build/ClaudePet.dmg "$OUT/ClaudePet.dmg"
# Same base name as the archive: embedded as the release notes Sparkle shows.
[ -n "$NOTES" ] && cp "$NOTES" "$OUT/ClaudePet.html"
"$TOOLS/generate_appcast" --account claude-pet --embed-release-notes \
  --download-url-prefix "https://github.com/thomaslorenzini/claude-pet/releases/download/$TAG/" "$OUT"
# The DMG must be the very file that was signed: compare before uploading.
cmp -s build/ClaudePet.dmg "$OUT/ClaudePet.dmg"
grep -q 'sparkle-signatures' "$OUT/appcast.xml"
echo "OK : $OUT/appcast.xml ($TAG)"
