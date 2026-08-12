#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script_under_test="$script_dir/repair-openburnbar-safari-development-profile.sh"
tmp_root="${TMPDIR:-/tmp}"
if ! work_root="$(mktemp -d "$tmp_root/openburnbar-safari-development-repair-test.XXXXXX" 2>/dev/null)"; then
  work_root="$(mktemp -d "/tmp/openburnbar-safari-development-repair-test.XXXXXX")"
fi
work_root="$(cd "$work_root" && pwd -P)"
trap 'rm -rf "$work_root"' EXIT

team_id="4Y367DF25B"
signing_identity="Apple Development: OpenBurnBar Fixture (CERT123456)"
current_mac_udid="FIXTURE-MAC-UDID"
certificate_bytes="fixture-apple-development-certificate"
certificate_sha1="$(
  printf '%s' "$certificate_bytes" \
    | /usr/bin/python3 -c 'import hashlib, sys; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest().upper())'
)"

fail_test() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$file_path"; then
    echo "Expected '$expected' in $file_path:" >&2
    sed -n '1,260p' "$file_path" >&2 || true
    fail_test "missing expected fixture evidence"
  fi
}

assert_file_not_contains() {
  local file_path="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file_path"; then
    echo "Did not expect '$unexpected' in $file_path:" >&2
    sed -n '1,260p' "$file_path" >&2 || true
    fail_test "unexpected fixture evidence"
  fi
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local stderr_path="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected status $expected, found $actual." >&2
    sed -n '1,260p' "$stderr_path" >&2 || true
    fail_test "unexpected fixture status"
  fi
}

write_plist() {
  local destination="$1"
  local json_payload="$2"
  /usr/bin/python3 - "$destination" "$json_payload" <<'PY'
import datetime as dt
import json
import plistlib
import sys
from pathlib import Path

destination, payload_json = sys.argv[1:]
payload = json.loads(payload_json)
if payload.pop("_future_expiration", False):
    payload["ExpirationDate"] = dt.datetime(2035, 1, 1, tzinfo=dt.timezone.utc)
if payload.pop("_expired", False):
    payload["ExpirationDate"] = dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc)
with Path(destination).open("wb") as file:
    plistlib.dump(payload, file)
PY
}

write_fixture() {
  local fixture_root="$1"
  mkdir -p "$fixture_root/mock-bin"
  : >"$fixture_root/commands.log"

  local app="$fixture_root/OpenBurnBar.app"
  local appex="$app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
  local parent_framework="$appex/Contents/Frameworks/Parent.framework"
  local nested_framework="$parent_framework/Versions/A/Frameworks/Nested.framework"
  mkdir -p \
    "$app/Contents" \
    "$appex/Contents" \
    "$parent_framework/Versions/A/Frameworks" \
    "$nested_framework"
  printf 'host-profile-original\n' >"$app/Contents/embedded.provisionprofile"
  printf 'safari-profile-wildcard\n' >"$appex/Contents/embedded.provisionprofile"

  write_plist \
    "$fixture_root/host-entitlements.plist" \
    '{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app","com.apple.security.get-task-allow":true}'
  write_plist \
    "$fixture_root/appex-entitlements.plist" \
    '{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension","com.apple.security.get-task-allow":true}'
  write_plist \
    "$fixture_root/nested-entitlements.plist" \
    '{}'
  write_plist \
    "$fixture_root/exact-safari.provisionprofile" \
    '{"_future_expiration":true,"TeamIdentifier":["4Y367DF25B"],"Platform":["OSX"],"ProvisionedDevices":["FIXTURE-MAC-UDID"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension","com.apple.developer.team-identifier":"4Y367DF25B","com.apple.security.get-task-allow":true}}'

  cat >"$fixture_root/mock-bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'security' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
case "${1:-}" in
  find-identity)
    printf '  1) %s "%s"\n' \
      "$OPENBURNBAR_FIXTURE_CERTIFICATE_SHA1" \
      "$OPENBURNBAR_FIXTURE_SIGNING_IDENTITY"
    printf '     1 valid identities found\n'
    ;;
  cms)
    profile=""
    while (($# > 0)); do
      if [[ "$1" == "-i" ]]; then
        profile="${2:-}"
        break
      fi
      shift
    done
    [[ -n "$profile" ]] || exit 2
    cat "$profile"
    ;;
  *)
    echo "unexpected fixture security command: $*" >&2
    exit 2
    ;;
esac
SH

  cat >"$fixture_root/mock-bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"

target="${!#}"
if [[ "$*" == *"--extract-certificates"* ]]; then
  printf '%s' "$OPENBURNBAR_FIXTURE_CERTIFICATE_BYTES" >codesign0
  exit 0
fi
if [[ "${1:-}" == "-dv" ]]; then
  printf 'Identifier=com.openburnbar.app.safari-extension\n' >&2
  printf 'TeamIdentifier=4Y367DF25B\n' >&2
  printf 'Authority=%s\n' "$OPENBURNBAR_FIXTURE_SIGNING_IDENTITY" >&2
  exit 0
fi
if [[ "$*" == *"--entitlements :-"* ]]; then
  if [[ "${OPENBURNBAR_FIXTURE_ENTITLEMENT_FAILURE_TARGET:-}" == "$target" ]]; then
    exit 31
  fi
  case "$target" in
    *.app)
      cat "$OPENBURNBAR_FIXTURE_ROOT/host-entitlements.plist"
      ;;
    *.appex)
      cat "$OPENBURNBAR_FIXTURE_ROOT/appex-entitlements.plist"
      ;;
    *)
      cat "$OPENBURNBAR_FIXTURE_ROOT/nested-entitlements.plist"
      ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "--verify" ]]; then
  exit 0
