#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
LIBSIGNAL_DIR="${ROOT_DIR}/Vendor/libsignal"
IROH_DIR="${ROOT_DIR}/crates/openburnbar-iroh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_cmd cargo
require_cmd cmake
require_cmd protoc

if [[ ! -f "${LIBSIGNAL_DIR}/rust/bridge/ffi/Cargo.toml" ]]; then
  echo "Missing libsignal FFI crate at ${LIBSIGNAL_DIR}; initialize Vendor/libsignal first." >&2
  exit 1
fi

if [[ ! -f "${IROH_DIR}/Cargo.toml" ]]; then
  echo "Missing openburnbar-iroh crate at ${IROH_DIR}." >&2
  exit 1
fi

echo "== libsignal ffi =="
cargo build \
  --manifest-path "${LIBSIGNAL_DIR}/rust/bridge/ffi/Cargo.toml" \
  --locked \
  --target-dir "${LIBSIGNAL_DIR}/target-linux-ffi-serial" \
  -j1

test -f "${LIBSIGNAL_DIR}/target-linux-ffi-serial/debug/libsignal_ffi.a"
ls -lh "${LIBSIGNAL_DIR}/target-linux-ffi-serial/debug/libsignal_ffi.a"

echo "== openburnbar iroh ffi =="
cargo test \
  --manifest-path "${IROH_DIR}/Cargo.toml" \
  --locked \
  --target-dir "${IROH_DIR}/target-linux-ffi-serial" \
  -j1
cargo build \
  --manifest-path "${IROH_DIR}/Cargo.toml" \
  --locked \
  --release \
  --target-dir "${IROH_DIR}/target-linux-ffi-serial" \
  -j1

test -f "${IROH_DIR}/target-linux-ffi-serial/release/libopenburnbar_iroh.so"
ls -lh "${IROH_DIR}/target-linux-ffi-serial/release/libopenburnbar_iroh.so"
