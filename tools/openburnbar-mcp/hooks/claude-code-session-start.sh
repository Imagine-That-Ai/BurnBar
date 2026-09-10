#!/usr/bin/env bash
# Claude Code SessionStart hook: drain the Memory Blind Sync inbox into the local OpenBurnBar memory store.
#
# OPT-IN. Unlike the SessionEnd memorize hook (which defaults on once installed),
# this one stays off until OPENBURNBAR_MEMORY_SYNC_HOOK is set to an enabling
# value: it merges content this device did not write, and that is a decision the
# member makes, not one an installer makes for them. The app's own consent gate
# is still the boundary — with device sync off the daemon hands over nothing —
# but a hook that silently starts merging on install would be the wrong default
# even behind a second gate.
#
# Reads the hook JSON on stdin. Never blocks session start: always exits 0.
set -u
case "${OPENBURNBAR_MEMORY_SYNC_HOOK:-off}" in 1 | on | true | yes | enabled) ;; *) exit 0 ;; esac
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$(cd "$HERE/.." && pwd)"
PY="${OPENBURNBAR_MEMORY_PYTHON:-$MCP_DIR/.venv/bin/python}"
if [ ! -x "$PY" ]; then
  "$MCP_DIR/bootstrap-memory.sh" >/dev/null 2>&1 || exit 0
  PY="$MCP_DIR/.venv/bin/python"
fi
[ -x "$PY" ] || exit 0
LOG="${OPENBURNBAR_MEMORY_SYNC_HOOK_LOG:-/dev/null}"
# The log carries the drain receipt -- counts and status codes -- with no memory
# text. Still 0600: counts alone are telling. An existing file keeps its mode.
umask 077
"$PY" "$MCP_DIR/sync_remote_memories.py" --hook-stdin >>"$LOG" 2>&1 || true
exit 0
