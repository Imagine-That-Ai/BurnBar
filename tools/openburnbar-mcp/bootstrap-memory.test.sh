#!/usr/bin/env bash
# Integration self-test for the cargo-free memory MCP bootstrap.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_DIR="${REPO_ROOT}/tools/openburnbar-mcp"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-memory-bootstrap-test.XXXXXX")"
FIXTURE_DIR="${TMP_ROOT}/tools/openburnbar-mcp"
trap 'rm -rf "${TMP_ROOT}"' EXIT

mkdir -p "${FIXTURE_DIR}" "${TMP_ROOT}/bin"
cp \
  "${SOURCE_DIR}/bootstrap-memory.sh" \
  "${SOURCE_DIR}/launch-memory.sh" \
  "${SOURCE_DIR}/requirements.txt" \
  "${FIXTURE_DIR}/"
chmod +x "${FIXTURE_DIR}/bootstrap-memory.sh" "${FIXTURE_DIR}/launch-memory.sh"

# A start-and-exit fixture lets the launcher prove it bootstraps a missing venv
# and execs Python without leaving a real MCP server waiting on stdio.
cat >"${FIXTURE_DIR}/server.py" <<'PY'
import os

import cryptography
import mcp
import tiktoken

assert os.environ["BURNBAR_MCP_TOOLSET"] == "memory"
print("OK: fixture server import through launcher")
PY

# If the bootstrap ever reaches for cargo, fail loudly and leave a receipt.
cat >"${TMP_ROOT}/bin/cargo" <<SH
#!/usr/bin/env bash
touch "${TMP_ROOT}/cargo-was-called"
exit 97
SH
chmod +x "${TMP_ROOT}/bin/cargo"

launcher_output="$(
  PATH="${TMP_ROOT}/bin:${PATH}" \
    BURNBAR_MCP_TOOLSET=memory \
    "${FIXTURE_DIR}/launch-memory.sh"
)"
[[ "${launcher_output}" == "OK: fixture server import through launcher" ]] || {
  echo "FAIL: launcher returned unexpected output: ${launcher_output}" >&2
  exit 1
}

VENV_PYTHON="${FIXTURE_DIR}/.venv/bin/python"
[[ -x "${VENV_PYTHON}" ]] || {
  echo "FAIL: bootstrap did not create ${VENV_PYTHON}" >&2
  exit 1
}
[[ ! -e "${TMP_ROOT}/cargo-was-called" ]] || {
  echo "FAIL: cargo was called by the memory-only bootstrap" >&2
  exit 1
}

# Match the bootstrap's documented interpreter preference, while remaining
# portable to hosts that only provide the final python3 fallback.
expected_version=""
for candidate in python3.12 python3.11 python3.13 python3; do
  if command -v "${candidate}" >/dev/null 2>&1 && "${candidate}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
    expected_version="$("${candidate}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    break
  fi
done
actual_version="$("${VENV_PYTHON}" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
[[ -n "${expected_version}" && "${actual_version}" == "${expected_version}" ]] || {
  echo "FAIL: bootstrap selected Python ${actual_version}; expected ${expected_version:-none}" >&2
  exit 1
}

# Import the real server through the temp venv, then apply the same memory
# toolset filter used at process startup. This is deliberately start-free:
# a successful check cannot hang waiting for MCP stdio like server.py itself.
BURNBAR_MCP_TOOLSET=memory "${VENV_PYTHON}" - "${SOURCE_DIR}" <<'PY'
import importlib
import importlib.metadata
import os
import sys

source_dir = sys.argv[1]
sys.path.insert(0, source_dir)

import cryptography
import mcp
import tiktoken

server = importlib.import_module("server")
effective = server._apply_toolset_filter(server.mcp, os.environ["BURNBAR_MCP_TOOLSET"])
tool_names = set(server.mcp._tool_manager._tools)

assert importlib.metadata.version("mcp") == "1.28.1"
assert effective == "memory"
assert tool_names == server.MEMORY_TOOLSET
print(f"OK: server.py import exposed {len(tool_names)} memory tools on Python {sys.version.split()[0]}")
PY

echo "PASS: cargo-free OpenBurnBar memory MCP bootstrap"
