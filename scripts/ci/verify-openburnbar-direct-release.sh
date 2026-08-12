#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
safari_verifier="${OPENBURNBAR_SAFARI_EXTENSION_VERIFIER:-$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh}"
profile_certificate_verifier="${OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER:-$repo_root/scripts/ci/verify-signing-profile-certificate.sh}"

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 APP_PATH EXPECTED_TEAM_ID HOST_PROFILE SAFARI_PROFILE [RECEIPT_JSON]" >&2
  exit 64
fi

app_path="$1"
expected_team_id="$2"
host_profile="$3"
safari_profile="$4"
receipt_path="${5:-}"
expected_host_bundle_id="com.openburnbar.app"
expected_safari_bundle_id="com.openburnbar.app.safari-extension"
expected_app_group="group.com.openburnbar.app"
expected_keychain_suffix="com.openburnbar.app"
appex_path="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
embedded_host_profile="$app_path/Contents/embedded.provisionprofile"
embedded_safari_profile="$appex_path/Contents/embedded.provisionprofile"

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Expected Apple team ID must be exactly 10 uppercase letters/digits; found '${expected_team_id:-missing}'." >&2
  exit 64
fi
for required_file in "$host_profile" "$safari_profile"; do
  if [[ ! -f "$required_file" || -L "$required_file" ]]; then
    echo "ERROR: Direct-release provisioning profile is missing or symlinked: $required_file" >&2
    exit 66
  fi
done
if [[ ! -d "$app_path" || -L "$app_path" ]]; then
  echo "ERROR: Direct-release app bundle is missing or symlinked: $app_path" >&2
  exit 66
fi
if [[ ! -d "$appex_path" || -L "$appex_path" ]]; then
  echo "ERROR: Direct-release Safari extension is missing or symlinked: $appex_path" >&2
  exit 66
fi
if [[ ! -f "$embedded_host_profile" || -L "$embedded_host_profile" ]]; then
  echo "ERROR: Direct-release host is missing a real embedded provisioning profile." >&2
  exit 66
fi
if [[ ! -f "$embedded_safari_profile" || -L "$embedded_safari_profile" ]]; then
  echo "ERROR: Direct-release Safari extension is missing a real embedded provisioning profile." >&2
  exit 66
fi
if ! cmp -s "$host_profile" "$embedded_host_profile"; then
  echo "ERROR: Embedded host profile differs from the candidate profile supplied to the verifier." >&2
  exit 1
fi
if ! cmp -s "$safari_profile" "$embedded_safari_profile"; then
  echo "ERROR: Embedded Safari extension profile differs from the candidate profile supplied to the verifier." >&2
  exit 1
fi

tmp_root="${TMPDIR:-/tmp}"
if ! work_dir="$(mktemp -d "$tmp_root/openburnbar-direct-release-verify.XXXXXX" 2>/dev/null)"; then
  work_dir="$(mktemp -d "/tmp/openburnbar-direct-release-verify.XXXXXX")"
fi
chmod 700 "$work_dir"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

host_entitlements="$work_dir/host-entitlements.plist"
host_profile_plist="$work_dir/host-profile.plist"
safari_profile_plist="$work_dir/safari-profile.plist"
host_signature_path="$work_dir/host-signature.txt"

codesign --verify --deep --strict --verbose=4 "$app_path"
codesign -d --entitlements :- "$app_path" > "$host_entitlements" 2>/dev/null
codesign -dv --verbose=4 "$app_path" > "$host_signature_path" 2>&1
security cms -D -i "$embedded_host_profile" > "$host_profile_plist"
security cms -D -i "$embedded_safari_profile" > "$safari_profile_plist"

host_signature="$(cat "$host_signature_path")"
if ! grep -Fq "Identifier=$expected_host_bundle_id" <<<"$host_signature"; then
  echo "ERROR: Direct-release host signature identifier must be $expected_host_bundle_id." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if ! grep -Fq "TeamIdentifier=$expected_team_id" <<<"$host_signature"; then
  echo "ERROR: Direct-release host signature must belong to Apple team $expected_team_id." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if grep -Fq "Signature=adhoc" <<<"$host_signature"; then
  echo "ERROR: Direct-release host must not be ad-hoc signed." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' <<<"$host_signature" \
  || ! grep -Eq 'flags=.*library-validation' <<<"$host_signature"; then
  echo "ERROR: Direct-release host must enable hardened runtime and library validation." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if ! grep -Fq "Authority=Developer ID Application:" <<<"$host_signature"; then
  echo "ERROR: Direct-release host must use a Developer ID Application certificate." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if ! grep -Fq "Timestamp=" <<<"$host_signature"; then
  echo "ERROR: Direct-release host signature must carry a secure timestamp." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi

python3 - \
  "$host_entitlements" \
  "$host_profile_plist" \
  "$safari_profile_plist" \
  "$expected_team_id" \
  "$expected_host_bundle_id" \
  "$expected_safari_bundle_id" \
  "$expected_app_group" \
  "$expected_keychain_suffix" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

(
    host_entitlements_path,
    host_profile_path,
    safari_profile_path,
    team_id,
    host_bundle_id,
    safari_bundle_id,
    app_group,
    keychain_suffix,
) = sys.argv[1:]


def load(path: str) -> dict:
    with Path(path).open("rb") as file:
        value = plistlib.load(file)
    if not isinstance(value, dict):
        raise SystemExit(f"ERROR: Expected a plist dictionary at {path}.")
    return value


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_equal(actual, expected, label: str) -> None:
    if actual != expected:
        fail(f"{label} must be {expected!r}; found {actual!r}.")


