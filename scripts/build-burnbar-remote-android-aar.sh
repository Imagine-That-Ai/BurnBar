#!/usr/bin/env bash
# Build Vendor/burnbar-remote.aar from crates/burnbar-remote/burnbar-remote-ffi.
#
# Usage:
#   ./scripts/build-burnbar-remote-android-aar.sh
#   BURNBAR_REMOTE_BUILD_PROFILE=debug ./scripts/build-burnbar-remote-android-aar.sh
#   BURNBAR_REMOTE_ANDROID_ABIS="arm64-v8a x86_64" ./scripts/build-burnbar-remote-android-aar.sh
#   ./scripts/build-burnbar-remote-android-aar.sh --dry-run
#
# Output:
#   Vendor/burnbar-remote.aar
#   android/burnbar-remote/src/main/java/uniffi/burnbar_remote/burnbar_remote.kt

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/crates/burnbar-remote"
PACKAGE_NAME="burnbar-remote-ffi"
LIB_NAME="burnbar_remote"
VENDOR_DIR="${ROOT_DIR}/Vendor"
AAR_PATH="${VENDOR_DIR}/burnbar-remote.aar"
KOTLIN_PKG_DIR="${ROOT_DIR}/android/burnbar-remote/src/main/java"
GENERATED_KT_DIR="${KOTLIN_PKG_DIR}/uniffi/burnbar_remote"
BUILD_DIR="${ROOT_DIR}/build/burnbar-remote-aar"
ARCHS_DIR="${BUILD_DIR}/jni"
UNIFFI_HELPER_DIR="${ROOT_DIR}/build/burnbar-remote-uniffi-bindgen-kotlin-helper"
DETERMINISTIC_ZIP_TIME="${BURNBAR_REMOTE_AAR_ZIP_TIME:-202401010000.00}"

PROFILE="${BURNBAR_REMOTE_BUILD_PROFILE:-release}"
PROFILE_FLAG=""
PROFILE_DIR="release"
if [[ "${PROFILE}" == "debug" ]]; then
  PROFILE_DIR="debug"
else
  PROFILE_FLAG="--release"
fi

DEFAULT_ABIS=(arm64-v8a x86_64 armeabi-v7a x86)
if [[ -n "${BURNBAR_REMOTE_ANDROID_ABIS:-}" ]]; then
  # shellcheck disable=SC2206
  ABIS=(${BURNBAR_REMOTE_ANDROID_ABIS})
else
  ABIS=("${DEFAULT_ABIS[@]}")
fi

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown arg: ${arg}" >&2; exit 64 ;;
  esac
done

log() { printf '[burnbar-remote-aar] %s\n' "$*" >&2; }

abort() {
  echo "[burnbar-remote-aar] FATAL: $*" >&2
  exit 1
}

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

RUST_TOOLCHAIN="$(
  cd "${CRATE_DIR}"
  "${RUSTUP_BIN}" show active-toolchain | awk '{print $1}'
)"

ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
[[ -d "${ANDROID_SDK}" ]] || abort "Android SDK not found at ${ANDROID_SDK}; export ANDROID_HOME"

ensure_ndk() {
  local desired_version="${BURNBAR_REMOTE_ANDROID_NDK_VERSION:-${ANDROID_NDK_VERSION:-29.0.14206865}}"
  local ndk_root="${ANDROID_SDK}/ndk/${desired_version}"
  if [[ -d "${ndk_root}" ]]; then
    log "found NDK at ${ndk_root}"
    echo "${ndk_root}"
    return
  fi
  local sdkmanager_bin=""
  for candidate in \
    "${ANDROID_SDK}/cmdline-tools/latest/bin/sdkmanager" \
    "${ANDROID_SDK}/cmdline-tools/bin/sdkmanager" \
    "${ANDROID_SDK}/tools/bin/sdkmanager"; do
    if [[ -x "${candidate}" ]]; then
      sdkmanager_bin="${candidate}"; break
    fi
  done
  if [[ -z "${sdkmanager_bin}" ]]; then
    abort "Android NDK ${desired_version} missing and sdkmanager not available. Install Android SDK Command-line Tools or pre-install ndk;${desired_version}."
  fi
  log "installing Android NDK ${desired_version} via sdkmanager"
  yes | "${sdkmanager_bin}" --licenses >/dev/null 2>&1 || true
  "${sdkmanager_bin}" "ndk;${desired_version}" >&2
  [[ -d "${ndk_root}" ]] || abort "NDK install failed; ${ndk_root} not present"
  printf '%s\n' "${ndk_root}"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry run: ANDROID_SDK=${ANDROID_SDK} ABIs=${ABIS[*]} profile=${PROFILE}"
  log "dry run: would write ${AAR_PATH} and ${GENERATED_KT_DIR}"
  exit 0
fi

ANDROID_NDK_HOME="$(ensure_ndk)"
export ANDROID_NDK_HOME
export ANDROID_NDK_ROOT="${ANDROID_NDK_HOME}"
log "using NDK at ${ANDROID_NDK_HOME}"

ANDROID_16KB_RUSTFLAGS="-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384"
android_rustflags() {
  if [[ -n "${RUSTFLAGS:-}" ]]; then
    printf '%s %s\n' "${RUSTFLAGS}" "${ANDROID_16KB_RUSTFLAGS}"
  else
    printf '%s\n' "${ANDROID_16KB_RUSTFLAGS}"
  fi
}

abi_to_rust_target() {
  case "$1" in
    arm64-v8a) echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "armv7-linux-androideabi" ;;
    x86) echo "i686-linux-android" ;;
    x86_64) echo "x86_64-linux-android" ;;
    *) abort "unknown abi: $1" ;;
  esac
}

