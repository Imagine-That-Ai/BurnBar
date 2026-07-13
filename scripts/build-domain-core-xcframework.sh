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
VENDOR_DIR="${ROOT_DIR}/Vendor"
XCFRAMEWORK="${VENDOR_DIR}/OpenBurnBarDomainCore.xcframework"
SWIFT_PKG_DIR="${ROOT_DIR}/OpenBurnBarCore/Sources/OpenBurnBarDomainCore"
GENERATED_DIR="${SWIFT_PKG_DIR}/Generated"
HEADERS_DIR="${ROOT_DIR}/build/domain-core-xcframework-headers"
UNIFFI_HELPER_DIR="${ROOT_DIR}/build/uniffi-bindgen-swift-helper"

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
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    IPHONE_SIMULATOR_DEPLOYMENT_TARGET=17.0 \
    PATH="${HOME}/.cargo/bin:${PATH}" \
      "${CARGO_BIN}" build ${PROFILE_FLAG} --target "${target}"
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
HOST_DYLIB="${CRATE_DIR}/target/${TARGETS[0]}/${PROFILE_DIR}/libopenburnbar_domain_ffi.dylib"
if [[ ! -f "${HOST_DYLIB}" ]]; then
  HOST_DYLIB="${CRATE_DIR}/target/${TARGETS[0]}/${PROFILE_DIR}/libopenburnbar_domain_ffi.a"
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
find "${GENERATED_DIR}" -maxdepth 1 -type f -exec \
  perl -0pi -e 's/[ \t]+$//mg; s/\n+\z/\n/' {} +

# Tear down any prior xcframework so the recipe is hermetic.
rm -rf "${XCFRAMEWORK}"

# Stage modulemap + headers next to each architecture's staticlib so the
# xcframework bundles them together. uniffi-bindgen-swift emits both into
# ${GENERATED_DIR}; we copy and rename for the xcframework recipe.
build_xcframework_args=()
ARCHS_DIR="${ROOT_DIR}/build/domain-core-archs"
rm -rf "${ARCHS_DIR}"
mkdir -p "${ARCHS_DIR}"

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
  mkdir -p "${out_dir}/Headers"
  cp "${CRATE_DIR}/target/${target}/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
     "${out_dir}/libopenburnbar_domain_ffi.a"
  if compgen -G "${GENERATED_DIR}/*.h" >/dev/null; then
    cp "${GENERATED_DIR}/"*.h "${out_dir}/Headers/"
  fi
  if compgen -G "${GENERATED_DIR}/*.modulemap" >/dev/null; then
    cp "${GENERATED_DIR}/"*.modulemap "${out_dir}/Headers/module.modulemap"
    perl -0pi -e 's/framework module /module /g' "${out_dir}/Headers/module.modulemap"
  fi
  build_xcframework_args+=(-library "${out_dir}/libopenburnbar_domain_ffi.a" -headers "${out_dir}/Headers")
}

# Direct-download macOS supports Apple Silicon and Intel. Package both
# architectures as one macOS library definition in the XCFramework.
if printf '%s\n' "${TARGETS[@]}" | grep -q "aarch64-apple-darwin" \
   && printf '%s\n' "${TARGETS[@]}" | grep -q "x86_64-apple-darwin"; then
  MAC_DIR="${ARCHS_DIR}/macos"
  mkdir -p "${MAC_DIR}/Headers"
  lipo -create \
    "${CRATE_DIR}/target/aarch64-apple-darwin/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    "${CRATE_DIR}/target/x86_64-apple-darwin/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    -output "${MAC_DIR}/libopenburnbar_domain_ffi.a"
  cp "${GENERATED_DIR}/"*.h "${MAC_DIR}/Headers/"
  cp "${GENERATED_DIR}/"*.modulemap "${MAC_DIR}/Headers/module.modulemap"
  perl -0pi -e 's/framework module /module /g' "${MAC_DIR}/Headers/module.modulemap"
  build_xcframework_args+=(-library "${MAC_DIR}/libopenburnbar_domain_ffi.a" -headers "${MAC_DIR}/Headers")
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
  mkdir -p "${SIM_DIR}/Headers"
  lipo -create \
    "${CRATE_DIR}/target/aarch64-apple-ios-sim/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    "${CRATE_DIR}/target/x86_64-apple-ios/${PROFILE_DIR}/libopenburnbar_domain_ffi.a" \
    -output "${SIM_DIR}/libopenburnbar_domain_ffi.a"
  if compgen -G "${GENERATED_DIR}/*.h" >/dev/null; then
    cp "${GENERATED_DIR}/"*.h "${SIM_DIR}/Headers/"
  fi
  if compgen -G "${GENERATED_DIR}/*.modulemap" >/dev/null; then
    cp "${GENERATED_DIR}/"*.modulemap "${SIM_DIR}/Headers/module.modulemap"
    perl -0pi -e 's/framework module /module /g' "${SIM_DIR}/Headers/module.modulemap"
  fi
  build_xcframework_args+=(-library "${SIM_DIR}/libopenburnbar_domain_ffi.a" -headers "${SIM_DIR}/Headers")

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

log "DONE: ${XCFRAMEWORK}"
log "swift bindings: ${GENERATED_DIR}"
