#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/signal-ffi-prepare-test.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

default_targets="aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios"
metadata_name=".openburnbar-signal-ffi-build.env"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_fake_tool() {
  local path="$1"
  cat > "$path" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$path"
}

make_fixture_repo() {
  local name="$1"
  local fixture="$tmp_root/$name"
  mkdir -p "$fixture/scripts/lib" "$fixture/scripts" "$fixture/Vendor/libsignal" "$fixture/bin"
  cp "$repo_root/scripts/lib/prepare-signal-ffi-xcframework.sh" "$fixture/scripts/lib/prepare-signal-ffi-xcframework.sh"
  chmod +x "$fixture/scripts/lib/prepare-signal-ffi-xcframework.sh"
  write_fake_tool "$fixture/bin/protoc"
  write_fake_tool "$fixture/bin/cargo"
  cat > "$fixture/scripts/build-signal-ffi-xcframework.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
metadata_name=".openburnbar-signal-ffi-build.env"
targets="${SIGNAL_FFI_BUILD_TARGETS:-aarch64-apple-darwin x86_64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios}"
printf '%s\n' "${SIGNAL_FFI_BUILD_PROFILE:-<unset>}" >> "$repo_root/build-invocations.log"
printf 'build_root=%s\n' "${SIGNAL_FFI_BUILD_ROOT:-<unset>}" >> "$repo_root/build-invocations.log"
printf 'cargo_target_root=%s\n' "${SIGNAL_FFI_CARGO_TARGET_ROOT:-<unset>}" >> "$repo_root/build-invocations.log"
if [[ -n "${SIGNAL_FFI_BUILD_ROOT:-}" ]]; then
  mkdir -p "$SIGNAL_FFI_BUILD_ROOT"
  printf 'staging-root-ok\n' > "$SIGNAL_FFI_BUILD_ROOT/staging.txt"
fi
if [[ -n "${SIGNAL_FFI_CARGO_TARGET_ROOT:-}" ]]; then
  mkdir -p "$SIGNAL_FFI_CARGO_TARGET_ROOT"
  printf 'cargo-root-ok\n' > "$SIGNAL_FFI_CARGO_TARGET_ROOT/cargo.txt"
fi
for artifact in OpenBurnBarSignalFfiIOS.xcframework OpenBurnBarSignalFfiMac.xcframework; do
  mkdir -p "$repo_root/Vendor/$artifact"
  {
    printf 'profile=%s\n' "${SIGNAL_FFI_BUILD_PROFILE:-<unset>}"
    printf 'targets=%s\n' "$targets"
  } > "$repo_root/Vendor/$artifact/$metadata_name"
done
SH
  chmod +x "$fixture/scripts/build-signal-ffi-xcframework.sh"
  printf '%s\n' "$fixture"
}

write_artifact() {
  local fixture="$1"
  local artifact="$2"
  local profile="${3:-}"
  local targets="${4:-$default_targets}"
  mkdir -p "$fixture/Vendor/$artifact"
  if [[ -n "$profile" ]]; then
    {
      printf 'profile=%s\n' "$profile"
      printf 'targets=%s\n' "$targets"
    } > "$fixture/Vendor/$artifact/$metadata_name"
  fi
}

run_prepare() {
  local fixture="$1"
  shift
  (
    cd "$fixture"
    PATH="$fixture/bin:$PATH" "$@" bash scripts/lib/prepare-signal-ffi-xcframework.sh
  )
}

assert_invocation_profile() {
  local fixture="$1"
  local expected="$2"
  [[ -f "$fixture/build-invocations.log" ]] || fail "expected build invocation for $fixture"
  grep -qx "$expected" "$fixture/build-invocations.log" ||
    fail "expected build profile $expected, got $(cat "$fixture/build-invocations.log")"
}

assert_no_invocation() {
  local fixture="$1"
  [[ ! -f "$fixture/build-invocations.log" ]] ||
    fail "expected no build invocation, got $(cat "$fixture/build-invocations.log")"
}

assert_invocation_root() {
  local fixture="$1"
  local key="$2"
  local expected="$3"
  grep -qx "${key}=${expected}" "$fixture/build-invocations.log" ||
    fail "expected ${key}=${expected}, got $(cat "$fixture/build-invocations.log")"
}

fixture="$(make_fixture_repo release-rebuilds-debug)"
write_artifact "$fixture" OpenBurnBarSignalFfiIOS.xcframework debug
write_artifact "$fixture" OpenBurnBarSignalFfiMac.xcframework debug
run_prepare "$fixture" env CONFIG=Release
assert_invocation_profile "$fixture" release

fixture="$(make_fixture_repo release-reuses-release)"
write_artifact "$fixture" OpenBurnBarSignalFfiIOS.xcframework release
write_artifact "$fixture" OpenBurnBarSignalFfiMac.xcframework release
run_prepare "$fixture" env CONFIG=Release
assert_no_invocation "$fixture"

fixture="$(make_fixture_repo missing-metadata-rebuilds)"
write_artifact "$fixture" OpenBurnBarSignalFfiIOS.xcframework
write_artifact "$fixture" OpenBurnBarSignalFfiMac.xcframework
run_prepare "$fixture" env CONFIG=Release
assert_invocation_profile "$fixture" release

fixture="$(make_fixture_repo nonrelease-defaults-debug)"
run_prepare "$fixture" env
assert_invocation_profile "$fixture" debug

fixture="$(make_fixture_repo invalid-profile)"
invalid_profile_output="$tmp_root/invalid-profile.out"
if run_prepare "$fixture" env SIGNAL_FFI_BUILD_PROFILE=fast >"$invalid_profile_output" 2>&1; then
  fail "invalid SIGNAL_FFI_BUILD_PROFILE unexpectedly succeeded"
fi
grep -q "Invalid SIGNAL_FFI_BUILD_PROFILE=fast" "$invalid_profile_output" ||
  fail "invalid profile error message missing"
assert_no_invocation "$fixture"

fixture="$(make_fixture_repo isolated-roots)"
isolated_root="$fixture/.tmp/mobile-scratch"
ffi_build_root="$isolated_root/signal-ffi-build"
ffi_target_root="$isolated_root/signal-ffi-target"
ffi_build_root="$(python3 - "$ffi_build_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
ffi_target_root="$(python3 - "$ffi_target_root" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"
run_prepare "$fixture" env \
  SIGNAL_FFI_BUILD_ROOT="$ffi_build_root" \
  SIGNAL_FFI_CARGO_TARGET_ROOT="$ffi_target_root"
assert_invocation_profile "$fixture" debug
assert_invocation_root "$fixture" build_root "$ffi_build_root"
assert_invocation_root "$fixture" cargo_target_root "$ffi_target_root"
[[ -f "$ffi_build_root/staging.txt" ]] || fail "isolated Signal FFI build root was not used"
[[ -f "$ffi_target_root/cargo.txt" ]] || fail "isolated Signal FFI Cargo target root was not used"

fixture="$(make_fixture_repo relative-root-rejected)"
relative_root_output="$tmp_root/relative-root.out"
if run_prepare "$fixture" env SIGNAL_FFI_BUILD_ROOT=relative/signal-ffi >"$relative_root_output" 2>&1; then
  fail "relative SIGNAL_FFI_BUILD_ROOT unexpectedly succeeded"
fi
grep -q "SIGNAL_FFI_BUILD_ROOT must be an absolute path" "$relative_root_output" ||
  fail "relative Signal FFI root error message missing"
assert_no_invocation "$fixture"

echo "prepare-signal-ffi-xcframework boundary tests passed"
