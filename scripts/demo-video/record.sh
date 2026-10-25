#!/bin/bash
# Records one take of the demo: a private Claude Pet instance (port 47400, invisible to the real
# hooks), a ScreenCaptureKit capture of the wallpaper + the pet only, and the storyboard driver.
#
#   scripts/demo-video/record.sh [work dir]     (default: $TMPDIR/claude-pet-demo)
#
# Output in the work dir: take.mov (HEVC, native 2×, 60 fps), take.mov.json (first frame time),
# cursor.jsonl (driver log), wallpaper.png, cursor.png/.json (system arrow), sprites/.
# Moves the real mouse: don't touch it during the ~40 s take.
set -euo pipefail
cd "$(dirname "$0")/../.."
WORK="${1:-${TMPDIR:-/tmp}/claude-pet-demo}"
mkdir -p "$WORK/hooks-home"
PORT=47400
export CLAUDE_PET_PORT=$PORT

swift build -c release 2>&1 | tail -1
swiftc -O scripts/demo-video/capture.swift -o "$WORK/capture" 2>/dev/null
swiftc -O scripts/demo-video/drive.swift -o "$WORK/drive" 2>/dev/null
swiftc -O scripts/demo-video/menubar.swift -o "$WORK/menubar" 2>/dev/null
swiftc -O scripts/demo-video/cursor.swift -o "$WORK/cursor" 2>/dev/null
"$WORK/cursor" "$WORK/cursor.png" >"$WORK/cursor.json"
rm -rf "$WORK/sprites"; .build/release/ClaudePet --export-sprites "$WORK/sprites" >/dev/null

if curl -s -m 1 "127.0.0.1:$PORT/health" >/dev/null; then
  echo "Something already answers on port $PORT: quit it first." >&2
  exit 1
fi

# The bare binary uses the "ClaudePet" defaults domain, never the app's (local.claude-pet).
defaults write ClaudePet usageAPIEnabled -bool false   # no Keychain, no real quotas
defaults write ClaudePet setupAccepted -bool true
defaults write ClaudePet tutorialDone -bool true
defaults write ClaudePet petScale -int 6
defaults write ClaudePet petInNotch -bool true

# No publishing: this session's own Claude Code hooks must not reach the demo pet.
CLAUDE_PET_NO_PUBLISH=1 CLAUDE_PET_HOOKS_HOME="$WORK/hooks-home" \
  .build/release/ClaudePet -AppleLanguages "(en)" >"$WORK/pet.log" 2>&1 &
PET=$!
MENUBAR=""
trap 'kill $PET $MENUBAR 2>/dev/null || true' EXIT
for _ in $(seq 50); do curl -s -m 1 "127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.1; done
curl -s -d '{"notch":true}' "127.0.0.1:$PORT/control" >/dev/null
"$WORK/drive" move 1185 640 0.5
sleep 1.5

# The menu bar icon is drawn by the system, not capturable: find it from the panel, which opens
# centered under it, and draw it there in the fake menu bar.
curl -s -d '{"panel":true}' "127.0.0.1:$PORT/control" >/dev/null; sleep 0.8
ICON_X=$("$WORK/drive" windows | awk '$2 == 101 { gsub(/[(),]/, " "); print $3 + $5 / 2 }' | head -1)
curl -s -d '{"panel":false}' "127.0.0.1:$PORT/control" >/dev/null; sleep 0.5
[ -n "$ICON_X" ] || { echo "Menu bar icon not found" >&2; exit 1; }
echo "menu bar icon at x $ICON_X"

"$WORK/capture" $PET "$WORK/take.mov" --still "$WORK/wallpaper.png" --wallpaper-only
"$WORK/menubar" "$WORK/wallpaper.png" "$WORK/sprites/idle_0.png" "$ICON_X" &
MENUBAR=$!
sleep 1
"$WORK/capture" $PET,$MENUBAR "$WORK/take.mov" &
CAP=$!
sleep 2
"$WORK/drive" take "$WORK/cursor.jsonl" "$ICON_X" 16
touch "$WORK/take.mov.stop"
wait $CAP
"$WORK/drive" move 1300 700 0.4   # out of the way
echo "take ready in $WORK"