fi
if [[ "$*" == *"--force"* ]]; then
  if [[ "${OPENBURNBAR_FIXTURE_SIGN_FAILURE_TARGET:-}" == "$target" ]]; then
    exit 32
  fi
  if [[ "${OPENBURNBAR_FIXTURE_MUTATE_HOST_PROFILE:-}" == "1" && "$target" == *.app ]]; then
    printf 'host-profile-mutated\n' >"$target/Contents/embedded.provisionprofile"
  fi
  exit 0
fi
echo "unexpected fixture codesign command: $*" >&2
exit 2
SH

  cat >"$fixture_root/certificate-verifier.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'certificate-verifier' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
if [[ "${OPENBURNBAR_FIXTURE_CERTIFICATE_VERIFIER_FAIL:-}" == "1" ]]; then
  exit 33
fi
SH

  chmod +x \
    "$fixture_root/mock-bin/security" \
    "$fixture_root/mock-bin/codesign" \
    "$fixture_root/certificate-verifier.sh"
}

run_fixture() {
  local fixture_root="$1"
  shift
  write_fixture "$fixture_root"
  local app="$fixture_root/OpenBurnBar.app"
  local profile="$fixture_root/exact-safari.provisionprofile"
  local stdout_path="$fixture_root/stdout.log"
  local stderr_path="$fixture_root/stderr.log"

  set +e
  env \
    PATH="$fixture_root/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OPENBURNBAR_FIXTURE_ROOT="$fixture_root" \
    OPENBURNBAR_FIXTURE_COMMAND_LOG="$fixture_root/commands.log" \
    OPENBURNBAR_FIXTURE_SIGNING_IDENTITY="$signing_identity" \
    OPENBURNBAR_FIXTURE_CERTIFICATE_BYTES="$certificate_bytes" \
    OPENBURNBAR_FIXTURE_CERTIFICATE_SHA1="$certificate_sha1" \
    OPENBURNBAR_CODESIGN_BIN="$fixture_root/mock-bin/codesign" \
    OPENBURNBAR_SECURITY_BIN="$fixture_root/mock-bin/security" \
    OPENBURNBAR_PYTHON_BIN="/usr/bin/python3" \
    OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER="$fixture_root/certificate-verifier.sh" \
    "$@" \
    bash "$script_under_test" \
      "$app" \
      "$profile" \
      "$team_id" \
      "$signing_identity" \
      "$certificate_sha1" \
      "$current_mac_udid" \
      >"$stdout_path" \
      2>"$stderr_path"
  fixture_status=$?
  set -e
}

assert_no_mutation() {
  local fixture_root="$1"
  assert_file_not_contains "$fixture_root/commands.log" "<--force>"
  if [[ "$(cat "$fixture_root/OpenBurnBar.app/Contents/embedded.provisionprofile")" != "host-profile-original" ]]; then
    fail_test "host profile changed during rejected preflight"
  fi
  if [[ "$(cat "$fixture_root/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile")" != "safari-profile-wildcard" ]]; then
    fail_test "Safari profile changed during rejected preflight"
  fi
}

