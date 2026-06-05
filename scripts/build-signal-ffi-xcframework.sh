#!/usr/bin/env bash
# Build OpenBurnBarSignalFfi.xcframework from the vendored libsignal FFI.
#
# Usage:
#   ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_SKIP_BUILD=1 ./scripts/build-signal-ffi-xcframework.sh
#   SIGNAL_FFI_BUILD_TARGETS="aarch64-apple-darwin aarch64-apple-ios-sim" ./scripts/build-signal-ffi-xcframework.sh
#
# Output:
#   Vendor/OpenBurnBarSignalFfi.xcframework/
#
# The Swift libsignal package links a library named `signal_ffi`. OpenBurnBar
# also links a Rust iroh static archive, so linking libsignal_ffi as a static
# archive duplicates Rust runtime symbols. This packages libsignal_ffi as a
# dylib XCFramework and lets SwiftPM/Xcode embed it as a binary dependency.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBSIGNAL_DIR="${ROOT_DIR}/Vendor/libsignal"
VENDOR_DIR="${ROOT_DIR}/Vendor"
XCFRAMEWORK="${VENDOR_DIR}/OpenBurnBarSignalFfi.xcframework"
BUILD_DIR="${ROOT_DIR}/build/signal-ffi-xcframework"
ARCHS_DIR="${BUILD_DIR}/archs"
HEADERS_DIR="${BUILD_DIR}/Headers"

