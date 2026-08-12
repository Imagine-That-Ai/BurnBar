#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/ci/verify-openburnbar-direct-release.sh"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-direct-release-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

team_id="4Y367DF25B"
app_path="$work_dir/OpenBurnBar.app"
appex_path="$app_path/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
host_profile="$work_dir/OpenBurnBar-MAC_APP_DIRECT.provisionprofile"
safari_profile="$work_dir/OpenBurnBarSafariExtension-MAC_APP_DIRECT.provisionprofile"
embedded_host_profile="$app_path/Contents/embedded.provisionprofile"
embedded_safari_profile="$appex_path/Contents/embedded.provisionprofile"
host_entitlements="$work_dir/host-entitlements.plist"
receipt_path="$work_dir/signing-receipt.json"
mock_bin="$work_dir/mock-bin"
verification_log="$work_dir/verification.log"

mkdir -p "$appex_path/Contents" "$mock_bin"

write_fixtures() {
  python3 - \
    "$host_profile" \
    "$safari_profile" \
    "$host_entitlements" \
    "$team_id" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

host_profile_path, safari_profile_path, entitlements_path, team_id = sys.argv[1:]
app_group = "group.com.openburnbar.app"
keychain_group = f"{team_id}.com.openburnbar.app"


def profile(bundle_id: str) -> dict:
    return {
        "CreationDate": dt.datetime(2026, 8, 12, tzinfo=dt.timezone.utc),
        "DeveloperCertificates": [b"authorized-signer"],
        "Entitlements": {
            "com.apple.application-identifier": f"{team_id}.{bundle_id}",
            "com.apple.developer.team-identifier": team_id,
            # Apple may materialize a team wildcard in Developer ID profiles.
            # Exact App Group scope is enforced on the signed code.
            "com.apple.security.application-groups": [f"{team_id}.*"],
            "keychain-access-groups": [f"{team_id}.*"],
        },
        "ExpirationDate": dt.datetime(2099, 8, 12, tzinfo=dt.timezone.utc),
        "Platform": ["OSX"],
        "ProvisionsAllDevices": True,
        "TeamIdentifier": [team_id],
    }


with Path(host_profile_path).open("wb") as file:
    plistlib.dump(profile("com.openburnbar.app"), file)
with Path(safari_profile_path).open("wb") as file:
    plistlib.dump(profile("com.openburnbar.app.safari-extension"), file)
with Path(entitlements_path).open("wb") as file:
    plistlib.dump(
        {
            "com.apple.application-identifier": f"{team_id}.com.openburnbar.app",
            "com.apple.developer.team-identifier": team_id,
            "com.apple.security.app-sandbox": False,
            "com.apple.security.application-groups": [app_group],
            "keychain-access-groups": [keychain_group],
        },
        file,
    )
PY
  cp "$host_profile" "$embedded_host_profile"
  cp "$safari_profile" "$embedded_safari_profile"
}

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

if [[ " $* " == *" --verify "* ]]; then
  exit 0
fi
if [[ "$1" == "-d" && " $* " == *" --entitlements :- "* ]]; then
  cat "$MOCK_HOST_ENTITLEMENTS"
  exit 0
fi
if [[ "$1" == "-dv" ]]; then
  cat <<EOF
Executable=$MOCK_APP_PATH/Contents/MacOS/OpenBurnBar
Identifier=${MOCK_HOST_IDENTIFIER:-com.openburnbar.app}
Authority=${MOCK_HOST_AUTHORITY:-Developer ID Application: OpenBurnBar Test ($MOCK_TEAM_ID)}
TeamIdentifier=${MOCK_HOST_TEAM_ID:-$MOCK_TEAM_ID}
${MOCK_HOST_SIGNATURE_FLAGS:-flags=0x30000(runtime,library-validation)}
${MOCK_HOST_TIMESTAMP:-Timestamp=Aug 12, 2026 at 12:00:00}
EOF
  exit 0
fi
echo "unexpected mock codesign invocation: $*" >&2
exit 98
SH

cat > "$mock_bin/safari-verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf 'safari:%s\n' "$*" >> "$MOCK_VERIFICATION_LOG"
[[ "$2" == "direct" ]]
[[ "$3" == "$MOCK_TEAM_ID" ]]
cmp -s "$4" "$MOCK_SAFARI_PROFILE"
SH

