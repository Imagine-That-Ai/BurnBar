#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verify_script="$repo_root/scripts/ci/verify-iroh-release-artifact.sh"
fixture_root="$(mktemp -d /tmp/openburnbar-iroh-preflight.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

artifact="$fixture_root/Vendor/OpenBurnBarIroh.xcframework"

if OPENBURNBAR_IROH_REPO_ROOT="$fixture_root" "$verify_script" >"$fixture_root/missing.log" 2>&1; then
  echo "expected missing artifact to fail" >&2
  exit 1
fi
grep -q "missing $artifact" "$fixture_root/missing.log"

mkdir -p "$artifact/macos-arm64/Headers"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' >"$artifact/Info.plist"
if [[ "$(uname -s)" == "Darwin" ]]; then
  printf '%s\n' 'int openburnbar_iroh_fixture(void) { return 7; }' \
    >"$fixture_root/linkable.c"
  xcrun clang -c "$fixture_root/linkable.c" -o "$fixture_root/linkable.o"
  ZERO_AR_DATE=1 xcrun libtool \
    -static \
    -o "$artifact/macos-arm64/libopenburnbar_iroh.a" \
    "$fixture_root/linkable.o"
else
  printf '%s\n' 'static archive fixture' >"$artifact/macos-arm64/libopenburnbar_iroh.a"
fi
printf '%s\n' 'void openburnbar_iroh_fixture(void);' >"$artifact/macos-arm64/Headers/openburnbar_irohFFI.h"
printf '%s\n' 'module openburnbar_irohFFI { header "openburnbar_irohFFI.h" export * }' \
  >"$artifact/macos-arm64/Headers/module.modulemap"

if OPENBURNBAR_IROH_REPO_ROOT="$fixture_root" "$verify_script" >"$fixture_root/no-marker.log" 2>&1; then
  echo "expected artifact without a build-profile marker to fail" >&2
  exit 1
fi
grep -q "missing build-profile marker" "$fixture_root/no-marker.log"

printf '%s\n' 'debug' >"$artifact/openburnbar-iroh-build-profile"
if OPENBURNBAR_IROH_REPO_ROOT="$fixture_root" "$verify_script" >"$fixture_root/debug.log" 2>&1; then
  echo "expected debug-profile artifact to fail" >&2
  exit 1
fi
grep -q "cargo profile 'debug'" "$fixture_root/debug.log"

printf '%s\n' 'release' >"$artifact/openburnbar-iroh-build-profile"
if [[ "$(uname -s)" == "Darwin" ]]; then
  printf '%s\n' 'typedef int openburnbar_symbol_empty_fixture;' \
    >"$fixture_root/symbol-empty.c"
  xcrun clang -c "$fixture_root/symbol-empty.c" -o "$fixture_root/symbol-empty.o"
  ZERO_AR_DATE=1 xcrun libtool \
    -static \
    -o "$artifact/macos-arm64/libopenburnbar_iroh.a" \
    "$fixture_root/linkable.o" \
    "$fixture_root/symbol-empty.o" \
    >"$fixture_root/symbol-empty-build.log" 2>&1
  if OPENBURNBAR_IROH_REPO_ROOT="$fixture_root" "$verify_script" \
    >"$fixture_root/symbol-empty.log" 2>&1; then
    echo "expected a symbol-empty archive member to fail" >&2
    exit 1
  fi
  grep -q "symbol-empty members" "$fixture_root/symbol-empty.log"
  ZERO_AR_DATE=1 xcrun libtool \
    -static \
    -o "$artifact/macos-arm64/libopenburnbar_iroh.a" \
    "$fixture_root/linkable.o"
fi
OPENBURNBAR_IROH_REPO_ROOT="$fixture_root" "$verify_script" >"$fixture_root/present.log"
grep -q "Mercury release preflight passed" "$fixture_root/present.log"

printf '%s\n' "verify-iroh-release-artifact tests passed"
