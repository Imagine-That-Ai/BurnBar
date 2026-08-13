#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
project_manifest="$repo_root/project.yml"
tmp_root="${TMPDIR:-/tmp}"
if ! work_dir="$(mktemp -d "$tmp_root/openburnbar-development-signing-test.XXXXXX" 2>/dev/null)"; then
  work_dir="$(mktemp -d "/tmp/openburnbar-development-signing-test.XXXXXX")"
fi
trap 'rm -rf "$work_dir"' EXIT

team_id="4Y367DF25B"
current_mac_provisioning_udid="$(
  /usr/sbin/system_profiler SPHardwareDataType -json 2>/dev/null \
    | python3 "$repo_root/scripts/lib/parse-macos-provisioning-udid.py"
)"
app_path="$work_dir/OpenBurnBar.app"
app_contents="$app_path/Contents"
appex_path="$app_contents/PlugIns/OpenBurnBarSafariExtension.appex"
appex_contents="$appex_path/Contents"
resources_path="$appex_contents/Resources"
helpers_path="$app_contents/Helpers"
daemon_path="$helpers_path/OpenBurnBarDaemon"
execution_path="$helpers_path/OpenBurnBarPrivilegedInputExecution"
virtual_hid_path="$helpers_path/OpenBurnBarVirtualHIDBridge"
watchdog_path="$helpers_path/OpenBurnBarPrivilegedInputKillSwitchWatchdog"
app_profile="$app_contents/embedded.provisionprofile"
appex_profile="$appex_contents/embedded.provisionprofile"
app_entitlements="$work_dir/app-entitlements.plist"
appex_entitlements="$work_dir/appex-entitlements.plist"
good_app_profile="$work_dir/good-app-profile.plist"
good_appex_profile="$work_dir/good-appex-profile.plist"
good_app_entitlements="$work_dir/good-app-entitlements.plist"
good_appex_entitlements="$work_dir/good-appex-entitlements.plist"
codesign_log="$work_dir/codesign.log"
mock_bin="$work_dir/mock-bin"

mkdir -p \
  "$app_contents/MacOS" \
  "$appex_contents/MacOS" \
  "$helpers_path" \
  "$resources_path/icons" \
  "$mock_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$app_contents/MacOS/OpenBurnBar"
printf '#!/usr/bin/env bash\nexit 0\n' > "$appex_contents/MacOS/OpenBurnBarSafariExtension"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "--help" ]]; then echo "Usage: OpenBurnBarDaemon [OPTIONS]"; exit 0; fi\nexit 2\n' > "$daemon_path"
printf '#!/usr/bin/env bash\nexit 0\n' > "$execution_path"
printf '#!/usr/bin/env bash\nexit 0\n' > "$virtual_hid_path"
printf '#!/usr/bin/env bash\nexit 0\n' > "$watchdog_path"
chmod +x \
  "$app_contents/MacOS/OpenBurnBar" \
  "$appex_contents/MacOS/OpenBurnBarSafariExtension" \
  "$daemon_path" \
  "$execution_path" \
  "$virtual_hid_path" \
  "$watchdog_path"

python3 - "$project_manifest" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
required = (
    'DAEMON_SOURCE="${BUILT_PRODUCTS_DIR}/OpenBurnBarDaemon"',
    'cp "${DAEMON_SOURCE}" "${HELPERS_DIR}/OpenBurnBarDaemon"',
    "- $(BUILT_PRODUCTS_DIR)/OpenBurnBarDaemon",
    "- $(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/OpenBurnBarDaemon",
    "- target: OpenBurnBarDaemonExecutable",
    "OTHER_CODE_SIGN_FLAGS: --identifier com.openburnbar.app --options runtime,library",
    "OTHER_CODE_SIGN_FLAGS: --identifier com.openburnbar.privileged-input-execution --options runtime,library",
    "OTHER_CODE_SIGN_FLAGS: --identifier com.openburnbar.virtual-hid-bridge --options runtime,library",
    "OTHER_CODE_SIGN_FLAGS: --identifier com.openburnbar.privileged-input-killswitch-watchdog --options runtime,library",
)
missing = [entry for entry in required if entry not in source]
if missing:
    raise SystemExit(
        "FAIL: project.yml no longer builds and embeds the required daemon: "
        + ", ".join(missing)
    )
PY

printf 'background\n' > "$resources_path/background.js"
printf 'popup\n' > "$resources_path/popup.html"
printf 'runner\n' > "$resources_path/page-world-runner.js"
printf 'icon\n' > "$resources_path/icons/app-icon-128.png"

