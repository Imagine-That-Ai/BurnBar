#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 APP_PATH development|direct|mas EXPECTED_TEAM_ID [PROVISIONING_PROFILE]" >&2
  exit 64
fi

app_path="$1"
distribution="$2"
expected_team_id="$3"
provided_profile="${4:-}"
expected_bundle_id="com.openburnbar.app.safari-extension"
expected_app_group="group.com.openburnbar.app"
expected_keychain_suffix="com.openburnbar.app"
appex_path="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
embedded_profile="$appex_path/Contents/embedded.provisionprofile"

case "$distribution" in
  development | direct | mas) ;;
  *)
    echo "ERROR: Safari extension distribution must be 'development', 'direct', or 'mas'; found '$distribution'." >&2
    exit 64
    ;;
esac

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Expected Apple team ID must be exactly 10 uppercase letters/digits; found '${expected_team_id:-missing}'." >&2
  exit 64
fi
if [[ ! -d "$app_path" || -L "$app_path" ]]; then
  echo "ERROR: OpenBurnBar app bundle is missing or symlinked: $app_path" >&2
  exit 66
fi
if [[ ! -d "$appex_path" || -L "$appex_path" ]]; then
  echo "ERROR: Safari extension must exist as a real bundle at $appex_path." >&2
  exit 66
fi
python3 "$repo_root/scripts/ci/verify-openburnbar-safari-extension-layout.py" "$appex_path"
if [[ ! -f "$embedded_profile" || -L "$embedded_profile" ]]; then
  echo "ERROR: Safari extension is missing a real embedded provisioning profile at $embedded_profile." >&2
  exit 66
fi
if [[ -n "$provided_profile" ]]; then
  if [[ ! -f "$provided_profile" || -L "$provided_profile" ]]; then
    echo "ERROR: Provided Safari extension provisioning profile is missing or symlinked: $provided_profile" >&2
    exit 66
  fi
  if ! cmp -s "$provided_profile" "$embedded_profile"; then
    echo "ERROR: Embedded Safari extension profile differs from the candidate profile supplied to the verifier." >&2
    exit 1
  fi
fi

current_mac_provisioning_udid=""
if [[ "$distribution" == "development" ]]; then
  if ! current_mac_provisioning_udid="$(
    /usr/sbin/system_profiler SPHardwareDataType -json 2>/dev/null \
      | python3 "$repo_root/scripts/lib/parse-macos-provisioning-udid.py" 2>/dev/null
  )"; then
    echo "ERROR: Could not determine this Mac's unique provisioning UDID from system_profiler." >&2
    exit 69
  fi
fi

tmp_root="${TMPDIR:-/tmp}"
if ! work_dir="$(mktemp -d "$tmp_root/openburnbar-safari-extension-verify.XXXXXX" 2>/dev/null)"; then
  work_dir="$(mktemp -d "/tmp/openburnbar-safari-extension-verify.XXXXXX")"
fi
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

signed_entitlements="$work_dir/signed-entitlements.plist"
profile_plist="$work_dir/profile.plist"

verify_nested_code() {
  local nested_path="$1"
  local nested_signature

  if [[ -L "$nested_path" ]]; then
    echo "ERROR: Nested Safari code must not be a symlink: $nested_path" >&2
    exit 1
  fi
  codesign --verify --strict --verbose=4 "$nested_path"
  nested_signature="$(codesign -dv --verbose=4 "$nested_path" 2>&1)"
  if ! grep -Fq "TeamIdentifier=$expected_team_id" <<<"$nested_signature"; then
    echo "ERROR: Nested Safari code must belong to Apple team $expected_team_id: $nested_path" >&2
    printf '%s\n' "$nested_signature" >&2
    exit 1
  fi
  if grep -Fq "Signature=adhoc" <<<"$nested_signature"; then
    echo "ERROR: Nested Safari code must not be ad-hoc signed: $nested_path" >&2
    printf '%s\n' "$nested_signature" >&2
    exit 1
  fi
  if ! grep -Eq 'flags=.*runtime' <<<"$nested_signature"; then
    echo "ERROR: Nested Safari code must enable hardened runtime: $nested_path" >&2
    printf '%s\n' "$nested_signature" >&2
    exit 1
  fi
  if [[ "$distribution" == "direct" ]] && ! grep -Fq "Authority=Developer ID Application" <<<"$nested_signature"; then
    echo "ERROR: Nested direct-download Safari code must use a Developer ID Application certificate: $nested_path" >&2
    printf '%s\n' "$nested_signature" >&2
    exit 1
  fi
  if [[ "$distribution" == "development" ]] && ! grep -Fq "Authority=Apple Development:" <<<"$nested_signature"; then
    echo "ERROR: Nested development Safari code must use an Apple Development certificate: $nested_path" >&2
    printf '%s\n' "$nested_signature" >&2
    exit 1
  fi
  if [[ "$distribution" == "mas" ]] && ! grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application)' <<<"$nested_signature"; then
    echo "ERROR: Nested Mac App Store Safari code must use an App Store distribution certificate: $nested_path" >&2
    printf '%s\n' "$nested_signature" >&2
    exit 1
  fi
}

