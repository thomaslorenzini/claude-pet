#!/bin/sh
# Builds a release binary and wraps it in build/ClaudePet.app (LSUIElement: no Dock icon).
# Version: $VERSION if set, else the latest vX.Y.Z tag, else 0.1.0. The build number is the commit count,
# so it always grows. $BUNDLE_ID only for update tests (an app that never shares the real one's settings).
# Sparkle checks updates against SUPublicEDKey: the matching private key is in Thomas's Keychain
# (account "claude-pet"), never in this repository.
set -e
cd "$(dirname "$0")/.."
if [ -z "$VERSION" ]; then
  VERSION=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')
fi
VERSION=${VERSION:-0.1.0}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
BUNDLE_ID=${BUNDLE_ID:-fr.thomaslorenzini.claude-pet}
FEED=https://github.com/thomaslorenzini/claude-pet/releases/latest/download/appcast.xml
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/ClaudePet.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/ClaudePet" "$APP/Contents/MacOS/ClaudePet"
# ditto keeps the framework's symlinks. Its XPC services are only for sandboxed apps: left out.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
# Generated from the sprite by scripts/make-icon.sh, committed.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Pet</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>ClaudePet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <!-- The app's own texts pick their language in L10n.swift; this tells macOS (and Sparkle's windows). -->
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>fr</string></array>
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>X4r4j4zua39Nq7RIx8HLsoO/sZsIwrlEApdPD0DwISU=</string>
  <key>SURequireSignedFeed</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
</dict>
</plist>
PLIST
# Ad hoc, from the inside out. A broken signature would make Sparkle reject the next update: fail here.
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$FW/Versions/B/Autoupdate"
codesign --force --sign - "$FW/Versions/B/Updater.app"
codesign --force --sign - "$FW"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "OK : $APP $VERSION ($BUILD)  (open $APP)"