python3 - \
  "$app_contents/Info.plist" \
  "$appex_contents/Info.plist" \
  "$resources_path/manifest.json" \
  "$app_profile" \
  "$appex_profile" \
  "$app_entitlements" \
  "$appex_entitlements" \
  "$team_id" \
  "$current_mac_provisioning_udid" <<'PY'
import datetime as dt
import json
import plistlib
import sys
from pathlib import Path

(
    app_info_path,
    appex_info_path,
    manifest_path,
    app_profile_path,
    appex_profile_path,
    app_entitlements_path,
    appex_entitlements_path,
    team_id,
    current_mac_provisioning_udid,
) = sys.argv[1:]

app_bundle_id = "com.openburnbar.app"
appex_bundle_id = "com.openburnbar.app.safari-extension"
app_group = "group.com.openburnbar.app"
keychain_group = f"{team_id}.com.openburnbar.app"

app_info = {
    "CFBundleExecutable": "OpenBurnBar",
    "CFBundleIdentifier": app_bundle_id,
    "CFBundlePackageType": "APPL",
    "CFBundleShortVersionString": "1.0.34",
}
appex_info = {
    "CFBundleExecutable": "OpenBurnBarSafariExtension",
    "CFBundleIdentifier": appex_bundle_id,
    "CFBundlePackageType": "XPC!",
    "CFBundleShortVersionString": "1.0.34",
    "NSExtension": {
        "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
        "NSExtensionPrincipalClass": "OpenBurnBarSafariExtension.SafariWebExtensionHandler",
    },
}
manifest = {
    "manifest_version": 3,
    "version": "1.0.34",
    "background": {"service_worker": "background.js"},
    "action": {
        "default_popup": "popup.html",
        "default_icon": {"128": "icons/app-icon-128.png"},
    },
    "icons": {"128": "icons/app-icon-128.png"},
    "browser_specific_settings": {"safari": {"strict_min_version": "15.4"}},
    "permissions": [
        "activeTab",
        "alarms",
        "nativeMessaging",
        "scripting",
        "storage",
        "tabs",
    ],
    "host_permissions": [
        "http://127.0.0.1/*",
        "http://localhost/*",
        "http://[::1]/*",
    ],
    "optional_host_permissions": ["http://*/*", "https://*/*"],
    "web_accessible_resources": [
        {
            "resources": ["page-world-runner.js"],
            "matches": ["http://*/*", "https://*/*"],
        }
    ],
    "content_security_policy": {
        "extension_pages": "script-src 'self'; object-src 'none'; base-uri 'none'"
    },
}

app_signed_entitlements = {
    "com.apple.application-identifier": f"{team_id}.{app_bundle_id}",
    "com.apple.developer.team-identifier": team_id,
    "com.apple.security.app-sandbox": False,
    "com.apple.security.get-task-allow": True,
    "com.apple.security.application-groups": [app_group],
    "keychain-access-groups": [keychain_group],
}
appex_signed_entitlements = {
    "com.apple.application-identifier": f"{team_id}.{appex_bundle_id}",
    "com.apple.developer.team-identifier": team_id,
    "com.apple.security.app-sandbox": True,
    "com.apple.security.get-task-allow": True,
    "com.apple.security.network.client": True,
    "com.apple.security.application-groups": [app_group],
    "keychain-access-groups": [keychain_group],
}


def development_profile(bundle_id: str) -> dict:
    return {
        "CreationDate": dt.datetime(2026, 8, 11, tzinfo=dt.timezone.utc),
        "ExpirationDate": dt.datetime(2099, 8, 11, tzinfo=dt.timezone.utc),
        "Name": f"OpenBurnBar Development: {bundle_id}",
        "Platform": ["OSX"],
        "ProvisionedDevices": [current_mac_provisioning_udid],
        "TeamIdentifier": [team_id],
        "DeveloperCertificates": [b"openburnbar-fixture-signer"],
        "Entitlements": {
            "com.apple.application-identifier": f"{team_id}.{bundle_id}",
            "com.apple.developer.team-identifier": team_id,
            "com.apple.security.get-task-allow": True,
            "com.apple.security.application-groups": [f"{team_id}.*"],
            "keychain-access-groups": [f"{team_id}.*"],
        },
    }


for path, value in (
    (app_info_path, app_info),
    (appex_info_path, appex_info),
    (app_profile_path, development_profile(app_bundle_id)),
    (appex_profile_path, development_profile(appex_bundle_id)),
    (app_entitlements_path, app_signed_entitlements),
    (appex_entitlements_path, appex_signed_entitlements),
):
    with Path(path).open("wb") as file:
        plistlib.dump(value, file)
