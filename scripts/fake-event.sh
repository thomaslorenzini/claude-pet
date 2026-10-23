#!/bin/sh
# Sends fake Claude Code hook events to Claude Pet, to test without Claude.
#
#   fake-event.sh start | prompt | tool [Name] | done [Name] | fail [Name]
#                 permission | notify | idle-notify | stop | stop-fail | end
#   fake-event.sh demo      # plays a whole turn
#   fake-event.sh multi     # two sessions in parallel
#   fake-event.sh state     # prints the aggregated state
#
# SID=<id> picks the session (default: fake-session). CLAUDE_PET_PORT overrides the port.

PORT="${CLAUDE_PET_PORT:-47319}"
URL="http://127.0.0.1:$PORT"
SID="${SID:-fake-session}"

post() { # post <hook_event_name> [extra json fields]
  body="{\"hook_event_name\":\"$1\",\"session_id\":\"$SID\",\"cwd\":\"$PWD\"${2:+,$2}}"
  curl -s -m 1 -H "Content-Type: application/json" --data-binary "$body" "$URL/event" ||
    echo "Claude Pet ne répond pas sur $URL (lancé ?)" >&2
  echo
}

case "$1" in
  start) post SessionStart '"source":"startup"' ;;
  prompt) post UserPromptSubmit '"prompt":"fais un truc"' ;;
  tool) post PreToolUse "\"tool_name\":\"${2:-Bash}\",\"tool_input\":{}" ;;
  done) post PostToolUse "\"tool_name\":\"${2:-Bash}\",\"tool_input\":{},\"tool_response\":{}" ;;
  fail) post PostToolUseFailure "\"tool_name\":\"${2:-Bash}\",\"error\":\"boom\"" ;;
  permission) post PermissionRequest "\"tool_name\":\"${2:-Bash}\"" ;;
  notify) post Notification '"notification_type":"permission_prompt","message":"Claude needs your permission"' ;;
  idle-notify) post Notification '"notification_type":"idle_prompt","message":"Claude is waiting for your input"' ;;
  stop) post Stop ;;
  stop-fail) post StopFailure ;;
  end) post SessionEnd '"reason":"exit"' ;;
  state) curl -s -m 1 "$URL/state"; echo ;;
  demo)
    for step in "start" "prompt" "tool Read" "done Read" "tool Grep" "done Grep" \
                "tool Edit" "done Edit" "tool Bash" "fail Bash" "tool WebFetch" "done WebFetch" \
                "tool Task" "done Task" "permission Bash" "tool Bash" "done Bash" "stop"; do
      echo "→ $step"
      # shellcheck disable=SC2086
      "$0" $step >/dev/null
      sleep 2
    done
    ;;
  multi)
    SID=session-a "$0" prompt >/dev/null
    SID=session-a "$0" tool Bash >/dev/null
    SID=session-b "$0" prompt >/dev/null
    echo "A travaille (Bash), B réfléchit → le pet montre A"; sleep 3
    SID=session-b "$0" notify >/dev/null
    echo "B attend l'utilisateur → le pet montre B (priorité)"; sleep 3
    SID=session-b "$0" tool Edit >/dev/null
    SID=session-b "$0" stop >/dev/null
    echo "B a fini → le pet revient sur A (travaille > content)"; sleep 3
    SID=session-a "$0" stop >/dev/null
    echo "A a fini → content"
    "$0" state
    ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
