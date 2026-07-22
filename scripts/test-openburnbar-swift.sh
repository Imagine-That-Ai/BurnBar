#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# When the focused domain-core consumer job requires the native Rust domain-core
# artifact but does NOT need libsignal, skip building libsignal-ffi entirely and
# gate the local LibSignalClient Swift package out of the package graph. This
# prevents two Rust staticlibs (domain-core + libsignal) from colliding on
# `_rust_eh_personality` at link time. Full-app CI gates still exercise libsignal.
if [[ "${OPENBURNBAR_REQUIRE_DOMAIN_CORE_NATIVE:-}" == "1" ]]; then
  export OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE=1
fi

prepare_libsignal_ffi() {
  local libsignal_dir="${repo_root}/Vendor/libsignal"
  local macos_xcframework="${repo_root}/Vendor/OpenBurnBarSignalFfiMac.xcframework"
  local legacy_xcframework="${repo_root}/Vendor/OpenBurnBarSignalFfi.xcframework"
  local libsignal_build_script="${libsignal_dir}/swift/build_ffi.sh"
  local auth_messages_service="${libsignal_dir}/swift/Sources/LibSignalClient/chat/AuthMessagesService.swift"
  local host_target

  if [[ -d "${macos_xcframework}" || -d "${legacy_xcframework}" ]]; then
    echo "Using prebuilt Signal FFI XCFramework."
    return
  fi

  if [[ ! -x "${libsignal_build_script}" ]]; then
    if [[ -f "${repo_root}/.gitmodules" ]] && command -v git >/dev/null 2>&1; then
      bash "${repo_root}/scripts/ci/update-submodules-with-retry.sh" Vendor/libsignal
    fi
  fi

  if [[ ! -x "${libsignal_build_script}" ]]; then
    echo "Missing ${libsignal_build_script}; initialize Vendor/libsignal before running Swift tests." >&2
    exit 1
  fi

  if [[ -f "${auth_messages_service}" ]]; then
    perl -0pi -e 's/\bextendLifetime\(([^)]+)\)/withExtendedLifetime($1) {}/g' "${auth_messages_service}"
  fi

  if ! command -v protoc >/dev/null 2>&1; then
    echo "Missing protoc; install protobuf before running Swift libsignal tests." >&2
    exit 1
  fi

  case "$(uname -m)" in
    arm64) host_target="aarch64-apple-darwin" ;;
    x86_64) host_target="x86_64-apple-darwin" ;;
    *)
      echo "Unsupported macOS architecture for Signal FFI: $(uname -m)" >&2
      exit 1
      ;;
  esac

  # macOS must not link libsignal and domain-core as two Rust static archives:
  # both bundle Rust std and collide on symbols such as rust_eh_personality.
  # Reuse the production builder's reviewed cdylib/XCFramework path instead.
  echo "Building host dynamic Signal FFI XCFramework for SwiftPM tests."
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
  MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
  SIGNAL_FFI_BUILD_TARGETS="${host_target}" \
  SIGNAL_FFI_BUILD_PROFILE=debug \
    bash "${repo_root}/scripts/build-signal-ffi-xcframework.sh"
}

coverage_flags=()
if [[ "${OPENBURNBAR_ENABLE_COVERAGE:-}" == "YES" ]]; then
  coverage_flags+=(--enable-code-coverage)
fi

if [[ "${OPENBURNBAR_DISABLE_LIBSIGNAL_SWIFT_PACKAGE:-}" != "1" ]]; then
  prepare_libsignal_ffi
fi

run_swift_tests() {
  local package_path="$1"
  local filter="${2:-}"
  local args=(--package-path "$package_path")

  if ((${#coverage_flags[@]})); then
    args+=("${coverage_flags[@]}")
  fi
  if [[ -n "$filter" ]]; then
    args+=(--filter "$filter")
  fi

  if [[ "$package_path" == "$repo_root/OpenBurnBarDaemon" ]]; then
    local build_args=(--package-path "$package_path" --build-tests)
    if ((${#coverage_flags[@]})); then
      build_args+=("${coverage_flags[@]}")
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