Path(manifest_path).write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")
PY

cp "$app_profile" "$good_app_profile"
cp "$appex_profile" "$good_appex_profile"
cp "$app_entitlements" "$good_app_entitlements"
cp "$appex_entitlements" "$good_appex_entitlements"

cat > "$mock_bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

input=""
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index += 1)); do
  if [[ "${arguments[$index]}" == "-i" ]]; then
    input="${arguments[$((index + 1))]}"
  fi
done
if [[ "$1" == "cms" && -n "$input" ]]; then
  cat "$input"
  exit 0
fi
echo "unexpected mock security invocation: $*" >&2
exit 97
SH

cat > "$mock_bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$MOCK_CODESIGN_LOG"

if [[ " $* " == *" --verify "* ]]; then
  exit 0
fi
if [[ "$1" == "-d" && " $* " == *" --extract-certificates "* ]]; then
  printf 'openburnbar-fixture-signer' > codesign0
  exit 0
fi
if [[ "$1" == "-d" && " $* " == *" --entitlements :- "* ]]; then
  target="${@: -1}"
  if [[ "$target" == "$MOCK_APPEX" ]]; then
    cat "$MOCK_APPEX_ENTITLEMENTS"
  elif [[ "$target" == "$MOCK_DAEMON" ]]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
  elif [[ "$target" == "$MOCK_EXECUTION" ]]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.developer.hid.virtual.device</key><true/></dict></plist>'
  elif [[ "$target" == "$MOCK_VIRTUAL_HID" || "$target" == "$MOCK_WATCHDOG" ]]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
  else
    cat "$MOCK_APP_ENTITLEMENTS"
  fi
  exit 0
fi
if [[ "$1" == "-dr" ]]; then
  printf '%s\n' 'designated => identifier "com.openburnbar.app" and anchor apple generic'
  exit 0
fi
if [[ "$1" == "-dv" || "$1" == "-d" ]]; then
  target="${@: -1}"
  if [[ "$target" == "$MOCK_APPEX" ]]; then
    identifier="${MOCK_APPEX_IDENTIFIER:-com.openburnbar.app.safari-extension}"
    authority="${MOCK_APPEX_AUTHORITY:-Apple Development: OpenBurnBar Test ($MOCK_TEAM_ID)}"
    flags="${MOCK_APPEX_FLAGS:-flags=0x12000(runtime,library-validation)}"
  elif [[ "$target" == "$MOCK_DAEMON" ]]; then
    identifier="${MOCK_DAEMON_IDENTIFIER:-com.openburnbar.app}"
    authority="${MOCK_DAEMON_AUTHORITY:-Apple Development: OpenBurnBar Test ($MOCK_TEAM_ID)}"
    flags="${MOCK_DAEMON_FLAGS:-flags=0x12000(runtime,library-validation)}"
  elif [[ "$target" == "$MOCK_EXECUTION" ]]; then
    identifier="${MOCK_EXECUTION_IDENTIFIER:-com.openburnbar.privileged-input-execution}"
    authority="Apple Development: OpenBurnBar Test ($MOCK_TEAM_ID)"
    flags="${MOCK_EXECUTION_FLAGS:-flags=0x12000(runtime,library-validation)}"
  elif [[ "$target" == "$MOCK_VIRTUAL_HID" ]]; then
    identifier="${MOCK_VIRTUAL_HID_IDENTIFIER:-com.openburnbar.virtual-hid-bridge}"
    authority="Apple Development: OpenBurnBar Test ($MOCK_TEAM_ID)"
    flags="${MOCK_VIRTUAL_HID_FLAGS:-flags=0x12000(runtime,library-validation)}"
  elif [[ "$target" == "$MOCK_WATCHDOG" ]]; then
    identifier="${MOCK_WATCHDOG_IDENTIFIER:-com.openburnbar.privileged-input-killswitch-watchdog}"
    authority="Apple Development: OpenBurnBar Test ($MOCK_TEAM_ID)"
    flags="${MOCK_WATCHDOG_FLAGS:-flags=0x12000(runtime,library-validation)}"
  else
    identifier="${MOCK_APP_IDENTIFIER:-com.openburnbar.app}"
    authority="${MOCK_APP_AUTHORITY:-Apple Development: OpenBurnBar Test ($MOCK_TEAM_ID)}"
    flags="${MOCK_APP_FLAGS:-flags=0x12000(runtime,library-validation)}"
  fi
  cat <<EOF
