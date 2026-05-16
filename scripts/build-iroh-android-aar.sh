#!/usr/bin/env bash
# Build Vendor/openburnbar-iroh.aar from crates/openburnbar-iroh.
#
# Usage:
#   ./scripts/build-iroh-android-aar.sh                    # release, all ABIs
#   IROH_BUILD_PROFILE=debug ./scripts/build-iroh-android-aar.sh
#   IROH_ANDROID_ABIS="arm64-v8a x86_64" ./scripts/build-iroh-android-aar.sh
#   ./scripts/build-iroh-android-aar.sh --dry-run          # validate inputs only
#
# Requires:
#   * rustup with android targets (script installs on demand)
#   * cargo-ndk (script installs on demand via `cargo install`)
#   * Android NDK (script installs via sdkmanager if ANDROID_HOME/ANDROID_SDK_ROOT is set)
#   * uniffi_bindgen with Kotlin support, pinned (`=0.28.3`)
#   * `zip` (BSD or GNU) for packing the AAR
#   * `keytool` + `jar` from any JDK (Android requires a built-in classes.jar)
#
# Output:
#   Vendor/openburnbar-iroh.aar  (multi-ABI, classes.jar + 4 jni libs)
#   android/openburnbar-iroh-relay/src/main/java/uniffi/openburnbar_iroh/openburnbar_iroh.kt
#
# Mirrors the iOS build flow in scripts/build-iroh-xcframework.sh — same crate,
# same UniFFI surface, different bindgen + packaging.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${ROOT_DIR}/crates/openburnbar-iroh"
VENDOR_DIR="${ROOT_DIR}/Vendor"
AAR_PATH="${VENDOR_DIR}/openburnbar-iroh.aar"
KOTLIN_PKG_DIR="${ROOT_DIR}/android/openburnbar-iroh-relay/src/main/java"
GENERATED_KT_DIR="${KOTLIN_PKG_DIR}/uniffi/openburnbar_iroh"
BUILD_DIR="${ROOT_DIR}/build/iroh-aar"
ARCHS_DIR="${BUILD_DIR}/jni"
UNIFFI_HELPER_DIR="${ROOT_DIR}/build/uniffi-bindgen-kotlin-helper"

PROFILE="${IROH_BUILD_PROFILE:-release}"
PROFILE_FLAG=""
PROFILE_DIR="release"
if [[ "${PROFILE}" == "debug" ]]; then
  PROFILE_DIR="debug"
else
  PROFILE_FLAG="--release"
fi

# Default ABIs — all four supported by Google Play.
DEFAULT_ABIS=(arm64-v8a x86_64 armeabi-v7a x86)
if [[ -n "${IROH_ANDROID_ABIS:-}" ]]; then
  # shellcheck disable=SC2206
  ABIS=(${IROH_ANDROID_ABIS})
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

log() { printf '[iroh-aar] %s\n' "$*"; }

abort() {
  echo "[iroh-aar] FATAL: $*" >&2
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

# --- Android SDK + NDK discovery ------------------------------------------------
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android}}"
[[ -d "${ANDROID_SDK}" ]] || abort "Android SDK not found at ${ANDROID_SDK}; export ANDROID_HOME"

ensure_ndk() {
  local desired_version="${IROH_ANDROID_NDK_VERSION:-26.3.11579264}"
  local ndk_root="${ANDROID_SDK}/ndk/${desired_version}"
  if [[ -d "${ndk_root}" ]]; then
    log "found NDK at ${ndk_root}"
    echo "${ndk_root}"
    return
  fi
  # Auto-install via sdkmanager if available.
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
  "${sdkmanager_bin}" "ndk;${desired_version}"
  [[ -d "${ndk_root}" ]] || abort "NDK install failed; ${ndk_root} not present"
  echo "${ndk_root}"
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
  log "dry run: ANDROID_SDK=${ANDROID_SDK} ABIs=${ABIS[*]} profile=${PROFILE}"
  log "dry run: would write ${AAR_PATH} and ${GENERATED_KT_DIR}"
  exit 0
fi

ANDROID_NDK_HOME="$(ensure_ndk)"
export ANDROID_NDK_HOME
log "using NDK at ${ANDROID_NDK_HOME}"

# --- Rust targets --------------------------------------------------------------
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
  if ! "${RUSTUP_BIN}" target list --installed | grep -q "^${target}$"; then
    log "installing rust target ${target}"
    "${RUSTUP_BIN}" target add "${target}"
  fi
}

if ! command -v cargo-ndk >/dev/null 2>&1; then
  log "installing cargo-ndk"
  "${CARGO_BIN}" install cargo-ndk --locked --version "^3.5"
fi

