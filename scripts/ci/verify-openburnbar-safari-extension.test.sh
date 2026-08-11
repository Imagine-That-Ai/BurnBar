#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-safari-extension-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

team_id="4Y367DF25B"
bundle_id="com.openburnbar.app.safari-extension"
app_path="$work_dir/OpenBurnBar.app"
appex_path="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
contents_path="$appex_path/Contents"
resources_path="$contents_path/Resources"
executable_path="$contents_path/MacOS/OpenBurnBarSafariExtension"
profile_path="$work_dir/OpenBurnBarSafariExtension-MAC_APP_DIRECT.provisionprofile"
signed_entitlements_path="$work_dir/signed-entitlements.plist"
good_entitlements_path="$work_dir/good-entitlements.plist"
codesign_log="$work_dir/codesign.log"
profile_verifier_log="$work_dir/profile-verifier.log"
mock_bin="$work_dir/mock-bin"

mkdir -p \
  "$contents_path/MacOS" \
  "$resources_path/icons" \
  "$contents_path/Frameworks/Nested.framework" \
  "$mock_bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$executable_path"
chmod +x "$executable_path"
printf 'nested framework\n' > "$contents_path/Frameworks/Nested.framework/Nested"
chmod +x "$contents_path/Frameworks/Nested.framework/Nested"
printf 'background\n' > "$resources_path/background.js"
printf 'popup\n' > "$resources_path/popup.html"
printf 'runner\n' > "$resources_path/page-world-runner.js"
printf 'icon\n' > "$resources_path/icons/app-icon-128.png"

python3 - \
  "$contents_path/Info.plist" \
  "$resources_path/manifest.json" \
  "$profile_path" \
  "$team_id" \
  "$bundle_id" <<'PY'
import datetime as dt
import json
import plistlib
import sys
from pathlib import Path

info_path, manifest_path, profile_path, team_id, bundle_id = sys.argv[1:]
application_identifier = f"{team_id}.{bundle_id}"
keychain_group = f"{team_id}.com.openburnbar.app"