ensure_rust_target() {
  local target="$1"
  if ! "${RUSTUP_BIN}" target list --installed --toolchain "${RUST_TOOLCHAIN}" | grep -q "^${target}$"; then
    log "installing rust target ${target} for ${RUST_TOOLCHAIN}"
    "${RUSTUP_BIN}" target add "${target}" --toolchain "${RUST_TOOLCHAIN}"
  fi
}

if ! command -v cargo-ndk >/dev/null 2>&1; then
  log "installing cargo-ndk"
  "${CARGO_BIN}" install cargo-ndk --locked --version "^3.5"
fi

ensure_uniffi_bindgen_kotlin_helper() {
  mkdir -p "${UNIFFI_HELPER_DIR}/src"
  cat > "${UNIFFI_HELPER_DIR}/Cargo.toml" <<'EOF'
[package]
name = "burnbar-remote-uniffi-bindgen-kotlin-helper"
version = "0.1.0"
edition = "2021"
publish = false

[dependencies]
anyhow = "1"
camino = "1"
cargo_metadata = "0.15"
uniffi_bindgen = "=0.28.3"
EOF
  cat > "${UNIFFI_HELPER_DIR}/src/main.rs" <<'EOF'
use anyhow::Context;
use camino::Utf8PathBuf;
use cargo_metadata::MetadataCommand;
use uniffi_bindgen::{
    bindings::KotlinBindingGenerator,
    cargo_metadata::CrateConfigSupplier,
    library_mode::generate_bindings,
};

fn main() -> anyhow::Result<()> {
    let library_path = Utf8PathBuf::from(
        std::env::var("UNIFFI_LIBRARY_PATH").context("UNIFFI_LIBRARY_PATH is required")?,
    );
    let out_dir = Utf8PathBuf::from(
        std::env::var("UNIFFI_OUT_DIR").context("UNIFFI_OUT_DIR is required")?,
    );
    let metadata = MetadataCommand::new().exec().context("cargo metadata failed")?;
    let config_supplier = CrateConfigSupplier::from(metadata);

    generate_bindings(
        &library_path,
        None,
        &KotlinBindingGenerator,
        &config_supplier,
        None,
        &out_dir,
        false,
    )?;
    Ok(())
}
EOF
}

mkdir -p "${VENDOR_DIR}" "${BUILD_DIR}" "${ARCHS_DIR}"

CARGO_NDK_ARGS=()
for abi in "${ABIS[@]}"; do
  ensure_rust_target "$(abi_to_rust_target "${abi}")"
  CARGO_NDK_ARGS+=(-t "${abi}")
done

log "building burnbar-remote for ${ABIS[*]} (${PROFILE})"
(
  cd "${CRATE_DIR}"
  ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" \
  RUSTFLAGS="$(android_rustflags)" \
  PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" ndk \
      "${CARGO_NDK_ARGS[@]}" \
      -o "${ARCHS_DIR}" \
      build ${PROFILE_FLAG} --lib --package "${PACKAGE_NAME}"
)

for abi in "${ABIS[@]}"; do
  expected="${ARCHS_DIR}/${abi}/lib${LIB_NAME}.so"
  [[ -f "${expected}" ]] || abort "expected output missing: ${expected}"
done

ensure_uniffi_bindgen_kotlin_helper
BINDGEN_ABI="${ABIS[0]}"
BINDGEN_TARGET="$(abi_to_rust_target "${BINDGEN_ABI}")"
HOST_SO="${CRATE_DIR}/target/${BINDGEN_TARGET}/${PROFILE_DIR}/lib${LIB_NAME}.so"
[[ -f "${HOST_SO}" ]] || HOST_SO="${ARCHS_DIR}/${BINDGEN_ABI}/lib${LIB_NAME}.so"

