#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
script_under_test="$script_dir/provision-openburnbar-safari-development.sh"
tmp_root="${TMPDIR:-/tmp}"
if ! work_root="$(mktemp -d "$tmp_root/openburnbar-safari-provision-test.XXXXXX" 2>/dev/null)"; then
  work_root="$(mktemp -d "/tmp/openburnbar-safari-provision-test.XXXXXX")"
fi
work_root="$(cd "$work_root" && pwd -P)"
trap 'rm -rf "$work_root"' EXIT

candidate_commit="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
candidate_tree="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
team_id="4Y367DF25B"
signing_identity="Apple Development: OpenBurnBar Fixture (CERT123456)"
identity_sha1="1234567890ABCDEF1234567890ABCDEF12345678"
second_identity_sha1="ABCDEF1234567890ABCDEF1234567890ABCDEF12"
certificate_sha256="53E0F0DC7BFE1F043380956ECDF432B83D4E625E0DC8F732BF1A325C305DE5A5"

fail_test() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  local file_path="$1"
  local expected="$2"
  if ! grep -Fq -- "$expected" "$file_path"; then
    echo "Expected '$expected' in $file_path:" >&2
    sed -n '1,240p' "$file_path" >&2 || true
    fail_test "missing expected fixture evidence"
  fi
}

assert_file_not_contains() {
  local file_path="$1"
  local unexpected="$2"
  if grep -Fq -- "$unexpected" "$file_path"; then
    echo "Did not expect '$unexpected' in $file_path:" >&2
    sed -n '1,240p' "$file_path" >&2 || true
    fail_test "unsafe fallback appeared in command"
  fi
}

assert_status() {
  local expected="$1"
  local actual="$2"
  local stderr_path="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected status $expected, found $actual." >&2
    sed -n '1,240p' "$stderr_path" >&2 || true
    fail_test "unexpected fixture status"
  fi
}

write_fixture_commands() {
  local fixture_root="$1"
  local mock_bin="$fixture_root/mock-bin"
  mkdir -p "$mock_bin"

  command_log="$fixture_root/commands.log"
  : >"$command_log"

  cat >"$mock_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'git' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
if [[ "${1:-}" == "-C" ]]; then
  shift 2
fi
case "${1:-}" in
  cat-file)
    reference="${3:-}"
    if [[ "${OPENBURNBAR_FIXTURE_GIT_MISSING:-}" == "commit" &&
      "$reference" == "$OPENBURNBAR_FIXTURE_CANDIDATE_COMMIT^{commit}" ]]
    then
      exit 1
    fi
    if [[ "${OPENBURNBAR_FIXTURE_GIT_MISSING:-}" == "tree" &&
      "$reference" == "$OPENBURNBAR_FIXTURE_CANDIDATE_TREE^{tree}" ]]
    then
      exit 1
    fi
    exit 0
    ;;
  rev-parse)
    case "${2:-}" in
      --show-toplevel)
        printf '%s\n' "$OPENBURNBAR_FIXTURE_REPO_ROOT"
        ;;
      HEAD^{commit})
        printf '%s\n' "${OPENBURNBAR_FIXTURE_ACTUAL_COMMIT:-$OPENBURNBAR_FIXTURE_CANDIDATE_COMMIT}"
        ;;
      HEAD^{tree}|"$OPENBURNBAR_FIXTURE_CANDIDATE_COMMIT^{tree}")
        printf '%s\n' "${OPENBURNBAR_FIXTURE_ACTUAL_TREE:-$OPENBURNBAR_FIXTURE_CANDIDATE_TREE}"
        ;;
      *)
        echo "unexpected fixture rev-parse: ${2:-}" >&2
        exit 2
        ;;
    esac
    ;;
  status)
    if [[ -f "${OPENBURNBAR_FIXTURE_SAFARI_CI_MARKER:-/dev/null}" &&
      -n "${OPENBURNBAR_FIXTURE_POST_SAFARI_GIT_STATUS:-}" ]]
    then
      printf '%s\n' "$OPENBURNBAR_FIXTURE_POST_SAFARI_GIT_STATUS"
    elif [[ -n "${OPENBURNBAR_FIXTURE_GIT_STATUS:-}" ]]; then
      printf '%s\n' "$OPENBURNBAR_FIXTURE_GIT_STATUS"
    fi
    ;;
  *)
    echo "unexpected fixture git command: $*" >&2
    exit 2
    ;;
