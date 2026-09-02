#!/usr/bin/env bash
# Self-bootstrapping entry point used by the repo's .mcp.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PYTHON="${SCRIPT_DIR}/.venv/bin/python"

# The bootstrap is a cheap no-op when the interpreter, imports, and pinned
# requirements hash all match. MCP stdout is reserved for JSON-RPC.
"${SCRIPT_DIR}/bootstrap-memory.sh" >&2

exec "${VENV_PYTHON}" "${SCRIPT_DIR}/server.py" "$@"
