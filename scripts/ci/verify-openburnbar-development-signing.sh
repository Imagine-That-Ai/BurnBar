#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ $# -ne 2 && $# -ne 4 && $# -ne 6 ]]; then
  echo "usage: $0 APP_PATH EXPECTED_TEAM_ID [AUDITED_HOST_PROFILE AUDITED_SAFARI_PROFILE [EXPECTED_APPLE_DEVELOPMENT_IDENTITY EXPECTED_SIGNING_CERTIFICATE_SHA1]]" >&2
  exit 64
fi

app_path="$1"
expected_team_id="$2"
audited_host_profile="${3:-}"
audited_safari_profile="${4:-}"
expected_signing_identity="${5:-}"
expected_signing_certificate_sha1="${6:-}"
expected_bundle_id="com.openburnbar.app"
expected_app_group="group.com.openburnbar.app"
expected_keychain_suffix="com.openburnbar.app"
embedded_profile="$app_path/Contents/embedded.provisionprofile"
appex_path="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
embedded_safari_profile="$appex_path/Contents/embedded.provisionprofile"

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Expected Apple team ID must be exactly 10 uppercase letters/digits; found '${expected_team_id:-missing}'." >&2
  exit 64
fi
if [[ -n "$expected_signing_identity" ]]; then
  if [[ "$expected_signing_identity" == *$'\n'* || "$expected_signing_identity" == *$'\r'* ]]; then
    echo "ERROR: Expected Apple Development identity must be exactly one line." >&2
    exit 64
  fi
  identity_name="${expected_signing_identity#Apple Development: }"
  if [[ "$identity_name" == "$expected_signing_identity" || -z "$identity_name" ]]; then
    echo "ERROR: Expected signing identity must be an exact Apple Development identity." >&2
    exit 64
  fi
  if [[ ! "$expected_signing_certificate_sha1" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "ERROR: Expected Apple Development certificate SHA-1 must be exactly 40 hexadecimal characters." >&2
    exit 64
  fi
  expected_signing_certificate_sha1="$(
    printf '%s' "$expected_signing_certificate_sha1" | tr '[:lower:]' '[:upper:]'
  )"
elif [[ -n "$expected_signing_certificate_sha1" ]]; then
  echo "ERROR: Expected signing certificate SHA-1 requires an exact Apple Development identity." >&2
  exit 64
fi
if [[ ! -d "$app_path" || -L "$app_path" ]]; then
  echo "ERROR: OpenBurnBar development app must exist as a real bundle: $app_path" >&2
  exit 66
fi
if [[ ! -f "$embedded_profile" || -L "$embedded_profile" ]]; then
  echo "ERROR: OpenBurnBar development app is missing a real embedded provisioning profile: $embedded_profile" >&2
  exit 66
fi
if [[ -n "$audited_host_profile" || -n "$audited_safari_profile" ]]; then
  if [[ -z "$audited_host_profile" || -z "$audited_safari_profile" ]]; then
    echo "ERROR: Certification requires both audited host and Safari development profiles." >&2
    exit 64
  fi
  if [[ ! -f "$audited_host_profile" || -L "$audited_host_profile" ]]; then
    echo "ERROR: Audited host development profile is missing or symlinked: $audited_host_profile" >&2
    exit 66
  fi
  if [[ ! -f "$audited_safari_profile" || -L "$audited_safari_profile" ]]; then
    echo "ERROR: Audited Safari development profile is missing or symlinked: $audited_safari_profile" >&2
    exit 66
  fi
  if ! cmp -s "$audited_host_profile" "$embedded_profile"; then
    echo "ERROR: Embedded host development profile differs from the audited host profile." >&2
    exit 1
  fi
  if [[ ! -f "$embedded_safari_profile" || -L "$embedded_safari_profile" ]]; then
    echo "ERROR: Safari extension is missing a real embedded development profile: $embedded_safari_profile" >&2
    exit 66
  fi
  if ! cmp -s "$audited_safari_profile" "$embedded_safari_profile"; then
    echo "ERROR: Embedded Safari development profile differs from the audited Safari profile." >&2
    exit 1
  fi
fi

if ! current_mac_provisioning_udid="$(
  /usr/sbin/system_profiler SPHardwareDataType -json 2>/dev/null \
    | python3 "$repo_root/scripts/lib/parse-macos-provisioning-udid.py" 2>/dev/null
)"; then
  echo "ERROR: Could not determine this Mac's unique provisioning UDID from system_profiler." >&2
  exit 69
