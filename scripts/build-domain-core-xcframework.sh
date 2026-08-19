#!/usr/bin/env bash
# Build OpenBurnBarDomainCore.xcframework from crates/openburnbar-domain-core.
#
# Usage:
#   ./scripts/build-domain-core-xcframework.sh                 # release build, all targets
#   DOMAIN_CORE_BUILD_PROFILE=debug ./scripts/build-domain-core-xcframework.sh
#   DOMAIN_CORE_BUILD_TARGETS="aarch64-apple-darwin" ./scripts/build-domain-core-xcframework.sh
#
# Requires:
#   * rustup with the targets installed (we install on demand)
#   * Rust/Cargo; the script builds a pinned UniFFI Swift bindgen helper on demand
#   * Xcode command-line tools (xcodebuild, lipo)
#
# Output:
#   Vendor/OpenBurnBarDomainCore.xcframework/
#   OpenBurnBarCore/Sources/OpenBurnBarDomainCore/Generated/openburnbar_domain_ffi.swift

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/crates/openburnbar-domain-core"
TARGET_DIR="${CARGO_TARGET_DIR:-${CRATE_DIR}/target}"
VENDOR_DIR="${ROOT_DIR}/Vendor"
XCFRAMEWORK="${VENDOR_DIR}/OpenBurnBarDomainCore.xcframework"
SWIFT_PKG_DIR="${ROOT_DIR}/OpenBurnBarCore/Sources/OpenBurnBarDomainCore"
GENERATED_DIR="${SWIFT_PKG_DIR}/Generated"
SAFE_QUOTA_SHIM="${ROOT_DIR}/scripts/domain-core/safe-quota-ffi.swift.inc"
HEADERS_DIR="${ROOT_DIR}/build/domain-core-xcframework-headers"
UNIFFI_HELPER_DIR="${ROOT_DIR}/build/uniffi-bindgen-swift-helper"
PROVENANCE_DIR="${CRATE_DIR}/artifact-provenance"
FINGERPRINT_NAME="openburnbar-domain-core-source.sha256"
SOURCE_FINGERPRINT="$(
  python3 "${ROOT_DIR}/scripts/ci/domain-core-union-gate.py" --source-fingerprint
)"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1704067200}"
export TZ=UTC
REMAP_FLAGS="--remap-path-prefix=${ROOT_DIR}=. --remap-path-prefix=${HOME}=~"

PROFILE="${DOMAIN_CORE_BUILD_PROFILE:-release}"
PROFILE_FLAG=""
PROFILE_DIR="release"
if [[ "${PROFILE}" == "debug" ]]; then
  PROFILE_DIR="debug"
else
  PROFILE_FLAG="--release"
fi