Identifier=$identifier
Authority=$authority
TeamIdentifier=$MOCK_TEAM_ID
$flags
EOF
  exit 0
fi

echo "unexpected mock codesign invocation: $*" >&2
exit 99
SH

chmod +x \
  "$mock_bin/security" \
  "$mock_bin/codesign"

export PATH="$mock_bin:$PATH"
export MOCK_APPEX="$appex_path"
export MOCK_DAEMON="$daemon_path"
export MOCK_EXECUTION="$execution_path"
export MOCK_VIRTUAL_HID="$virtual_hid_path"
export MOCK_WATCHDOG="$watchdog_path"
export MOCK_APP_ENTITLEMENTS="$app_entitlements"
export MOCK_APPEX_ENTITLEMENTS="$appex_entitlements"
export MOCK_CODESIGN_LOG="$codesign_log"
export MOCK_TEAM_ID="$team_id"

assert_fails_with() {
  local expected="$1"
  shift
  local output

  if output="$("$@" 2>&1)"; then
    echo "FAIL: command unexpectedly passed: $*" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "FAIL: expected failure text '$expected'" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER=/usr/bin/false \
  TMPDIR="$work_dir/missing-tmp-root" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" \
  "$team_id"

expected_identity="Apple Development: OpenBurnBar Test ($team_id)"
expected_certificate_sha1="$(
  printf 'openburnbar-fixture-signer' | shasum -a 1 | awk '{print toupper($1)}'
)"
OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER=/usr/bin/false \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" \
  "$team_id" \
  "$good_app_profile" \
  "$good_appex_profile" \
  "$expected_identity" \
  "$expected_certificate_sha1"

if [[ "$(grep -c -- "--extract-certificates" "$codesign_log")" != "10" ]]; then
  echo "FAIL: host, Safari, daemon, and privileged-input helper signer/profile certificate membership were not verified in both compatibility and audited-profile modes." >&2
  cat "$codesign_log" >&2
  exit 1
fi

mv "$daemon_path" "$daemon_path.missing"
assert_fails_with \
  "OpenBurnBar development app is missing the required embedded daemon executable" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
mv "$daemon_path.missing" "$daemon_path"

export MOCK_DAEMON_IDENTIFIER="com.openburnbar.daemon"
assert_fails_with \
  "App and daemon must share the com.openburnbar.app signing identifier" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
unset MOCK_DAEMON_IDENTIFIER

export MOCK_DAEMON_FLAGS="flags=0x10000(runtime)"
assert_fails_with \
  "Daemon must use hardened runtime and library validation" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
unset MOCK_DAEMON_FLAGS

export MOCK_EXECUTION_IDENTIFIER="OpenBurnBarPrivilegedInputExecution"
assert_fails_with \
  "Privileged input execution helper has the wrong signing identifier" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
unset MOCK_EXECUTION_IDENTIFIER

export MOCK_VIRTUAL_HID_FLAGS="flags=0x10000(runtime)"
assert_fails_with \
  "Virtual HID bridge must use hardened runtime and library validation" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
unset MOCK_VIRTUAL_HID_FLAGS

export MOCK_WATCHDOG_IDENTIFIER="OpenBurnBarPrivilegedInputKillSwitchWatchdog"
assert_fails_with \
  "Kill-switch watchdog has the wrong signing identifier" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
unset MOCK_WATCHDOG_IDENTIFIER

audited_host_profile="$work_dir/audited-host-mismatch.provisionprofile"
cp "$good_app_profile" "$audited_host_profile"
printf 'mismatch\n' >> "$audited_host_profile"
assert_fails_with \
  "Embedded host development profile differs from the audited host profile" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id" "$audited_host_profile" "$good_appex_profile"

audited_appex_profile="$work_dir/audited-appex-mismatch.provisionprofile"
cp "$good_appex_profile" "$audited_appex_profile"
printf 'mismatch\n' >> "$audited_appex_profile"
assert_fails_with \
  "Embedded Safari development profile differs from the audited Safari profile" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id" "$good_app_profile" "$audited_appex_profile"

export MOCK_APP_AUTHORITY="Apple Development: Substituted Signer ($team_id)"
assert_fails_with \
  "Development app leaf signing identity must exactly match" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id" "$good_app_profile" "$good_appex_profile" "$expected_identity" "$expected_certificate_sha1"
unset MOCK_APP_AUTHORITY

export MOCK_APPEX_AUTHORITY="Apple Development: Substituted Signer ($team_id)"
assert_fails_with \
  "Safari extension leaf signing identity must exactly match" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id" "$good_app_profile" "$good_appex_profile" "$expected_identity" "$expected_certificate_sha1"