test_success_preserves_host_and_signs_in_containment_order() {
  local fixture_root="$work_root/success"
  run_fixture "$fixture_root"
  assert_status 0 "$fixture_status" "$fixture_root/stderr.log"
  assert_file_contains "$fixture_root/stdout.log" "PASS:"

  cmp -s \
    "$fixture_root/exact-safari.provisionprofile" \
    "$fixture_root/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile" ||
    fail_test "exact Safari profile was not installed byte-for-byte"
  if [[ "$(cat "$fixture_root/OpenBurnBar.app/Contents/embedded.provisionprofile")" != "host-profile-original" ]]; then
    fail_test "host profile did not remain byte-for-byte unchanged"
  fi

  local log="$fixture_root/commands.log"
  assert_file_contains "$log" \
    "certificate-verifier <$fixture_root/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex> <$fixture_root/exact-safari.provisionprofile>"
  local deepest parent appex host
  deepest="$(grep -n '^codesign .*--force.*Nested.framework>$' "$log" | cut -d: -f1)"
  parent="$(grep -n '^codesign .*--force.*Parent.framework>$' "$log" | cut -d: -f1)"
  appex="$(grep -n '^codesign .*--force.*OpenBurnBarSafariExtension.appex>$' "$log" | cut -d: -f1)"
  host="$(grep -n '^codesign .*--force.*OpenBurnBar.app>$' "$log" | cut -d: -f1)"
  if [[ -z "$deepest" || -z "$parent" || -z "$appex" || -z "$host" ||
    "$deepest" -ge "$parent" || "$parent" -ge "$appex" || "$appex" -ge "$host" ]]
  then
    fail_test "nested code, appex, and host were not signed deepest-first"
  fi

  local sign_line
  while IFS= read -r sign_line; do
    [[ "$sign_line" == *"<--sign> <$signing_identity>"* ]] ||
      fail_test "signing command did not use the exact Apple Development identity"
    [[ "$sign_line" == *"<--timestamp=none>"* ]] ||
      fail_test "signing command did not disable timestamping"
    [[ "$sign_line" == *"<--options> <runtime,library>"* ]] ||
      fail_test "signing command omitted hardened runtime or library validation"
    [[ "$sign_line" == *"<--preserve-metadata=identifier,requirements>"* ]] ||
      fail_test "signing command did not preserve designated requirements"
  done < <(grep '^codesign .*--force' "$log")
  assert_file_contains "$log" \
    "<--entitlements> </"
}

test_rejects_invalid_profiles_before_mutation() {
  local cases=(
    wrong-team
    wrong-app-id
    wrong-platform
    wrong-device
    expired
    wrong-get-task-allow
    distribution
  )
  local case_name fixture_root profile
  for case_name in "${cases[@]}"; do
    fixture_root="$work_root/$case_name"
    write_fixture "$fixture_root"
    profile="$fixture_root/exact-safari.provisionprofile"
    case "$case_name" in
      wrong-team)
        write_plist "$profile" \
          '{"_future_expiration":true,"TeamIdentifier":["AAAAAAAAAA"],"Platform":["OSX"],"ProvisionedDevices":["FIXTURE-MAC-UDID"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension"}}'
        ;;
      wrong-app-id)
        write_plist "$profile" \
          '{"_future_expiration":true,"TeamIdentifier":["4Y367DF25B"],"Platform":["OSX"],"ProvisionedDevices":["FIXTURE-MAC-UDID"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.*"}}'
        ;;
      wrong-platform)
        write_plist "$profile" \
          '{"_future_expiration":true,"TeamIdentifier":["4Y367DF25B"],"Platform":["iOS"],"ProvisionedDevices":["FIXTURE-MAC-UDID"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension"}}'
        ;;
      wrong-device)
        write_plist "$profile" \
          '{"_future_expiration":true,"TeamIdentifier":["4Y367DF25B"],"Platform":["OSX"],"ProvisionedDevices":["OTHER-MAC"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension"}}'
        ;;
      expired)
        write_plist "$profile" \
          '{"_expired":true,"TeamIdentifier":["4Y367DF25B"],"Platform":["OSX"],"ProvisionedDevices":["FIXTURE-MAC-UDID"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension"}}'
        ;;
      wrong-get-task-allow)
        write_plist "$profile" \
          '{"_future_expiration":true,"TeamIdentifier":["4Y367DF25B"],"Platform":["OSX"],"ProvisionedDevices":["FIXTURE-MAC-UDID"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension","com.apple.security.get-task-allow":false}}'
        ;;
      distribution)
        write_plist "$profile" \
          '{"_future_expiration":true,"TeamIdentifier":["4Y367DF25B"],"Platform":["OSX"],"ProvisionsAllDevices":true,"ProvisionedDevices":["FIXTURE-MAC-UDID"],"Entitlements":{"com.apple.application-identifier":"4Y367DF25B.com.openburnbar.app.safari-extension"}}'
        ;;
    esac
    set +e
    env \
      PATH="$fixture_root/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      OPENBURNBAR_FIXTURE_ROOT="$fixture_root" \
      OPENBURNBAR_FIXTURE_COMMAND_LOG="$fixture_root/commands.log" \
      OPENBURNBAR_FIXTURE_SIGNING_IDENTITY="$signing_identity" \
      OPENBURNBAR_FIXTURE_CERTIFICATE_BYTES="$certificate_bytes" \
      OPENBURNBAR_FIXTURE_CERTIFICATE_SHA1="$certificate_sha1" \
      OPENBURNBAR_CODESIGN_BIN="$fixture_root/mock-bin/codesign" \
      OPENBURNBAR_SECURITY_BIN="$fixture_root/mock-bin/security" \
      OPENBURNBAR_PYTHON_BIN="/usr/bin/python3" \
      OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER="$fixture_root/certificate-verifier.sh" \
      bash "$script_under_test" \
        "$fixture_root/OpenBurnBar.app" \
        "$profile" \
        "$team_id" \
        "$signing_identity" \
        "$certificate_sha1" \
        "$current_mac_udid" \
        >"$fixture_root/stdout.log" \
        2>"$fixture_root/stderr.log"
    fixture_status=$?
    set -e
    [[ "$fixture_status" != "0" ]] ||
      fail_test "$case_name profile unexpectedly succeeded"
    assert_no_mutation "$fixture_root"
  done
}

