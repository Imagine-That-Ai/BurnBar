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

run_swift_tests() {
  local package_path="$1"
  local filter="${2:-}"
  local args=(--package-path "$package_path")

  if ((${#coverage_flags[@]})); then
    args+=("${coverage_flags[@]}")
  fi
  if ((${#libsignal_linker_flags[@]})); then
    args+=("${libsignal_linker_flags[@]}")
  fi
  if [[ -n "$filter" ]]; then
    args+=(--filter "$filter")
  fi

  if [[ "$package_path" == "$repo_root/OpenBurnBarDaemon" ]]; then
    local build_args=(--package-path "$package_path" --build-tests)
    if ((${#coverage_flags[@]})); then
      build_args+=("${coverage_flags[@]}")
    fi
    if ((${#libsignal_linker_flags[@]})); then
      build_args+=("${libsignal_linker_flags[@]}")
    fi

    swift build "${build_args[@]}"

    local bin_path
    bin_path="$(swift build --package-path "$package_path" --show-bin-path)"

    local sqlcipher_framework_src="${package_path}/.build/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos-arm64_x86_64/SQLCipher.framework"
    local sqlcipher_framework_dst="${bin_path}/PackageFrameworks/SQLCipher.framework"
    if [[ ! -d "$sqlcipher_framework_src" ]]; then
      echo "Missing SQLCipher.framework at ${sqlcipher_framework_src}; SwiftPM did not resolve the SQLCipher binary artifact." >&2
      exit 1
    fi

    mkdir -p "$(dirname "$sqlcipher_framework_dst")"
    rm -rf "$sqlcipher_framework_dst"
    cp -R "$sqlcipher_framework_src" "$sqlcipher_framework_dst"

    swift test "${args[@]}" --skip-build
    return
  fi

  swift test "${args[@]}"
}

# OPENBURNBAR_SKIP_CORE_SWIFT_TESTS=1 runs the daemon package on its own — the
# symmetric counterpart to OPENBURNBAR_SKIP_DAEMON_SWIFT_TESTS, used by the
# focused daemon PR gate so daemon correctness blocks merges without paying for
# the full Core suite on every PR.
if [[ "${OPENBURNBAR_SKIP_CORE_SWIFT_TESTS:-}" != "1" ]]; then
  run_swift_tests "$repo_root/OpenBurnBarCore" "${OPENBURNBAR_CORE_SWIFT_FILTER:-}"
fi
if [[ "${OPENBURNBAR_SKIP_DAEMON_SWIFT_TESTS:-}" != "1" ]]; then
  run_swift_tests "$repo_root/OpenBurnBarDaemon" "${OPENBURNBAR_DAEMON_SWIFT_FILTER:-}"
fi
