#!/usr/bin/env bash
# Build BurnBarRemote.xcframework from crates/burnbar-remote/burnbar-remote-ffi.
#
# Usage:
#   ./scripts/build-burnbar-remote-xcframework.sh
#   BURNBAR_REMOTE_BUILD_PROFILE=debug ./scripts/build-burnbar-remote-xcframework.sh
#   BURNBAR_REMOTE_BUILD_TARGETS="aarch64-apple-darwin" ./scripts/build-burnbar-remote-xcframework.sh
#
# Output:
#   Vendor/BurnBarRemote.xcframework/
#   OpenBurnBarCore/Sources/BurnBarRemote/Generated/burnbar_remote.swift

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/crates/burnbar-remote"
PACKAGE_NAME="burnbar-remote-ffi"
LIB_NAME="burnbar_remote"
VENDOR_DIR="${ROOT_DIR}/Vendor"
XCFRAMEWORK="${VENDOR_DIR}/BurnBarRemote.xcframework"
SWIFT_PKG_DIR="${ROOT_DIR}/OpenBurnBarCore/Sources/BurnBarRemote"
GENERATED_DIR="${SWIFT_PKG_DIR}/Generated"
HEADERS_DIR="${ROOT_DIR}/build/burnbar-remote-xcframework-headers"
UNIFFI_HELPER_DIR="${ROOT_DIR}/build/burnbar-remote-uniffi-bindgen-swift-helper"

PROFILE="${BURNBAR_REMOTE_BUILD_PROFILE:-release}"
PROFILE_FLAG=""
PROFILE_DIR="release"
if [[ "${PROFILE}" == "debug" ]]; then
  PROFILE_DIR="debug"
else
  PROFILE_FLAG="--release"
fi