# --- UniFFI Kotlin bindgen helper ----------------------------------------------
ensure_uniffi_bindgen_kotlin_helper() {
  mkdir -p "${UNIFFI_HELPER_DIR}/src"
  cat > "${UNIFFI_HELPER_DIR}/Cargo.toml" <<'EOF'
[package]
name = "openburnbar-uniffi-bindgen-kotlin-helper"
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
use uniffi_bindgen::bindings::{generate_bindings, KotlinBindingGenerator};

fn main() -> anyhow::Result<()> {
    let library_path = Utf8PathBuf::from(
        std::env::var("UNIFFI_LIBRARY_PATH").context("UNIFFI_LIBRARY_PATH is required")?,
    );
    let out_dir = Utf8PathBuf::from(
        std::env::var("UNIFFI_OUT_DIR").context("UNIFFI_OUT_DIR is required")?,
    );
    generate_bindings(
        library_path,
        None,
        KotlinBindingGenerator,
        None,
        Some(out_dir),
        false,
    )?;
    Ok(())
}
EOF
}

# --- Build per-ABI staticlibs (we want cdylib for Android) ---------------------
mkdir -p "${VENDOR_DIR}" "${BUILD_DIR}" "${ARCHS_DIR}"

CARGO_NDK_ARGS=()
for abi in "${ABIS[@]}"; do
  ensure_rust_target "$(abi_to_rust_target "${abi}")"
  CARGO_NDK_ARGS+=(-t "${abi}")
done

log "building openburnbar-iroh for ${ABIS[*]} (${PROFILE})"
(
  cd "${CRATE_DIR}"
  ANDROID_NDK_HOME="${ANDROID_NDK_HOME}" \
  PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" ndk \
      "${CARGO_NDK_ARGS[@]}" \
      -o "${ARCHS_DIR}" \
      build ${PROFILE_FLAG} --lib
)

# cargo-ndk emits files as libopenburnbar_iroh.so under jniLibs/<abi>/.
for abi in "${ABIS[@]}"; do
  expected="${ARCHS_DIR}/${abi}/libopenburnbar_iroh.so"
  [[ -f "${expected}" ]] || abort "expected output missing: ${expected}"
done

# --- Generate Kotlin bindings from one ABI's .so -------------------------------
ensure_uniffi_bindgen_kotlin_helper
HOST_SO="${ARCHS_DIR}/arm64-v8a/libopenburnbar_iroh.so"
[[ -f "${HOST_SO}" ]] || HOST_SO="${ARCHS_DIR}/${ABIS[0]}/libopenburnbar_iroh.so"

rm -rf "${GENERATED_KT_DIR}"
mkdir -p "${GENERATED_KT_DIR}"
log "generating kotlin bindings via pinned UniFFI helper"
(
  cd "${CRATE_DIR}"
  UNIFFI_LIBRARY_PATH="${HOST_SO}" \
  UNIFFI_OUT_DIR="${BUILD_DIR}/kotlin-out" \
  PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" run --manifest-path "${UNIFFI_HELPER_DIR}/Cargo.toml" --release --quiet
)

# Move uniffi/openburnbar_iroh/* into the Kotlin module's java sourceset.
if [[ ! -d "${BUILD_DIR}/kotlin-out/uniffi/openburnbar_iroh" ]]; then
  abort "uniffi-bindgen-kotlin did not produce uniffi/openburnbar_iroh/"
fi
cp -R "${BUILD_DIR}/kotlin-out/uniffi/openburnbar_iroh/." "${GENERATED_KT_DIR}/"

# --- Assemble the AAR ----------------------------------------------------------
AAR_STAGING="${BUILD_DIR}/staging"
rm -rf "${AAR_STAGING}"
mkdir -p "${AAR_STAGING}/jni"

for abi in "${ABIS[@]}"; do
  mkdir -p "${AAR_STAGING}/jni/${abi}"
  cp "${ARCHS_DIR}/${abi}/libopenburnbar_iroh.so" \
     "${AAR_STAGING}/jni/${abi}/libopenburnbar_iroh.so"
  # uniffi expects the companion uniffi_<crate>.so. We ship the same binary
  # under both names so the generated loader's first lookup succeeds.
  cp "${ARCHS_DIR}/${abi}/libopenburnbar_iroh.so" \
     "${AAR_STAGING}/jni/${abi}/libuniffi_openburnbar_iroh.so"
done

cat > "${AAR_STAGING}/AndroidManifest.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
          package="com.openburnbar.iroh.native_">
  <uses-sdk android:minSdkVersion="26" />
</manifest>
EOF

# Empty classes.jar — required by AGP even though the AAR only ships .so.
EMPTY_JAR_DIR="${BUILD_DIR}/empty-classes"
rm -rf "${EMPTY_JAR_DIR}"
mkdir -p "${EMPTY_JAR_DIR}"
(
  cd "${EMPTY_JAR_DIR}"
  jar cf "${AAR_STAGING}/classes.jar" -C "${EMPTY_JAR_DIR}" .
)

# proguard.txt + R.txt (empty) — required by AGP.
: > "${AAR_STAGING}/proguard.txt"
: > "${AAR_STAGING}/R.txt"

mkdir -p "${VENDOR_DIR}"
rm -f "${AAR_PATH}"
(
  cd "${AAR_STAGING}"
  zip -rq "${AAR_PATH}" .
)

log "DONE: ${AAR_PATH}"
log "kotlin bindings: ${GENERATED_KT_DIR}"
