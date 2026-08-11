#!/usr/bin/env bash
# Build OpenBurnBarIroh.xcframework from crates/openburnbar-iroh.
#
# Usage:
#   ./scripts/build-iroh-xcframework.sh                 # release build, all targets
#   IROH_BUILD_PROFILE=debug ./scripts/build-iroh-xcframework.sh
#   IROH_BUILD_TARGETS="aarch64-apple-darwin" ./scripts/build-iroh-xcframework.sh
#   IROH_BUILD_JOBS=4 ./scripts/build-iroh-xcframework.sh
#   IROH_CARGO_HOME=/path/to/writable/cargo-home ./scripts/build-iroh-xcframework.sh
#   IROH_BUILD_TMPDIR=/tmp/openburnbar-iroh ./scripts/build-iroh-xcframework.sh
#
# Requires:
#   * rustup with the targets installed (we install on demand)
#   * Rust/Cargo; the script builds a pinned UniFFI Swift bindgen helper on demand
#   * Xcode command-line tools (xcodebuild, lipo)
#
# Output:
#   Vendor/OpenBurnBarIroh.xcframework/
#   OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/openburnbar_iroh.swift

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/apple-static-archive.sh
source "${ROOT_DIR}/scripts/lib/apple-static-archive.sh"
CRATE_DIR="${ROOT_DIR}/crates/openburnbar-iroh"
VENDOR_DIR="${ROOT_DIR}/Vendor"
XCFRAMEWORK="${VENDOR_DIR}/OpenBurnBarIroh.xcframework"
XCFRAMEWORK_STAGING="${ROOT_DIR}/build/OpenBurnBarIroh.staging.$$.xcframework"
XCFRAMEWORK_BACKUP="${ROOT_DIR}/build/OpenBurnBarIroh.xcframework.backup.$$"
SWIFT_PKG_DIR="${ROOT_DIR}/OpenBurnBarCore/Sources/OpenBurnBarIroh"
GENERATED_DIR="${SWIFT_PKG_DIR}/Generated"
GENERATED_STAGING="${ROOT_DIR}/build/OpenBurnBarIrohGenerated.staging.$$"
GENERATED_BACKUP="${ROOT_DIR}/build/OpenBurnBarIrohGenerated.backup.$$"
HEADERS_DIR="${ROOT_DIR}/build/iroh-xcframework-headers"
UNIFFI_HELPER_DIR="${ROOT_DIR}/build/uniffi-bindgen-swift-helper"
CARGO_TARGET_ROOT="${IROH_CARGO_TARGET_DIR:-${CRATE_DIR}/target}"
PROCESS_TMPDIR="${IROH_BUILD_TMPDIR:-/tmp}"
CARGO_HOME_REQUESTED="${IROH_CARGO_HOME:-${CARGO_HOME:-${HOME}/.cargo}}"

if [[ -z "${PROCESS_TMPDIR}" ]]; then
  echo "IROH_BUILD_TMPDIR must not be empty." >&2
  exit 64
fi
mkdir -p "${PROCESS_TMPDIR}"
PROCESS_TMPDIR_PROBE=""
if [[ -d "${PROCESS_TMPDIR}" && -w "${PROCESS_TMPDIR}" ]]; then
  PROCESS_TMPDIR_PROBE="$(
    mktemp "${PROCESS_TMPDIR%/}/.openburnbar-iroh-tmp-write.XXXXXX" 2>/dev/null \
      || true
  )"
fi
if [[ -z "${PROCESS_TMPDIR_PROBE}" ]]; then
  echo "Iroh build TMPDIR is not writable: ${PROCESS_TMPDIR}" >&2
  exit 73
fi
rm -f "${PROCESS_TMPDIR_PROBE}"
export TMPDIR="${PROCESS_TMPDIR%/}/"

