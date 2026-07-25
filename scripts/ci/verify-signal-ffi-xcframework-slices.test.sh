#!/usr/bin/env bash
# Proves verify-signal-ffi-xcframework-slices.sh rejects every partial-artifact
# shape it exists to catch. Runs on Linux and macOS (python3 + plistlib only).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${script_dir}/verify-signal-ffi-xcframework-slices.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0
fail=0

# make_framework <dir> <plist-body-python>
make_framework() {
  local dir="$1" body="$2"
  mkdir -p "$dir"
  python3 - "$dir/Info.plist" <<PY
import plistlib, sys
info = $body
with open(sys.argv[1], "wb") as fh:
    plistlib.dump(info, fh)
PY
}

expect() {
  local desc="$1" want="$2"; shift 2
  local got=0
  "$@" >/dev/null 2>&1 || got=$?
  if [[ "$got" -eq "$want" ]]; then
    echo "ok - ${desc}"; pass=$((pass + 1))
  else
    echo "not ok - ${desc} (expected exit ${want}, got ${got})"; fail=$((fail + 1))
  fi
}

MAC_FULL='{"AvailableLibraries":[{"LibraryIdentifier":"macos-arm64_x86_64","SupportedPlatform":"macos","SupportedArchitectures":["arm64","x86_64"],"LibraryPath":"libsignal_ffi.dylib"}]}'
MAC_THIN='{"AvailableLibraries":[{"LibraryIdentifier":"macos-arm64","SupportedPlatform":"macos","SupportedArchitectures":["arm64"],"LibraryPath":"libsignal_ffi.dylib"}]}'
IOS_FULL='{"AvailableLibraries":[{"LibraryIdentifier":"ios-arm64","SupportedPlatform":"ios","SupportedArchitectures":["arm64"],"LibraryPath":"libsignal_ffi.a"},{"LibraryIdentifier":"ios-arm64_x86_64-simulator","SupportedPlatform":"ios","SupportedPlatformVariant":"simulator","SupportedArchitectures":["arm64","x86_64"],"LibraryPath":"libsignal_ffi.a"}]}'
IOS_SIM_ONLY='{"AvailableLibraries":[{"LibraryIdentifier":"ios-arm64_x86_64-simulator","SupportedPlatform":"ios","SupportedPlatformVariant":"simulator","SupportedArchitectures":["arm64","x86_64"],"LibraryPath":"libsignal_ffi.a"}]}'
EMPTY='{"AvailableLibraries":[]}'

make_framework "$work/mac_full.xcframework" "$MAC_FULL"
make_framework "$work/mac_thin.xcframework" "$MAC_THIN"
make_framework "$work/ios_full.xcframework" "$IOS_FULL"
make_framework "$work/ios_sim.xcframework"  "$IOS_SIM_ONLY"
make_framework "$work/empty.xcframework"    "$EMPTY"
mkdir -p "$work/noplist.xcframework"
mkdir -p "$work/truncated.xcframework"; printf '<?xml version="1.0"' > "$work/truncated.xcframework/Info.plist"

expect "accepts a full macOS universal artifact"        0 bash "$SCRIPT" "$work/mac_full.xcframework" 1 arm64,x86_64
expect "REJECTS an arm64-only macOS artifact"           1 bash "$SCRIPT" "$work/mac_thin.xcframework" 1 arm64,x86_64
expect "accepts iOS device + simulator"                 0 bash "$SCRIPT" "$work/ios_full.xcframework" 2 arm64,x86_64
expect "REJECTS a simulator-only iOS artifact"          1 bash "$SCRIPT" "$work/ios_sim.xcframework"  2 arm64,x86_64
expect "REJECTS an xcframework with no libraries"       1 bash "$SCRIPT" "$work/empty.xcframework"    1 arm64
expect "REJECTS a directory with no Info.plist"         1 bash "$SCRIPT" "$work/noplist.xcframework"  1 arm64
expect "REJECTS a truncated/malformed plist"            1 bash "$SCRIPT" "$work/truncated.xcframework" 1 arm64
expect "REJECTS a missing framework entirely"           1 bash "$SCRIPT" "$work/absent.xcframework"   1 arm64
expect "rejects bad usage rather than passing silently" 2 bash "$SCRIPT" "$work/mac_full.xcframework"

echo
echo "${pass}/$((pass + fail)) passed"
[[ "$fail" -eq 0 ]]
