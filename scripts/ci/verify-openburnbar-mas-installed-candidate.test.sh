#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-mas-installed-candidate.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

app="$work_dir/OpenBurnBar.app"
receipt="$app/Contents/_MASReceipt/receipt"
processing="$work_dir/app-store-connect-receipt.json"
output="$work_dir/installed-candidate.json"
artifact_verifier="$work_dir/artifact-verifier"
verification_log="$work_dir/verification.log"
team_id="4Y367DF25B"
commit="1111111111111111111111111111111111111111"
tree="2222222222222222222222222222222222222222"
mkdir -p "$(dirname "$receipt")"
printf 'opaque-store-receipt\n' > "$receipt"
chmod 600 "$receipt"

python3 - "$app/Contents/Info.plist" "$processing" "$commit" "$tree" <<'PY'
import json
import plistlib
import sys
from pathlib import Path

info, receipt, commit, tree = map(Path, sys.argv[1:])
with info.open("wb") as file:
    plistlib.dump(
        {
            "CFBundleIdentifier": "com.openburnbar.app",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "456",
        },
        file,
    )
payload = {
    "schemaVersion": 1,
    "platform": "MAC_OS",
    "status": "processed",
    "processedStatus": "complete",
    "readbackStatus": "valid",
    "deliveryId": "DELIVERY-1",
    "appAppleId": "1234567890",
    "bundleIdentifier": "com.openburnbar.app",
    "version": "1.2.3",
    "build": "456",
    "candidate": {"commit": commit.name, "tree": tree.name},
    "artifacts": {
        "archiveTreeSha256": "a" * 64,
        "hostAppTreeSha256": "b" * 64,
        "safariExtensionTreeSha256": "c" * 64,
        "packageSha256": "d" * 64,
        "packageSize": 42,
    },
    "responses": {
        "validationSha256": "e" * 64,
        "uploadSha256": "f" * 64,
        "deliveryStatusSha256": "1" * 64,
        "exactBuildReadbackSha256": "2" * 64,
    },
    "readbackIdentity": {
        "platform": "MAC_OS",
        "appAppleId": "1234567890",
        "bundleIdentifier": "com.openburnbar.app",
        "version": "1.2.3",
        "build": "456",
    },
}
receipt.write_text(json.dumps(payload) + "\n")
PY
chmod 600 "$processing"

cat > "$artifact_verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$OPENBURNBAR_FIXTURE_VERIFICATION_LOG"
[[ "$1" == "$OPENBURNBAR_FIXTURE_APP" ]]
[[ "$2" == "$OPENBURNBAR_FIXTURE_TEAM" ]]
SH
chmod +x "$artifact_verifier"

OPENBURNBAR_MAS_INSTALLED_ARTIFACT_VERIFIER="$artifact_verifier" \
OPENBURNBAR_FIXTURE_VERIFICATION_LOG="$verification_log" \
OPENBURNBAR_FIXTURE_APP="$app" \
OPENBURNBAR_FIXTURE_TEAM="$team_id" \
  bash "$repo_root/scripts/ci/verify-openburnbar-mas-installed-candidate.sh" \
  "$app" "$team_id" "$processing" "$output"

[[ "$(cat "$verification_log")" == "$app $team_id" ]]
[[ "$(stat -f %Lp "$output")" == "600" ]]
python3 - "$output" "$processing" "$commit" "$tree" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

output, processing, commit, tree = map(Path, sys.argv[1:])
value = json.loads(output.read_text())
assert value["candidateCommit"] == commit.name
assert value["candidateTree"] == tree.name
assert value["appStoreConnect"]["processingReceiptSha256"] == hashlib.sha256(
    processing.read_bytes()
).hexdigest()
assert value["appStoreConnect"]["packageSha256"] == "d" * 64
PY

if OPENBURNBAR_MAS_INSTALLED_ARTIFACT_VERIFIER="$artifact_verifier" \
  OPENBURNBAR_FIXTURE_VERIFICATION_LOG="$verification_log" \
  OPENBURNBAR_FIXTURE_APP="$app" \
  OPENBURNBAR_FIXTURE_TEAM="$team_id" \
  bash "$repo_root/scripts/ci/verify-openburnbar-mas-installed-candidate.sh" \
  "$app" "$team_id" "$processing" "$output" >/dev/null 2>&1; then
  echo "ERROR: installed-candidate verifier overwrote existing evidence." >&2
  exit 1
fi

python3 - "$processing" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
value = json.loads(path.read_text())
value["readbackIdentity"]["build"] = "999"
path.write_text(json.dumps(value) + "\n")
PY
chmod 600 "$processing"
different_output="$work_dir/wrong-build.json"
if OPENBURNBAR_MAS_INSTALLED_ARTIFACT_VERIFIER="$artifact_verifier" \
  OPENBURNBAR_FIXTURE_VERIFICATION_LOG="$verification_log" \
  OPENBURNBAR_FIXTURE_APP="$app" \
  OPENBURNBAR_FIXTURE_TEAM="$team_id" \
  bash "$repo_root/scripts/ci/verify-openburnbar-mas-installed-candidate.sh" \
  "$app" "$team_id" "$processing" "$different_output" >/dev/null 2>&1; then
  echo "ERROR: installed-candidate verifier accepted mismatched returned build identity." >&2
  exit 1
fi
[[ ! -e "$different_output" ]]

echo "PASS: installed MAS lifecycle command binds signature/profile and store receipt proof to exact App Store Connect processing evidence."
