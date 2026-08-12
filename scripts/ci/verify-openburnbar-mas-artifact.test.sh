#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-mas-artifact-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

team_id="4Y367DF25B"
app="$work_dir/OpenBurnBar.app"
appex="$app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
pkg="$work_dir/OpenBurnBar.pkg"
host_entitlements="$work_dir/host-entitlements.plist"
host_profile="$app/Contents/embedded.provisionprofile"
appex_profile="$appex/Contents/embedded.provisionprofile"
mock_bin="$work_dir/mock-bin"
mock_log="$work_dir/mock.log"
mkdir -p "$app/Contents" "$appex/Contents" "$mock_bin"
printf 'pkg\n' > "$pkg"

python3 - \
  "$app/Contents/Info.plist" \
  "$host_entitlements" \
  "$host_profile" \
  "$appex_profile" \
  "$team_id" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

info_path, entitlements_path, host_profile_path, appex_profile_path, team_id = sys.argv[1:]
app_group = "group.com.openburnbar.app"
keychain_group = f"{team_id}.com.openburnbar.app"
host_entitlements = {
    "com.apple.application-identifier": f"{team_id}.com.openburnbar.app",
    "com.apple.developer.team-identifier": team_id,
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
    "com.apple.security.application-groups": [app_group],
    "keychain-access-groups": [keychain_group],
    "com.apple.developer.applesignin": ["Default"],
    "com.apple.security.get-task-allow": False,
}


def profile(bundle_id: str, *, get_task_allow: bool | None = None) -> dict:
    entitlements = {
        "com.apple.application-identifier": f"{team_id}.{bundle_id}",
        "com.apple.developer.team-identifier": team_id,
        "com.apple.security.application-groups": [app_group],
        "keychain-access-groups": [keychain_group],
    }
    if get_task_allow is not None:
        entitlements["com.apple.security.get-task-allow"] = get_task_allow
    return {
        "ExpirationDate": dt.datetime(2099, 1, 1, tzinfo=dt.timezone.utc),
        "Platform": ["OSX"],
        "TeamIdentifier": [team_id],
        "DeveloperCertificates": [b"fixture-cert"],
        "Entitlements": entitlements,
    }


with Path(info_path).open("wb") as file:
    plistlib.dump(
        {
            "CFBundleIdentifier": "com.openburnbar.app",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        },
        file,
    )
with Path(entitlements_path).open("wb") as file:
    plistlib.dump(host_entitlements, file)
with Path(host_profile_path).open("wb") as file:
    plistlib.dump(profile("com.openburnbar.app"), file)
with Path(appex_profile_path).open("wb") as file:
    plistlib.dump(profile("com.openburnbar.app.safari-extension"), file)
PY

cat > "$mock_bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "$MOCK_LOG"
if [[ " $* " == *" --verify "* ]]; then
  exit 0
fi
if [[ "$1" == "-d" && " $* " == *" --entitlements :- "* ]]; then
  cat "$MOCK_HOST_ENTITLEMENTS"
  exit 0
fi
if [[ "$1" == "-dv" ]]; then
  cat <<EOF
Identifier=${MOCK_HOST_IDENTIFIER:-com.openburnbar.app}
Authority=${MOCK_HOST_AUTHORITY:-Apple Distribution: OpenBurnBar Test ($MOCK_TEAM)}
TeamIdentifier=$MOCK_TEAM
flags=0x30000(runtime,library-validation)
EOF
  exit 0
fi
exit 99
SH

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
cat "$input"
SH

cat > "$mock_bin/pkgutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'pkgutil %s\n' "$*" >> "$MOCK_LOG"
cat <<EOF
Package "OpenBurnBar.pkg":
   Status: signed by a certificate trusted by macOS
   Certificate Chain:
    1. Apple Distribution: OpenBurnBar Test ($MOCK_TEAM)
EOF
SH

cat > "$mock_bin/spctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'spctl %s\n' "$*" >> "$MOCK_LOG"
echo "accepted"
SH

cat > "$work_dir/profile-verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'profile-verifier %s\n' "$*" >> "$MOCK_LOG"
SH

cat > "$work_dir/safari-verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'safari-verifier %s\n' "$*" >> "$MOCK_LOG"
[[ "$2" == "mas" ]]
SH

chmod +x "$mock_bin/"* "$work_dir/profile-verifier" "$work_dir/safari-verifier"
export PATH="$mock_bin:$PATH"
export MOCK_LOG="$mock_log"
export MOCK_HOST_ENTITLEMENTS="$host_entitlements"
export MOCK_TEAM="$team_id"
export OPENBURNBAR_MAS_PROFILE_CERTIFICATE_VERIFIER="$work_dir/profile-verifier"
export OPENBURNBAR_MAS_SAFARI_VERIFIER="$work_dir/safari-verifier"

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
    echo "FAIL: expected failure containing '$expected'" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

bash "$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh" \
  "$app" "$team_id" "1.2.3" "456" "$pkg"
grep -Fq -- "--deep --strict" "$mock_log"
grep -Fq "profile-verifier $app $host_profile" "$mock_log"
grep -Fq "safari-verifier $app mas $team_id" "$mock_log"
grep -Fq "pkgutil --check-signature $pkg" "$mock_log"
grep -Fq "spctl -a -vv -t install $pkg" "$mock_log"

# Explicit false remains accepted, matching profiles that serialize the value.
python3 - "$host_profile" "$appex_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

for raw_path in sys.argv[1:]:
    path = Path(raw_path)
    with path.open("rb") as file:
        profile = plistlib.load(file)
    profile["Entitlements"]["com.apple.security.get-task-allow"] = False
    with path.open("wb") as file:
        plistlib.dump(profile, file)
PY
bash "$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh" \
  "$app" "$team_id" "1.2.3" "456"

python3 - "$host_profile" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
with path.open("rb") as file:
    profile = plistlib.load(file)
profile["Entitlements"]["com.apple.security.get-task-allow"] = True
with path.open("wb") as file:
    plistlib.dump(profile, file)
PY
assert_fails_with \
  "host App Store profile get-task-allow must be absent or false" \
  bash "$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh" \
  "$app" "$team_id" "1.2.3" "456"

python3 - "$host_profile" <<'PY'
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

export MOCK_HOST_AUTHORITY="Developer ID Application: Wrong ($team_id)"
assert_fails_with \
  "must use an Apple Distribution application certificate" \
  bash "$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh" \
  "$app" "$team_id" "1.2.3" "456"
unset MOCK_HOST_AUTHORITY

python3 - "$host_profile" <<'PY'
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
  "host profile platform must be ['OSX']" \
  bash "$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh" \
  "$app" "$team_id" "1.2.3" "456"

echo "PASS: Mac App Store artifact verifier enforces host/profile/package identity and invokes nested appex verification."
