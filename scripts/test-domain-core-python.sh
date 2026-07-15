#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MCP_DIR="${ROOT_DIR}/tools/openburnbar-mcp"
PYTHON="${MCP_DIR}/.venv/bin/python"

"${ROOT_DIR}/scripts/build-domain-core-python.sh"
if [[ ! -x "${PYTHON}" ]]; then
  PYTHON="$(command -v python3)"
fi
"${PYTHON}" -m pytest "${MCP_DIR}/tests/test_domain_core_cloudvault.py" "$@"