def validate_profile(profile: dict, bundle_id: str, label: str) -> None:
    require_equal(profile.get("Platform"), ["OSX"], f"{label} profile platform")
    require_equal(profile.get("TeamIdentifier"), [team_id], f"{label} profile TeamIdentifier")
    if profile.get("ProvisionsAllDevices") is not True:
        fail(f"{label} profile must set ProvisionsAllDevices=true (MAC_APP_DIRECT).")

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        fail(f"{label} profile is missing ExpirationDate.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        fail(f"{label} profile expired at {expiration.isoformat()}.")

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail(f"{label} profile is missing Entitlements.")
    expected_identifier = f"{team_id}.{bundle_id}"
    require_equal(
        entitlements.get("com.apple.application-identifier"),
        expected_identifier,
        f"{label} profile application identifier",
    )
    profile_team = entitlements.get("com.apple.developer.team-identifier")
    if profile_team is not None:
        require_equal(profile_team, team_id, f"{label} profile team identifier")
    # macOS App Groups are unrestricted entitlements, so Developer ID profiles
    # can carry a team wildcard instead of the concrete shared group. The exact
    # group is still mandatory on the signed host and Safari extension.
    keychain_groups = entitlements.get("keychain-access-groups")
    expected_keychain = f"{team_id}.{keychain_suffix}"
    if not isinstance(keychain_groups, list) or not {
        expected_keychain,
        f"{team_id}.*",
    }.intersection(keychain_groups):
        fail(
            f"{label} profile Keychain groups must authorize "
            f"{expected_keychain!r}; found {keychain_groups!r}."
        )
    if entitlements.get("com.apple.security.get-task-allow") is True:
        fail(f"{label} profile must not enable get-task-allow.")


signed = load(host_entitlements_path)
host_profile = load(host_profile_path)
safari_profile = load(safari_profile_path)
expected_host_identifier = f"{team_id}.{host_bundle_id}"
expected_keychain = f"{team_id}.{keychain_suffix}"

require_equal(
    signed.get("com.apple.application-identifier"),
    expected_host_identifier,
    "signed host application identifier",
)
require_equal(
    signed.get("com.apple.developer.team-identifier"),
    team_id,
    "signed host team identifier",
)
require_equal(
    signed.get("com.apple.security.app-sandbox"),
    False,
    "signed direct-release host sandbox entitlement",
)
require_equal(
    signed.get("com.apple.security.application-groups"),
    [app_group],
    "signed host App Groups",
)
require_equal(
    signed.get("keychain-access-groups"),
    [expected_keychain],
    "signed host Keychain groups",
)
if signed.get("com.apple.security.get-task-allow") is True:
    fail("signed direct-release host must not enable get-task-allow.")

validate_profile(host_profile, host_bundle_id, "host")
validate_profile(safari_profile, safari_bundle_id, "Safari extension")
PY

bash "$safari_verifier" \
  "$app_path" \
  direct \
  "$expected_team_id" \
  "$safari_profile"
bash "$profile_certificate_verifier" "$app_path" "$embedded_host_profile"

if [[ -n "$receipt_path" ]]; then
  mkdir -p "$(dirname "$receipt_path")"
  python3 - \
    "$receipt_path" \
    "$repo_root/scripts/lib" \
    "$host_profile_plist" \
    "$safari_profile_plist" \
    "$host_profile" \
    "$safari_profile" \
    "$expected_team_id" \
    "$expected_host_bundle_id" \
    "$expected_safari_bundle_id" \
    "$expected_app_group" \
    "$expected_keychain_suffix" <<'PY'
import hashlib
import plistlib
import sys
from datetime import timezone
from pathlib import Path

(
    output_path,
    library_path,
    host_profile_plist_path,
    safari_profile_plist_path,
    host_profile_source_path,
    safari_profile_source_path,
    team_id,
    host_bundle_id,
    safari_bundle_id,
    app_group,
    keychain_suffix,
) = sys.argv[1:]
sys.path.insert(0, library_path)
from exclusive_json import write_exclusive_json


def load(path: str) -> dict:
    with Path(path).open("rb") as file:
        return plistlib.load(file)


def sha256(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def iso8601(value) -> str:
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


host = load(host_profile_plist_path)
safari = load(safari_profile_plist_path)
receipt = {
    "schemaVersion": 1,
    "distribution": "developer-id",
    "teamId": team_id,
    "appGroup": app_group,
    "keychainGroup": f"{team_id}.{keychain_suffix}",
    "host": {
        "bundleIdentifier": host_bundle_id,
        "profileExpiration": iso8601(host["ExpirationDate"]),
        "profileSha256": sha256(host_profile_source_path),
        "signature": {
            "authority": "Developer ID Application",
            "hardenedRuntime": True,
            "libraryValidation": True,
            "secureTimestamp": True,
        },
    },
    "safariExtension": {
        "bundleIdentifier": safari_bundle_id,
        "profileExpiration": iso8601(safari["ExpirationDate"]),
        "profileSha256": sha256(safari_profile_source_path),
        "signature": {
            "authority": "Developer ID Application",
            "hardenedRuntime": True,
            "libraryValidation": True,
        },
    },
    "verification": {
        "embeddedProfilesByteEqual": True,
        "profileCertificateMembership": True,
        "strictDeepNestedSignatures": True,
        "getTaskAllow": False,
        "platform": "OSX",
    },
}
write_exclusive_json(Path(output_path), receipt)
PY
fi

echo "PASS: Developer ID host and Safari appex are exact-profile-bound, OSX-scoped, future-dated, entitlement-exact, certificate-authorized, and strict/deep hardened."
