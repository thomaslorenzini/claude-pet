#!/bin/sh
# Claude Pet status line bridge, installed by install-hooks.py in place of the status line command.
# Forwards the status line JSON (quotas, context window) to the pet, then runs the original status
# line command, saved next to this script, with the same input: what the terminal shows is unchanged.
d="$HOME/Library/Application Support/claude-pet"
p=$(cat)
if read -r port pid < "$d/endpoint" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
  printf '%s' "$p" | curl -s -m 0.5 --connect-timeout 0.2 -H "Expect:" -H "Content-Type: application/json" \
    --data-binary @- "http://127.0.0.1:$port/status" >/dev/null 2>&1
fi
[ -s "$d/statusline-original" ] && printf '%s' "$p" | /bin/sh -c "$(cat "$d/statusline-original")"
exit 0