esac
SH

  cat >"$mock_bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'security' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
case "${OPENBURNBAR_FIXTURE_IDENTITY_MODE:-one}" in
  missing)
    printf '     0 valid identities found\n'
    ;;
  ambiguous)
    printf '  1) %s "%s"\n' "$OPENBURNBAR_FIXTURE_IDENTITY_SHA1" "$OPENBURNBAR_FIXTURE_IDENTITY"
    printf '  2) %s "%s"\n' "$OPENBURNBAR_FIXTURE_SECOND_IDENTITY_SHA1" "$OPENBURNBAR_FIXTURE_IDENTITY"
    printf '     2 valid identities found\n'
    ;;
  one)
    printf '  1) %s "%s"\n' "$OPENBURNBAR_FIXTURE_IDENTITY_SHA1" "$OPENBURNBAR_FIXTURE_IDENTITY"
    printf '     1 valid identities found\n'
    ;;
  *)
    echo "unknown fixture identity mode" >&2
    exit 2
    ;;
esac
SH

  cat >"$mock_bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
if [[ "$*" != *"--extract-certificates"* ]]; then
  echo "unexpected fixture codesign command: $*" >&2
  exit 2
fi
printf 'openburnbar-fixture-leaf-certificate\n' >codesign0
SH

  cat >"$mock_bin/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
  if [[ -n "${!name:-}" ]]; then
    echo "candidate Git override leaked into xcodebuild: $name" >&2
    exit 2
  fi
done
if [[ "${FIREBASE_SOURCE_FIRESTORE:-}" != "1" ]]; then
  echo "signed build did not select the locked source-built Firestore graph" >&2
  exit 2
fi
printf 'xcodebuild' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"

scheme=""
build_products=""
while (($# > 0)); do
  case "$1" in
    -scheme)
      scheme="${2:-}"
      shift 2
      ;;
    CONFIGURATION_BUILD_DIR=*)
      build_products="${1#CONFIGURATION_BUILD_DIR=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -z "$scheme" || -z "$build_products" ]]; then
  echo "fixture xcodebuild requires -scheme and CONFIGURATION_BUILD_DIR" >&2
  exit 2
fi

if [[ "$scheme" != "OpenBurnBar" ]]; then
  echo "unexpected scheme: $scheme" >&2
  exit 2
fi

app="$build_products/OpenBurnBar.app"
appex="$app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
mkdir -p "$appex/Contents" "$app/Contents/MacOS"
printf 'binary\n' >"$app/Contents/MacOS/OpenBurnBar"
printf 'host-profile\n' >"$app/Contents/embedded.provisionprofile"
if [[ "${OPENBURNBAR_FIXTURE_PROFILE_MODE:-complete}" != "missing-safari" ]]; then
  printf 'safari-profile\n' >"$appex/Contents/embedded.provisionprofile"
fi
if [[ "${OPENBURNBAR_FIXTURE_PROFILE_MODE:-complete}" == "ambiguous-safari" ]]; then
  duplicate="$app/Contents/PlugIns/Duplicate.appex/Contents"
  mkdir -p "$duplicate"
  printf 'duplicate-profile\n' >"$duplicate/embedded.provisionprofile"
fi
cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.0.34</string>
<key>CFBundleVersion</key><string>76</string>
</dict></plist>
PLIST
SH

  cat >"$mock_bin/ditto" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
cp -R "$1" "$2"
SH

  cat >"$mock_bin/PlistBuddy" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$2" in
  *CFBundleShortVersionString*) printf '1.0.34\n' ;;
  *CFBundleVersion*) printf '76\n' ;;
  *) echo "unexpected fixture PlistBuddy request: $*" >&2; exit 2 ;;
esac
SH

  cat >"$mock_bin/system_profiler" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'system_profiler' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '{"SPHardwareDataType":[{"provisioning_UDID":"FIXTURE-MAC-UDID"}]}\n'
SH

  cat >"$fixture_root/prepare.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
  if [[ -n "${!name:-}" ]]; then
    echo "candidate Git override leaked into SwiftPM preparation: $name" >&2
    exit 2
  fi
done
if [[ ! -f "$OPENBURNBAR_FIXTURE_SIGNAL_FFI_MARKER" ]]; then
  echo "Signal FFI preparation must complete before SwiftPM resolves the package graph." >&2
  exit 2
