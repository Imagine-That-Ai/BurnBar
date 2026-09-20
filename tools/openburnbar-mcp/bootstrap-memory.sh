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

venv_is_ready() {
  [[ -x "${VENV_PYTHON}" ]] && python_is_supported "${VENV_PYTHON}" \
    && memory_dependencies_import "${VENV_PYTHON}" && requirements_are_current "${VENV_PYTHON}"
}

# Fast path, read-only: the common launch does not take the lock.
if venv_is_ready; then
  exit 0
fi

# Two MCP clients can start from the same checkout at once. Creation, install,
# validation, and the stamp are serialized with an atomic mkdir lock (macOS has
# no flock(1)); a lock whose owner died is reclaimed.
LOCK_DIR="${VENV_DIR}.bootstrap.lock"
release_lock() { rm -rf -- "${LOCK_DIR}"; }
acquire_lock() {
  local waited=0 owner
  until mkdir -- "${LOCK_DIR}" 2>/dev/null; do
    owner="$(cat "${LOCK_DIR}/pid" 2>/dev/null || true)"
    if [[ -n "${owner}" ]] && ! kill -0 "${owner}" 2>/dev/null; then
      echo "WARN: reclaiming memory MCP bootstrap lock left by dead process ${owner}" >&2
      rm -rf -- "${LOCK_DIR}"
      continue
    fi
    sleep 0.2
    waited=$((waited + 1))
    if (( waited > 1500 )); then
      echo "ERROR: another bootstrap has held ${LOCK_DIR} for over five minutes; remove it if no bootstrap is running." >&2
      return 1
    fi
  done
  printf '%s\n' "$$" >"${LOCK_DIR}/pid"
  trap release_lock EXIT
}
acquire_lock

# Re-check under the lock: the other client may have finished the work.
if venv_is_ready; then
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

# A venv made by `uv venv` or `python -m venv --without-pip` has no pip. Prefer
# pip when it is there, restore it with ensurepip when it is not, and fall back
# to uv when the interpreter has no ensurepip (some distro pythons).
install_requirements() {
  if "${VENV_PYTHON}" -m pip --version >/dev/null 2>&1; then
    "${VENV_PYTHON}" -m pip install --disable-pip-version-check --quiet -r "${REQUIREMENTS_FILE}"
    return
  fi
  if "${VENV_PYTHON}" -m ensurepip --upgrade --default-pip >/dev/null 2>&1 \
    && "${VENV_PYTHON}" -m pip --version >/dev/null 2>&1; then
    echo "INFO: restored pip in the memory MCP venv with ensurepip" >&2
    "${VENV_PYTHON}" -m pip install --disable-pip-version-check --quiet -r "${REQUIREMENTS_FILE}"
    return
  fi
  if command -v uv >/dev/null 2>&1; then
    echo "INFO: installing memory MCP requirements with uv (venv has no pip)" >&2
    uv pip install --quiet --python "${VENV_PYTHON}" -r "${REQUIREMENTS_FILE}"
    return
  fi
  echo "ERROR: ${VENV_PYTHON} has no pip, ensurepip is unavailable, and uv is not installed." >&2
  echo "Remove ${VENV_DIR} and rerun to recreate it with python -m venv, or install uv." >&2
  return 1
}

install_requirements
memory_dependencies_import "${VENV_PYTHON}" || {
  echo "ERROR: memory MCP dependencies still do not import after installation into ${VENV_DIR}." >&2
  exit 1
}
requirements_hash "${VENV_PYTHON}" >"${REQUIREMENTS_STAMP}"
chmod 600 "${REQUIREMENTS_STAMP}"

echo "OK: OpenBurnBar memory MCP dependencies are ready in ${VENV_DIR}"