if [[ "${PROFILE}" != "debug" ]]; then
  log "building debug metadata library for Kotlin bindgen (${BINDGEN_ABI})"
  (
    cd "${CRATE_DIR}"
    ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" \
    RUSTFLAGS="$(android_rustflags)" \
    PATH="${HOME}/.cargo/bin:${PATH}" \
      "${CARGO_BIN}" ndk \
        -t "${BINDGEN_ABI}" \
        -o "${BUILD_DIR}/bindgen-jni" \
        build --lib --package "${PACKAGE_NAME}"
  )
  HOST_SO="${CRATE_DIR}/target/${BINDGEN_TARGET}/debug/lib${LIB_NAME}.so"
fi

rm -rf "${GENERATED_KT_DIR}"
rm -rf "${BUILD_DIR}/kotlin-out"
mkdir -p "${GENERATED_KT_DIR}"
log "generating kotlin bindings via pinned UniFFI helper (${BINDGEN_ABI})"
(
  cd "${CRATE_DIR}"
  UNIFFI_LIBRARY_PATH="${HOST_SO}" \
  UNIFFI_OUT_DIR="${BUILD_DIR}/kotlin-out" \
  PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" run --manifest-path "${UNIFFI_HELPER_DIR}/Cargo.toml" --release --quiet
)

if [[ ! -d "${BUILD_DIR}/kotlin-out/uniffi/burnbar_remote" ]]; then
  abort "uniffi-bindgen-kotlin did not produce uniffi/burnbar_remote/"
fi
cp -R "${BUILD_DIR}/kotlin-out/uniffi/burnbar_remote/." "${GENERATED_KT_DIR}/"
find "${GENERATED_KT_DIR}" -name '*.kt' -type f | while IFS= read -r generated_file; do
  sanitized_file="${generated_file}.sanitized"
  awk '
    /^@file:Suppress\(/ { next }
    /^[[:space:]]*@Suppress\(/ { next }
    {
      sub(/[[:space:]]+$/, "")
      lines[++line_count] = $0
    }
    END {
      while (line_count > 0 && lines[line_count] == "") {
        line_count--
      }
      for (line = 1; line <= line_count; line++) {
        print lines[line]
      }
    }
  ' "${generated_file}" > "${sanitized_file}"
  mv "${sanitized_file}" "${generated_file}"
  perl -0pi -e 's{// [T]ODO: maybe we should log a warning if called more than once\?}{// Generated UniFFI lifecycle guard intentionally ignores duplicate destroy calls.}g' "${generated_file}"
done

AAR_STAGING="${BUILD_DIR}/staging"
rm -rf "${AAR_STAGING}"
mkdir -p "${AAR_STAGING}/jni"

for abi in "${ABIS[@]}"; do
  mkdir -p "${AAR_STAGING}/jni/${abi}"
  cp "${ARCHS_DIR}/${abi}/lib${LIB_NAME}.so" \
     "${AAR_STAGING}/jni/${abi}/lib${LIB_NAME}.so"
  cp "${ARCHS_DIR}/${abi}/lib${LIB_NAME}.so" \
     "${AAR_STAGING}/jni/${abi}/libuniffi_${LIB_NAME}.so"
done

cat > "${AAR_STAGING}/AndroidManifest.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="com.openburnbar.remote.native_">
  <uses-sdk android:minSdkVersion="26" />
</manifest>
EOF

EMPTY_JAR_DIR="${BUILD_DIR}/empty-classes"
rm -rf "${EMPTY_JAR_DIR}"
mkdir -p "${EMPTY_JAR_DIR}/META-INF"
cat > "${EMPTY_JAR_DIR}/META-INF/MANIFEST.MF" <<'EOF'
Manifest-Version: 1.0
Created-By: OpenBurnBar

EOF
find "${EMPTY_JAR_DIR}" -exec touch -h -t "${DETERMINISTIC_ZIP_TIME}" {} +
(
  cd "${EMPTY_JAR_DIR}"
  COPYFILE_DISABLE=1 zip -0 -X -q "${AAR_STAGING}/classes.jar" META-INF/MANIFEST.MF
)

: > "${AAR_STAGING}/proguard.txt"
: > "${AAR_STAGING}/R.txt"

mkdir -p "${VENDOR_DIR}"
rm -f "${AAR_PATH}"
find "${AAR_STAGING}" -exec touch -h -t "${DETERMINISTIC_ZIP_TIME}" {} +
(
  cd "${AAR_STAGING}"
  find . -type f | LC_ALL=C sort | COPYFILE_DISABLE=1 zip -0 -X -q "${AAR_PATH}" -@
)

log "DONE: ${AAR_PATH}"
log "kotlin bindings: ${GENERATED_KT_DIR}"
