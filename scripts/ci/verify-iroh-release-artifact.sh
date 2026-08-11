#!/usr/bin/env bash
set -euo pipefail

# SwiftPM probes and links only Vendor/OpenBurnBarIroh.xcframework (see
# OpenBurnBarCore/Package.swift), so this preflight validates exactly that
# path. OPENBURNBAR_IROH_REPO_ROOT exists for the test harness only; it moves
# the whole root rather than the artifact path so the check can never pass
# against an artifact SwiftPM would not consume.
repo_root="${OPENBURNBAR_IROH_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
xcframework="$repo_root/Vendor/OpenBurnBarIroh.xcframework"
# shellcheck source=scripts/lib/apple-static-archive.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/apple-static-archive.sh"

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

# Reject archives built from a non-release cargo profile. The builder records
# the profile in a marker file; artifacts predating the marker must be rebuilt.
profile_marker="$xcframework/openburnbar-iroh-build-profile"
[[ -f "$profile_marker" ]] || fail "missing build-profile marker; rebuild the artifact to record its cargo profile"
profile="$(tr -d '[:space:]' < "$profile_marker")"
if [[ "$profile" != "release" ]]; then
  fail "artifact was built with cargo profile '$profile'; release builds must link a release-profile archive"
fi

if ! openburnbar_verify_apple_static_archive_has_no_empty_members \
  "$xcframework/macos-arm64/libopenburnbar_iroh.a"; then
  fail "macOS archive contains symbol-empty members that produce linker warnings"
fi

echo "Mercury release preflight passed: $xcframework"
