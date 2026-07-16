#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-mobile-runner-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

destination="platform=iOS,id=00008132-001158191E9A401C"
filter="OpenBurnBarMobileTests/OpenBurnBarMobileTests/testSealedApprovalDecisionCarriesKindAndActionAtRootOfSealedPayload"

scratch="$tmp_root/scratch"
scratch="$(python3 - "$scratch" <<'PY'
import os
import sys

print(os.path.abspath(sys.argv[1]))
PY
)"
dry_output="$tmp_root/dry-run.out"
OPENBURNBAR_IOS_DESTINATION="$destination" \
OPENBURNBAR_MOBILE_DRY_RUN=1 \
OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT="$scratch" \
OPENBURNBAR_MOBILE_TEST_FILTER="$filter" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$dry_output"

grep -q "platform=iOS,id=00008132-001158191E9A401C" "$dry_output" ||
  fail "dry run did not print the resolved physical-device destination"
grep -q "SwiftPM cache root: $scratch/swiftpm-cache" "$dry_output" ||
  fail "dry run did not resolve the scratch-rooted SwiftPM cache"
grep -q "Signal FFI build root: $scratch/signal-ffi-build" "$dry_output" ||
  fail "dry run did not resolve the scratch-rooted Signal FFI build root"
grep -q "Signal FFI Cargo target root: $scratch/signal-ffi-cargo-target" "$dry_output" ||
  fail "dry run did not resolve the scratch-rooted Cargo target root"
[[ ! -e "$scratch" ]] || fail "dry run created scratch directories"

outside_output="$tmp_root/outside.out"
if OPENBURNBAR_IOS_DESTINATION="$destination" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT="$scratch" \
  OPENBURNBAR_MOBILE_SWIFTPM_CACHE_ROOT="$tmp_root/outside-cache" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$outside_output" 2>&1; then
  fail "outside SwiftPM cache path unexpectedly passed containment validation"
fi
grep -q "SwiftPM cache must remain under OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT" "$outside_output" ||
  fail "outside SwiftPM cache error did not identify the containment rule"

mkdir -p "$scratch" "$tmp_root/outside-target"
ln -s "$tmp_root/outside-target" "$scratch/escape-cache"
symlink_output="$tmp_root/symlink.out"
if OPENBURNBAR_IOS_DESTINATION="$destination" \
  OPENBURNBAR_MOBILE_DRY_RUN=1 \
  OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT="$scratch" \
  OPENBURNBAR_MOBILE_SWIFTPM_CACHE_ROOT="$scratch/escape-cache" \
  "$repo_root/scripts/test-openburnbar-mobile.sh" >"$symlink_output" 2>&1; then
  fail "symlink-escaped SwiftPM cache path unexpectedly passed validation"
fi
grep -q "SwiftPM cache resolves outside OPENBURNBAR_MOBILE_TEST_SCRATCH_ROOT" "$symlink_output" ||
  fail "symlink escape error did not identify the containment rule"

echo "test-openburnbar-mobile root boundary tests passed"