unset MOCK_APPEX_AUTHORITY

assert_fails_with \
  "Development app leaf certificate SHA-1 must match" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id" "$good_app_profile" "$good_appex_profile" "$expected_identity" "1111111111111111111111111111111111111111"

python3 - "$appex_profile" "$team_id" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
team_id = sys.argv[2]
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["Entitlements"]["com.apple.application-identifier"] = f"{team_id}.*"
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "Safari profile application identifier must be '4Y367DF25B.com.openburnbar.app.safari-extension'" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_profile" "$appex_profile"

export MOCK_APPEX_FLAGS="flags=0x10000(runtime)"
assert_fails_with \
  "Safari extension must be signed with hardened runtime and library validation" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
unset MOCK_APPEX_FLAGS

python3 - "$app_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["Platform"] = ["iOS"]
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "development app profile platform must be ['OSX']" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_app_profile" "$app_profile"

python3 - "$appex_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile.pop("Platform", None)
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "development Safari profile platform must be ['OSX']" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_profile" "$appex_profile"

python3 - "$app_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["ProvisionedDevices"] = ["11111111-1111111111111111"]
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "development app profile must authorize this Mac's provisioning UDID" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_app_profile" "$app_profile"

python3 - "$appex_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["ProvisionedDevices"] = ["11111111-1111111111111111"]
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "development Safari profile must authorize this Mac's provisioning UDID" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_profile" "$appex_profile"

python3 - "$app_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["Entitlements"]["com.apple.security.get-task-allow"] = "invalid"
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "development app profile get-task-allow entitlement must be absent or True" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_app_profile" "$app_profile"

python3 - "$app_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["Entitlements"].pop("com.apple.security.get-task-allow", None)
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_app_profile" "$app_profile"

python3 - "$appex_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["Entitlements"]["com.apple.security.get-task-allow"] = False
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "development Safari profile must not explicitly disable get-task-allow" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_profile" "$appex_profile"

python3 - "$appex_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["Entitlements"].pop("com.apple.security.get-task-allow", None)
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_profile" "$appex_profile"

python3 - "$app_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    entitlements = plistlib.load(file)
entitlements["com.apple.security.application-groups"].append("group.com.openburnbar.unexpected")
with path.open("wb") as file:
    plistlib.dump(entitlements, file)
PY
assert_fails_with \
  "signed development app App Groups must be ['group.com.openburnbar.app']" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_app_entitlements" "$app_entitlements"

python3 - "$app_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    entitlements = plistlib.load(file)
entitlements["keychain-access-groups"].append("4Y367DF25B.com.openburnbar.unexpected")
with path.open("wb") as file:
    plistlib.dump(entitlements, file)
PY
assert_fails_with \
  "signed development app Keychain groups must be ['4Y367DF25B.com.openburnbar.app']" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_app_entitlements" "$app_entitlements"

python3 - "$appex_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    entitlements = plistlib.load(file)
entitlements["com.apple.security.application-groups"].append("group.com.openburnbar.unexpected")
with path.open("wb") as file:
    plistlib.dump(entitlements, file)
PY
assert_fails_with \
  "signed Safari App Groups must be ['group.com.openburnbar.app']" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_entitlements" "$appex_entitlements"

python3 - "$appex_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    entitlements = plistlib.load(file)
entitlements["keychain-access-groups"].append("4Y367DF25B.com.openburnbar.unexpected")
with path.open("wb") as file:
    plistlib.dump(entitlements, file)
PY
assert_fails_with \
  "signed Safari Keychain groups must be ['4Y367DF25B.com.openburnbar.app']" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_entitlements" "$appex_entitlements"

python3 - "$appex_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    entitlements = plistlib.load(file)
entitlements.pop("com.apple.security.get-task-allow", None)
with path.open("wb") as file:
    plistlib.dump(entitlements, file)
PY
assert_fails_with \
  "signed development Safari get-task-allow entitlement must be True" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"
cp "$good_appex_entitlements" "$appex_entitlements"

export MOCK_APP_AUTHORITY="Developer ID Application: OpenBurnBar Test ($team_id)"
assert_fails_with \
  "Development app must be signed with an Apple Development certificate" \
  bash "$repo_root/scripts/ci/verify-openburnbar-development-signing.sh" \
  "$app_path" "$team_id"

echo "PASS: development signing gate accepts macOS/current-device profiles with the exact embedded daemon and rejects bundle, daemon, platform, device, debug, signed-authority, flag, entitlement, and identity mismatches"
