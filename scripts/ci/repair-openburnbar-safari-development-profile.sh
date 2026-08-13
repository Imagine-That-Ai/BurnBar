#!/usr/bin/env bash

set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

if [[ $# -ne 6 ]]; then
  echo "usage: $0 APP_PATH EXACT_SAFARI_PROFILE EXPECTED_TEAM_ID EXACT_APPLE_DEVELOPMENT_IDENTITY EXPECTED_CERTIFICATE_SHA1 CURRENT_MAC_UDID" >&2
  exit 64
fi

app_path="$1"
safari_profile="$2"
expected_team_id="$3"
signing_identity="$4"
expected_certificate_sha1="$5"
current_mac_udid="$6"

expected_bundle_id="com.openburnbar.app.safari-extension"
appex_path="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
host_profile="$app_path/Contents/embedded.provisionprofile"
embedded_safari_profile="$appex_path/Contents/embedded.provisionprofile"
helpers_dir="$app_path/Contents/Helpers"
daemon_path="$helpers_dir/OpenBurnBarDaemon"
execution_path="$helpers_dir/OpenBurnBarPrivilegedInputExecution"
virtual_hid_path="$helpers_dir/OpenBurnBarVirtualHIDBridge"
watchdog_path="$helpers_dir/OpenBurnBarPrivilegedInputKillSwitchWatchdog"
execution_entitlements="$repo_root/OpenBurnBarDaemon/Resources/PrivilegedInputExecution/OpenBurnBarPrivilegedInputExecution.entitlements"

codesign_bin="${OPENBURNBAR_CODESIGN_BIN:-codesign}"
security_bin="${OPENBURNBAR_SECURITY_BIN:-security}"
python_bin="${OPENBURNBAR_PYTHON_BIN:-python3}"
certificate_verifier="${OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER:-$repo_root/scripts/ci/verify-signing-profile-certificate.sh}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Required command is unavailable: $1"
  fi
}

canonical_real_directory() {
  local raw_path="$1"
  local label="$2"
  if [[ "$raw_path" != /* ]]; then
    fail "$label must be an absolute path."
  fi
  if [[ ! -d "$raw_path" || -L "$raw_path" ]]; then
    fail "$label must be a real non-symlink directory: $raw_path"
  fi
  local canonical_path
  canonical_path="$(cd "$raw_path" && pwd -P)"
  if [[ "$canonical_path" != "$raw_path" ]]; then
    fail "$label must not traverse symlinks or non-canonical path segments: $raw_path"
  fi
  printf '%s\n' "$canonical_path"
}

canonical_real_file() {
  local raw_path="$1"
  local label="$2"
  if [[ "$raw_path" != /* ]]; then
    fail "$label must be an absolute path."
  fi
  if [[ ! -f "$raw_path" || -L "$raw_path" || ! -s "$raw_path" ]]; then
    fail "$label must be a non-empty real non-symlink file: $raw_path"
  fi
  local parent_path parent_real canonical_path
  parent_path="$(dirname "$raw_path")"
  if [[ ! -d "$parent_path" || -L "$parent_path" ]]; then
    fail "$label parent must be a real non-symlink directory: $parent_path"
  fi
  parent_real="$(cd "$parent_path" && pwd -P)"
  canonical_path="$parent_real/$(basename "$raw_path")"
  if [[ "$canonical_path" != "$raw_path" ]]; then
    fail "$label must not traverse symlinks or non-canonical path segments: $raw_path"
  fi
  printf '%s\n' "$canonical_path"
}

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Expected Apple team ID must be exactly 10 uppercase letters/digits." >&2
  exit 64
fi
if [[ "$signing_identity" == *$'\n'* || "$signing_identity" == *$'\r'* ||
  "$signing_identity" != "Apple Development: "* ]]
then
  echo "ERROR: Signing identity must be one exact Apple Development identity." >&2
  exit 64
fi
if [[ ! "$expected_certificate_sha1" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "ERROR: Expected Apple Development certificate SHA-1 must be exactly 40 hexadecimal characters." >&2
  exit 64
fi
expected_certificate_sha1="$(
  printf '%s' "$expected_certificate_sha1" | tr '[:lower:]' '[:upper:]'
)"
if [[ -z "$current_mac_udid" ||
  "$current_mac_udid" == *$'\n'* ||
  "$current_mac_udid" == *$'\r'* ]]
then
  echo "ERROR: Current Mac provisioning UDID must be a non-empty single-line value." >&2
  exit 64
fi

for required_command in "$codesign_bin" "$security_bin" "$python_bin"; do
  require_command "$required_command"
done
if [[ ! -f "$certificate_verifier" || -L "$certificate_verifier" ]]; then
  fail "Signing-profile certificate verifier must be a real file: $certificate_verifier"
fi

app_path="$(canonical_real_directory "$app_path" "OpenBurnBar app")"
appex_path="$(canonical_real_directory "$appex_path" "OpenBurnBar Safari appex")"
safari_profile="$(canonical_real_file "$safari_profile" "Exact Safari development profile")"
host_profile="$(canonical_real_file "$host_profile" "Embedded host development profile")"
embedded_safari_profile="$appex_path/Contents/embedded.provisionprofile"
embedded_safari_profile="$(
  canonical_real_file "$embedded_safari_profile" "Embedded Safari development profile"
)"
daemon_path="$(canonical_real_file "$daemon_path" "Embedded OpenBurnBar daemon")"
execution_path="$(canonical_real_file "$execution_path" "Embedded privileged input execution helper")"
virtual_hid_path="$(canonical_real_file "$virtual_hid_path" "Embedded virtual HID bridge")"
watchdog_path="$(canonical_real_file "$watchdog_path" "Embedded kill-switch watchdog")"
execution_entitlements="$(
  canonical_real_file "$execution_entitlements" "Privileged input execution entitlements"
)"

identity_matches=()
while IFS= read -r identity_line; do
  if [[ "$identity_line" == *"\"$signing_identity\""* &&
    "$identity_line" =~ ([0-9A-Fa-f]{40}) ]]
  then
    identity_matches+=("$(
      printf '%s' "${BASH_REMATCH[1]}" | tr '[:lower:]' '[:upper:]'
    )")
  fi
done < <("$security_bin" find-identity -v -p codesigning)
if ((${#identity_matches[@]} != 1)); then
  fail "Exact Apple Development identity must have one valid keychain match; found ${#identity_matches[@]}."
fi
if [[ "${identity_matches[0]}" != "$expected_certificate_sha1" ]]; then
  fail "Exact Apple Development identity resolves to ${identity_matches[0]}; expected $expected_certificate_sha1."
fi

tmp_root="${TMPDIR:-/tmp}"
if ! work_dir="$(mktemp -d "$tmp_root/openburnbar-safari-development-repair.XXXXXX" 2>/dev/null)"; then
  work_dir="$(mktemp -d "/tmp/openburnbar-safari-development-repair.XXXXXX")"
fi
chmod 700 "$work_dir"
work_dir="$(cd "$work_dir" && pwd -P)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

profile_plist="$work_dir/safari-profile.plist"
host_profile_snapshot="$work_dir/host.provisionprofile"
host_entitlements="$work_dir/host-entitlements.plist"
appex_entitlements="$work_dir/appex-entitlements.plist"
install -m 600 "$host_profile" "$host_profile_snapshot"

if ! "$security_bin" cms -D -i "$safari_profile" >"$profile_plist"; then
  fail "Could not decode the exact Safari development profile."
fi
if [[ ! -s "$profile_plist" ]]; then
  fail "Decoded Safari development profile is empty."
fi

"$python_bin" - \
  "$profile_plist" \
  "$expected_team_id" \
  "$expected_bundle_id" \
  "$current_mac_udid" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

profile_path, team_id, bundle_id, current_mac_udid = sys.argv[1:]

try:
    with Path(profile_path).open("rb") as file:
        profile = plistlib.load(file)
except Exception as error:
    raise SystemExit(f"ERROR: Exact Safari development profile is not a valid plist: {error}")


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


if not isinstance(profile, dict):
    fail("Exact Safari development profile root must be a dictionary.")
if profile.get("TeamIdentifier") != [team_id]:
    fail(
        "Safari profile TeamIdentifier must contain only "
        f"{team_id!r}; found {profile.get('TeamIdentifier')!r}."
    )
if profile.get("Platform") != ["OSX"]:
    fail(
        "Safari development profile platform must be ['OSX']; "
        f"found {profile.get('Platform')!r}."
    )
if profile.get("ProvisionsAllDevices") is True:
    fail("Safari development profile must not be an all-devices distribution profile.")

devices = profile.get("ProvisionedDevices")
if not isinstance(devices, list) or current_mac_udid not in devices:
    fail(
        "Safari development profile must authorize this Mac's provisioning UDID; "
        f"found {devices!r}."
    )

expiration = profile.get("ExpirationDate")
if not isinstance(expiration, dt.datetime):
    fail("Safari development profile is missing ExpirationDate.")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=dt.timezone.utc)
if expiration <= dt.datetime.now(dt.timezone.utc):
    fail(f"Safari development profile expired at {expiration.isoformat()}.")

entitlements = profile.get("Entitlements")
if not isinstance(entitlements, dict):
    fail("Safari development profile is missing Entitlements.")
expected_application_identifier = f"{team_id}.{bundle_id}"
if entitlements.get("com.apple.application-identifier") != expected_application_identifier:
    fail(
        "Safari profile application identifier must be "
        f"{expected_application_identifier!r}; found "
        f"{entitlements.get('com.apple.application-identifier')!r}."
    )
profile_team = entitlements.get("com.apple.developer.team-identifier")
if profile_team is not None and profile_team != team_id:
    fail(
        f"Safari profile team identifier must be {team_id!r}; "
        f"found {profile_team!r}."
    )
get_task_allow = entitlements.get("com.apple.security.get-task-allow")
if get_task_allow is False:
    fail("Safari development profile must not explicitly disable get-task-allow.")
if get_task_allow not in (None, True):
    fail(
        "Safari development profile get-task-allow must be absent or True; "
        f"found {get_task_allow!r}."
    )
PY

capture_entitlements() {
  local signed_path="$1"
  local destination="$2"
  local label="$3"
  if ! "$codesign_bin" -d --entitlements :- "$signed_path" >"$destination" 2>/dev/null; then
    fail "Could not capture $label effective entitlements before repair."
  fi
  if [[ ! -s "$destination" ]]; then
    fail "Captured $label effective entitlements are empty."
  fi
  "$python_bin" - "$destination" "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

path, label = sys.argv[1:]
try:
    with Path(path).open("rb") as file:
        entitlements = plistlib.load(file)
except Exception as error:
    raise SystemExit(f"ERROR: Captured {label} entitlements are not a valid plist: {error}")
if not isinstance(entitlements, dict):
    raise SystemExit(f"ERROR: Captured {label} entitlements root must be a dictionary.")
print("nonempty" if entitlements else "empty")
PY
}

if ! "$codesign_bin" --verify --strict --verbose=4 "$app_path"; then
  fail "OpenBurnBar host signature is invalid before Safari profile repair."
fi
if ! "$codesign_bin" --verify --strict --verbose=4 "$appex_path"; then
  fail "OpenBurnBar Safari appex signature is invalid before profile repair."
fi
for helper_path in \
  "$daemon_path" \
  "$execution_path" \
  "$virtual_hid_path" \
  "$watchdog_path"; do
  if ! "$codesign_bin" --verify --strict --verbose=4 "$helper_path"; then
    fail "Embedded OpenBurnBar helper signature is invalid before profile repair: $helper_path"
  fi
done
host_entitlement_mode="$(
  capture_entitlements "$app_path" "$host_entitlements" "host"
)"
if [[ "$host_entitlement_mode" != "nonempty" ]]; then
  fail "Captured host effective entitlements must not be empty."
fi
appex_entitlement_mode="$(
  capture_entitlements "$appex_path" "$appex_entitlements" "Safari appex"
)"
if [[ "$appex_entitlement_mode" != "nonempty" ]]; then
  fail "Captured Safari appex effective entitlements must not be empty."
fi

appex_signature="$("$codesign_bin" -dv --verbose=4 "$appex_path" 2>&1)"
if ! grep -Fq "Authority=$signing_identity" <<<"$appex_signature"; then
  fail "Existing Safari appex is not signed by the exact requested Apple Development identity."
fi

certificate_dir="$work_dir/appex-certificate"
mkdir -m 700 "$certificate_dir"
(
  cd "$certificate_dir"
  "$codesign_bin" -d --extract-certificates "$appex_path" >/dev/null 2>&1
)
appex_leaf_certificate="$certificate_dir/codesign0"
if [[ ! -f "$appex_leaf_certificate" || -L "$appex_leaf_certificate" || ! -s "$appex_leaf_certificate" ]]; then
  fail "Could not extract the Safari appex leaf signing certificate."
fi
actual_certificate_sha1="$(
  "$python_bin" - "$appex_leaf_certificate" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha1(Path(sys.argv[1]).read_bytes()).hexdigest().upper())
PY
)"
if [[ "$actual_certificate_sha1" != "$expected_certificate_sha1" ]]; then
  fail "Existing Safari appex certificate SHA-1 is $actual_certificate_sha1; expected $expected_certificate_sha1."
fi

if ! bash "$certificate_verifier" "$appex_path" "$safari_profile"; then
  fail "Exact Safari development profile does not authorize the requested Apple Development certificate."
fi

nested_paths=()
nested_entitlements=()
nested_entitlement_modes=()
nested_index=0
while IFS= read -r -d '' nested_path; do
  if ! "$codesign_bin" --verify --strict --verbose=4 "$nested_path"; then
    fail "Nested Safari code signature is invalid before profile repair: $nested_path"
  fi
  nested_paths+=("$nested_path")
  nested_entitlement_path="$work_dir/nested-${nested_index}-entitlements.plist"
  nested_entitlement_mode="$(
    capture_entitlements "$nested_path" "$nested_entitlement_path" "nested Safari code"
  )"
  nested_entitlements+=("$nested_entitlement_path")
  nested_entitlement_modes+=("$nested_entitlement_mode")
  nested_index=$((nested_index + 1))
done < <(
  {
    find "$appex_path/Contents" -mindepth 1 \
      -type d \
      \( -name "*.framework" -o -name "*.bundle" -o -name "*.xpc" -o -name "*.app" \) \
      -print0
    find "$appex_path/Contents" -mindepth 1 \
      -type f \
      -name "*.dylib" \
      -print0
  } | "$python_bin" -c 'import sys; paths=[p for p in sys.stdin.buffer.read().split(b"\0") if p]; paths.sort(key=lambda p: (p.count(b"/"), len(p)), reverse=True); sys.stdout.buffer.write(b"\0".join(paths) + (b"\0" if paths else b""))'
)

replacement_profile="$work_dir/replacement.provisionprofile"
install -m 600 "$safari_profile" "$replacement_profile"
install -m 600 "$replacement_profile" "$embedded_safari_profile"
if ! cmp -s "$safari_profile" "$embedded_safari_profile"; then
  fail "Embedded Safari profile bytes differ immediately after replacement."
fi

sign_with_entitlements() {
  local target_path="$1"
  local entitlement_path="$2"
  "$codesign_bin" \
    --force \
    --sign "$signing_identity" \
    --timestamp=none \
    --generate-entitlement-der \
    --options runtime,library \
    --preserve-metadata=identifier,requirements \
    --entitlements "$entitlement_path" \
    "$target_path"
  "$codesign_bin" --verify --strict --verbose=4 "$target_path"
}

sign_helper() {
  local target_path="$1"
  local identifier="$2"
  local entitlement_path="${3:-}"
  local sign_args=(
    --force
    --sign "$signing_identity"
    --timestamp=none
    --generate-entitlement-der
    --options "runtime,library"
    --identifier "$identifier"
  )
  if [[ -n "$entitlement_path" ]]; then
    sign_args+=(--entitlements "$entitlement_path")
  fi
  "$codesign_bin" "${sign_args[@]}" "$target_path"
  "$codesign_bin" --verify --strict --verbose=4 "$target_path"
}

sign_helper "$daemon_path" "com.openburnbar.app"
sign_helper \
  "$execution_path" \
  "com.openburnbar.privileged-input-execution" \
  "$execution_entitlements"
sign_helper "$virtual_hid_path" "com.openburnbar.virtual-hid-bridge"
sign_helper \
  "$watchdog_path" \
  "com.openburnbar.privileged-input-killswitch-watchdog"

for ((index = 0; index < ${#nested_paths[@]}; index++)); do
  nested_sign_args=(--force)
  nested_sign_args+=(--sign "$signing_identity")
  nested_sign_args+=(--timestamp=none)
  nested_sign_args+=(--generate-entitlement-der)
  nested_sign_args+=(--options "runtime,library")
  nested_sign_args+=("--preserve-metadata=identifier,requirements")
  if [[ "${nested_entitlement_modes[$index]}" == "nonempty" ]]; then
    nested_sign_args+=(--entitlements "${nested_entitlements[$index]}")
  fi
  "$codesign_bin" "${nested_sign_args[@]}" "${nested_paths[$index]}"
  "$codesign_bin" --verify --strict --verbose=4 "${nested_paths[$index]}"
done

sign_with_entitlements "$appex_path" "$appex_entitlements"
sign_with_entitlements "$app_path" "$host_entitlements"

if ! cmp -s "$host_profile_snapshot" "$host_profile"; then
  fail "Embedded host development profile changed during Safari profile repair."
fi
if ! cmp -s "$safari_profile" "$embedded_safari_profile"; then
  fail "Embedded Safari development profile does not match the exact supplied profile."
fi

verify_entitlements_preserved() {
  local signed_path="$1"
  local before_path="$2"
  local label="$3"
  local after_path="$work_dir/${label// /-}-entitlements-after.plist"
  capture_entitlements "$signed_path" "$after_path" "$label" >/dev/null
  "$python_bin" - "$before_path" "$after_path" "$label" <<'PY'
import plistlib
import sys
from pathlib import Path

before_path, after_path, label = sys.argv[1:]
with Path(before_path).open("rb") as file:
    before = plistlib.load(file)
with Path(after_path).open("rb") as file:
    after = plistlib.load(file)
if before != after:
    raise SystemExit(
        f"ERROR: Effective {label} entitlements changed during Safari profile repair."
    )
PY
}

verify_entitlements_preserved "$appex_path" "$appex_entitlements" "Safari appex"
verify_entitlements_preserved "$app_path" "$host_entitlements" "host"

echo "PASS: exact Safari development profile embedded; daemon and privileged-input helper signatures normalized; nested code, appex, and host re-signed in containment order without changing the host profile or effective entitlements."
