#!/bin/sh
# Builds a release binary and wraps it in build/ClaudePet.app (LSUIElement: no Dock icon).
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/ClaudePet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudePet "$APP/Contents/MacOS/ClaudePet"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleIdentifier</key><string>local.claude-pet</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "OK : $APP  (open $APP)"