PROFILE="${SIGNAL_FFI_BUILD_PROFILE:-release}"
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
if [[ -n "${SIGNAL_FFI_BUILD_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=(${SIGNAL_FFI_BUILD_TARGETS})
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

log() { printf '[signal-ffi-xcframework] %s\n' "$*"; }

abort() {
  echo "[signal-ffi-xcframework] FATAL: $*" >&2
  exit 1
}

[[ -d "${LIBSIGNAL_DIR}" ]] || abort "missing ${LIBSIGNAL_DIR}; clone libsignal v0.94.4 first"
[[ -x "/usr/bin/xcodebuild" ]] || abort "xcodebuild is required"
[[ -x "/usr/bin/lipo" ]] || abort "lipo is required"
[[ -x "/usr/bin/install_name_tool" ]] || abort "install_name_tool is required"

if [[ -x "${HOME}/.cargo/bin/rustup" ]]; then
  RUSTUP_BIN="${HOME}/.cargo/bin/rustup"
else
  RUSTUP_BIN="$(command -v rustup || true)"
fi
[[ -x "${RUSTUP_BIN}" ]] || abort "rustup not found in PATH"

if [[ -x "${HOME}/.cargo/bin/cargo" ]]; then
  CARGO_BIN="${HOME}/.cargo/bin/cargo"
else
  CARGO_BIN="$(command -v cargo || true)"
fi
[[ -x "${CARGO_BIN}" ]] || abort "cargo not found in PATH"

ensure_rust_target() {
  local target="$1"
  if ! "${RUSTUP_BIN}" +stable target list --installed | grep -q "^${target}$"; then
    log "installing rust target ${target}"
    "${RUSTUP_BIN}" +stable target add "${target}"
  fi
}

build_target() {
  local target="$1"
  local features="log/release_max_level_info"
  if [[ "${target}" != "aarch64-apple-ios" ]]; then
    features="libsignal-bridge-testing ${features}"
  fi
  ensure_rust_target "${target}"
  log "cargo +stable rustc ${PROFILE} ${target}"
  (
    cd "${LIBSIGNAL_DIR}"
    CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    IPHONE_SIMULATOR_DEPLOYMENT_TARGET=17.0 \
    PATH="${HOME}/.cargo/bin:${PATH}" \
      "${CARGO_BIN}" +stable rustc \
        -p libsignal-ffi \
        ${PROFILE_FLAG} \
        --target "${target}" \
        --features "${features}" \
        -- --crate-type cdylib
  )
}

latest_target_dylib() {
  local target="$1"
  local dir="${LIBSIGNAL_DIR}/target/${target}/${PROFILE_DIR}/deps"
  [[ -d "${dir}" ]] || abort "missing build output dir ${dir}"
  local dylib
  dylib="$(ls -t "${dir}"/libsignal_ffi-*.dylib 2>/dev/null | head -n 1 || true)"
  [[ -f "${dylib}" ]] || abort "missing libsignal_ffi dylib for ${target}"
  printf '%s\n' "${dylib}"
}

stage_headers() {
  rm -rf "${HEADERS_DIR}"
  mkdir -p "${HEADERS_DIR}"
  cat > "${HEADERS_DIR}/OpenBurnBarSignalFfi.h" <<'EOF'
void OpenBurnBarSignalFfiLinkAnchor(void);
EOF
}

stage_target() {
  local target="$1"
  local platform_id="$2"
  local dylib
  dylib="$(latest_target_dylib "${target}")"
  local out_dir="${ARCHS_DIR}/${platform_id}"
  mkdir -p "${out_dir}/Headers"
  cp "${dylib}" "${out_dir}/libsignal_ffi.dylib"
  /usr/bin/install_name_tool -id "@rpath/libsignal_ffi.dylib" "${out_dir}/libsignal_ffi.dylib"
  cp "${HEADERS_DIR}/"* "${out_dir}/Headers/"
}

if [[ "${SIGNAL_FFI_SKIP_BUILD:-0}" != "1" ]]; then
  for target in "${TARGETS[@]}"; do
    build_target "${target}"
  done
else
  log "skipping cargo builds; packaging existing target outputs"
fi

mkdir -p "${VENDOR_DIR}"
rm -rf "${ARCHS_DIR}" "${XCFRAMEWORK}"
mkdir -p "${ARCHS_DIR}"
stage_headers

build_xcframework_args=()

if [[ " ${TARGETS[*]} " == *" aarch64-apple-darwin "* ]]; then
  stage_target aarch64-apple-darwin macos-arm64
  build_xcframework_args+=(-library "${ARCHS_DIR}/macos-arm64/libsignal_ffi.dylib" -headers "${ARCHS_DIR}/macos-arm64/Headers")
fi

if [[ " ${TARGETS[*]} " == *" aarch64-apple-ios "* ]]; then
  stage_target aarch64-apple-ios ios-arm64
  build_xcframework_args+=(-library "${ARCHS_DIR}/ios-arm64/libsignal_ffi.dylib" -headers "${ARCHS_DIR}/ios-arm64/Headers")
fi

if [[ " ${TARGETS[*]} " == *" aarch64-apple-ios-sim "* && " ${TARGETS[*]} " == *" x86_64-apple-ios "* ]]; then
  stage_target aarch64-apple-ios-sim ios-arm64-simulator
  stage_target x86_64-apple-ios ios-x86_64-simulator
  local_sim_dir="${ARCHS_DIR}/ios-simulator"
  mkdir -p "${local_sim_dir}/Headers"
  /usr/bin/lipo -create \
    "${ARCHS_DIR}/ios-arm64-simulator/libsignal_ffi.dylib" \
    "${ARCHS_DIR}/ios-x86_64-simulator/libsignal_ffi.dylib" \
    -output "${local_sim_dir}/libsignal_ffi.dylib"
  /usr/bin/install_name_tool -id "@rpath/libsignal_ffi.dylib" "${local_sim_dir}/libsignal_ffi.dylib"
  cp "${HEADERS_DIR}/"* "${local_sim_dir}/Headers/"
  build_xcframework_args+=(-library "${local_sim_dir}/libsignal_ffi.dylib" -headers "${local_sim_dir}/Headers")
else
  if [[ " ${TARGETS[*]} " == *" aarch64-apple-ios-sim "* ]]; then
    stage_target aarch64-apple-ios-sim ios-arm64-simulator
    build_xcframework_args+=(-library "${ARCHS_DIR}/ios-arm64-simulator/libsignal_ffi.dylib" -headers "${ARCHS_DIR}/ios-arm64-simulator/Headers")
  fi
  if [[ " ${TARGETS[*]} " == *" x86_64-apple-ios "* ]]; then
    stage_target x86_64-apple-ios ios-x86_64-simulator
    build_xcframework_args+=(-library "${ARCHS_DIR}/ios-x86_64-simulator/libsignal_ffi.dylib" -headers "${ARCHS_DIR}/ios-x86_64-simulator/Headers")
  fi
fi

[[ "${#build_xcframework_args[@]}" -gt 0 ]] || abort "no XCFramework libraries staged"

log "assembling ${XCFRAMEWORK}"
/usr/bin/xcodebuild -create-xcframework \
  "${build_xcframework_args[@]}" \
  -output "${XCFRAMEWORK}"

log "DONE: ${XCFRAMEWORK}"