info = {
    "CFBundleExecutable": "OpenBurnBarSafariExtension",
    "CFBundleIdentifier": bundle_id,
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
entitlements = {
    "com.apple.application-identifier": application_identifier,
    "com.apple.developer.team-identifier": team_id,
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
    "com.apple.security.application-groups": ["group.com.openburnbar.app"],
    "keychain-access-groups": [keychain_group],
}
profile = {
    "CreationDate": dt.datetime(2026, 8, 10, tzinfo=dt.timezone.utc),
    "ExpirationDate": dt.datetime(2099, 8, 10, tzinfo=dt.timezone.utc),
    "Name": "OpenBurnBar Safari Extension MAC_APP_DIRECT",
    "ProvisionsAllDevices": True,
    "TeamIdentifier": [team_id],
    "Entitlements": entitlements,
}

with Path(info_path).open("wb") as file:
    plistlib.dump(info, file)
Path(manifest_path).write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")
with Path(profile_path).open("wb") as file:
    plistlib.dump(profile, file)
PY

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
if [[ "$1" == "-d" && " $* " == *" --entitlements :- "* ]]; then
  cat "$MOCK_SIGNED_ENTITLEMENTS"
  exit 0
fi
if [[ "$1" == "-dv" ]]; then
  target="${@: -1}"
  reported_team="$MOCK_CODESIGN_TEAM"
  if [[ "$target" == "$MOCK_NESTED_PATH" && -n "${MOCK_NESTED_CODESIGN_TEAM:-}" ]]; then
    reported_team="$MOCK_NESTED_CODESIGN_TEAM"
  fi
  cat <<EOF
Executable=$MOCK_APPEX/Contents/MacOS/OpenBurnBarSafariExtension
Identifier=${MOCK_CODESIGN_IDENTIFIER:-com.openburnbar.app.safari-extension}
Authority=${MOCK_CODESIGN_AUTHORITY:-Developer ID Application: OpenBurnBar Test ($reported_team)}
TeamIdentifier=${reported_team}
Sealed Resources version=2 rules=13 files=8
flags=0x30000(runtime,library-validation)
EOF
  exit 0
fi
if [[ " $* " == *" --sign "* ]]; then
  arguments=("$@")
  entitlements=""
  target=""
  for ((index = 0; index < ${#arguments[@]}; index += 1)); do
    target="${arguments[$index]}"
    if [[ "${arguments[$index]}" == "--entitlements" ]]; then
      entitlements="${arguments[$((index + 1))]}"
    fi
  done
  if [[ "$target" == "$MOCK_APPEX" ]]; then
    if [[ -z "$entitlements" ]]; then
      echo "appex signing invocation omitted --entitlements" >&2
      exit 98
    fi
    cp "$entitlements" "$MOCK_SIGNED_ENTITLEMENTS"
  fi
  exit 0
fi

echo "unexpected mock codesign invocation: $*" >&2
exit 99
SH

cat > "$mock_bin/profile-verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_PROFILE_VERIFIER_LOG"
SH

chmod +x "$mock_bin/security" "$mock_bin/codesign" "$mock_bin/profile-verifier"

export PATH="$mock_bin:$PATH"
export MOCK_APPEX="$appex_path"
export MOCK_CODESIGN_LOG="$codesign_log"
export MOCK_SIGNED_ENTITLEMENTS="$signed_entitlements_path"
export MOCK_CODESIGN_TEAM="$team_id"
export MOCK_NESTED_PATH="$contents_path/Frameworks/Nested.framework"
export MOCK_NESTED_CODESIGN_TEAM="$team_id"
export MOCK_PROFILE_VERIFIER_LOG="$profile_verifier_log"
export OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER="$mock_bin/profile-verifier"

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

bash "$repo_root/scripts/ci/sign-openburnbar-safari-extension.sh" \
  "$app_path" \
  "Developer ID Application: OpenBurnBar Test ($team_id)" \
  "$profile_path" \
  "$team_id"

embedded_profile="$contents_path/embedded.provisionprofile"
cmp "$profile_path" "$embedded_profile"
cp "$signed_entitlements_path" "$good_entitlements_path"

python3 - "$signed_entitlements_path" "$team_id" "$bundle_id" <<'PY'
import plistlib
import sys
from pathlib import Path

path, team_id, bundle_id = sys.argv[1:]
with Path(path).open("rb") as file:
    entitlements = plistlib.load(file)
assert entitlements["com.apple.application-identifier"] == f"{team_id}.{bundle_id}"
assert entitlements["com.apple.developer.team-identifier"] == team_id
assert entitlements["com.apple.security.application-groups"] == ["group.com.openburnbar.app"]
assert entitlements["keychain-access-groups"] == [f"{team_id}.com.openburnbar.app"]
PY

nested_line="$(grep -nF "$contents_path/Frameworks/Nested.framework" "$codesign_log" | head -n 1 | cut -d: -f1)"
appex_line="$(grep -nF -- "--entitlements" "$codesign_log" | tail -n 1 | cut -d: -f1)"
if [[ -z "$nested_line" || -z "$appex_line" || "$nested_line" -ge "$appex_line" ]]; then
  echo "FAIL: nested Safari code was not signed before the appex." >&2
  cat "$codesign_log" >&2
  exit 1
fi
if [[ ! -s "$profile_verifier_log" ]]; then
  echo "FAIL: Safari signing/profile certificate membership verifier was not invoked." >&2
  exit 1
fi
if ! grep -Fq -- "--verify --strict --verbose=4 $MOCK_NESTED_PATH" "$codesign_log"; then
  echo "FAIL: nested Safari code was signed but not explicitly verified." >&2
  cat "$codesign_log" >&2
  exit 1
fi

bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" \
  direct \
  "$team_id" \
  "$profile_path"

python3 - "$signed_entitlements_path" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    entitlements = plistlib.load(file)
entitlements["com.apple.security.application-groups"] = []
with path.open("wb") as file:
    plistlib.dump(entitlements, file)
PY
assert_fails_with \
  "signed Safari App Groups must include 'group.com.openburnbar.app'" \
  bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" direct "$team_id"
cp "$good_entitlements_path" "$signed_entitlements_path"

export MOCK_NESTED_CODESIGN_TEAM="AAAAAAAAAA"
assert_fails_with \
  "Nested Safari code must belong to Apple team $team_id" \
  bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" direct "$team_id"
export MOCK_NESTED_CODESIGN_TEAM="$team_id"

python3 - "$resources_path/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["permissions"].remove("nativeMessaging")
path.write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")
PY
assert_fails_with \
  "Safari manifest permissions must include 'nativeMessaging'" \
  bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" direct "$team_id"

python3 - "$resources_path/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["permissions"].append("nativeMessaging")
path.write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")
PY

python3 - "$resources_path/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["host_permissions"].append("<all_urls>")
path.write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")
PY
assert_fails_with \
  "Safari persistent host permissions must be exactly" \
  bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" direct "$team_id"

python3 - "$resources_path/manifest.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
manifest = json.loads(path.read_text(encoding="utf-8"))
manifest["host_permissions"].remove("<all_urls>")
path.write_text(f"{json.dumps(manifest, indent=2)}\n", encoding="utf-8")
PY

export MOCK_CODESIGN_TEAM="AAAAAAAAAA"
assert_fails_with \
  "Safari extension signature must belong to Apple team $team_id" \
  bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" direct "$team_id"
export MOCK_CODESIGN_TEAM="$team_id"

python3 - "$embedded_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile.pop("ProvisionsAllDevices", None)
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
export MOCK_CODESIGN_AUTHORITY="Apple Distribution: OpenBurnBar Test ($team_id)"
bash "$repo_root/scripts/ci/verify-openburnbar-safari-extension.sh" \
  "$app_path" \
  mas \
  "$team_id"

echo "PASS: Safari extension signing/verifier rejects identity, entitlement, manifest, ordering, and distribution regressions"
