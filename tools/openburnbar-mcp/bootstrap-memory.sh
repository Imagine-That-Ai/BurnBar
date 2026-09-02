#!/usr/bin/env bash
# Bootstrap the repo-scoped memory MCP without building either Rust tier.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${SCRIPT_DIR}/.venv"
VENV_PYTHON="${VENV_DIR}/bin/python"
REQUIREMENTS_FILE="${SCRIPT_DIR}/requirements.txt"
REQUIREMENTS_STAMP="${VENV_DIR}/.openburnbar-requirements.sha256"

python_is_supported() {
  "$1" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

memory_dependencies_import() {
  "$1" -c 'import cryptography, mcp, tiktoken' >/dev/null 2>&1
}

requirements_hash() {
  "$1" - "${REQUIREMENTS_FILE}" <<'PY'
import hashlib
import pathlib
import sys

print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

requirements_are_current() {
  [[ -r "${REQUIREMENTS_STAMP}" ]] || return 1
  [[ "$(<"${REQUIREMENTS_STAMP}")" == "$(requirements_hash "$1")" ]]
}

select_python() {
  local candidate resolved
  for candidate in python3.12 python3.11 python3.13 python3; do
    resolved="$(command -v "${candidate}" 2>/dev/null || true)"
    if [[ -n "${resolved}" ]] && python_is_supported "${resolved}"; then
      printf '%s\n' "${resolved}"
      return 0
    fi
  done

  echo "ERROR: OpenBurnBar's memory MCP requires Python 3.11 or newer." >&2
  echo "Tried python3.12, python3.11, python3.13, then python3." >&2
  return 1
}

if [[ -x "${VENV_PYTHON}" ]] && python_is_supported "${VENV_PYTHON}" \
  && memory_dependencies_import "${VENV_PYTHON}" && requirements_are_current "${VENV_PYTHON}"; then
  exit 0
fi

if [[ -e "${VENV_DIR}" ]]; then
  if [[ ! -x "${VENV_PYTHON}" ]] || ! python_is_supported "${VENV_PYTHON}"; then
    echo "WARN: existing memory MCP venv is broken or uses Python older than 3.11; recreating it." >&2
    rm -rf -- "${VENV_DIR}"
  fi
fi

if [[ ! -x "${VENV_PYTHON}" ]]; then
  PYTHON_BIN="$(select_python)"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

"${VENV_PYTHON}" -m pip install --disable-pip-version-check --quiet -r "${REQUIREMENTS_FILE}"
memory_dependencies_import "${VENV_PYTHON}"
requirements_hash "${VENV_PYTHON}" >"${REQUIREMENTS_STAMP}"
chmod 600 "${REQUIREMENTS_STAMP}"

echo "OK: OpenBurnBar memory MCP dependencies are ready in ${VENV_DIR}"
