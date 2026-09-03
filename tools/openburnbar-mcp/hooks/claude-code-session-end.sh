#!/usr/bin/env bash
# Claude Code SessionEnd hook: memorize the session transcript into the local OpenBurnBar memory store.
# Reads the hook JSON on stdin. Never blocks session end: always exits 0.
set -u
case "${OPENBURNBAR_MEMORY_SESSION_HOOK:-on}" in 0 | off | false | no | disabled) exit 0 ;; esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$(cd "$HERE/.." && pwd)"
PY="${OPENBURNBAR_MEMORY_PYTHON:-$MCP_DIR/.venv/bin/python}"
if [ ! -x "$PY" ]; then
  "$MCP_DIR/bootstrap-memory.sh" >/dev/null 2>&1 || exit 0
  PY="$MCP_DIR/.venv/bin/python"
fi
[ -x "$PY" ] || exit 0
LOG="${OPENBURNBAR_MEMORY_SESSION_HOOK_LOG:-/dev/null}"
"$PY" "$MCP_DIR/memorize_transcript.py" --hook-stdin >>"$LOG" 2>&1 || true
exit 0
