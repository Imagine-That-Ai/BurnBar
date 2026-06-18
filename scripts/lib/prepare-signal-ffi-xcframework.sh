#!/usr/bin/env bash
#
# Ensure Xcode-based OpenBurnBar tests can link libsignal FFI.
#
# SwiftPM-only tests can pass an unsafe -L flag to Vendor/libsignal/target, but
# Xcode app/mobile targets resolve the Swift package as a normal dependency.
# Materializing the XCFramework lets Package.swift attach the binary target and
# keeps app/mobile test linking on the same path production builds use.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
libsignal_dir="$repo_root/Vendor/libsignal"
ios_xcframework="$repo_root/Vendor/OpenBurnBarSignalFfiIOS.xcframework"
macos_xcframework="$repo_root/Vendor/OpenBurnBarSignalFfiMac.xcframework"
legacy_xcframework="$repo_root/Vendor/OpenBurnBarSignalFfi.xcframework"
build_script="$repo_root/scripts/build-signal-ffi-xcframework.sh"

DEFAULT_SIGNAL_FFI_BUILD_TARGETS=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
if [[ -n "${SIGNAL_FFI_BUILD_TARGETS:-}" ]]; then
  # shellcheck disable=SC2206
  requested_targets=(${SIGNAL_FFI_BUILD_TARGETS})
else
  requested_targets=("${DEFAULT_SIGNAL_FFI_BUILD_TARGETS[@]}")
fi

needs_ios_xcframework=0
needs_macos_xcframework=0
for target in "${requested_targets[@]}"; do
  case "$target" in
    *-apple-ios*) needs_ios_xcframework=1 ;;
    *-apple-darwin*) needs_macos_xcframework=1 ;;
  esac
done

artifacts_satisfy_requested_targets() {
  if [[ "$needs_ios_xcframework" == "1" && ! -d "$ios_xcframework" ]]; then
    return 1
  fi
  if [[ "$needs_macos_xcframework" == "1" && ! -d "$macos_xcframework" && ! -d "$legacy_xcframework" ]]; then
    return 1
  fi
  return 0
}

if artifacts_satisfy_requested_targets; then
  echo ">>> Using existing Signal FFI XCFramework artifacts for requested targets."
  exit 0
fi

if [[ -f "$repo_root/.gitmodules" ]] && command -v git >/dev/null 2>&1; then
  bash "$repo_root/scripts/ci/update-submodules-with-retry.sh" Vendor/libsignal
fi

if [[ ! -d "$libsignal_dir" ]]; then
  echo "Missing $libsignal_dir; initialize Vendor/libsignal before running Xcode tests." >&2
  exit 1
fi

if [[ ! -x "$build_script" ]]; then
  echo "Missing executable build script: $build_script" >&2
  exit 1
fi

if ! command -v protoc >/dev/null 2>&1; then
  echo "Missing protoc; install protobuf before running Xcode libsignal tests." >&2
  exit 1
fi

if ! command -v cargo >/dev/null 2>&1 && [[ ! -x "$HOME/.cargo/bin/cargo" ]]; then
  echo "Missing cargo; install Rust before running Xcode libsignal tests." >&2
  exit 1
fi

echo ">>> Building Signal FFI XCFramework artifacts for Xcode tests."
SIGNAL_FFI_BUILD_PROFILE="${SIGNAL_FFI_BUILD_PROFILE:-debug}" \
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
  bash "$build_script"
