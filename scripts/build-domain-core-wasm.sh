#!/usr/bin/env bash
# Build the checked-in browser Wasm package for the shared domain core.
#
# Usage:
#   ./scripts/build-domain-core-wasm.sh          # regenerate the vendored package
#   ./scripts/build-domain-core-wasm.sh --check  # fail when generated output drifts

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="${ROOT_DIR}/crates/openburnbar-domain-core"
TARGET_DIR="${CARGO_TARGET_DIR:-${WORKSPACE_DIR}/target}"
PACKAGE_DIR="${WORKSPACE_DIR}/domain-wasm"
VENDOR_DIR="${ROOT_DIR}/apps/console/vendor/openburnbar-domain-core-wasm"
FUNCTIONS_VENDOR_DIR="${ROOT_DIR}/functions/vendor/openburnbar/domain-core-wasm"
TARGET="wasm32-unknown-unknown"
WASM_BINDGEN_VERSION="0.2.105"
TOOL_ROOT="${ROOT_DIR}/build/domain-core-wasm-tools/wasm-bindgen-${WASM_BINDGEN_VERSION}"
WASM_BINDGEN_BIN="${TOOL_ROOT}/bin/wasm-bindgen"
MODE="${1:-build}"
FINGERPRINT_NAME="openburnbar-domain-core-source.sha256"

if [[ "${MODE}" != "build" && "${MODE}" != "--check" ]]; then
  printf 'usage: %s [--check]\n' "$0" >&2
  exit 64
fi

log() { printf '[domain-core-wasm] %s\n' "$*"; }

compare_trees_exactly() {
  local label="$1" committed="$2" generated="$3"
  python3 - "${label}" "${committed}" "${generated}" <<'PY'
import hashlib
import pathlib
import sys

label, committed_raw, generated_raw = sys.argv[1:]
committed = pathlib.Path(committed_raw)
generated = pathlib.Path(generated_raw)

def inventory(root):
    return {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*")
        if path.is_file()
    }

expected = inventory(committed)
actual = inventory(generated)
if expected != actual:
    for name in sorted(set(expected) | set(actual)):
        if expected.get(name) != actual.get(name):
            print(
                f"{label}: {name}: committed={expected.get(name, 'missing')} "
                f"rebuilt={actual.get(name, 'missing')}",
                file=sys.stderr,
            )
    raise SystemExit(f"{label}: rebuilt package is not byte-identical")
print(f"{label}: rebuilt package is byte-identical ({len(actual)} files)")
PY
}

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
SOURCE_FINGERPRINT="$(
  python3 "${ROOT_DIR}/scripts/ci/domain-core-union-gate.py" --source-fingerprint
)"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"
export TZ=UTC
REMAP_FLAGS="--remap-path-prefix=${ROOT_DIR}=. --remap-path-prefix=${HOME}=~"
(
  cd "${WORKSPACE_DIR}"
  RUSTFLAGS="${RUSTFLAGS:-} ${REMAP_FLAGS}" \
    PATH="${HOME}/.cargo/bin:${PATH}" "${CARGO_BIN}" build \
    --locked \
    --release \
    --target "${TARGET}" \
    -p openburnbar-domain-wasm
)

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-domain-wasm.XXXXXX")"
NODE_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-domain-node-wasm.XXXXXX")"
trap 'rm -rf "${STAGING_DIR}" "${NODE_STAGING_DIR}"' EXIT

log "generating browser bindings"
"${WASM_BINDGEN_BIN}" \
  --target web \
  --typescript \
  --out-dir "${STAGING_DIR}" \
  --out-name openburnbar_domain_core \
  "${TARGET_DIR}/${TARGET}/release/openburnbar_domain_wasm.wasm"
cp "${PACKAGE_DIR}/package.json" "${STAGING_DIR}/package.json"
printf '%s\n' "${SOURCE_FINGERPRINT}" > "${STAGING_DIR}/${FINGERPRINT_NAME}"

log "generating Node bindings"
"${WASM_BINDGEN_BIN}" \
  --target nodejs \
  --typescript \
  --out-dir "${NODE_STAGING_DIR}" \
  --out-name openburnbar_domain_core \
  "${TARGET_DIR}/${TARGET}/release/openburnbar_domain_wasm.wasm"
cp "${PACKAGE_DIR}/package.node.json" "${NODE_STAGING_DIR}/package.json"
printf '%s\n' "${SOURCE_FINGERPRINT}" > "${NODE_STAGING_DIR}/${FINGERPRINT_NAME}"

# wasm-bindgen emits blanket linter suppressions in declarations. The generated
# declarations are clean under the repo rules, so remove them instead of
# weakening the no-new-suppressions gate.
for declaration in "${STAGING_DIR}"/*.d.ts "${NODE_STAGING_DIR}"/*.d.ts; do
  sed -i.bak \
    -e '/^\/\* tslint:disable \*\/$/d' \
    -e '/^\/\* eslint-disable \*\/$/d' \
    "${declaration}"
  rm -f "${declaration}.bak"
done
for javascript in "${STAGING_DIR}"/*.js "${NODE_STAGING_DIR}"/*.js; do
  perl -0pi -e 's/\n+\z/\n/' "${javascript}"
done

log "running generated-package smoke test"
node "${PACKAGE_DIR}/tests/package-smoke.mjs" "${STAGING_DIR}"
node "${PACKAGE_DIR}/tests/node-package-equivalence.cjs" "${NODE_STAGING_DIR}" "${NODE_STAGING_DIR}"

if [[ "${MODE}" == "--check" ]]; then
  node "${PACKAGE_DIR}/tests/package-equivalence.mjs" \
    "${VENDOR_DIR}" "${STAGING_DIR}"
  node "${PACKAGE_DIR}/tests/node-package-equivalence.cjs" \
    "${FUNCTIONS_VENDOR_DIR}" "${NODE_STAGING_DIR}"
  compare_trees_exactly "browser Wasm" "${VENDOR_DIR}" "${STAGING_DIR}"
  compare_trees_exactly "Node Wasm" "${FUNCTIONS_VENDOR_DIR}" "${NODE_STAGING_DIR}"
  log "checked-in browser and Node packages are API-, behavior-, and byte-equivalent"
  exit 0
fi

rm -rf "${VENDOR_DIR}"
mkdir -p "$(dirname "${VENDOR_DIR}")"
cp -R "${STAGING_DIR}" "${VENDOR_DIR}"
rm -rf "${FUNCTIONS_VENDOR_DIR}"
mkdir -p "$(dirname "${FUNCTIONS_VENDOR_DIR}")"
cp -R "${NODE_STAGING_DIR}" "${FUNCTIONS_VENDOR_DIR}"
log "wrote ${VENDOR_DIR} and ${FUNCTIONS_VENDOR_DIR}"
