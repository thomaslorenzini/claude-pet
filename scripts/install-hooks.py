#!/usr/bin/env python3
"""Add or remove the Claude Pet hooks in ~/.claude/settings.json.

Idempotent: our entries are tagged with MARKER, removed first, then re-added.
Other hooks are left untouched. Shows a diff and asks before writing; backs up the file.

    install-hooks.py install   [--dry-run] [--yes] [--settings PATH]
    install-hooks.py uninstall [--dry-run] [--yes] [--settings PATH]
"""

import argparse
import copy
import datetime
import difflib
import json
import os
import shutil
import sys
import tempfile

MARKER = "# claude-pet-hook"
# Written by the app once its server listens: "<port> <pid>". The port can change if it was taken.
ENDPOINT = "$HOME/Library/Application Support/claude-pet/endpoint"

# Events whose matcher filters on tool name; the others take no matcher.
TOOL_EVENTS = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
OTHER_EVENTS = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "Notification",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
]


def hook_command():
    # Find the pet through its endpoint file with shell builtins only (read, kill -0): when the pet
    # is not running, the hook costs no extra process at all.
    # Synchronous on purpose: a background post lets a large PostToolUse overtake the next
    # PreToolUse and show the wrong state. Measured cost: ~10 ms per hook, ~30 ms for a 5 MB
    # payload, 1 s at most if the app hangs.
    # "Expect:" stops curl from waiting for a 100-continue on bodies over 1 MB.
    return (
        f"/bin/sh -c 'f=\"{ENDPOINT}\"; read -r port pid < \"$f\" 2>/dev/null && kill -0 \"$pid\" 2>/dev/null && "
        "curl -s -m 1 --connect-timeout 0.2 -H \"Expect:\" -H \"Content-Type: application/json\" "
        f"--data-binary @- \"http://127.0.0.1:$port/event\" >/dev/null 2>&1; exit 0' {MARKER}"
    )


def is_ours(hook):
    return isinstance(hook, dict) and MARKER in str(hook.get("command", ""))


def strip_ours(settings):
    hooks = settings.get("hooks")
    if not isinstance(hooks, dict):
        return
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            if isinstance(group, dict) and isinstance(group.get("hooks"), list):
                remaining = [h for h in group["hooks"] if not is_ours(h)]
                if not remaining:
                    continue
                group = {**group, "hooks": remaining}
            kept.append(group)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        del settings["hooks"]


def add_ours(settings):
    hooks = settings.setdefault("hooks", {})
    entry = {"type": "command", "command": hook_command(), "timeout": 5}
    for event in TOOL_EVENTS + OTHER_EVENTS:
        group = {"hooks": [dict(entry)]}
        if event in TOOL_EVENTS:
            group = {"matcher": "*", **group}
        hooks.setdefault(event, []).append(group)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["install", "uninstall"])
    parser.add_argument("--settings", default=os.path.expanduser("~/.claude/settings.json"))
    parser.add_argument("--dry-run", action="store_true", help="show the diff, write nothing")
    parser.add_argument("--yes", action="store_true", help="apply without asking")
    args = parser.parse_args()

    path = os.path.realpath(args.settings)
    original_text = ""
    settings = {}
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            original_text = f.read()
        if original_text.strip():
            settings = json.loads(original_text)
    if not isinstance(settings, dict):
        sys.exit(f"{path} n'est pas un objet JSON, abandon.")

    updated = copy.deepcopy(settings)
    strip_ours(updated)
    if args.action == "install":
        add_ours(updated)

    if updated == settings:
        print("Rien à changer : settings.json est déjà à jour.")
        return

    new_text = json.dumps(updated, indent=2, ensure_ascii=False) + "\n"
    diff = difflib.unified_diff(
        original_text.splitlines(keepends=True),
        new_text.splitlines(keepends=True),
        fromfile=path,
        tofile=f"{path} (après {args.action})",
    )
    sys.stdout.writelines(diff)

    if args.dry_run:
        print("\n--dry-run : rien n'a été écrit.")
        return
    if not args.yes:
        if not sys.stdin.isatty():
            sys.exit("\nPas de terminal pour confirmer : relance avec --yes pour appliquer.")
        if input("\nAppliquer ces changements ? [o/N] ").strip().lower() not in ("o", "oui", "y", "yes"):
            print("Annulé.")
            return

    if os.path.exists(path):
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = f"{path}.claude-pet-backup-{stamp}"
        shutil.copy2(path, backup)
        print(f"Sauvegarde : {backup}")

    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".settings.", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(new_text)
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)
    print(f"{args.action} terminé : {path}")


if __name__ == "__main__":
    main()
