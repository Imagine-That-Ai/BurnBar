#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

prepare_libsignal_ffi() {
  local libsignal_dir="${repo_root}/Vendor/libsignal"
  local xcframework="${repo_root}/Vendor/OpenBurnBarSignalFfi.xcframework"
  local build_script="${libsignal_dir}/swift/build_ffi.sh"
  local cargo_cmd=()

  if [[ -d "${xcframework}" ]]; then
    echo "Using prebuilt OpenBurnBarSignalFfi.xcframework."
    return
  fi

  if [[ ! -x "${build_script}" ]]; then
    if [[ -f "${repo_root}/.gitmodules" ]] && command -v git >/dev/null 2>&1; then
      git -C "${repo_root}" submodule update --init --recursive Vendor/libsignal
    fi
  fi

  if [[ ! -x "${build_script}" ]]; then
    echo "Missing ${build_script}; initialize Vendor/libsignal before running Swift tests." >&2
    exit 1
  fi

  if command -v rustup >/dev/null 2>&1; then
    cargo_cmd=(rustup run stable cargo)
  elif command -v cargo >/dev/null 2>&1; then
    cargo_cmd=(cargo)
  else
    echo "Missing cargo; install Rust before running Swift libsignal tests." >&2
    exit 1
  fi

  if ! command -v protoc >/dev/null 2>&1; then
    echo "Missing protoc; install protobuf before running Swift libsignal tests." >&2
    exit 1
  fi

  echo "Building host libsignal FFI for SwiftPM tests."
  (
    cd "${libsignal_dir}"
    CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    PATH="${HOME}/.cargo/bin:${PATH}" \
      "${cargo_cmd[@]}" rustc \
        -p libsignal-ffi \
        --features "libsignal-bridge-testing log/release_max_level_info" \
        -- --crate-type staticlib
  )
}

coverage_flags=()
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
  coverage_flags+=(--enable-code-coverage)
fi

prepare_libsignal_ffi
libsignal_linker_flags=()
if [[ ! -d "${repo_root}/Vendor/OpenBurnBarSignalFfi.xcframework" ]]; then
  libsignal_linker_flags=(-Xlinker "-L${repo_root}/Vendor/libsignal/target/debug")
fi

# `set -u` + the empty-array expansion `${coverage_flags[@]}` triggers
# "unbound variable" on bash 3.2 (macOS default). Use the empty-safe
# `${coverage_flags[@]+"${coverage_flags[@]}"}` idiom instead.
swift test --package-path "$repo_root/OpenBurnBarCore" ${coverage_flags[@]+"${coverage_flags[@]}"} ${libsignal_linker_flags[@]+"${libsignal_linker_flags[@]}"}
swift test --package-path "$repo_root/OpenBurnBarDaemon" ${coverage_flags[@]+"${coverage_flags[@]}"} ${libsignal_linker_flags[@]+"${libsignal_linker_flags[@]}"}
