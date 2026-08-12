#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ $# -lt 2 || $# -gt 5 ]]; then
  echo "usage: $0 APP_PATH EXPECTED_TEAM_ID [EXPECTED_VERSION] [EXPECTED_BUILD] [INSTALLER_PKG]" >&2
  exit 64
fi

app_path="$1"
expected_team_id="$2"
expected_version="${3:-}"
expected_build="${4:-}"
installer_pkg="${5:-}"
expected_bundle_id="com.openburnbar.app"
expected_appex_bundle_id="com.openburnbar.app.safari-extension"
expected_app_group="group.com.openburnbar.app"
expected_keychain_group="${expected_team_id}.com.openburnbar.app"
embedded_profile="$app_path/Contents/embedded.provisionprofile"
appex_profile="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex/Contents/embedded.provisionprofile"
safari_verifier="${OPENBURNBAR_MAS_SAFARI_VERIFIER:-$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh}"
profile_certificate_verifier="${OPENBURNBAR_MAS_PROFILE_CERTIFICATE_VERIFIER:-$repo_root/scripts/ci/verify-signing-profile-certificate.sh}"

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Expected Apple team ID must be exactly 10 uppercase letters/digits; found '${expected_team_id:-missing}'." >&2
  exit 64
fi
if [[ ! -d "$app_path" || -L "$app_path" ]]; then
  echo "ERROR: Mac App Store app must exist as a real bundle: $app_path" >&2
  exit 66
fi
if [[ ! -f "$app_path/Contents/Info.plist" || -L "$app_path/Contents/Info.plist" ]]; then
  echo "ERROR: Mac App Store app is missing a real Contents/Info.plist." >&2
  exit 66
fi
if [[ ! -f "$embedded_profile" || -L "$embedded_profile" ]]; then
  echo "ERROR: Mac App Store host is missing a real embedded provisioning profile: $embedded_profile" >&2
  exit 66
fi
if [[ ! -f "$appex_profile" || -L "$appex_profile" ]]; then
  echo "ERROR: Mac App Store Safari extension is missing a real embedded provisioning profile: $appex_profile" >&2
  exit 66
fi
if [[ -n "$installer_pkg" && ( ! -f "$installer_pkg" || -L "$installer_pkg" ) ]]; then
  echo "ERROR: Mac App Store installer package must be a real file: $installer_pkg" >&2
  exit 66
fi

tmp_root="${TMPDIR:-/tmp}"
if ! work_dir="$(mktemp -d "$tmp_root/openburnbar-mas-artifact.XXXXXX" 2>/dev/null)"; then
  work_dir="$(mktemp -d "/tmp/openburnbar-mas-artifact.XXXXXX")"
fi
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

host_entitlements="$work_dir/host-entitlements.plist"
host_profile_plist="$work_dir/host-profile.plist"
appex_profile_plist="$work_dir/appex-profile.plist"
pkg_signature_log="$work_dir/pkg-signature.log"
pkg_assessment_log="$work_dir/pkg-assessment.log"

codesign --verify --deep --strict --verbose=4 "$app_path"
codesign -d --entitlements :- "$app_path" > "$host_entitlements" 2>/dev/null
host_signature="$(codesign -dv --verbose=4 "$app_path" 2>&1)"

if ! grep -Fq "Identifier=$expected_bundle_id" <<<"$host_signature"; then
  echo "ERROR: Mac App Store host signature identifier must be $expected_bundle_id." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if ! grep -Fq "TeamIdentifier=$expected_team_id" <<<"$host_signature"; then
  echo "ERROR: Mac App Store host signature must belong to Apple team $expected_team_id." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if grep -Fq "Signature=adhoc" <<<"$host_signature"; then
  echo "ERROR: Mac App Store host must not be ad-hoc signed." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if ! grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application)' <<<"$host_signature"; then
  echo "ERROR: Mac App Store host must use an Apple Distribution application certificate." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' <<<"$host_signature" || ! grep -Eq 'flags=.*library-validation' <<<"$host_signature"; then
  echo "ERROR: Mac App Store host must use hardened runtime and library validation." >&2
  printf '%s\n' "$host_signature" >&2
  exit 1
fi

security cms -D -i "$embedded_profile" > "$host_profile_plist"
security cms -D -i "$appex_profile" > "$appex_profile_plist"

python3 - \
  "$app_path/Contents/Info.plist" \
  "$host_entitlements" \
  "$host_profile_plist" \
  "$appex_profile_plist" \
  "$expected_team_id" \
  "$expected_bundle_id" \
  "$expected_appex_bundle_id" \
  "$expected_app_group" \
  "$expected_keychain_group" \
  "$expected_version" \
  "$expected_build" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

(
    info_path,
    entitlements_path,
    host_profile_path,
    appex_profile_path,
    team_id,
    bundle_id,
    appex_bundle_id,
    app_group,
    keychain_group,
    expected_version,
    expected_build,
) = sys.argv[1:]


def read_plist(path: str) -> dict:
    with Path(path).open("rb") as file:
        value = plistlib.load(file)
    if not isinstance(value, dict):
        raise SystemExit(f"ERROR: expected a dictionary plist at {path}.")
    return value


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_equal(actual, expected, label: str) -> None:
    if actual != expected:
        fail(f"{label} must be {expected!r}; found {actual!r}.")