test_rejects_certificate_and_entitlement_failures_before_mutation() {
  local fixture_root="$work_root/certificate-failure"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_CERTIFICATE_VERIFIER_FAIL=1
  [[ "$fixture_status" != "0" ]] ||
    fail_test "certificate allowlist failure unexpectedly succeeded"
  assert_no_mutation "$fixture_root"

  fixture_root="$work_root/entitlement-failure"
  local appex="$fixture_root/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_ENTITLEMENT_FAILURE_TARGET="$appex"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "entitlement extraction failure unexpectedly succeeded"
  assert_no_mutation "$fixture_root"
}

test_rejects_symlinks_and_relative_profile_before_mutation() {
  local fixture_root="$work_root/symlink-profile"
  write_fixture "$fixture_root"
  ln -s "$fixture_root/exact-safari.provisionprofile" "$fixture_root/profile-link.provisionprofile"
  set +e
  env \
    PATH="$fixture_root/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OPENBURNBAR_FIXTURE_ROOT="$fixture_root" \
    OPENBURNBAR_FIXTURE_COMMAND_LOG="$fixture_root/commands.log" \
    OPENBURNBAR_FIXTURE_SIGNING_IDENTITY="$signing_identity" \
    OPENBURNBAR_FIXTURE_CERTIFICATE_BYTES="$certificate_bytes" \
    OPENBURNBAR_FIXTURE_CERTIFICATE_SHA1="$certificate_sha1" \
    OPENBURNBAR_CODESIGN_BIN="$fixture_root/mock-bin/codesign" \
    OPENBURNBAR_SECURITY_BIN="$fixture_root/mock-bin/security" \
    OPENBURNBAR_PYTHON_BIN="/usr/bin/python3" \
    OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER="$fixture_root/certificate-verifier.sh" \
    bash "$script_under_test" \
      "$fixture_root/OpenBurnBar.app" \
      "$fixture_root/profile-link.provisionprofile" \
      "$team_id" \
      "$signing_identity" \
      "$certificate_sha1" \
      "$current_mac_udid" \
      >"$fixture_root/stdout.log" \
      2>"$fixture_root/stderr.log"
  fixture_status=$?
  set -e
  [[ "$fixture_status" != "0" ]] ||
    fail_test "symlinked profile unexpectedly succeeded"
  assert_no_mutation "$fixture_root"

  fixture_root="$work_root/symlink-host-profile"
  write_fixture "$fixture_root"
  mv \
    "$fixture_root/OpenBurnBar.app/Contents/embedded.provisionprofile" \
    "$fixture_root/host-real.provisionprofile"
  ln -s \
    "$fixture_root/host-real.provisionprofile" \
    "$fixture_root/OpenBurnBar.app/Contents/embedded.provisionprofile"
  run_fixture "$fixture_root"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "symlinked host profile unexpectedly succeeded"
  assert_file_not_contains "$fixture_root/commands.log" "<--force>"
}

test_sign_failure_and_host_mutation_never_claim_success() {
  local fixture_root="$work_root/sign-failure"
  local appex="$fixture_root/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_SIGN_FAILURE_TARGET="$appex"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "appex signing failure unexpectedly succeeded"
  assert_file_not_contains "$fixture_root/stdout.log" "PASS:"

  fixture_root="$work_root/host-profile-mutation"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_MUTATE_HOST_PROFILE=1
  [[ "$fixture_status" != "0" ]] ||
    fail_test "host profile mutation unexpectedly succeeded"
  assert_file_contains \
    "$fixture_root/stderr.log" \
    "Embedded host development profile changed"
  assert_file_not_contains "$fixture_root/stdout.log" "PASS:"
}

test_success_preserves_host_and_signs_in_containment_order
test_rejects_invalid_profiles_before_mutation
test_rejects_certificate_and_entitlement_failures_before_mutation
test_rejects_symlinks_and_relative_profile_before_mutation
test_sign_failure_and_host_mutation_never_claim_success

echo "PASS: exact Safari development profile repair fixtures"