while IFS= read -r -d '' nested_path; do
  verify_nested_code "$nested_path"
done < <(
  find "$appex_path/Contents" -mindepth 1 \
    \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" -o -name "*.xpc" -o -name "*.app" \) \
    -print0 \
    | python3 -c 'import sys; paths=[p for p in sys.stdin.buffer.read().split(b"\0") if p]; paths.sort(key=lambda p: (p.count(b"/"), len(p)), reverse=True); sys.stdout.buffer.write(b"\0".join(paths) + (b"\0" if paths else b""))'
)

codesign --verify --strict --verbose=4 "$appex_path"
codesign -d --entitlements :- "$appex_path" > "$signed_entitlements" 2>/dev/null
security cms -D -i "$embedded_profile" > "$profile_plist"

signature="$(codesign -dv --verbose=4 "$appex_path" 2>&1)"
if ! grep -Fq "Identifier=$expected_bundle_id" <<<"$signature"; then
  echo "ERROR: Safari extension signature identifier must be $expected_bundle_id." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if ! grep -Fq "TeamIdentifier=$expected_team_id" <<<"$signature"; then
  echo "ERROR: Safari extension signature must belong to Apple team $expected_team_id." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if grep -Fq "Signature=adhoc" <<<"$signature"; then
  echo "ERROR: Safari extension must not be ad-hoc signed." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if ! grep -Eq 'flags=.*runtime' <<<"$signature" || ! grep -Eq 'flags=.*library-validation' <<<"$signature"; then
  echo "ERROR: Safari extension must be signed with hardened runtime and library validation." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if [[ "$distribution" == "direct" ]] && ! grep -Fq "Authority=Developer ID Application" <<<"$signature"; then
  echo "ERROR: Direct-download Safari extension must be signed with a Developer ID Application certificate." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if [[ "$distribution" == "development" ]] && ! grep -Fq "Authority=Apple Development:" <<<"$signature"; then
  echo "ERROR: Development Safari extension must be signed with an Apple Development certificate." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi
if [[ "$distribution" == "mas" ]] && ! grep -Eq 'Authority=(Apple Distribution|3rd Party Mac Developer Application)' <<<"$signature"; then
  echo "ERROR: Mac App Store Safari extension must be signed with an App Store distribution certificate." >&2
  printf '%s\n' "$signature" >&2
  exit 1
fi

python3 - \
  "$signed_entitlements" \
  "$profile_plist" \
  "$distribution" \
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
    distribution,
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
    "signed Safari application identifier",
)
require_equal(
    signed.get("com.apple.developer.team-identifier"),
    team_id,
    "signed Safari team identifier",
)
require_equal(
    signed.get("com.apple.security.app-sandbox"),
    True,
    "signed Safari app sandbox entitlement",
)
require_equal(
    signed.get("com.apple.security.network.client"),
    True,
    "signed Safari network client entitlement",
)
require_equal(
    signed.get("com.apple.security.application-groups"),
    [app_group],
    "signed Safari App Groups",
)
require_equal(
    signed.get("keychain-access-groups"),
    [expected_keychain_group],
    "signed Safari Keychain groups",
)
if distribution == "development":
    require_equal(
        signed.get("com.apple.security.get-task-allow"),
        True,
        "signed development Safari get-task-allow entitlement",
    )