CARGO_HOME_PROBE=""
if [[ -n "${CARGO_HOME_REQUESTED}" ]]; then
  mkdir -p "${CARGO_HOME_REQUESTED}" 2>/dev/null || true
  if [[ -d "${CARGO_HOME_REQUESTED}" && -w "${CARGO_HOME_REQUESTED}" ]]; then
    CARGO_HOME_PROBE="$(
      mktemp "${CARGO_HOME_REQUESTED%/}/.openburnbar-iroh-cargo-write.XXXXXX" \
        2>/dev/null \
        || true
    )"
  fi
fi
if [[ -z "${CARGO_HOME_PROBE}" ]]; then
  if [[ -n "${IROH_CARGO_HOME+x}" ]]; then
    echo "IROH_CARGO_HOME is not writable: ${CARGO_HOME_REQUESTED:-<empty>}" >&2
    exit 73
  fi
  CARGO_HOME_REQUESTED="${ROOT_DIR}/build/iroh-cargo-home"
  mkdir -p "${CARGO_HOME_REQUESTED}"
  CARGO_HOME_PROBE="$(
    mktemp "${CARGO_HOME_REQUESTED}/.openburnbar-iroh-cargo-write.XXXXXX"
  )"
  printf '[iroh-xcframework] inherited Cargo home is unavailable; using %s\n' \
    "${CARGO_HOME_REQUESTED}"
fi
rm -f "${CARGO_HOME_PROBE}"
export CARGO_HOME="${CARGO_HOME_REQUESTED}"

TRANSACTION_COMMITTED=0
XCFRAMEWORK_INSTALLED=0
GENERATED_INSTALLED=0

cleanup_xcframework_transaction() {
  local original_status="${1:-0}"
  local cleanup_status=0

  if ((TRANSACTION_COMMITTED == 0)); then
    if [[ -e "${XCFRAMEWORK_BACKUP}" ]]; then
      if [[ -e "${XCFRAMEWORK}" ]]; then
        rm -rf "${XCFRAMEWORK}" || cleanup_status=$?
      fi
      if [[ ! -e "${XCFRAMEWORK}" ]]; then
        mv "${XCFRAMEWORK_BACKUP}" "${XCFRAMEWORK}" || cleanup_status=$?
      fi
    elif ((XCFRAMEWORK_INSTALLED)) && [[ -e "${XCFRAMEWORK}" ]]; then
      rm -rf "${XCFRAMEWORK}" || cleanup_status=$?
    fi

    if [[ -e "${GENERATED_BACKUP}" ]]; then
      if [[ -e "${GENERATED_DIR}" ]]; then
        rm -rf "${GENERATED_DIR}" || cleanup_status=$?
      fi
      if [[ ! -e "${GENERATED_DIR}" ]]; then
        mv "${GENERATED_BACKUP}" "${GENERATED_DIR}" || cleanup_status=$?
      fi
    elif ((GENERATED_INSTALLED)) && [[ -e "${GENERATED_DIR}" ]]; then
      rm -rf "${GENERATED_DIR}" || cleanup_status=$?
    fi
  else
    if [[ -e "${XCFRAMEWORK_BACKUP}" ]]; then
      rm -rf "${XCFRAMEWORK_BACKUP}" || cleanup_status=$?
    fi
    if [[ -e "${GENERATED_BACKUP}" ]]; then
      rm -rf "${GENERATED_BACKUP}" || cleanup_status=$?
    fi
  fi

  if [[ -e "${XCFRAMEWORK_STAGING}" ]]; then
    rm -rf "${XCFRAMEWORK_STAGING}" || cleanup_status=$?
  fi
  if [[ -e "${GENERATED_STAGING}" ]]; then
    rm -rf "${GENERATED_STAGING}" || cleanup_status=$?
  fi
  if ((original_status == 0 && cleanup_status != 0)); then
    return "${cleanup_status}"
  fi
  return "${original_status}"
}

cleanup_on_exit() {
  local original_status=$?
  trap - EXIT
  cleanup_xcframework_transaction "${original_status}"
  exit $?
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "${XCFRAMEWORK_STAGING}" \
  || -e "${XCFRAMEWORK_BACKUP}" \
  || -e "${GENERATED_STAGING}" \
  || -e "${GENERATED_BACKUP}" ]]; then
  echo "Iroh build transaction paths already exist for pid $$." >&2
  exit 73
