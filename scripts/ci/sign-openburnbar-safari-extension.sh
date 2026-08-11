#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ $# -ne 4 ]]; then
  echo "usage: $0 APP_PATH SIGNING_IDENTITY MAC_APP_DIRECT_PROFILE EXPECTED_TEAM_ID" >&2
  exit 64
fi

app_path="$1"
signing_identity="$2"
profile="$3"
expected_team_id="$4"
expected_bundle_id="com.openburnbar.app.safari-extension"
expected_app_group="group.com.openburnbar.app"
expected_keychain_suffix="com.openburnbar.app"
appex_path="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
source_entitlements="$repo_root/OpenBurnBarSafariExtension/Resources/OpenBurnBarSafariExtension.entitlements"
embedded_profile="$appex_path/Contents/embedded.provisionprofile"

if [[ ! "$expected_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: Expected Apple team ID must be exactly 10 uppercase letters/digits; found '${expected_team_id:-missing}'." >&2
  exit 64
fi
if [[ -z "$signing_identity" ]]; then
  echo "ERROR: Safari extension signing identity must be non-empty." >&2
  exit 64
fi
if [[ ! -d "$appex_path" || -L "$appex_path" ]]; then
  echo "ERROR: Safari extension must exist as a real bundle before signing: $appex_path" >&2
  exit 66
fi
if [[ ! -f "$profile" || -L "$profile" ]]; then
  echo "ERROR: Safari MAC_APP_DIRECT profile is missing or symlinked: $profile" >&2
  exit 66
fi
if [[ ! -f "$source_entitlements" || -L "$source_entitlements" ]]; then
  echo "ERROR: Safari extension entitlements are missing or symlinked: $source_entitlements" >&2
  exit 66
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-safari-extension-sign.XXXXXX")"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

profile_plist="$work_dir/profile.plist"
signing_entitlements="$work_dir/signing-entitlements.plist"
security cms -D -i "$profile" > "$profile_plist"

python3 - \
  "$source_entitlements" \
  "$profile_plist" \
  "$signing_entitlements" \
  "$expected_team_id" \
  "$expected_bundle_id" \
  "$expected_app_group" \
  "$expected_keychain_suffix" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

(
    source_path,
    profile_path,
    destination_path,
    team_id,
    bundle_id,
    app_group,
    keychain_suffix,
) = sys.argv[1:]

with Path(source_path).open("rb") as file:
    source = plistlib.load(file)
with Path(profile_path).open("rb") as file:
    profile = plistlib.load(file)


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_member(values, expected, label: str) -> None:
    if not isinstance(values, list) or expected not in values:
        fail(f"{label} must include {expected!r}; found {values!r}.")


if source.get("com.apple.security.app-sandbox") is not True:
    fail("Safari source entitlements must enable App Sandbox.")
if source.get("com.apple.security.network.client") is not True:
    fail("Safari source entitlements must enable outbound network access.")
require_member(
    source.get("com.apple.security.application-groups"),
    app_group,
    "Safari source App Groups",
)
source_keychain_groups = source.get("keychain-access-groups")
if not isinstance(source_keychain_groups, list) or not any(
    value.endswith(keychain_suffix) for value in source_keychain_groups if isinstance(value, str)
):
    fail(
        "Safari source Keychain groups must contain the OpenBurnBar host access group "
        f"suffix {keychain_suffix!r}."
    )

team_identifiers = profile.get("TeamIdentifier")
if team_identifiers != [team_id]:
    fail(
        "Safari profile TeamIdentifier must contain only "
        f"{team_id!r}; found {team_identifiers!r}."
    )
if profile.get("ProvisionsAllDevices") is not True:
    fail("Safari direct-download profile must set ProvisionsAllDevices=true.")
expiration = profile.get("ExpirationDate")
if not isinstance(expiration, dt.datetime):
    fail("Safari profile is missing ExpirationDate.")
if expiration.tzinfo is None:
    expiration = expiration.replace(tzinfo=dt.timezone.utc)
if expiration <= dt.datetime.now(dt.timezone.utc):
    fail(f"Safari profile expired at {expiration.isoformat()}.")

expected_application_identifier = f"{team_id}.{bundle_id}"
expected_keychain_group = f"{team_id}.{keychain_suffix}"
profile_entitlements = profile.get("Entitlements")
if not isinstance(profile_entitlements, dict):
    fail("Safari profile is missing Entitlements.")
if profile_entitlements.get("com.apple.application-identifier") != expected_application_identifier:
    fail(
        "Safari profile must authorize "
        f"{expected_application_identifier!r}; found "
        f"{profile_entitlements.get('com.apple.application-identifier')!r}."
    )
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
if profile_entitlements.get("com.apple.security.get-task-allow") is True:
    fail("Safari release profile must not enable get-task-allow.")


def expand(value):
    if isinstance(value, str):
        return (
            value.replace("$(AppIdentifierPrefix)", f"{team_id}.")
            .replace("$(TeamIdentifierPrefix)", team_id)
            .replace("$(PRODUCT_BUNDLE_IDENTIFIER)", bundle_id)
        )
    if isinstance(value, list):
        return [expand(item) for item in value]
    if isinstance(value, dict):
        return {key: expand(item) for key, item in value.items()}
    return value


expanded = expand(source)
expanded["com.apple.application-identifier"] = expected_application_identifier
expanded["com.apple.developer.team-identifier"] = team_id
require_member(
    expanded.get("keychain-access-groups"),
    expected_keychain_group,
    "expanded Safari Keychain groups",
)
with Path(destination_path).open("wb") as file:
    plistlib.dump(expanded, file)
PY

mkdir -p "$(dirname "$embedded_profile")"
cp "$profile" "$embedded_profile"

while IFS= read -r -d '' item; do
  codesign --force --timestamp --options runtime,library --sign "$signing_identity" "$item"
done < <(
  find "$appex_path/Contents" -mindepth 1 \
    \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" -o -name "*.xpc" -o -name "*.app" \) \
    -print0 \
    | python3 -c 'import sys; paths=[p for p in sys.stdin.buffer.read().split(b"\0") if p]; paths.sort(key=lambda p: (p.count(b"/"), len(p)), reverse=True); sys.stdout.buffer.write(b"\0".join(paths) + (b"\0" if paths else b""))'
)

codesign --force --timestamp --options runtime,library \
  --entitlements "$signing_entitlements" \
  --sign "$signing_identity" \
  "$appex_path"

bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" \
  direct \
  "$expected_team_id" \
  "$profile"

echo "PASS: OpenBurnBar Safari extension signed before the containing app with its dedicated MAC_APP_DIRECT profile."