elif distribution == "mas":
    require_equal(
        signed.get("com.apple.security.get-task-allow"),
        False,
        "signed Mac App Store Safari get-task-allow entitlement",
    )
elif signed.get("com.apple.security.get-task-allow") is True:
    fail("release Safari extension must not enable get-task-allow.")

team_identifiers = profile.get("TeamIdentifier")
if not isinstance(team_identifiers, list) or team_identifiers != [team_id]:
    fail(
        "Safari provisioning profile TeamIdentifier must contain only "
        f"{team_id!r}; found {team_identifiers!r}."
    )
expiration = profile.get("ExpirationDate")
if not isinstance(expiration, dt.datetime):
    fail("Safari provisioning profile is missing ExpirationDate.")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=dt.timezone.utc)
if expiration <= dt.datetime.now(dt.timezone.utc):
    fail(f"Safari provisioning profile expired at {expiration.isoformat()}.")

profile_entitlements = profile.get("Entitlements")
if not isinstance(profile_entitlements, dict):
    fail("Safari provisioning profile is missing Entitlements.")
require_equal(
    profile_entitlements.get("com.apple.application-identifier"),
    expected_application_identifier,
    "Safari profile application identifier",
)
profile_team = profile_entitlements.get("com.apple.developer.team-identifier")
if profile_team is not None:
    require_equal(profile_team, team_id, "Safari profile team identifier")
require_member(
    profile_entitlements.get("com.apple.security.application-groups"),
    app_group,
    "Safari profile App Groups",
)
profile_keychain_groups = profile_entitlements.get("keychain-access-groups")
if not isinstance(profile_keychain_groups, list) or not {
    expected_keychain_group,
    f"{team_id}.*",
}.intersection(profile_keychain_groups):
    fail(
        "Safari profile Keychain groups must authorize "
        f"{expected_keychain_group!r}; found {profile_keychain_groups!r}."
    )
if distribution == "mas":
    require_equal(
        profile_entitlements.get("com.apple.security.get-task-allow"),
        False,
        "Mac App Store Safari profile get-task-allow entitlement",
    )
elif distribution != "development" and profile_entitlements.get(
    "com.apple.security.get-task-allow"
) is True:
    fail("Safari provisioning profile must not enable get-task-allow.")

all_devices = profile.get("ProvisionsAllDevices") is True
provisioned_devices = profile.get("ProvisionedDevices")
if distribution == "development":
    if all_devices:
        fail("development Safari profile must not be an all-devices distribution profile.")
    require_equal(
        profile.get("Platform"),
        ["OSX"],
        "development Safari profile platform",
    )
    if not isinstance(provisioned_devices, list) or not provisioned_devices:
        fail("development Safari profile must authorize at least one registered device.")
    if current_mac_provisioning_udid not in provisioned_devices:
        fail("development Safari profile must authorize this Mac's provisioning UDID.")
    profile_get_task_allow = profile_entitlements.get("com.apple.security.get-task-allow")
    if profile_get_task_allow is False:
        fail("development Safari profile must not explicitly disable get-task-allow.")
    if profile_get_task_allow not in (None, True):
        fail(
            "development Safari profile get-task-allow entitlement must be absent or True; "
            f"found {profile_get_task_allow!r}."
        )
if distribution == "direct" and not all_devices:
    fail("direct Safari profile must set ProvisionsAllDevices=true (MAC_APP_DIRECT).")
if distribution == "mas" and all_devices:
    fail("Mac App Store Safari profile must not be a MAC_APP_DIRECT all-devices profile.")
if distribution == "mas":
    require_equal(
        profile.get("Platform"),
        ["OSX"],
        "Mac App Store Safari profile platform",
    )
PY

bash "$repo_root/scripts/ci/verify-signing-profile-certificate.sh" \
  "$appex_path" \
  "$embedded_profile"

echo "PASS: $distribution OpenBurnBar Safari extension and nested code are structurally complete, profile-bound, explicitly signed by team $expected_team_id, sandboxed, App-Group scoped, and hardened."