fi
printf 'prepare' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf ' <%s>' "$@" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
printf '\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
SH

  cat >"$fixture_root/prepare-signal-ffi.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
  if [[ -n "${!name:-}" ]]; then
    echo "candidate Git override leaked into Signal FFI preparation: $name" >&2
    exit 2
  fi
done
printf 'prepare-signal-ffi profile=<%s> targets=<%s> build-root=<%s> cargo-root=<%s>\n' \
  "${SIGNAL_FFI_BUILD_PROFILE:-}" \
  "${SIGNAL_FFI_BUILD_TARGETS:-}" \
  "${SIGNAL_FFI_BUILD_ROOT:-}" \
  "${SIGNAL_FFI_CARGO_TARGET_ROOT:-}" \
  >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
if [[ "${OPENBURNBAR_FIXTURE_SIGNAL_PREPARE_FAIL:-}" == "1" ]]; then
  echo "fixture Signal FFI preparation failed" >&2
  exit 23
fi
: >"$OPENBURNBAR_FIXTURE_SIGNAL_FFI_MARKER"
SH

  cat >"$fixture_root/safari-ci.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
  if [[ -n "${!name:-}" ]]; then
    echo "candidate Git override leaked into Safari CI: $name" >&2
    exit 2
  fi
done
printf 'safari-ci\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
: >"$OPENBURNBAR_FIXTURE_SAFARI_CI_MARKER"
if [[ "${OPENBURNBAR_FIXTURE_SAFARI_CI_FAIL:-}" == "1" ]]; then
  echo "fixture Safari CI failed" >&2
  exit 29
fi
SH

  cat >"$fixture_root/compat.sh" <<'SH'
#!/usr/bin/env bash
openburnbar_prepare_google_sign_in_macos_compat() {
  printf 'prepare-google <%s>\n' "$1" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
}
openburnbar_restore_google_sign_in_macos_compat() {
  printf 'restore-google\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
}
openburnbar_prepare_libsignal_swift_compat() {
  printf 'prepare-libsignal <%s>\n' "$1" >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
}
openburnbar_restore_libsignal_swift_compat() {
  printf 'restore-libsignal\n' >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
}
SH

  cat >"$fixture_root/verifier.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 6 ]]; then
  echo "verifier expected six arguments" >&2
  exit 2
fi
app="$1"
team="$2"
host_profile="$3"
safari_profile="$4"
identity="$5"
cmp -s "$host_profile" "$app/Contents/embedded.provisionprofile"
cmp -s \
  "$safari_profile" \
  "$app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile"
certificate_sha1="$6"
printf 'verify <%s> <%s> <%s> <%s> <%s> <%s>\n' \
  "$app" "$team" "$host_profile" "$safari_profile" "$identity" "$certificate_sha1" \
  >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
SH

  cat >"$fixture_root/repairer.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 6 ]]; then
  echo "repairer expected six arguments" >&2
  exit 2
fi
app="$1"
safari_profile="$2"
team="$3"
identity="$4"
certificate_sha1="$5"
current_mac_udid="$6"
printf 'repair <%s> <%s> <%s> <%s> <%s> <%s>\n' \
  "$app" \
  "$safari_profile" \
  "$team" \
  "$identity" \
  "$certificate_sha1" \
  "$current_mac_udid" \
  >>"$OPENBURNBAR_FIXTURE_COMMAND_LOG"
if [[ "${OPENBURNBAR_FIXTURE_REPAIR_FAIL:-}" == "1" ]]; then
  echo "fixture Safari profile repair failed" >&2
  exit 24
fi
install -m 600 \
  "$safari_profile" \
  "$app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile"
if [[ "${OPENBURNBAR_FIXTURE_REPAIR_MUTATE_HOST:-}" == "1" ]]; then
  printf 'mutated-host-profile\n' >"$app/Contents/embedded.provisionprofile"
fi
SH

  cat >"$fixture_root/receipt.py" <<'PY'
#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

parser = argparse.ArgumentParser()
for name in (
    "output",
    "candidate_commit",
    "candidate_tree",
    "app",
    "host_profile",
    "safari_profile",
    "team_id",
    "signing_identity",
    "signing_certificate_sha256",
    "current_mac_provisioning_udid",
    "version",
    "build",
):
    parser.add_argument(f"--{name.replace('_', '-')}", required=True)
