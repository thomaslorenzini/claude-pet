#!/bin/sh
# Builds build/ClaudePet.dmg: the app on the left, an Applications link on the right, over a drawn
# background (scripts/dmg-background.swift). The window layout is set through Finder (AppleScript):
# if macOS refuses the automation, the DMG is still produced, just with Finder's default layout.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
VOLNAME="Claude Pet"
DMG=build/ClaudePet.dmg
RW=build/ClaudePet-rw.dmg
STAGE=build/dmg-stage

scripts/bundle.sh

rm -rf "$STAGE" "$RW" "$DMG"
mkdir -p "$STAGE/.background"
# Installed as "Claude Pet.app": the name people read in Applications and Launchpad.
cp -R build/ClaudePet.app "$STAGE/Claude Pet.app"
ln -s /Applications "$STAGE/Applications"
swift scripts/dmg-background.swift build/dmg-bg
# One TIFF holding both resolutions: Finder picks the 2× one on Retina.
tiffutil -cathidpicheck build/dmg-bg/background.png build/dmg-bg/background@2x.png -out "$STAGE/.background/background.tiff" >/dev/null

hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size 64m "$RW"

# Mounted where macOS chooses ("Claude Pet 1" if the name is taken); Finder addresses it by that name.
ATTACH=$(hdiutil attach -readwrite -noverify -noautoopen "$RW")
DEVICE=$(printf '%s\n' "$ATTACH" | awk '/Apple_HFS/ {print $1; exit}')
MOUNT=$(printf '%s\n' "$ATTACH" | awk -F '\t' '/Apple_HFS/ {print $NF; exit}')
DISK=$(basename "$MOUNT")
detach() { hdiutil detach -quiet "$DEVICE" 2>/dev/null || hdiutil detach -quiet -force "$DEVICE"; }
trap detach EXIT

LAYOUT=ok
if ! osascript >/dev/null 2>build/dmg-finder.log <<APPLESCRIPT
with timeout of 60 seconds
  tell application "Finder"
    tell disk "$DISK"
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {200, 120, 800, 520}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 112
      set text size of opts to 13
      set background picture of opts to file ".background:background.tiff"
      set position of item "Claude Pet.app" of container window to {160, 205}
      set position of item "Applications" of container window to {440, 205}
      set extension hidden of item "Claude Pet.app" to true
      update without registering applications
      delay 1
      close
    end tell
  end tell
end timeout
APPLESCRIPT
then
  LAYOUT=failed
fi

# Volume icon: the app's. Added after Finder's pass, which removes a .VolumeIcon.icns found earlier
# (seen on macOS 27), as hdiutil's -srcfolder does. SetFile comes with Xcode's command line tools;
# without it the volume keeps the default icon.
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then SetFile -a C "$MOUNT" 2>/dev/null || true; fi

# Finder writes .DS_Store lazily: give it a moment, then make sure nothing stays open.
sync
sleep 1
rm -rf "$MOUNT/.fseventsd" 2>/dev/null || true
detach
trap - EXIT

hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$RW"

echo "OK : $ROOT/$DMG"
if [ "$LAYOUT" = failed ]; then
  echo "Attention : Finder n'a pas pu mettre en page la fenêtre (automatisation refusée ?)." >&2
  echo "  Le DMG fonctionne, avec la disposition par défaut de Finder. Détail : build/dmg-finder.log" >&2
  echo "  Pour l'autoriser : Réglages Système › Confidentialité et sécurité › Automatisation, puis relance." >&2
fi