DEFAULT_TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
if [[ -n "${DOMAIN_CORE_BUILD_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=(${DOMAIN_CORE_BUILD_TARGETS})
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

log() { printf '[domain-core-xcframework] %s\n' "$*"; }

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

ensure_rust_target() {
  local target="$1"
  if ! (cd "${CRATE_DIR}" && "${RUSTUP_BIN}" target list --installed) | grep -q "^${target}$"; then
    log "installing rust target ${target}"
    (cd "${CRATE_DIR}" && "${RUSTUP_BIN}" target add "${target}")
  fi
}

ensure_uniffi_bindgen_swift_helper() {
  mkdir -p "${UNIFFI_HELPER_DIR}/src"
  cat > "${UNIFFI_HELPER_DIR}/Cargo.toml" <<'EOF'
[package]
name = "openburnbar-uniffi-bindgen-swift-helper"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
anyhow = "1"
camino = "1"
uniffi_bindgen = "=0.28.3"
EOF
  cat > "${UNIFFI_HELPER_DIR}/src/main.rs" <<'EOF'
use anyhow::Context;
use camino::Utf8PathBuf;
use uniffi_bindgen::bindings::{generate_swift_bindings, SwiftBindingsOptions};

fn main() -> anyhow::Result<()> {
    let library_path = Utf8PathBuf::from(
        std::env::var("UNIFFI_LIBRARY_PATH").context("UNIFFI_LIBRARY_PATH is required")?,
    );
    let out_dir = Utf8PathBuf::from(
        std::env::var("UNIFFI_OUT_DIR").context("UNIFFI_OUT_DIR is required")?,
    );
    let module_name = std::env::var("UNIFFI_MODULE_NAME").ok();

    generate_swift_bindings(SwiftBindingsOptions {
        generate_swift_sources: true,
        generate_headers: true,
        generate_modulemap: true,
        library_path,
        out_dir,
        xcframework: true,
        module_name,
        modulemap_filename: None,
        metadata_no_deps: false,
    })
}
EOF
}

build_target() {
  local target="$1"
  ensure_rust_target "${target}"
  log "cargo build ${PROFILE} ${target}"
  (
    cd "${CRATE_DIR}"
    # Deployment minimums belong to the consuming Xcode targets. Exporting
    # Apple deployment variables here also affects Cargo's host-built proc
    # macros and can make their dependencies unresolvable under pinned Rust.
    RUSTFLAGS="${RUSTFLAGS:-} ${REMAP_FLAGS}" \
    PATH="${HOME}/.cargo/bin:${PATH}" \
      "${CARGO_BIN}" build ${PROFILE_FLAG} --target "${target}" \
        -p openburnbar-domain-ffi --lib
  )
}

mkdir -p "${VENDOR_DIR}" "${GENERATED_DIR}" "${HEADERS_DIR}"

for target in "${TARGETS[@]}"; do
  build_target "${target}"
done

# Generate Swift bindings from one host-built dylib so the .swift output is
# identical across CI hosts. The dylib is byte-equivalent to the staticlib
# from the iroh-introspection point of view.
log "generating swift bindings via pinned UniFFI helper"
ensure_uniffi_bindgen_swift_helper
HOST_DYLIB="${TARGET_DIR}/${TARGETS[0]}/${PROFILE_DIR}/libopenburnbar_domain_ffi.dylib"
if [[ ! -f "${HOST_DYLIB}" ]]; then
  HOST_DYLIB="${TARGET_DIR}/${TARGETS[0]}/${PROFILE_DIR}/libopenburnbar_domain_ffi.a"
fi
rm -rf "${GENERATED_DIR}"
mkdir -p "${GENERATED_DIR}"
(
  cd "${CRATE_DIR}"
  UNIFFI_LIBRARY_PATH="${HOST_DYLIB}" \
  UNIFFI_OUT_DIR="${GENERATED_DIR}" \
  UNIFFI_MODULE_NAME="openburnbar_domain_ffiFFI" \
  PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" run --manifest-path "${UNIFFI_HELPER_DIR}/Cargo.toml" --release --quiet
)
if compgen -G "${GENERATED_DIR}/*.modulemap" >/dev/null; then
  perl -0pi -e 's/framework module /module /g' "${GENERATED_DIR}/"*.modulemap
fi
SWIFT_BINDING="${GENERATED_DIR}/openburnbar_domain_ffi.swift"
python3 - "${SWIFT_BINDING}" "${SAFE_QUOTA_SHIM}" <<'PY'
from pathlib import Path
import sys

binding_path = Path(sys.argv[1])
shim_path = Path(sys.argv[2])
marker = "// swiftlint:enable all"
binding = binding_path.read_text()
if binding.count(marker) != 1:
    raise SystemExit(f"expected exactly one {marker!r} in {binding_path}")
shim = shim_path.read_text().rstrip() + "\n\n"
injected = binding.replace(marker, shim + marker)
binding_path.write_text(injected.rstrip() + "\n")
PY
find "${GENERATED_DIR}" -maxdepth 1 -type f -exec \
  perl -0pi -e 's/[ \t]+$//mg; s/\n+\z/\n/' {} +
mkdir -p "${PROVENANCE_DIR}"
printf '%s\n' "${SOURCE_FINGERPRINT}" > "${PROVENANCE_DIR}/swift.sha256"

# Tear down any prior xcframework so the recipe is hermetic.
rm -rf "${XCFRAMEWORK}"

# Stage modulemap + headers next to each architecture's staticlib so the
# xcframework bundles them together. uniffi-bindgen-swift emits both into
# ${GENERATED_DIR}; we copy and rename for the xcframework recipe.
build_xcframework_args=()
ARCHS_DIR="${ROOT_DIR}/build/domain-core-archs"
rm -rf "${ARCHS_DIR}"
mkdir -p "${ARCHS_DIR}"

# The iOS archive links this xcframework alongside OpenBurnBarIroh. Both used to
# ship a bare static library plus `Headers/module.modulemap`, and Xcode flattens
# every `-headers` directory into the SAME `BuildProductsPath/include`, so both
# tried to write `include/module.modulemap` and the archive failed with
# "Multiple commands produce ...". Packaging as a real `.framework` keeps the
# module map inside the bundle at `Modules/module.modulemap`, where it cannot
# collide with any other binary target. BurnBarRemote.xcframework already ships
# this way; this converges on that proven layout.
FRAMEWORK_MODULE_NAME="openburnbar_domain_ffiFFI"

make_framework() {
  local source_library="$1"
  local out_dir="$2"
  local framework_dir="${out_dir}/${FRAMEWORK_MODULE_NAME}.framework"
  local umbrella_header="${FRAMEWORK_MODULE_NAME}.h"
  [[ -f "${GENERATED_DIR}/${umbrella_header}" ]] \
    || { echo "missing generated umbrella header ${umbrella_header} in ${GENERATED_DIR}" >&2; exit 1; }
  rm -rf "${framework_dir}"
  mkdir -p "${framework_dir}/Headers" "${framework_dir}/Modules"
  cp "${source_library}" "${framework_dir}/${FRAMEWORK_MODULE_NAME}"
  cp "${GENERATED_DIR}/"*.h "${framework_dir}/Headers/"
  cat > "${framework_dir}/Modules/module.modulemap" <<EOF
framework module ${FRAMEWORK_MODULE_NAME} {
  umbrella header "${umbrella_header}"
  export *
}
EOF
  cat > "${framework_dir}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleName</key>
  <string>${FRAMEWORK_MODULE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>ai.openburnbar.domain-core-ffi</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
</dict>
</plist>
EOF
  build_xcframework_args+=(-framework "${framework_dir}")
}

# Group iOS device + simulator separately because lipo cannot merge across
# platforms; we let `xcodebuild -create-xcframework` do platform separation.
package_static_for_target() {
  local target="$1"
  local platform_id
  case "${target}" in
    aarch64-apple-darwin) platform_id="macos-arm64" ;;
    x86_64-apple-darwin) platform_id="macos-x86_64" ;;
    aarch64-apple-ios) platform_id="ios-arm64" ;;
    aarch64-apple-ios-sim) platform_id="ios-arm64-simulator" ;;
    x86_64-apple-ios) platform_id="ios-x86_64-simulator" ;;
    *) echo "unknown target ${target}" >&2; exit 1 ;;
  esac
  local out_dir="${ARCHS_DIR}/${platform_id}"
  mkdir -p "${out_dir}"
  cp "${TARGET_DIR}/${target}/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
     "${out_dir}/libopenburnbar_domain_ffi.a"
  make_framework "${out_dir}/libopenburnbar_domain_ffi.a" "${out_dir}"
}

