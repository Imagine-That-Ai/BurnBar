#!/usr/bin/env bash
# Launch OpenBurnBar daemon with the same XDG path contract as the shell/extension
# (VAL-PATH-001). Support/token always share one resolved directory.
#
# Installed as: /usr/libexec/openburnbar-daemon-launch
# (AUR PKGBUILD, deb/rpm via tauri.conf.json bundle files, release-manifest).
set -euo pipefail

APP_DIR_NAME=openburnbar
HOME_DIR="${HOME:-/}"
DATA_HOME="${XDG_DATA_HOME:-$HOME_DIR/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME_DIR/.config}"
RUNTIME_HOME="${XDG_RUNTIME_DIR:-}"
APPIMAGE_ROOT=""
if [[ -n "${APPDIR:-}" ]]; then
  appdir_real="$(readlink -f "${APPDIR}" 2>/dev/null || true)"
  script_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
  case "${script_real}" in
    "${appdir_real}"/*) APPIMAGE_ROOT="${appdir_real}" ;;
  esac
fi

# Canonical peer roots — forced, never replaced by daemon.env / EnvironmentFile.
# AppImage trust uses SHA-256 pins, not world-writable mount prefixes.
HARDENED_PEER_ROOTS="/usr/bin:/usr/local/bin:/opt/openburnbar/bin"

# Support override matches TS/Swift/Rust first_non_empty precedence.
if [[ -n "${OPENBURNBAR_DAEMON_SUPPORT_DIR:-}" ]]; then
  SUPPORT_DIR="${OPENBURNBAR_DAEMON_SUPPORT_DIR}"
elif [[ -n "${BURNBAR_DAEMON_SUPPORT_DIR:-}" ]]; then
  SUPPORT_DIR="${BURNBAR_DAEMON_SUPPORT_DIR}"
else
  SUPPORT_DIR="${DATA_HOME}/${APP_DIR_NAME}"
fi

if [[ -n "${OPENBURNBAR_SOCKET_PATH:-}" ]]; then
  SOCKET_PATH="${OPENBURNBAR_SOCKET_PATH}"
elif [[ -n "${OPENBURNBAR_DAEMON_SOCKET_PATH:-}" ]]; then
  SOCKET_PATH="${OPENBURNBAR_DAEMON_SOCKET_PATH}"
elif [[ -n "${BURNBAR_DAEMON_SOCKET_PATH:-}" ]]; then
  SOCKET_PATH="${BURNBAR_DAEMON_SOCKET_PATH}"
elif [[ -n "${RUNTIME_HOME}" ]]; then
  SOCKET_PATH="${RUNTIME_HOME}/${APP_DIR_NAME}/daemon.sock"
else
  SOCKET_PATH="${SUPPORT_DIR}/openburnbar-daemon.sock"
fi

TOKEN_FILE="${SUPPORT_DIR}/daemon-socket-auth-token"
CONFIG_DIR="${CONFIG_HOME}/${APP_DIR_NAME}"

mkdir -p "${SUPPORT_DIR}" "${CONFIG_DIR}" "$(dirname "${SOCKET_PATH}")"
chmod 700 "${SUPPORT_DIR}" || true

# Token path safety (align with Rust read_token_file_secure).
# Order is load-bearing: refuse symlink/non-regular *before* any create/write so we
# never write through an empty or dangling symlink (Round 5).
if [[ -L "${TOKEN_FILE}" ]]; then
  echo "openburnbar-daemon-launch: refusing token ${TOKEN_FILE} (symlink not allowed)" >&2
  exit 1
fi
if [[ -e "${TOKEN_FILE}" && ! -f "${TOKEN_FILE}" ]]; then
  echo "openburnbar-daemon-launch: refusing token ${TOKEN_FILE} (not a regular file)" >&2
  exit 1
fi

if [[ ! -e "${TOKEN_FILE}" ]]; then
  # Create only when the path does not exist. Use noclobber so a raced symlink is not overwritten.
  umask 077
  set -o noclobber
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 >"${TOKEN_FILE}" || {
      echo "openburnbar-daemon-launch: failed to create token ${TOKEN_FILE} (path may already exist)" >&2
      exit 1
    }
  else
    head -c 32 /dev/urandom | base64 >"${TOKEN_FILE}" || {
      echo "openburnbar-daemon-launch: failed to create token ${TOKEN_FILE} (path may already exist)" >&2
      exit 1
    }
  fi
  set +o noclobber
  chmod 600 "${TOKEN_FILE}"
elif [[ ! -s "${TOKEN_FILE}" ]]; then
  # Existing empty regular file: refill in place (never through a symlink; -L already refused).
  if [[ ! -f "${TOKEN_FILE}" ]]; then
    echo "openburnbar-daemon-launch: refusing token ${TOKEN_FILE} (not a regular file)" >&2
    exit 1
  fi
  umask 077
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 >"${TOKEN_FILE}"
  else
    head -c 32 /dev/urandom | base64 >"${TOKEN_FILE}"
  fi
  chmod 600 "${TOKEN_FILE}"
fi

# Final type/mode gate before exec (regular file, 0600 or 0400).
if [[ -L "${TOKEN_FILE}" || ! -f "${TOKEN_FILE}" ]]; then
  echo "openburnbar-daemon-launch: refusing token ${TOKEN_FILE} (must be a regular file, not a symlink)" >&2
  exit 1
fi
mode="$(stat -c '%a' "${TOKEN_FILE}" 2>/dev/null || stat -f '%OLp' "${TOKEN_FILE}" 2>/dev/null || echo 600)"
if [[ "${mode}" != "600" && "${mode}" != "400" && "${mode}" != "0600" && "${mode}" != "0400" ]]; then
  echo "openburnbar-daemon-launch: refusing token ${TOKEN_FILE} with mode ${mode}" >&2
  exit 1
fi

# Force hardened PEER_ROOTS. systemd EnvironmentFile=daemon.env can override the
# unit's Environment= line — ignore that class of override entirely so restart
# cannot set PEER_ROOTS=/ or $HOME and defeat peer path checks.
if [[ -n "${OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS:-}" && \
      "${OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS}" != "${HARDENED_PEER_ROOTS}" ]]; then
  echo "openburnbar-daemon-launch: ignoring non-canonical OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS from environment" >&2
  echo "  got=${OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS}" >&2
  echo "  using=${HARDENED_PEER_ROOTS}" >&2
  echo "  remove PEER_ROOTS from ~/.config/openburnbar/daemon.env (not allowed)" >&2
fi
export OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS="${HARDENED_PEER_ROOTS}"

export OPENBURNBAR_DAEMON_SUPPORT_DIR="${SUPPORT_DIR}"
export OPENBURNBAR_INDEX_DATABASE_PATH="${OPENBURNBAR_INDEX_DATABASE_PATH:-${SUPPORT_DIR}/openburnbar.sqlite}"

# Swift and native runtimes for the packaged daemon. AppImage exposes its
# extracted root through APPDIR; deb/rpm install the same payload under /usr.
swift_lib_dirs=()
if [[ -n "${OPENBURNBAR_SWIFT_LIB_DIR:-}" ]]; then
  swift_lib_dirs+=("${OPENBURNBAR_SWIFT_LIB_DIR}")
fi
if [[ -n "${APPIMAGE_ROOT}" ]]; then
  swift_lib_dirs+=("${APPIMAGE_ROOT}/usr/lib/openburnbar/swift")
fi
swift_lib_dirs+=(
  /usr/lib/openburnbar/swift
  /usr/lib/swift/linux
  /opt/openburnbar/lib/swift
  /opt/swift/usr/lib/swift/linux
  /opt/swift-6.1-RELEASE-ubuntu24.04-aarch64/usr/lib/swift/linux
  /opt/swift-6.0.3-RELEASE-ubuntu24.04-aarch64/usr/lib/swift/linux
)
swift_ld=""
for d in "${swift_lib_dirs[@]}"; do
  if [[ -d "${d}" ]]; then
    swift_ld="${d}"
    break
  fi
done
native_lib_dirs=()
if [[ -n "${APPIMAGE_ROOT}" ]]; then
  native_lib_dirs+=("${APPIMAGE_ROOT}/usr/lib/openburnbar/native")
fi
native_lib_dirs+=(/usr/lib/openburnbar/native /opt/openburnbar/lib)
native_ld=""
for d in "${native_lib_dirs[@]}"; do
  if [[ -d "${d}" ]]; then
    native_ld="${d}"
    break
  fi
done
if [[ -n "${swift_ld}" || -n "${native_ld}" ]]; then
  library_paths=()
  [[ -n "${swift_ld}" ]] && library_paths+=("${swift_ld}")
  [[ -n "${native_ld}" ]] && library_paths+=("${native_ld}")
  [[ -n "${LD_LIBRARY_PATH:-}" ]] && library_paths+=("${LD_LIBRARY_PATH}")
  export LD_LIBRARY_PATH="$(IFS=:; echo "${library_paths[*]}")"
fi

daemon_candidates=()
if [[ -n "${APPIMAGE_ROOT}" ]]; then
  daemon_candidates+=("${APPIMAGE_ROOT}/usr/bin/openburnbar-daemon")
fi
daemon_candidates+=( \
  /usr/local/bin/openburnbar-daemon \
  /opt/openburnbar/bin/openburnbar-daemon \
  /usr/bin/openburnbar-daemon \
)
DAEMON_BIN=""
for candidate in "${daemon_candidates[@]}"; do
  if [[ -x "${candidate}" ]]; then
    DAEMON_BIN="${candidate}"
    break
  fi
done
if [[ -z "${DAEMON_BIN}" ]]; then
  if command -v openburnbar-daemon >/dev/null 2>&1; then
    DAEMON_BIN="$(command -v openburnbar-daemon)"
  else
    echo "openburnbar-daemon-launch: openburnbar-daemon binary not found" >&2
    exit 1
  fi
fi

exec "${DAEMON_BIN}" \
  --socket-path "${SOCKET_PATH}" \
  --socket-auth-token-file "${TOKEN_FILE}" \
  --index-database-path "${OPENBURNBAR_INDEX_DATABASE_PATH}" \
  "$@"
