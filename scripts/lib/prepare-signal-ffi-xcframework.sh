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
xcframework="$repo_root/Vendor/OpenBurnBarSignalFfi.xcframework"
build_script="$repo_root/scripts/build-signal-ffi-xcframework.sh"

if [[ -d "$xcframework" ]]; then
  echo ">>> Using existing OpenBurnBarSignalFfi.xcframework."
  exit 0
fi

if [[ -f "$repo_root/.gitmodules" ]] && command -v git >/dev/null 2>&1; then
  git -C "$repo_root" submodule update --init --recursive Vendor/libsignal
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

echo ">>> Building OpenBurnBarSignalFfi.xcframework for Xcode tests."
SIGNAL_FFI_BUILD_PROFILE="${SIGNAL_FFI_BUILD_PROFILE:-debug}" \
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}" \
  bash "$build_script"