fi

PROFILE="${IROH_BUILD_PROFILE:-release}"
BUILD_JOBS="${IROH_BUILD_JOBS:-1}"
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
if [[ -n "${IROH_BUILD_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  TARGETS=(${IROH_BUILD_TARGETS})
else
  TARGETS=("${DEFAULT_TARGETS[@]}")
fi

log() { printf '[iroh-xcframework] %s\n' "$*"; }

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
  if ! "${RUSTUP_BIN}" target list --installed | grep -q "^${target}$"; then
    log "installing rust target ${target}"
    "${RUSTUP_BIN}" target add "${target}"
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
  local archive="${CARGO_TARGET_ROOT}/${target}/${PROFILE_DIR}/libopenburnbar_iroh.a"
  ensure_rust_target "${target}"
  log "cargo build ${PROFILE} ${target}"
  (
    cd "${CRATE_DIR}"
    CARGO_TARGET_DIR="${CARGO_TARGET_ROOT}" \
    CARGO_PROFILE_RELEASE_STRIP=none \
    MACOSX_DEPLOYMENT_TARGET=14.0 \
    IPHONEOS_DEPLOYMENT_TARGET=17.0 \
    IPHONE_SIMULATOR_DEPLOYMENT_TARGET=17.0 \
    PATH="${HOME}/.cargo/bin:${PATH}" \
      "${CARGO_BIN}" build ${PROFILE_FLAG} --target "${target}" --jobs "${BUILD_JOBS}"
  )
  [[ -s "${archive}" ]] || {
    echo "Cargo did not produce the expected Iroh archive: ${archive}" >&2
    exit 1
  }
}

mkdir -p "${VENDOR_DIR}" "${HEADERS_DIR}"

for target in "${TARGETS[@]}"; do
  build_target "${target}"
done

# Generate Swift bindings from one host-built dylib so the .swift output is
# identical across CI hosts. The dylib is byte-equivalent to the staticlib
# from the iroh-introspection point of view.
log "generating swift bindings via pinned UniFFI helper"
ensure_uniffi_bindgen_swift_helper
HOST_DYLIB="${CARGO_TARGET_ROOT}/${TARGETS[0]}/${PROFILE_DIR}/libopenburnbar_iroh.dylib"
if [[ ! -f "${HOST_DYLIB}" ]]; then
  HOST_DYLIB="${CARGO_TARGET_ROOT}/${TARGETS[0]}/${PROFILE_DIR}/libopenburnbar_iroh.a"
fi
mkdir -p "${GENERATED_STAGING}"
(
  cd "${CRATE_DIR}"
  CARGO_TARGET_DIR="${CARGO_TARGET_ROOT}" \
  CARGO_PROFILE_RELEASE_STRIP=none \
  UNIFFI_LIBRARY_PATH="${HOST_DYLIB}" \
  UNIFFI_OUT_DIR="${GENERATED_STAGING}" \
  UNIFFI_MODULE_NAME="openburnbar_irohFFI" \
  PATH="${HOME}/.cargo/bin:${PATH}" \
    "${CARGO_BIN}" run --manifest-path "${UNIFFI_HELPER_DIR}/Cargo.toml" \
      --release --quiet --jobs "${BUILD_JOBS}"
)
while IFS= read -r -d '' generated_file; do
  # UniFFI emits a blanket SwiftLint suppression. Keep the generated directive
  # explicit, but make its repository-required rationale deterministic so a
  # normal framework rebuild cannot dirty the reviewed source tree or fail the
  # no-new-suppressions gate.
  perl -0pi -e \
    's{// swiftlint:disable all\n}{// swiftlint:disable all -- reason: generated UniFFI binding; regenerate from Rust sources instead of hand-editing.\n}g' \
    "${generated_file}"
  if grep -Fqx '// swiftlint:disable all' "${generated_file}"; then
    echo "generated UniFFI Swift source retained an unjustified SwiftLint suppression: ${generated_file}" >&2
    exit 1
  fi
done < <(find "${GENERATED_STAGING}" -name '*.swift' -type f -print0 | sort -z)
if compgen -G "${GENERATED_STAGING}/*.modulemap" >/dev/null; then
  perl -0pi -e 's/framework module /module /g' "${GENERATED_STAGING}/"*.modulemap
fi

# Stage modulemap + headers next to each architecture's staticlib so the
# xcframework bundles them together. uniffi-bindgen-swift emits both into
# ${GENERATED_DIR}; we copy and rename for the xcframework recipe.
build_xcframework_args=()
ARCHS_DIR="${ROOT_DIR}/build/iroh-archs"
rm -rf "${ARCHS_DIR}"
mkdir -p "${ARCHS_DIR}"

stage_release_archive() {
  local source_archive="$1"
  local destination_archive="$2"
  local strip_log="${destination_archive}.strip.log"

  cp "${source_archive}" "${destination_archive}"
  if [[ "${PROFILE_DIR}" == "release" ]]; then
    # Never strip Cargo's cached output in place. A warm rebuild can otherwise
    # strip the already-stripped archive again and change the packaged bytes
    # without any source change. Remove symbol-empty members before strip so an
    # already-warm archive remains warning-free, strip only the fresh staging
    # copy, then scan once more in case the toolchain removed a final symbol.
    openburnbar_prune_symbol_empty_archive_members "${destination_archive}"
    if ! ZERO_AR_DATE=1 xcrun strip -S "${destination_archive}" \
      >"${strip_log}" 2>&1; then
      cat "${strip_log}" >&2
      return 65
    fi
    if [[ -s "${strip_log}" ]]; then
      echo "Release strip emitted diagnostics for ${destination_archive}:" >&2
      cat "${strip_log}" >&2
      return 65
    fi
    rm -f "${strip_log}"
    openburnbar_prune_symbol_empty_archive_members "${destination_archive}"
  fi
}

# Group iOS device + simulator separately because lipo cannot merge across
# platforms; we let `xcodebuild -create-xcframework` do platform separation.
package_static_for_target() {
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
  mkdir -p "${out_dir}/Headers"
  stage_release_archive \
    "${CARGO_TARGET_ROOT}/${target}/${PROFILE_DIR}/libopenburnbar_iroh.a" \
    "${out_dir}/libopenburnbar_iroh.a"
  if compgen -G "${GENERATED_STAGING}/*.h" >/dev/null; then
    cp "${GENERATED_STAGING}/"*.h "${out_dir}/Headers/"
  fi
  if compgen -G "${GENERATED_STAGING}/*.modulemap" >/dev/null; then
    cp "${GENERATED_STAGING}/"*.modulemap "${out_dir}/Headers/module.modulemap"
    perl -0pi -e 's/framework module /module /g' "${out_dir}/Headers/module.modulemap"
  fi
  build_xcframework_args+=(-library "${out_dir}/libopenburnbar_iroh.a" -headers "${out_dir}/Headers")
}

# Simulator: arm64 + x86_64 must be merged into a single fat archive before
# packaging into the xcframework slice.
if printf '%s\n' "${TARGETS[@]}" | grep -q "aarch64-apple-ios-sim" \
   && printf '%s\n' "${TARGETS[@]}" | grep -q "x86_64-apple-ios"; then
  SIM_DIR="${ARCHS_DIR}/ios-simulator"
  SIM_ARM64_DIR="${ARCHS_DIR}/ios-arm64-simulator-staged"
  SIM_X86_64_DIR="${ARCHS_DIR}/ios-x86_64-simulator-staged"
  mkdir -p "${SIM_DIR}/Headers"
  mkdir -p "${SIM_ARM64_DIR}" "${SIM_X86_64_DIR}"
  stage_release_archive \
    "${CARGO_TARGET_ROOT}/aarch64-apple-ios-sim/${PROFILE_DIR}/libopenburnbar_iroh.a" \
    "${SIM_ARM64_DIR}/libopenburnbar_iroh.a"
  stage_release_archive \
    "${CARGO_TARGET_ROOT}/x86_64-apple-ios/${PROFILE_DIR}/libopenburnbar_iroh.a" \
    "${SIM_X86_64_DIR}/libopenburnbar_iroh.a"
  lipo -create \
    "${SIM_ARM64_DIR}/libopenburnbar_iroh.a" \
    "${SIM_X86_64_DIR}/libopenburnbar_iroh.a" \
    -output "${SIM_DIR}/libopenburnbar_iroh.a"
  if compgen -G "${GENERATED_STAGING}/*.h" >/dev/null; then
    cp "${GENERATED_STAGING}/"*.h "${SIM_DIR}/Headers/"
  fi
  if compgen -G "${GENERATED_STAGING}/*.modulemap" >/dev/null; then
    cp "${GENERATED_STAGING}/"*.modulemap "${SIM_DIR}/Headers/module.modulemap"
    perl -0pi -e 's/framework module /module /g' "${SIM_DIR}/Headers/module.modulemap"
  fi
  build_xcframework_args+=(-library "${SIM_DIR}/libopenburnbar_iroh.a" -headers "${SIM_DIR}/Headers")

  # Per-arch slices still emitted for archive reproducibility.
  for t in aarch64-apple-darwin aarch64-apple-ios; do
    [[ " ${TARGETS[*]} " == *" ${t} "* ]] && package_static_for_target "${t}"
  done
else
  for target in "${TARGETS[@]}"; do
    package_static_for_target "${target}"
  done
fi

log "assembling xcframework"
xcodebuild -create-xcframework \
  "${build_xcframework_args[@]}" \
  -output "${XCFRAMEWORK_STAGING}"

# Record the cargo profile so the release preflight
# (scripts/ci/verify-iroh-release-artifact.sh) can reject debug archives.
printf '%s\n' "${PROFILE_DIR}" \
  > "${XCFRAMEWORK_STAGING}/openburnbar-iroh-build-profile"

openburnbar_verify_apple_static_archive_has_no_empty_members \
  "${XCFRAMEWORK_STAGING}/macos-arm64/libopenburnbar_iroh.a"

generated_needs_install=1
if [[ -d "${GENERATED_DIR}" ]]; then
  generated_diff_status=0
  diff -qr "${GENERATED_STAGING}" "${GENERATED_DIR}" >/dev/null \
    || generated_diff_status=$?
  case "${generated_diff_status}" in
    0) generated_needs_install=0 ;;
    1) generated_needs_install=1 ;;
    *)
      echo "Unable to compare staged and installed UniFFI bindings." >&2
      exit "${generated_diff_status}"
      ;;
  esac
fi

if [[ -e "${XCFRAMEWORK}" ]]; then
  mv "${XCFRAMEWORK}" "${XCFRAMEWORK_BACKUP}"
fi
if ((generated_needs_install)) && [[ -e "${GENERATED_DIR}" ]]; then
  mv "${GENERATED_DIR}" "${GENERATED_BACKUP}"
fi
if ! mv "${XCFRAMEWORK_STAGING}" "${XCFRAMEWORK}"; then
  echo "Unable to install the validated Iroh XCFramework." >&2
  exit 74
fi
XCFRAMEWORK_INSTALLED=1
if ((generated_needs_install)); then
  if ! mv "${GENERATED_STAGING}" "${GENERATED_DIR}"; then
    echo "Unable to install the validated UniFFI bindings." >&2
    exit 74
  fi
  GENERATED_INSTALLED=1
else
  rm -rf "${GENERATED_STAGING}"
fi
TRANSACTION_COMMITTED=1
cleanup_xcframework_transaction 0

log "DONE: ${XCFRAMEWORK}"
log "swift bindings: ${GENERATED_DIR}"
