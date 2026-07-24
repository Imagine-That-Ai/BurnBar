#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/signal-ffi-build-root-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_rejected() {
  local label="$1"
  local expected="$2"
  shift 2
  local output="$tmp_root/${label}.out"
  if "$@" >"$output" 2>&1; then
    fail "${label} unexpectedly succeeded"
  fi
  grep -q "$expected" "$output" ||
    fail "${label} did not report the expected validation error: $(sed -n '1,4p' "$output")"
}

assert_rejected relative-build-root \
  "SIGNAL_FFI_BUILD_ROOT must be an absolute path" \
  env SIGNAL_FFI_BUILD_ROOT=relative/signal-ffi \
  SIGNAL_FFI_SKIP_BUILD=1 SIGNAL_FFI_BUILD_TARGETS=aarch64-apple-ios \
  "$repo_root/scripts/build-signal-ffi-xcframework.sh"

assert_rejected relative-cargo-target-root \
  "SIGNAL_FFI_CARGO_TARGET_ROOT must be an absolute path" \
  env SIGNAL_FFI_CARGO_TARGET_ROOT=relative/target \
  SIGNAL_FFI_SKIP_BUILD=1 SIGNAL_FFI_BUILD_TARGETS=aarch64-apple-ios \
  "$repo_root/scripts/build-signal-ffi-xcframework.sh"

assert_rejected prune-without-explicit-root \
  "SIGNAL_FFI_PRUNE_CARGO_TARGETS=1 requires an explicit Cargo target root" \
  env SIGNAL_FFI_PRUNE_CARGO_TARGETS=1 \
  SIGNAL_FFI_SKIP_BUILD=1 SIGNAL_FFI_BUILD_TARGETS=aarch64-apple-ios \
  "$repo_root/scripts/build-signal-ffi-xcframework.sh"

assert_rejected prune-invalid-mode \
  "invalid SIGNAL_FFI_PRUNE_CARGO_TARGETS=maybe; expected 0 or 1" \
  env SIGNAL_FFI_PRUNE_CARGO_TARGETS=maybe \
  SIGNAL_FFI_SKIP_BUILD=1 SIGNAL_FFI_BUILD_TARGETS=aarch64-apple-ios \
  "$repo_root/scripts/build-signal-ffi-xcframework.sh"

assert_rejected mobile-prune-invalid-mode \
  "invalid SIGNAL_FFI_PRUNE_CARGO_TARGETS=maybe; expected 0 or 1" \
  env OPENBURNBAR_MOBILE_PRUNE_SIGNAL_FFI_CARGO_TARGETS=maybe \
  SIGNAL_FFI_SKIP_BUILD=1 SIGNAL_FFI_BUILD_TARGETS=aarch64-apple-ios \
  "$repo_root/scripts/build-signal-ffi-xcframework.sh"

assert_rejected prune-unknown-target \
  "pruning mode does not support unknown target" \
  env SIGNAL_FFI_PRUNE_CARGO_TARGETS=1 \
  SIGNAL_FFI_CARGO_TARGET_ROOT="$tmp_root/cargo" \
  SIGNAL_FFI_SKIP_BUILD=1 SIGNAL_FFI_BUILD_TARGETS=custom-target \
  "$repo_root/scripts/build-signal-ffi-xcframework.sh"

bash "$repo_root/scripts/lib/signal-ffi-cargo-cleanup.test.sh"

echo "build-signal-ffi-xcframework root boundary tests passed"