args = parser.parse_args()
payload = {
    "candidate": {
        "commit": args.candidate_commit,
        "tree": args.candidate_tree,
    },
    "artifact": {
        "version": args.version,
        "build": args.build,
    },
    "signing": {
        "teamId": args.team_id,
        "identity": args.signing_identity,
        "certificateSha256": args.signing_certificate_sha256,
        "currentMacProvisioningUDID": args.current_mac_provisioning_udid,
        "hostProfile": Path(args.host_profile).read_text(),
        "safariProfile": Path(args.safari_profile).read_text(),
    },
}
Path(args.output).write_text(json.dumps(payload, sort_keys=True) + "\n")
with Path(__import__("os").environ["OPENBURNBAR_FIXTURE_COMMAND_LOG"]).open("a") as log:
    log.write(
        "receipt "
        f"<{args.candidate_commit}> <{args.candidate_tree}> "
        f"<{args.app}> <{args.host_profile}> <{args.safari_profile}> "
        f"<{args.team_id}> <{args.signing_identity}> "
        f"<{args.signing_certificate_sha256}>\n"
    )
PY

  chmod +x \
    "$mock_bin/git" \
    "$mock_bin/security" \
    "$mock_bin/codesign" \
    "$mock_bin/xcodebuild" \
    "$mock_bin/ditto" \
    "$mock_bin/PlistBuddy" \
    "$mock_bin/system_profiler" \
    "$fixture_root/prepare.sh" \
    "$fixture_root/prepare-signal-ffi.sh" \
    "$fixture_root/safari-ci.sh" \
    "$fixture_root/verifier.sh" \
    "$fixture_root/repairer.sh" \
    "$fixture_root/receipt.py"
}

