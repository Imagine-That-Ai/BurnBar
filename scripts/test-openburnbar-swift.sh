#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Optional concurrency-safe SwiftPM build isolation. When set, Core and daemon
# use distinct package-named scratch directories below this root instead of
# sharing each checkout's `.build` cache with other local agents or CI jobs.
# Example: OPENBURNBAR_SWIFT_SCRATCH_ROOT=/tmp/openburnbar-swift ./scripts/test-openburnbar-swift.sh
swift_scratch_root="${OPENBURNBAR_SWIFT_SCRATCH_ROOT:-}"

# SwiftPM links every test target in OpenBurnBarCore into one package-test
# executable. On macOS that aggregate would otherwise contain both
# OpenBurnBarIroh.xcframework and BurnBarRemote.xcframework, which are Rust
# static archives that each export `_rust_eh_personality`. Keep the aggregate
# suite on the iroh-native graph and exercise the real BurnBarRemote archive in
# its dedicated one-archive smoke package below. Xcode app builds explicitly
# clear this seam and continue to resolve their normal production graph.
if [[ "$(uname -s)" == "Darwin" \
      && -d "${repo_root}/Vendor/OpenBurnBarIroh.xcframework" \
      && -d "${repo_root}/Vendor/BurnBarRemote.xcframework" \
      && -z "${OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK+x}" ]]; then
  export OPENBURNBAR_DISABLE_BURNBAR_REMOTE_XCFRAMEWORK=1
fi

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
  local auth_messages_service="${libsignal_dir}/swift/Sources/LibSignalClient/chat/AuthMessagesService.swift"
  local host_target

  # This compatibility rewrite is required even when the XCFramework cache
  # hits: the cached binary does not include the SwiftPM source patch, and a
  # warm cache must behave exactly like a cold build.
  if [[ -f "${auth_messages_service}" ]]; then
    perl -0pi -e 's/\bextendLifetime\(([^)]+)\)/withExtendedLifetime($1) {}/g' "${auth_messages_service}"
  fi

  case "$(uname -m)" in
    arm64) host_target="aarch64-apple-darwin" ;;
    x86_64) host_target="x86_64-apple-darwin" ;;
    *)
      echo "Unsupported macOS architecture for Signal FFI: $(uname -m)" >&2
      exit 1
      ;;
  esac

  # An existing XCFramework directory is not proof of health: several CI
  # workflows share the Signal FFI cache key, and single-target writers (the
  # CodeQL Swift lanes build x86_64-only) can populate it with an artifact the
  # host architecture cannot link. Delegate to the shared preparer, which
  # validates the target/profile metadata embedded by
  # build-signal-ffi-xcframework.sh and rebuilds on any mismatch. The rebuild
  # path reuses the production builder's reviewed cdylib/XCFramework flow:
  # macOS must not link libsignal and domain-core as two Rust static archives,
  # because both bundle Rust std and collide on symbols such as
  # rust_eh_personality.
  SIGNAL_FFI_BUILD_TARGETS="${host_target}" \
  SIGNAL_FFI_BUILD_PROFILE=debug \
  CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
  MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    bash "${repo_root}/scripts/lib/prepare-signal-ffi-xcframework.sh"
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
  local package_scratch_path="${package_path}/.build"

  if [[ -n "$swift_scratch_root" ]]; then
    package_scratch_path="${swift_scratch_root}/$(basename "$package_path")"
    mkdir -p "$package_scratch_path"
    args+=(--scratch-path "$package_scratch_path")
  fi

  if ((${#coverage_flags[@]})); then
    args+=("${coverage_flags[@]}")
  fi
  if [[ -n "$filter" ]]; then
    args+=(--filter "$filter")
  fi

  if [[ "$package_path" == "$repo_root/OpenBurnBarDaemon" ]]; then
    local build_args=(--package-path "$package_path" --build-tests)
    if [[ -n "$swift_scratch_root" ]]; then
      build_args+=(--scratch-path "$package_scratch_path")
    fi
    if ((${#coverage_flags[@]})); then
      build_args+=("${coverage_flags[@]}")
    fi

    swift build "${build_args[@]}"

    local bin_path
    local show_bin_path_args=(--package-path "$package_path" --show-bin-path)
    if [[ -n "$swift_scratch_root" ]]; then
      show_bin_path_args+=(--scratch-path "$package_scratch_path")
    fi
    bin_path="$(swift build "${show_bin_path_args[@]}")"

    local sqlcipher_framework_src="${package_scratch_path}/artifacts/sqlcipher.swift/SQLCipher/SQLCipher.xcframework/macos-arm64_x86_64/SQLCipher.framework"
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

  # Preserve native BurnBarRemote coverage even though the aggregate Core test
  # graph scopes out its static archive. Focused non-remote Core filters keep
  # their cheap behavior; the full gate and remote-focused runs execute this.
  case "${OPENBURNBAR_CORE_SWIFT_FILTER:-}" in
    ""|*BurnBarRemoteEngine*)
      if [[ "$(uname -s)" == "Darwin" \
            && -d "${repo_root}/Vendor/BurnBarRemote.xcframework" \
            && "${OPENBURNBAR_SKIP_BURNBAR_REMOTE_SWIFT_SMOKE:-}" != "1" ]]; then
        "${repo_root}/scripts/test-burnbar-remote-swift-smoke.sh"
      fi
      ;;
  esac
fi
if [[ "${OPENBURNBAR_SKIP_DAEMON_SWIFT_TESTS:-}" != "1" ]]; then
  run_swift_tests "$repo_root/OpenBurnBarDaemon" "${OPENBURNBAR_DAEMON_SWIFT_FILTER:-}"
fi
