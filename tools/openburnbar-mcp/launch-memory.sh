#!/usr/bin/env bash
# Self-bootstrapping entry point used by the repo's .mcp.json.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_PYTHON="${SCRIPT_DIR}/.venv/bin/python"

if [[ ! -x "${VENV_PYTHON}" ]] || ! "${VENV_PYTHON}" -c 'import cryptography, mcp, tiktoken' >/dev/null 2>&1; then
  # MCP stdout is reserved for JSON-RPC. Send one-time bootstrap output to stderr.
  "${SCRIPT_DIR}/bootstrap-memory.sh" >&2
fi

exec "${VENV_PYTHON}" "${SCRIPT_DIR}/server.py" "$@"