DEFAULT_TARGETS=(
  aarch64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
if [[ -n "${BURNBAR_REMOTE_BUILD_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=(${BURNBAR_REMOTE_BUILD_TARGETS})
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

log() { printf '[burnbar-remote-xcframework] %s\n' "$*"; }

normalize_generated_text_file() {
  perl -0pi -e 's{// T[O]DO:}{// UniFFI note:}g; s/[ \t]+(?=\n)//g; s/\n+\z/\n/' "$1"
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

RUST_TOOLCHAIN="$(
  cd "${CRATE_DIR}"
  "${RUSTUP_BIN}" show active-toolchain | awk '{print $1}'
)"

ensure_rust_target() {
  local target="$1"
  if ! "${RUSTUP_BIN}" target list --installed --toolchain "${RUST_TOOLCHAIN}" | grep -q "^${target}$"; then
    log "installing rust target ${target} for ${RUST_TOOLCHAIN}"
    "${RUSTUP_BIN}" target add "${target}" --toolchain "${RUST_TOOLCHAIN}"
  fi
}

ensure_uniffi_bindgen_swift_helper() {
  mkdir -p "${UNIFFI_HELPER_DIR}/src"
  cat > "${UNIFFI_HELPER_DIR}/Cargo.toml" <<'EOF'
[package]
name = "burnbar-remote-uniffi-bindgen-swift-helper"
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
      "${CARGO_BIN}" build ${PROFILE_FLAG} --target "${target}" --package "${PACKAGE_NAME}"
  )
}

mkdir -p "${VENDOR_DIR}" "${GENERATED_DIR}" "${HEADERS_DIR}"

for target in "${TARGETS[@]}"; do
  build_target "${target}"
done

log "generating swift bindings via pinned UniFFI helper"
ensure_uniffi_bindgen_swift_helper
HOST_DYLIB="${CRATE_DIR}/target/${TARGETS[0]}/${PROFILE_DIR}/lib${LIB_NAME}.dylib"
if [[ ! -f "${HOST_DYLIB}" ]]; then
  HOST_DYLIB="${CRATE_DIR}/target/${TARGETS[0]}/${PROFILE_DIR}/lib${LIB_NAME}.a"
fi
rm -rf "${GENERATED_DIR}"
mkdir -p "${GENERATED_DIR}"
(
  cd "${CRATE_DIR}"
  UNIFFI_LIBRARY_PATH="${HOST_DYLIB}" \
  UNIFFI_OUT_DIR="${GENERATED_DIR}" \
  UNIFFI_MODULE_NAME="burnbar_remoteFFI" \
  PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" run --manifest-path "${UNIFFI_HELPER_DIR}/Cargo.toml" --release --quiet
)
find "${GENERATED_DIR}" -name '*.swift' -type f | while IFS= read -r generated_file; do
  perl -0pi -e 's{// swiftlint:disable all\n}{// reason: generated UniFFI binding; regenerate from Rust sources instead of hand-editing.\n// swiftlint:disable all\n}g' "${generated_file}"
done
if compgen -G "${GENERATED_DIR}/*.modulemap" >/dev/null; then
  perl -0pi -e 's/framework module /module /g' "${GENERATED_DIR}/"*.modulemap
fi
find "${GENERATED_DIR}" \( -name '*.swift' -o -name '*.h' -o -name '*.modulemap' \) -type f | while IFS= read -r generated_file; do
  normalize_generated_text_file "${generated_file}"
done

rm -rf "${XCFRAMEWORK}"

build_xcframework_args=()
ARCHS_DIR="${ROOT_DIR}/build/burnbar-remote-archs"
rm -rf "${ARCHS_DIR}"
mkdir -p "${ARCHS_DIR}"

HEADER_FILE="$(find "${GENERATED_DIR}" -maxdepth 1 -name '*.h' -type f | head -n 1)"
[[ -n "${HEADER_FILE}" ]] || { echo "missing generated UniFFI header in ${GENERATED_DIR}" >&2; exit 1; }

make_framework() {
  local source_library="$1"
  local out_dir="$2"
  local framework_dir="${out_dir}/burnbar_remoteFFI.framework"
  rm -rf "${framework_dir}"
  mkdir -p "${framework_dir}/Headers" "${framework_dir}/Modules"
  cp "${source_library}" "${framework_dir}/burnbar_remoteFFI"
  cp "${HEADER_FILE}" "${framework_dir}/Headers/burnbar_remoteFFI.h"
  cat > "${framework_dir}/Modules/module.modulemap" <<'EOF'
framework module burnbar_remoteFFI {
  umbrella header "burnbar_remoteFFI.h"
  export *
}
EOF
  cat > "${framework_dir}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleName</key>
  <string>burnbar_remoteFFI</string>
  <key>CFBundleIdentifier</key>
  <string>ai.openburnbar.burnbar-remote-ffi</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
</dict>
</plist>
EOF
  build_xcframework_args+=(-framework "${framework_dir}")
}

package_framework_for_target() {
  local target="$1"
  local platform_id
  case "${target}" in
    aarch64-apple-darwin) platform_id="macos-arm64" ;;
    aarch64-apple-ios) platform_id="ios-arm64" ;;
    aarch64-apple-ios-sim) platform_id="ios-arm64-simulator" ;;
    x86_64-apple-ios) platform_id="ios-x86_64-simulator" ;;
    *) echo "unknown target ${target}" >&2; exit 1 ;;
  esac
  local out_dir="${ARCHS_DIR}/${platform_id}"
  mkdir -p "${out_dir}"
  make_framework "${CRATE_DIR}/target/${target}/${PROFILE_DIR}/lib${LIB_NAME}.a" "${out_dir}"
}

if printf '%s\n' "${TARGETS[@]}" | grep -q "aarch64-apple-ios-sim" \
   && printf '%s\n' "${TARGETS[@]}" | grep -q "x86_64-apple-ios"; then
  SIM_DIR="${ARCHS_DIR}/ios-simulator"
  mkdir -p "${SIM_DIR}"
  lipo -create \
    "${CRATE_DIR}/target/aarch64-apple-ios-sim/${PROFILE_DIR}/lib${LIB_NAME}.a" \
    "${CRATE_DIR}/target/x86_64-apple-ios/${PROFILE_DIR}/lib${LIB_NAME}.a" \
    -output "${SIM_DIR}/lib${LIB_NAME}.a"
  make_framework "${SIM_DIR}/lib${LIB_NAME}.a" "${SIM_DIR}"

  for target in aarch64-apple-darwin aarch64-apple-ios; do
    [[ " ${TARGETS[*]} " == *" ${target} "* ]] && package_framework_for_target "${target}"
  done
else
  for target in "${TARGETS[@]}"; do
    package_framework_for_target "${target}"
  done
fi

log "assembling xcframework"
xcodebuild -create-xcframework \
  "${build_xcframework_args[@]}" \
  -output "${XCFRAMEWORK}"

log "DONE: ${XCFRAMEWORK}"
log "swift bindings: ${GENERATED_DIR}"