fi

tmp_root="${TMPDIR:-/tmp}"
if ! work_dir="$(mktemp -d "$tmp_root/openburnbar-development-signing.XXXXXX" 2>/dev/null)"; then
  work_dir="$(mktemp -d "/tmp/openburnbar-development-signing.XXXXXX")"
fi
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

signed_entitlements="$work_dir/signed-entitlements.plist"
profile_plist="$work_dir/profile.plist"

codesign --verify --strict --verbose=4 "$app_path"
codesign -d --entitlements :- "$app_path" > "$signed_entitlements" 2>/dev/null
security cms -D -i "$embedded_profile" > "$profile_plist"

signature="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
if ! grep -Fq "Identifier=$expected_bundle_id" <<<"$signature"; then
  echo "ERROR: Development app signature identifier must be $expected_bundle_id." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if ! grep -Fq "TeamIdentifier=$expected_team_id" <<<"$signature"; then
  echo "ERROR: Development app signature must belong to Apple team $expected_team_id." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if grep -Fq "Signature=adhoc" <<<"$signature"; then
  echo "ERROR: Development app must not be ad-hoc signed." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' <<<"$signature" || ! grep -Eq 'flags=.*library-validation' <<<"$signature"; then
  echo "ERROR: Development app must be signed with hardened runtime and library validation." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if ! grep -Fq "Authority=Apple Development:" <<<"$signature"; then
  echo "ERROR: Development app must be signed with an Apple Development certificate." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if [[ -n "$expected_signing_identity" ]]; then
  leaf_authority="$(sed -n 's/^Authority=//p' <<<"$signature" | head -n 1)"
  if [[ "$leaf_authority" != "$expected_signing_identity" ]]; then
    echo "ERROR: Development app leaf signing identity must exactly match '$expected_signing_identity'; found '${leaf_authority:-missing}'." >&2
    exit 1
  fi
  appex_signature="$(codesign -dv --verbose=4 "$appex_path" 2>&1)"
  appex_leaf_authority="$(sed -n 's/^Authority=//p' <<<"$appex_signature" | head -n 1)"
  if [[ "$appex_leaf_authority" != "$expected_signing_identity" ]]; then
    echo "ERROR: Safari extension leaf signing identity must exactly match '$expected_signing_identity'; found '${appex_leaf_authority:-missing}'." >&2
    exit 1
  fi

  certificate_sha1_for_bundle() {
    local bundle_path="$1"
    local label="$2"
    local extraction_dir="$work_dir/$label-certificate"
    mkdir -m 700 "$extraction_dir"
    (
      cd "$extraction_dir"
      codesign -d --extract-certificates "$bundle_path" >/dev/null 2>&1
    )
    if [[ ! -f "$extraction_dir/codesign0" || -L "$extraction_dir/codesign0" ]]; then
      echo "ERROR: Could not extract the $label leaf signing certificate." >&2
      exit 1
    fi
    shasum -a 1 "$extraction_dir/codesign0" | awk '{print toupper($1)}'
  }

  host_certificate_sha1="$(certificate_sha1_for_bundle "$app_path" "host")"
  safari_certificate_sha1="$(certificate_sha1_for_bundle "$appex_path" "safari")"
  if [[ "$host_certificate_sha1" != "$expected_signing_certificate_sha1" ]]; then
    echo "ERROR: Development app leaf certificate SHA-1 must match '$expected_signing_certificate_sha1'; found '${host_certificate_sha1:-missing}'." >&2
    exit 1
  fi
  if [[ "$safari_certificate_sha1" != "$expected_signing_certificate_sha1" ]]; then
    echo "ERROR: Safari extension leaf certificate SHA-1 must match '$expected_signing_certificate_sha1'; found '${safari_certificate_sha1:-missing}'." >&2
    exit 1
  fi
fi

python3 - \
  "$signed_entitlements" \
  "$profile_plist" \
  "$expected_team_id" \
  "$expected_bundle_id" \
  "$expected_app_group" \
  "$expected_keychain_suffix" \
  "$current_mac_provisioning_udid" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

(
    signed_entitlements_path,
    profile_path,
    team_id,
    bundle_id,
    app_group,
    keychain_suffix,
    current_mac_provisioning_udid,
) = sys.argv[1:]

with Path(signed_entitlements_path).open("rb") as file:
    signed = plistlib.load(file)
