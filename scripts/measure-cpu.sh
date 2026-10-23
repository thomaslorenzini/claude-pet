#!/bin/zsh
# CPU and memory of Claude Pet per state, on a dev instance (port 47400) that hooks never reach.
#   scripts/measure-cpu.sh [binary]     (default: .build/release/ClaudePet)
# Each state: mean CPU % and idle wakeups/s from top, 6 × 5 s. The "mouse moving" case moves the real
# cursor for 30 s with synthetic events.
cd "$(dirname "$0")/.."
BIN=${1:-.build/release/ClaudePet}
MOVE=.build/tools/move-mouse
[ -x $MOVE ] || { mkdir -p .build/tools && swiftc -O -o $MOVE scripts/tools/move-mouse.swift; }
while lsof -nP -iTCP:47400 -sTCP:LISTEN >/dev/null; do sleep 0.3; done
CLAUDE_PET_PORT=47400 CLAUDE_PET_NO_PUBLISH=1 $BIN >/dev/null 2>&1 & P=$!
until curl -s -m 1 127.0.0.1:47400/health >/dev/null; do sleep 0.3; done
sleep 1
ev(){ CLAUDE_PET_PORT=47400 SID=m scripts/fake-event.sh "$@" >/dev/null; }
mv(){ $MOVE 200 700 1200 300 2; $MOVE 1200 300 200 700 2; }
measure(){ label=$1; shift
  ( for i in $(seq 1 8); do "$@"; sleep 4; done ) & L=$!
  top -l 7 -s 5 -pid $P -stats cpu,idlew 2>/dev/null | awk -v label="$label" '
    $1 ~ /^[0-9.]+$/ { n++; if (n > 1) { cpu += $1; w = $2; gsub(/[^0-9]/, "", w); if (n == 2) w0 = w; wl = w } }
    END { if (n < 3) { print label ": MESURE INVALIDE (processus absent)"; exit }
          printf "%-30s CPU %5.2f %%   réveils %5.1f /s\n", label, cpu/(n-1), (wl-w0)/((n-2)*5) }'
  kill $L 2>/dev/null; wait $L 2>/dev/null; }
measure "éveillé au repos (flottant)" ev start
measure "travaille (flottant)" ev tool Bash
curl -s -d '{"notch":true}' 127.0.0.1:47400/control >/dev/null; sleep 2
measure "travaille (encoche)" ev tool Bash
ev stop; sleep 12
measure "endormi (encoche)" true
measure "endormi, souris en mouvement" mv
fp=$(footprint -p $P 2>/dev/null | grep -E 'phys_footprint:' | head -1 | sed -E 's/.*phys_footprint: *//')
echo "RAM : RSS $(( $(ps -o rss= -p $P) / 1024 )) Mo · empreinte physique ${fp:-n/d}"
curl -s -d '{"notch":false}' 127.0.0.1:47400/control >/dev/null; sleep 1.5; kill $P