cat > "$mock_bin/profile-verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf 'profile:%s\n' "$*" >> "$MOCK_VERIFICATION_LOG"
[[ "$1" == "$MOCK_APP_PATH" ]]
cmp -s "$2" "$MOCK_HOST_PROFILE"
SH
chmod +x "$mock_bin"/*

export PATH="$mock_bin:$PATH"
export MOCK_APP_PATH="$app_path"
export MOCK_HOST_ENTITLEMENTS="$host_entitlements"
export MOCK_HOST_PROFILE="$host_profile"
export MOCK_SAFARI_PROFILE="$safari_profile"
export MOCK_TEAM_ID="$team_id"
export MOCK_VERIFICATION_LOG="$verification_log"
export OPENBURNBAR_SAFARI_EXTENSION_VERIFIER="$mock_bin/safari-verifier"
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
    echo "FAIL: expected failure text '$expected'." >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_fails() {
  if "$@" >/dev/null 2>&1; then
    echo "FAIL: command unexpectedly passed: $*" >&2
    exit 1
  fi
}

mutate_plist() {
  local path="$1"
  local operation="$2"
  python3 - "$path" "$operation" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
operation = sys.argv[2]
with path.open("rb") as file:
    value = plistlib.load(file)

if operation == "ios-platform":
    value["Platform"] = ["iOS"]
elif operation == "expired":
    value["ExpirationDate"] = dt.datetime(2020, 1, 1, tzinfo=dt.timezone.utc)
elif operation == "get-task-allow":
    value["Entitlements"]["com.apple.security.get-task-allow"] = True
elif operation == "wrong-app-group":
    value["com.apple.security.application-groups"] = ["group.example.wrong"]
else:
    raise SystemExit(f"unknown operation: {operation}")

with path.open("wb") as file:
    plistlib.dump(value, file)
PY
}

write_fixtures
rm -f "$verification_log"
"$verifier" \
  "$app_path" \
  "$team_id" \
  "$host_profile" \
  "$safari_profile" \
  "$receipt_path" >/dev/null

grep -Fq "safari:$app_path direct $team_id $safari_profile" "$verification_log"
grep -Fq "profile:$app_path $embedded_host_profile" "$verification_log"
python3 - "$receipt_path" "$host_profile" "$safari_profile" "$team_id" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

receipt_path, host_profile_path, safari_profile_path, team_id = sys.argv[1:]
receipt = json.loads(Path(receipt_path).read_text(encoding="utf-8"))
assert receipt["distribution"] == "developer-id"
assert receipt["teamId"] == team_id
assert receipt["host"]["profileSha256"] == hashlib.sha256(Path(host_profile_path).read_bytes()).hexdigest()
assert receipt["safariExtension"]["profileSha256"] == hashlib.sha256(
    Path(safari_profile_path).read_bytes()
).hexdigest()
assert receipt["verification"] == {
    "embeddedProfilesByteEqual": True,
    "getTaskAllow": False,
    "platform": "OSX",
    "profileCertificateMembership": True,
    "strictDeepNestedSignatures": True,
}
serialized = Path(receipt_path).read_text(encoding="utf-8")
assert os.stat(receipt_path).st_mode & 0o777 == 0o600
for forbidden in ("PRIVATE KEY", "issuer", "apiKey", "password"):
    assert forbidden not in serialized
PY

printf 'preserve\n' > "$receipt_path"
assert_fails_with \
  "File exists" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile" "$receipt_path"
[[ "$(cat "$receipt_path")" == "preserve" ]]

protected_receipt="$work_dir/protected-signing-receipt.json"
printf 'protected\n' > "$protected_receipt"
ln -sf "$protected_receipt" "$receipt_path"
assert_fails \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile" "$receipt_path"
[[ "$(cat "$protected_receipt")" == "protected" ]]
rm -f "$receipt_path"

printf 'different profile bytes\n' >> "$embedded_host_profile"
assert_fails_with \
  "Embedded host profile differs from the candidate profile" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"

write_fixtures
mutate_plist "$host_profile" ios-platform
cp "$host_profile" "$embedded_host_profile"
assert_fails_with \
  "host profile platform must be ['OSX']" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"

write_fixtures
mutate_plist "$safari_profile" expired
cp "$safari_profile" "$embedded_safari_profile"
assert_fails_with \
  "Safari extension profile expired at" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"

write_fixtures
mutate_plist "$host_profile" get-task-allow
cp "$host_profile" "$embedded_host_profile"
assert_fails_with \
  "host profile must not enable get-task-allow" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"

write_fixtures
mutate_plist "$host_entitlements" wrong-app-group
assert_fails_with \
  "signed host App Groups must be ['group.com.openburnbar.app']" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"

write_fixtures
export MOCK_HOST_TEAM_ID="AAAAAAAAAA"
assert_fails_with \
  "Direct-release host signature must belong to Apple team $team_id" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"
unset MOCK_HOST_TEAM_ID

export MOCK_HOST_SIGNATURE_FLAGS="flags=0x0(none)"
assert_fails_with \
  "Direct-release host must enable hardened runtime and library validation" \
  "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"
unset MOCK_HOST_SIGNATURE_FLAGS

OPENBURNBAR_SAFARI_EXTENSION_VERIFIER=/usr/bin/false \
  assert_fails "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"

OPENBURNBAR_SIGNING_PROFILE_CERTIFICATE_VERIFIER=/usr/bin/false \
  assert_fails "$verifier" "$app_path" "$team_id" "$host_profile" "$safari_profile"

echo "PASS: direct Developer ID verifier rejects profile drift, platform, expiry, entitlement, identity, and runtime regressions"
