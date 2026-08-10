#!/bin/bash
# Launch OpenBurnBar daemon with the same XDG path contract as the shell/extension
# (VAL-PATH-001). Support/token always share one resolved directory.
#
# Installed as: /usr/libexec/openburnbar-daemon-launch
# (AUR PKGBUILD, deb/rpm via tauri.conf.json bundle files, release-manifest).
set -euo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
unset BASH_ENV ENV CDPATH GLOBIGNORE LD_PRELOAD LD_AUDIT NODE_OPTIONS
unset OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS BURNBAR_DAEMON_LINUX_PEER_ROOTS
unset OPENBURNBAR_DAEMON_LINUX_PEER_SHA256_PINS BURNBAR_DAEMON_LINUX_PEER_SHA256_PINS
unset OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_PUBLIC_KEY OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST_FCITX5
unset OPENBURNBAR_LINUX_TEXT_EXPANSION_EXTERNAL

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

export OPENBURNBAR_DAEMON_SUPPORT_DIR="${SUPPORT_DIR}"
export OPENBURNBAR_INDEX_DATABASE_PATH="${OPENBURNBAR_INDEX_DATABASE_PATH:-${SUPPORT_DIR}/openburnbar.sqlite}"

# External text expansion trusts only the immutable release public key. The
# private release key is never present on an installed machine or inherited by
# the engine process.
if [[ -z "${APPIMAGE_ROOT}" ]]; then
  text_expansion_manifest="/usr/share/openburnbar/text-expansion/text-expansion-engine.json"
  fcitx5_manifest="/usr/share/openburnbar/text-expansion/text-expansion-engine-fcitx5.json"
  release_public_key="/usr/share/openburnbar/attestation/release-ed25519.pub.pem"
  if [[ -r "${text_expansion_manifest}" && -r "${release_public_key}" ]]; then
    raw_engine_key="$(openssl pkey -pubin -in "${release_public_key}" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')"
    if [[ "${#raw_engine_key}" -ne 44 ]]; then
      echo "openburnbar-daemon-launch: invalid packaged text-expansion trust key" >&2
      exit 1
    fi
    export OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_PUBLIC_KEY="${raw_engine_key}"
    export OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST="${text_expansion_manifest}"
    # The native Fcitx5 addon ships its own signed manifest; expose it only
    # when the package actually installed one so the daemon per-backend
    # signature gate stays exact.
    if [[ -r "${fcitx5_manifest}" ]]; then
      export OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST_FCITX5="${fcitx5_manifest}"
    else
      unset OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST_FCITX5
    fi
    export OPENBURNBAR_LINUX_TEXT_EXPANSION_EXTERNAL=1
  fi
else
  # A manifest signed for /usr/libexec cannot authenticate a transient AppImage
  # mount path. Keep system expansion unavailable instead of weakening path
  # identity; in-app expansion remains available.
  unset OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_PUBLIC_KEY
  unset OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST
  unset OPENBURNBAR_LINUX_TEXT_EXPANSION_ENGINE_MANIFEST_FCITX5
  unset OPENBURNBAR_LINUX_TEXT_EXPANSION_EXTERNAL
fi

# Public OAuth/Firebase identifiers ship with the exact package. AppImage must
# point the daemon at its mounted payload; deb/rpm use the same immutable path
# below /usr. The daemon reopens this path with O_NOFOLLOW and validates the
# root-owned, non-writable file plus its strict JSON schema.
if [[ -n "${APPIMAGE_ROOT}" ]]; then
  export OPENBURNBAR_PACKAGED_CLOUD_AUTH_CONFIG_FILE="${APPIMAGE_ROOT}/usr/share/openburnbar/cloud-auth.json"
else
  export OPENBURNBAR_PACKAGED_CLOUD_AUTH_CONFIG_FILE="/usr/share/openburnbar/cloud-auth.json"
fi

# The launcher owns the packaged Browser Computer Use bridge
# path. This keeps installed deb/rpm and AppImage sessions on the immutable
# package resource while development launches may still use the explicit
# OPENBURNBAR_PLAYWRIGHT_BRIDGE override.
if [[ -n "${APPIMAGE_ROOT}" ]]; then
  export OPENBURNBAR_PACKAGED_PLAYWRIGHT_BRIDGE="${APPIMAGE_ROOT}/usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js"
else
  export OPENBURNBAR_PACKAGED_PLAYWRIGHT_BRIDGE="/usr/lib/openburnbar/playwright/openburnbar-playwright-bridge.js"
fi

# Packaged Browser Computer Use never resolves JavaScript or Chromium from the
# user's environment. The externally provisioned runtime is accepted only from
# these root-owned, non-group/world-writable trees; the bridge revalidates every
# entry before loading Playwright and before launching Chromium.
unset NODE_OPTIONS
export OPENBURNBAR_PACKAGED_PLAYWRIGHT_RUNTIME=1
export NODE_PATH="/usr/lib/node_modules"
export PLAYWRIGHT_BROWSERS_PATH="/usr/lib/openburnbar/playwright-browsers"

# Swift and native runtimes for the packaged daemon. AppImage exposes its
# extracted root through APPDIR; deb/rpm install the same payload under /usr.
swift_lib_dirs=()
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
  library_path_value="$(IFS=:; echo "${library_paths[*]}")"
  export LD_LIBRARY_PATH="$library_path_value"
else
  unset LD_LIBRARY_PATH
fi

daemon_candidates=()
if [[ -n "${APPIMAGE_ROOT}" ]]; then
  daemon_candidates+=("${APPIMAGE_ROOT}/usr/bin/openburnbar-daemon")
fi
daemon_candidates+=( \
  /usr/bin/openburnbar-daemon \
  /usr/local/bin/openburnbar-daemon \
  /opt/openburnbar/bin/openburnbar-daemon \
)
DAEMON_BIN=""
for candidate in "${daemon_candidates[@]}"; do
  if [[ -x "${candidate}" ]]; then
    DAEMON_BIN="${candidate}"
    break
  fi
done
if [[ -z "${DAEMON_BIN}" ]]; then
  echo "openburnbar-daemon-launch: openburnbar-daemon binary not found" >&2
  exit 1
fi

exec "${DAEMON_BIN}" \
  --socket-path "${SOCKET_PATH}" \
  --socket-auth-token-file "${TOKEN_FILE}" \
  --index-database-path "${OPENBURNBAR_INDEX_DATABASE_PATH}" \
  "$@"
