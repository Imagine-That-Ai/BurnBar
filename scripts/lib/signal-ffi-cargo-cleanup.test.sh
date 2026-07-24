#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/lib/signal-ffi-cargo-cleanup.sh"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/signal-ffi-cargo-cleanup-test.XXXXXX")"
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
    fail "${label} did not report expected error: $(sed -n '1,4p' "$output")"
}

mkdir -p "$tmp_root/cargo/aarch64-apple-ios/release" \
  "$tmp_root/cargo/x86_64-apple-ios/release" \
  "$tmp_root/cargo/debug"
touch "$tmp_root/cargo/aarch64-apple-ios/release/sentinel" \
  "$tmp_root/cargo/x86_64-apple-ios/release/sentinel" \
  "$tmp_root/cargo/debug/shared-sentinel"

signal_ffi_prune_cargo_target_dir "$tmp_root/cargo" aarch64-apple-ios
[[ ! -e "$tmp_root/cargo/aarch64-apple-ios" ]] || fail "target directory survived pruning"
[[ -e "$tmp_root/cargo/x86_64-apple-ios/release/sentinel" ]] || fail "sibling target was removed"
[[ -e "$tmp_root/cargo/debug/shared-sentinel" ]] || fail "shared host output was removed"

signal_ffi_prune_cargo_target_dir "$tmp_root/cargo" debug
[[ ! -e "$tmp_root/cargo/debug" ]] || fail "shared host output was not pruned explicitly"

outside_root="$tmp_root/outside"
mkdir -p "$outside_root"
ln -s "$outside_root" "$tmp_root/cargo/symlink-target"
assert_rejected symlink-target "Refusing to prune symlinked" \
  signal_ffi_prune_cargo_target_dir "$tmp_root/cargo" symlink-target
[[ -L "$tmp_root/cargo/symlink-target" ]] || fail "symlink target was modified"

assert_rejected traversal-target "Refusing to prune unsafe" \
  signal_ffi_prune_cargo_target_dir "$tmp_root/cargo" ../outside

real_root="$tmp_root/real-cargo"
mkdir -p "$real_root/aarch64-apple-ios/release"
touch "$real_root/aarch64-apple-ios/release/sentinel"
ln -s "$real_root" "$tmp_root/cargo-root-link"
signal_ffi_prune_cargo_target_dir "$tmp_root/cargo-root-link" aarch64-apple-ios
[[ ! -e "$real_root/aarch64-apple-ios" ]] || fail "target under a symlinked root survived pruning"
[[ -L "$tmp_root/cargo-root-link" ]] || fail "symlinked root was replaced"

echo "signal-ffi Cargo cleanup boundary tests passed"