with Path(profile_path).open("rb") as file:
    profile = plistlib.load(file)


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_equal(actual, expected, label: str) -> None:
    if actual != expected:
        fail(f"{label} must be {expected!r}; found {actual!r}.")


def require_member(values, expected, label: str) -> None:
    if not isinstance(values, list) or expected not in values:
        fail(f"{label} must include {expected!r}; found {values!r}.")


expected_application_identifier = f"{team_id}.{bundle_id}"
expected_keychain_group = f"{team_id}.{keychain_suffix}"
require_equal(
    signed.get("com.apple.application-identifier"),
    expected_application_identifier,
    "signed development app application identifier",
)
require_equal(
    signed.get("com.apple.developer.team-identifier"),
    team_id,
    "signed development app team identifier",
)
require_equal(
    signed.get("com.apple.security.app-sandbox"),
    False,
    "signed development app sandbox entitlement",
)
require_equal(
    signed.get("com.apple.security.get-task-allow"),
    True,
    "signed development app get-task-allow entitlement",
)
require_equal(
    signed.get("com.apple.security.application-groups"),
    [app_group],
    "signed development app App Groups",
)
require_equal(
    signed.get("keychain-access-groups"),
    [expected_keychain_group],
    "signed development app Keychain groups",
)

team_identifiers = profile.get("TeamIdentifier")
if team_identifiers != [team_id]:
    fail(
        "development app profile TeamIdentifier must contain only "
        f"{team_id!r}; found {team_identifiers!r}."
    )
if profile.get("ProvisionsAllDevices") is True:
    fail("development app profile must not be an all-devices distribution profile.")
require_equal(
    profile.get("Platform"),
    ["OSX"],
    "development app profile platform",
)
provisioned_devices = profile.get("ProvisionedDevices")
if not isinstance(provisioned_devices, list) or not provisioned_devices:
    fail("development app profile must authorize at least one registered device.")
if current_mac_provisioning_udid not in provisioned_devices:
    fail("development app profile must authorize this Mac's provisioning UDID.")
expiration = profile.get("ExpirationDate")
if not isinstance(expiration, dt.datetime):
    fail("development app profile is missing ExpirationDate.")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=dt.timezone.utc)
if expiration <= dt.datetime.now(dt.timezone.utc):
    fail(f"development app profile expired at {expiration.isoformat()}.")

profile_entitlements = profile.get("Entitlements")
if not isinstance(profile_entitlements, dict):
    fail("development app profile is missing Entitlements.")
profile_get_task_allow = profile_entitlements.get("com.apple.security.get-task-allow")
if profile_get_task_allow is False:
    fail("development app profile must not explicitly disable get-task-allow.")
if profile_get_task_allow not in (None, True):
    fail(
        "development app profile get-task-allow entitlement must be absent or True; "
        f"found {profile_get_task_allow!r}."
    )
require_equal(
    profile_entitlements.get("com.apple.application-identifier"),
    expected_application_identifier,
    "development app profile application identifier",
)
profile_team = profile_entitlements.get("com.apple.developer.team-identifier")
if profile_team is not None:
    require_equal(profile_team, team_id, "development app profile team identifier")
# macOS App Groups are unrestricted entitlements, so a provisioning profile's
# value may be a team wildcard. The exact group remains mandatory on signed code.
profile_keychain_groups = profile_entitlements.get("keychain-access-groups")
if not isinstance(profile_keychain_groups, list) or not {
    expected_keychain_group,
    f"{team_id}.*",
}.intersection(profile_keychain_groups):
    fail(
        "development app profile Keychain groups must authorize "
        f"{expected_keychain_group!r}; found {profile_keychain_groups!r}."
    )
PY

bash "$repo_root/scripts/ci/verify-signing-profile-certificate.sh" \
  "$app_path" \
  "$embedded_profile"
safari_verifier_args=(
  "$app_path"
  development
  "$expected_team_id"
)
if [[ -n "$audited_safari_profile" ]]; then
  safari_verifier_args+=("$audited_safari_profile")
fi
bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "${safari_verifier_args[@]}"

if [[ -n "$expected_signing_identity" ]]; then
  echo "PASS: OpenBurnBar host and Safari appex are byte-bound to the audited Apple Development profiles and exact leaf identity, with shared App Group/Keychain authority, hardened runtime, and library validation."
else
  echo "PASS: OpenBurnBar host and Safari appex are exact-profile-bound Apple Development products with shared App Group/Keychain authority, hardened runtime, and library validation."
fi
