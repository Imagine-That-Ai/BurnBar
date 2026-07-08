#!/bin/bash
set -euo pipefail
OUT="/home/linuxtest/portal-evidence"
MODE="$(cat "$OUT/chooser-mode.txt" 2>/dev/null || echo approve)"
STDIN_PAYLOAD="$(cat || true)"
echo "{\"event\":\"consent-chooser-invoked\",\"mode\":\"$MODE\",\"args\":\"$*\",\"stdin\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$STDIN_PAYLOAD"),\"ts\":\"$(date -Iseconds)\"}" >> "$OUT/portal-lifecycle.jsonl"
grim "$OUT/portal-chooser-${MODE}-$(date +%s).png" 2>/dev/null || true
if [ "$MODE" = "deny" ] || [ "$MODE" = "cancel" ]; then
  echo "{\"event\":\"consent-chooser-denied\",\"mode\":\"$MODE\",\"ts\":\"$(date -Iseconds)\"}" >> "$OUT/portal-lifecycle.jsonl"
  exit 1
fi
SELECTED=""
if [ -n "$STDIN_PAYLOAD" ]; then
  SELECTED="$(printf '%s\n' "$STDIN_PAYLOAD" | sed '/^[[:space:]]*$/d' | head -1 | awk '{print $1}')"
fi
if [ -z "$SELECTED" ] && [ "$#" -gt 0 ]; then
  SELECTED="$1"
fi
if [ -z "$SELECTED" ]; then
  SELECTED="$(swaymsg -t get_outputs -r 2>/dev/null | python3 -c "import json,sys; print(next((o.get('name') for o in json.load(sys.stdin) if o.get('active')), ''))" 2>/dev/null || true)"
fi
if [ -z "$SELECTED" ]; then
  SELECTED="HEADLESS-1"
fi
echo "{\"event\":\"consent-chooser-selected\",\"mode\":\"$MODE\",\"selected\":\"$SELECTED\",\"ts\":\"$(date -Iseconds)\"}" >> "$OUT/portal-lifecycle.jsonl"
printf '%s\n' "$SELECTED"