# Direct-download macOS supports Apple Silicon and Intel. Package both
# architectures as one macOS library definition in the XCFramework.
if printf '%s\n' "${TARGETS[@]}" | grep -q "aarch64-apple-darwin" \
   && printf '%s\n' "${TARGETS[@]}" | grep -q "x86_64-apple-darwin"; then
  MAC_DIR="${ARCHS_DIR}/macos"
  mkdir -p "${MAC_DIR}"
  lipo -create \
    "${TARGET_DIR}/aarch64-apple-darwin/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    "${TARGET_DIR}/x86_64-apple-darwin/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    -output "${MAC_DIR}/libopenburnbar_domain_ffi.a"
  make_framework "${MAC_DIR}/libopenburnbar_domain_ffi.a" "${MAC_DIR}"
else
  for target in aarch64-apple-darwin x86_64-apple-darwin; do
    [[ " ${TARGETS[*]} " == *" ${target} "* ]] && package_static_for_target "${target}"
  done
fi

# Simulator: arm64 + x86_64 must be merged into a single fat archive before
# packaging into the xcframework slice.
if printf '%s\n' "${TARGETS[@]}" | grep -q "aarch64-apple-ios-sim" \
   && printf '%s\n' "${TARGETS[@]}" | grep -q "x86_64-apple-ios"; then
  SIM_DIR="${ARCHS_DIR}/ios-simulator"
  mkdir -p "${SIM_DIR}"
  lipo -create \
    "${TARGET_DIR}/aarch64-apple-ios-sim/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    "${TARGET_DIR}/x86_64-apple-ios/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    -output "${SIM_DIR}/libopenburnbar_domain_ffi.a"
  make_framework "${SIM_DIR}/libopenburnbar_domain_ffi.a" "${SIM_DIR}"

  # Per-arch slices still emitted for archive reproducibility.
  if [[ " ${TARGETS[*]} " == *" aarch64-apple-ios "* ]]; then
    package_static_for_target aarch64-apple-ios
  fi
else
  for target in "${TARGETS[@]}"; do
    if [[ "${target}" != "aarch64-apple-darwin" && "${target}" != "x86_64-apple-darwin" ]]; then
      package_static_for_target "${target}"
    fi
  done
fi

log "assembling xcframework"
xcodebuild -create-xcframework \
  "${build_xcframework_args[@]}" \
  -output "${XCFRAMEWORK}"
python3 "${ROOT_DIR}/scripts/lib/canonicalize-xcframework-plist.py" \
  "${XCFRAMEWORK}/Info.plist"
printf '%s\n' "${SOURCE_FINGERPRINT}" > "${XCFRAMEWORK}/${FINGERPRINT_NAME}"

log "DONE: ${XCFRAMEWORK}"
log "swift bindings: ${GENERATED_DIR}"