run_fixture_with_paths() {
  local fixture_root="$1"
  local output_dir="$2"
  local derived_data="$3"
  shift 3
  mkdir -p "$fixture_root"
  write_fixture_commands "$fixture_root"
  local stdout_path="$fixture_root/stdout.log"
  local stderr_path="$fixture_root/stderr.log"
  local env_args=(OPENBURNBAR_FIXTURE_RUN=1)
  local cli_args=(--configuration Release)
  while (($# > 0)) && [[ "$1" != "--" ]]; do
    env_args+=("$1")
    shift
  done
  if (($# > 0)); then
    shift
    cli_args=("$@")
  fi

  set +e
  env \
    PATH="$fixture_root/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OPENBURNBAR_FIXTURE_COMMAND_LOG="$fixture_root/commands.log" \
    OPENBURNBAR_FIXTURE_REPO_ROOT="$script_dir/.." \
    OPENBURNBAR_FIXTURE_CANDIDATE_COMMIT="$candidate_commit" \
    OPENBURNBAR_FIXTURE_CANDIDATE_TREE="$candidate_tree" \
    OPENBURNBAR_FIXTURE_IDENTITY="$signing_identity" \
    OPENBURNBAR_FIXTURE_IDENTITY_SHA1="$identity_sha1" \
    OPENBURNBAR_FIXTURE_SECOND_IDENTITY_SHA1="$second_identity_sha1" \
    OPENBURNBAR_FIXTURE_SIGNAL_FFI_MARKER="$fixture_root/signal-ffi-ready" \
    OPENBURNBAR_FIXTURE_SAFARI_CI_MARKER="$fixture_root/safari-ci-complete" \
    OPENBURNBAR_GIT_BIN="$fixture_root/mock-bin/git" \
    OPENBURNBAR_SECURITY_BIN="$fixture_root/mock-bin/security" \
    OPENBURNBAR_CODESIGN_BIN="$fixture_root/mock-bin/codesign" \
    OPENBURNBAR_SHASUM_BIN="/usr/bin/shasum" \
    OPENBURNBAR_XCODEBUILD_BIN="$fixture_root/mock-bin/xcodebuild" \
    OPENBURNBAR_DITTO_BIN="$fixture_root/mock-bin/ditto" \
    OPENBURNBAR_PYTHON_BIN="/usr/bin/python3" \
    OPENBURNBAR_PLIST_BUDDY_BIN="$fixture_root/mock-bin/PlistBuddy" \
    OPENBURNBAR_SYSTEM_PROFILER_BIN="$fixture_root/mock-bin/system_profiler" \
    OPENBURNBAR_PREPARE_SWIFTPM_SCRIPT="$fixture_root/prepare.sh" \
    OPENBURNBAR_PREPARE_SIGNAL_FFI_SCRIPT="$fixture_root/prepare-signal-ffi.sh" \
    OPENBURNBAR_SAFARI_CI_SCRIPT="$fixture_root/safari-ci.sh" \
    OPENBURNBAR_GOOGLE_SIGN_IN_COMPAT_SCRIPT="$fixture_root/compat.sh" \
    OPENBURNBAR_LIBSIGNAL_COMPAT_SCRIPT="$fixture_root/compat.sh" \
    OPENBURNBAR_DEVELOPMENT_SIGNING_VERIFIER="$fixture_root/verifier.sh" \
    OPENBURNBAR_DEVELOPMENT_SAFARI_PROFILE_REPAIRER="$fixture_root/repairer.sh" \
    OPENBURNBAR_DEVELOPMENT_RECEIPT_WRITER="$fixture_root/receipt.py" \
    OPENBURNBAR_MAC_UDID_PARSER="$script_dir/lib/parse-macos-provisioning-udid.py" \
    "${env_args[@]}" \
    bash "$script_under_test" \
      --candidate-commit "$candidate_commit" \
      --candidate-tree "$candidate_tree" \
      --team-id "$team_id" \
      --signing-identity "$signing_identity" \
      --output-dir "$output_dir" \
      --derived-data "$derived_data" \
      --package-cache "$fixture_root/package-cache" \
      "${cli_args[@]}" \
      >"$stdout_path" \
      2>"$stderr_path"
  fixture_status=$?
  set -e
}

run_fixture() {
  local fixture_root="$1"
  shift
  run_fixture_with_paths \
    "$fixture_root" \
    "$fixture_root/output" \
    "$fixture_root/derived-data" \
    "$@"
}

test_success_constructs_exact_scheme_scoped_provisioning() {
  local fixture_root="$work_root/success"
  run_fixture "$fixture_root"
  assert_status 0 "$fixture_status" "$fixture_root/stderr.log"

  local log="$fixture_root/commands.log"
  local first_xcode
  first_xcode="$(grep '^xcodebuild ' "$log" | sed -n '1p')"
  [[ "$first_xcode" == *"<-scheme> <OpenBurnBar>"* ]] ||
    fail_test "shared host scheme was not used"
  if [[ "$(grep -c '^xcodebuild ' "$log")" != "1" ]]; then
    fail_test "expected exactly one scheme-scoped xcodebuild call"
  fi
  assert_file_contains "$log" "safari-ci"
  assert_file_contains "$log" \
    "prepare-signal-ffi profile=<release> targets=<aarch64-apple-darwin> build-root=<$fixture_root/derived-data/SignalFFI> cargo-root=<$fixture_root/derived-data/SignalFFICargo>"
  local safari_ci_line signal_ffi_line swiftpm_line xcode_line
  safari_ci_line="$(grep -n '^safari-ci$' "$log" | cut -d: -f1)"
  signal_ffi_line="$(grep -n '^prepare-signal-ffi ' "$log" | cut -d: -f1)"
  swiftpm_line="$(grep -n '^prepare ' "$log" | cut -d: -f1)"
  xcode_line="$(grep -n '^xcodebuild ' "$log" | cut -d: -f1)"
  if ((signal_ffi_line >= swiftpm_line || signal_ffi_line >= xcode_line)); then
    fail_test "Signal FFI must be materialized before SwiftPM resolution and Xcode build"
  fi
  if ((safari_ci_line >= signal_ffi_line)); then
    fail_test "Safari CI must complete before native build preparation"
  fi

  for exact_argument in \
    "<-allowProvisioningUpdates>" \
    "<-allowProvisioningDeviceRegistration>" \
    "<CODE_SIGN_STYLE=Automatic>" \
    "<CODE_SIGNING_ALLOWED=YES>" \
    "<CODE_SIGNING_REQUIRED=YES>" \
    "<DEVELOPMENT_TEAM=$team_id>" \
    "<CODE_SIGN_IDENTITY=Apple Development>" \
    "<PROVISIONING_PROFILE=>" \
    "<PROVISIONING_PROFILE_SPECIFIER=>" \
    "<CONFIGURATION_BUILD_DIR=$fixture_root/output/build-products>" \
    "<-derivedDataPath> <$fixture_root/derived-data>"; do
    assert_file_contains "$log" "$exact_argument"
  done
  assert_file_not_contains "$log" "CODE_SIGN_IDENTITY=-"
  assert_file_not_contains "$log" "<CODE_SIGN_IDENTITY=$identity_sha1>"
  assert_file_not_contains "$log" "CODE_SIGNING_ALLOWED=NO"
  assert_file_not_contains "$log" "<-target>"
  assert_file_not_contains "$log" "repair "
  assert_file_contains "$log" \
    "verify <$fixture_root/output/OpenBurnBar.app> <$team_id> <$fixture_root/output/profiles/OpenBurnBar-host.provisionprofile> <$fixture_root/output/profiles/OpenBurnBar-Safari.provisionprofile> <$signing_identity> <$identity_sha1>"
  assert_file_contains "$log" \
    "receipt <$candidate_commit> <$candidate_tree> <$fixture_root/output/OpenBurnBar.app>"

  cmp -s \
    "$fixture_root/output/profiles/OpenBurnBar-host.provisionprofile" \
    "$fixture_root/output/OpenBurnBar.app/Contents/embedded.provisionprofile" ||
    fail_test "host profile export is not byte-exact"
  cmp -s \
    "$fixture_root/output/profiles/OpenBurnBar-Safari.provisionprofile" \
    "$fixture_root/output/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile" ||
    fail_test "Safari profile export is not byte-exact"

  /usr/bin/python3 - "$fixture_root/output/development-receipt.json" <<PY
import json
import sys
from pathlib import Path

receipt = json.loads(Path(sys.argv[1]).read_text())
assert receipt["candidate"] == {
    "commit": "$candidate_commit",
    "tree": "$candidate_tree",
}
assert receipt["artifact"] == {"version": "1.0.34", "build": "76"}
assert receipt["signing"]["teamId"] == "$team_id"
assert receipt["signing"]["identity"] == "$signing_identity"
assert receipt["signing"]["certificateSha256"] == "$certificate_sha256"
assert receipt["signing"]["currentMacProvisioningUDID"] == "FIXTURE-MAC-UDID"
assert receipt["signing"]["hostProfile"] == "host-profile\n"
assert receipt["signing"]["safariProfile"] == "safari-profile\n"
PY
}

test_exact_safari_profile_repairs_after_copy_before_verification() {
  local fixture_root="$work_root/exact-safari-profile"
  mkdir -p "$fixture_root"
  local exact_profile="$fixture_root/exact-safari.provisionprofile"
  printf 'exact-safari-profile\n' >"$exact_profile"

  run_fixture "$fixture_root" -- --safari-profile "$exact_profile"
  assert_status 0 "$fixture_status" "$fixture_root/stderr.log"

  local log="$fixture_root/commands.log"
  assert_file_contains "$log" \
    "repair <$fixture_root/output/OpenBurnBar.app> <$exact_profile> <$team_id> <$signing_identity> <$identity_sha1> <FIXTURE-MAC-UDID>"
  if grep '^xcodebuild ' "$log" | grep -Fq -- "$exact_profile"; then
    fail_test "exact Safari profile leaked into Xcode global build settings"
  fi

  local ditto_line repair_line verify_line receipt_line
  ditto_line="$(grep -n '^ditto ' "$log" | cut -d: -f1)"
  repair_line="$(grep -n '^repair ' "$log" | cut -d: -f1)"
  verify_line="$(grep -n '^verify ' "$log" | cut -d: -f1)"
  receipt_line="$(grep -n '^receipt ' "$log" | cut -d: -f1)"
  if ((ditto_line >= repair_line || repair_line >= verify_line || verify_line >= receipt_line)); then
    fail_test "expected ditto -> Safari repair -> verifier -> receipt order"
  fi

  if [[ "$(cat "$fixture_root/output/OpenBurnBar.app/Contents/embedded.provisionprofile")" != "host-profile" ]]; then
    fail_test "wrapper repair changed the host profile"
  fi
  cmp -s \
    "$exact_profile" \
    "$fixture_root/output/OpenBurnBar.app/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile" ||
    fail_test "wrapper did not embed the exact Safari profile"
  cmp -s \
    "$exact_profile" \
    "$fixture_root/output/profiles/OpenBurnBar-Safari.provisionprofile" ||
    fail_test "wrapper did not export the repaired Safari profile"
}

test_safari_profile_repair_failure_blocks_verification_and_receipt() {
  local fixture_root="$work_root/repair-failure"
  mkdir -p "$fixture_root"
  local exact_profile="$fixture_root/exact-safari.provisionprofile"
  printf 'exact-safari-profile\n' >"$exact_profile"

  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_REPAIR_FAIL=1 \
    -- \
    --safari-profile "$exact_profile"
  assert_status 24 "$fixture_status" "$fixture_root/stderr.log"
  assert_file_contains "$fixture_root/stderr.log" "fixture Safari profile repair failed"
  assert_file_not_contains "$fixture_root/commands.log" "verify "
  assert_file_not_contains "$fixture_root/commands.log" "receipt "

  fixture_root="$work_root/repair-host-mutation"
  mkdir -p "$fixture_root"
  exact_profile="$fixture_root/exact-safari.provisionprofile"
  printf 'exact-safari-profile\n' >"$exact_profile"
  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_REPAIR_MUTATE_HOST=1 \
    -- \
    --safari-profile "$exact_profile"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "host-profile mutation during repair unexpectedly succeeded"
  assert_file_contains \
    "$fixture_root/stderr.log" \
    "Safari profile repair changed the embedded host development profile"
  assert_file_not_contains "$fixture_root/commands.log" "verify "
  assert_file_not_contains "$fixture_root/commands.log" "receipt "
}

test_rejects_invalid_safari_profile_path_before_build() {
  local fixture_root="$work_root/relative-safari-profile"
  run_fixture "$fixture_root" -- --safari-profile relative.provisionprofile
  [[ "$fixture_status" != "0" ]] ||
    fail_test "relative Safari profile unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "--safari-profile must be an absolute path"
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/missing-safari-profile"
  run_fixture \
    "$fixture_root" \
    -- \
    --safari-profile "$fixture_root/missing.provisionprofile"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "missing Safari profile unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "--safari-profile must be a non-empty real file"
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/symlink-safari-profile"
  mkdir -p "$fixture_root"
  printf 'exact-safari-profile\n' >"$fixture_root/real.provisionprofile"
  ln -s "$fixture_root/real.provisionprofile" "$fixture_root/link.provisionprofile"
  run_fixture \
    "$fixture_root" \
    -- \
    --safari-profile "$fixture_root/link.provisionprofile"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "symlinked Safari profile unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "--safari-profile must be a non-empty real file"
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "
}

test_signal_ffi_preparation_fails_closed_before_resolution() {
  local fixture_root="$work_root/signal-ffi-failure"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_SIGNAL_PREPARE_FAIL=1
  assert_status 23 "$fixture_status" "$fixture_root/stderr.log"
  assert_file_contains "$fixture_root/stderr.log" "fixture Signal FFI preparation failed"
  assert_file_not_contains "$fixture_root/commands.log" "prepare "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "
}

test_safari_ci_fails_closed_and_rejects_generated_drift() {
  local fixture_root="$work_root/safari-ci-failure"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_SAFARI_CI_FAIL=1
  assert_status 29 "$fixture_status" "$fixture_root/stderr.log"
  assert_file_contains "$fixture_root/stderr.log" "fixture Safari CI failed"
  assert_file_not_contains "$fixture_root/commands.log" "security "
  assert_file_not_contains "$fixture_root/commands.log" "prepare-signal-ffi "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/safari-ci-drift"
  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_POST_SAFARI_GIT_STATUS=" M extensions/safari/dist/popup.js"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "Safari CI candidate drift unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "requires a clean candidate checkout"
  assert_file_contains "$fixture_root/stderr.log" "extensions/safari/dist/popup.js"
  assert_file_not_contains "$fixture_root/commands.log" "security "
  assert_file_not_contains "$fixture_root/commands.log" "prepare-signal-ffi "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "
}

test_rejects_candidate_mismatch_before_provisioning() {
  local fixture_root="$work_root/missing-commit"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_GIT_MISSING=commit
  [[ "$fixture_status" != "0" ]] ||
    fail_test "missing candidate commit unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "Candidate commit is missing"
  assert_file_not_contains "$fixture_root/commands.log" "security "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/missing-tree"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_GIT_MISSING=tree
  [[ "$fixture_status" != "0" ]] ||
    fail_test "missing candidate tree unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "Candidate tree is missing"
  assert_file_not_contains "$fixture_root/commands.log" "security "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/wrong-tree"
  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_ACTUAL_TREE="dddddddddddddddddddddddddddddddddddddddd"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "candidate tree mismatch unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "Candidate tree mismatch"
  assert_file_not_contains "$fixture_root/commands.log" "security "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/wrong-candidate"
  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_ACTUAL_COMMIT="cccccccccccccccccccccccccccccccccccccccc"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "candidate mismatch unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "does not match candidate commit"
  assert_file_not_contains "$fixture_root/commands.log" "security "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "
}

test_rejects_dirty_candidate_before_provisioning() {
  local fixture_root="$work_root/dirty-candidate"
  run_fixture \
    "$fixture_root" \
    OPENBURNBAR_FIXTURE_GIT_STATUS=" M user-owned-file"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "dirty candidate unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "requires a clean candidate checkout"
  assert_file_not_contains "$fixture_root/commands.log" "security "
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "
  assert_file_contains "$fixture_root/commands.log" "<--untracked-files=all>"
}

test_rejects_missing_and_ambiguous_identity() {
  local fixture_root="$work_root/missing-identity"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_IDENTITY_MODE=missing
  [[ "$fixture_status" != "0" ]] ||
    fail_test "missing identity unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "exact Apple Development identity is not available"
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/ambiguous-identity"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_IDENTITY_MODE=ambiguous
  [[ "$fixture_status" != "0" ]] ||
    fail_test "ambiguous identity unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "identity is ambiguous (2 valid matches)"
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "
}

test_rejects_missing_and_ambiguous_profiles() {
  local fixture_root="$work_root/missing-profile"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_PROFILE_MODE=missing-safari
  [[ "$fixture_status" != "0" ]] ||
    fail_test "missing Safari profile unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "contains 0 embedded extension profiles"
  assert_file_not_contains "$fixture_root/commands.log" "verify "
  assert_file_not_contains "$fixture_root/commands.log" "receipt "

  fixture_root="$work_root/ambiguous-profile"
  run_fixture "$fixture_root" OPENBURNBAR_FIXTURE_PROFILE_MODE=ambiguous-safari
  [[ "$fixture_status" != "0" ]] ||
    fail_test "ambiguous Safari profile unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "contains 2 embedded extension profiles"
  assert_file_not_contains "$fixture_root/commands.log" "verify "
  assert_file_not_contains "$fixture_root/commands.log" "receipt "
}

test_rejects_existing_or_source_tree_output() {
  local fixture_root="$work_root/existing-output"
  mkdir -p "$fixture_root/output"
  run_fixture_with_paths \
    "$fixture_root" \
    "$fixture_root/output" \
    "$fixture_root/derived-data"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "existing output unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "Output directory must not already exist"
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "

  fixture_root="$work_root/source-output"
  local source_output="$script_dir/.fixture-provision-output-do-not-create"
  [[ ! -e "$source_output" ]] || fail_test "fixture source-output path unexpectedly exists"
  run_fixture_with_paths \
    "$fixture_root" \
    "$source_output" \
    "$fixture_root/derived-data"
  [[ "$fixture_status" != "0" ]] ||
    fail_test "source-tree output unexpectedly succeeded"
  assert_file_contains "$fixture_root/stderr.log" "must be outside the exact candidate checkout"
  [[ ! -e "$source_output" ]] ||
    fail_test "source-tree output was created before rejection"
  assert_file_not_contains "$fixture_root/commands.log" "xcodebuild "
}

test_success_constructs_exact_scheme_scoped_provisioning
test_exact_safari_profile_repairs_after_copy_before_verification
test_safari_profile_repair_failure_blocks_verification_and_receipt
test_rejects_invalid_safari_profile_path_before_build
test_signal_ffi_preparation_fails_closed_before_resolution
test_safari_ci_fails_closed_and_rejects_generated_drift
test_rejects_candidate_mismatch_before_provisioning
test_rejects_dirty_candidate_before_provisioning
test_rejects_missing_and_ambiguous_identity
test_rejects_missing_and_ambiguous_profiles
test_rejects_existing_or_source_tree_output

echo "PASS: exact Safari Apple Development provisioning orchestration fixtures"
