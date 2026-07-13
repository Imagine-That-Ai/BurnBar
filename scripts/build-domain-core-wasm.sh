#!/usr/bin/env bash
# Build the checked-in browser Wasm package for the shared domain core.
#
# Usage:
#   ./scripts/build-domain-core-wasm.sh          # regenerate the vendored package
#   ./scripts/build-domain-core-wasm.sh --check  # fail when generated output drifts

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="${ROOT_DIR}/crates/openburnbar-domain-core"
PACKAGE_DIR="${WORKSPACE_DIR}/domain-wasm"
VENDOR_DIR="${ROOT_DIR}/apps/console/vendor/openburnbar-domain-core-wasm"
TARGET="wasm32-unknown-unknown"
WASM_BINDGEN_VERSION="0.2.105"
TOOL_ROOT="${ROOT_DIR}/build/domain-core-wasm-tools/wasm-bindgen-${WASM_BINDGEN_VERSION}"
WASM_BINDGEN_BIN="${TOOL_ROOT}/bin/wasm-bindgen"
MODE="${1:-build}"

if [[ "${MODE}" != "build" && "${MODE}" != "--check" ]]; then
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 64
fi

log() { printf '[domain-core-wasm] %s\n' "$*"; }

if [[ -x "${HOME}/.cargo/bin/rustup" ]]; then
  RUSTUP_BIN="${HOME}/.cargo/bin/rustup"
else
  RUSTUP_BIN="$(command -v rustup)"
fi

if [[ -x "${HOME}/.cargo/bin/cargo" ]]; then
  CARGO_BIN="${HOME}/.cargo/bin/cargo"
else
  CARGO_BIN="$(command -v cargo)"
fi

if ! (cd "${WORKSPACE_DIR}" && "${RUSTUP_BIN}" target list --installed) | grep -qx "${TARGET}"; then
  log "installing Rust target ${TARGET}"
  (cd "${WORKSPACE_DIR}" && "${RUSTUP_BIN}" target add "${TARGET}")
fi

if [[ ! -x "${WASM_BINDGEN_BIN}" ]] \
  || [[ "$("${WASM_BINDGEN_BIN}" --version)" != "wasm-bindgen ${WASM_BINDGEN_VERSION}" ]]; then
  log "installing pinned wasm-bindgen-cli ${WASM_BINDGEN_VERSION}"
  rm -rf "${TOOL_ROOT}"
  "${CARGO_BIN}" install \
    --root "${TOOL_ROOT}" \
    --version "=${WASM_BINDGEN_VERSION}" \
    --locked \
    wasm-bindgen-cli
fi

log "building openburnbar-domain-wasm"
(
  cd "${WORKSPACE_DIR}"
  PATH="${HOME}/.cargo/bin:${PATH}" "${CARGO_BIN}" build \
    --locked \
    --release \
    --target "${TARGET}" \
    -p openburnbar-domain-wasm
)

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-domain-wasm.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}"' EXIT

log "generating browser bindings"
"${WASM_BINDGEN_BIN}" \
  --target web \
  --typescript \
  --out-dir "${STAGING_DIR}" \
  --out-name openburnbar_domain_core \
  "${WORKSPACE_DIR}/target/${TARGET}/release/openburnbar_domain_wasm.wasm"
cp "${PACKAGE_DIR}/package.json" "${STAGING_DIR}/package.json"

# wasm-bindgen emits blanket linter suppressions in declarations. The generated
# declarations are clean under the repo rules, so remove them instead of
# weakening the no-new-suppressions gate.
for declaration in "${STAGING_DIR}"/*.d.ts; do
  sed -i.bak \
    -e '/^\/\* tslint:disable \*\/$/d' \
    -e '/^\/\* eslint-disable \*\/$/d' \
    "${declaration}"
  rm -f "${declaration}.bak"
done

log "running generated-package smoke test"
node "${PACKAGE_DIR}/tests/package-smoke.mjs" "${STAGING_DIR}"

if [[ "${MODE}" == "--check" ]]; then
  if ! diff -ruN "${VENDOR_DIR}" "${STAGING_DIR}"; then
    printf 'domain-core Wasm bindings drifted; run ./scripts/build-domain-core-wasm.sh\n' >&2
    exit 1
  fi
  log "checked-in browser package is current"
  exit 0
fi

rm -rf "${VENDOR_DIR}"
mkdir -p "$(dirname "${VENDOR_DIR}")"
cp -R "${STAGING_DIR}" "${VENDOR_DIR}"
log "wrote ${VENDOR_DIR}"
