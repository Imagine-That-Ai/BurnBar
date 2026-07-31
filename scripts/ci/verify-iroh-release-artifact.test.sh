#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verify_script="$repo_root/scripts/ci/verify-iroh-release-artifact.sh"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-iroh-preflight.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT

missing="$fixture_root/missing.xcframework"
if OPENBURNBAR_IROH_XCFRAMEWORK="$missing" "$verify_script" >"$fixture_root/missing.log" 2>&1; then
  echo "expected missing artifact to fail" >&2
  exit 1
fi
grep -q "missing $missing" "$fixture_root/missing.log"

artifact="$fixture_root/OpenBurnBarIroh.xcframework"
mkdir -p "$artifact/macos-arm64/Headers"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' >"$artifact/Info.plist"
printf '%s\n' 'static archive fixture' >"$artifact/macos-arm64/libopenburnbar_iroh.a"
printf '%s\n' 'void openburnbar_iroh_fixture(void);' >"$artifact/macos-arm64/Headers/openburnbar_irohFFI.h"
printf '%s\n' 'module openburnbar_irohFFI { header "openburnbar_irohFFI.h" export * }' \
  >"$artifact/macos-arm64/Headers/module.modulemap"

OPENBURNBAR_IROH_XCFRAMEWORK="$artifact" "$verify_script" >"$fixture_root/present.log"
grep -q "Mercury release preflight passed" "$fixture_root/present.log"

printf '%s\n' "verify-iroh-release-artifact tests passed"