def verify_profile(profile: dict, expected_bundle_id: str, label: str) -> None:
    team_identifiers = profile.get("TeamIdentifier")
    require_equal(team_identifiers, [team_id], f"{label} profile TeamIdentifier")
    require_equal(profile.get("Platform"), ["OSX"], f"{label} profile platform")
    if profile.get("ProvisionsAllDevices") is True:
        fail(f"{label} profile must not be a MAC_APP_DIRECT all-devices profile.")
    if profile.get("ProvisionedDevices") not in (None, []):
        fail(f"{label} App Store profile must not authorize development devices.")
    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, dt.datetime):
        fail(f"{label} profile is missing ExpirationDate.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    if expiration <= dt.datetime.now(dt.timezone.utc):
        fail(f"{label} profile expired at {expiration.isoformat()}.")
    profile_entitlements = profile.get("Entitlements")
    if not isinstance(profile_entitlements, dict):
        fail(f"{label} profile is missing Entitlements.")
    require_equal(
        profile_entitlements.get("com.apple.application-identifier"),
        f"{team_id}.{expected_bundle_id}",
        f"{label} profile application identifier",
    )
    profile_team = profile_entitlements.get("com.apple.developer.team-identifier")
    if profile_team is not None:
        require_equal(profile_team, team_id, f"{label} profile team identifier")
    # macOS App Groups are unrestricted entitlements, so App Store profiles
    # may carry a team wildcard. Signed host/appex checks remain exact.
    profile_keychain = profile_entitlements.get("keychain-access-groups")
    if not isinstance(profile_keychain, list) or not {
        keychain_group,
        f"{team_id}.*",
    }.intersection(profile_keychain):
        fail(
            f"{label} profile Keychain groups must authorize "
            f"{keychain_group!r}; found {profile_keychain!r}."
        )
    # Apple-issued App Store profiles commonly omit get-task-allow instead of
    # serializing an explicit false. Both encode the production-only policy;
    # an explicit true is the only forbidden profile value. Signed code below
    # remains stricter and must carry a literal false entitlement.
    profile_get_task_allow = profile_entitlements.get("com.apple.security.get-task-allow")
    if profile_get_task_allow not in (None, False):
        fail(
            f"{label} App Store profile get-task-allow must be absent or false; "
            f"found {profile_get_task_allow!r}."
        )


info = read_plist(info_path)
signed = read_plist(entitlements_path)
host_profile = read_plist(host_profile_path)
appex_profile = read_plist(appex_profile_path)

require_equal(info.get("CFBundleIdentifier"), bundle_id, "host bundle identifier")
if expected_version:
    require_equal(info.get("CFBundleShortVersionString"), expected_version, "host version")
if expected_build:
    require_equal(info.get("CFBundleVersion"), expected_build, "host build")

require_equal(
    signed.get("com.apple.application-identifier"),
    f"{team_id}.{bundle_id}",
    "signed host application identifier",
)
require_equal(
    signed.get("com.apple.developer.team-identifier"),
    team_id,
    "signed host team identifier",
)
require_equal(signed.get("com.apple.security.app-sandbox"), True, "signed host app sandbox")
require_equal(
    signed.get("com.apple.security.network.client"),
    True,
    "signed host network client",
)
require_equal(
    signed.get("com.apple.security.application-groups"),
    [app_group],
    "signed host App Groups",
)
require_equal(
    signed.get("keychain-access-groups"),
    [keychain_group],
    "signed host Keychain groups",
)
require_equal(
    signed.get("com.apple.developer.applesignin"),
    ["Default"],
    "signed host Sign in with Apple entitlement",
)
require_equal(
    signed.get("com.apple.security.get-task-allow"),
    False,
    "signed Mac App Store host get-task-allow",
)
if "com.apple.security.network.server" in signed:
    fail("signed Mac App Store host must not include network server entitlement.")

verify_profile(host_profile, bundle_id, "host")
verify_profile(appex_profile, appex_bundle_id, "Safari extension")
PY

bash "$profile_certificate_verifier" "$app_path" "$embedded_profile"
bash "$safari_verifier" "$app_path" mas "$expected_team_id"

if [[ -n "$installer_pkg" ]]; then
  pkgutil --check-signature "$installer_pkg" > "$pkg_signature_log" 2>&1
  if ! grep -Eq 'Apple Distribution|3rd Party Mac Developer Installer' "$pkg_signature_log"; then
    echo "ERROR: Mac App Store installer package does not report an Apple distribution installer authority." >&2
    cat "$pkg_signature_log" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_team_id" "$pkg_signature_log"; then
    echo "ERROR: Mac App Store installer package signature does not report team $expected_team_id." >&2
    cat "$pkg_signature_log" >&2
    exit 1
  fi
  spctl -a -vv -t install "$installer_pkg" > "$pkg_assessment_log" 2>&1
fi

echo "PASS: OpenBurnBar Mac App Store host, Safari appex, profiles, signer membership, nested signatures, and installer package are exact-team Apple Distribution artifacts."
