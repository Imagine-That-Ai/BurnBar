#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
xcframework="${OPENBURNBAR_IROH_XCFRAMEWORK:-$repo_root/Vendor/OpenBurnBarIroh.xcframework}"

fail() {
  echo "ERROR: Mercury release preflight failed: $*" >&2
  echo "       Build the required artifact with scripts/build-iroh-xcframework.sh" >&2
  echo "       or link Vendor/OpenBurnBarIroh.xcframework from the trusted build checkout." >&2
  exit 1
}

[[ -d "$xcframework" ]] || fail "missing $xcframework"
[[ -f "$xcframework/Info.plist" ]] || fail "missing XCFramework Info.plist"

required_files=(
  "macos-arm64/libopenburnbar_iroh.a"
  "macos-arm64/Headers/openburnbar_irohFFI.h"
  "macos-arm64/Headers/module.modulemap"
)

for relative_path in "${required_files[@]}"; do
  [[ -s "$xcframework/$relative_path" ]] || fail "missing or empty $relative_path"
done

if ! grep -q "openburnbar_irohFFI" "$xcframework/macos-arm64/Headers/module.modulemap"; then
  fail "macOS module map does not expose openburnbar_irohFFI"
fi

echo "Mercury release preflight passed: $xcframework"
