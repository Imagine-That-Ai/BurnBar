#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-mas-upload-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

pkg="$work_dir/OpenBurnBar.pkg"
archive="$work_dir/OpenBurnBar.xcarchive"
archive_app="$archive/Products/Applications/OpenBurnBar.app"
archive_appex="$archive_app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
export_inspection="$work_dir/export-inspection"
app="$export_inspection/OpenBurnBar.app"
appex="$app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
artifact_receipt="$work_dir/mas-archive-export-receipt.json"
evidence="$work_dir/evidence"
mock_bin="$work_dir/mock-bin"
xcrun_log="$work_dir/xcrun.log"
git_log="$work_dir/git.log"
key_id="KEY123"
team_id="4Y367DF25B"
secret="-----BEGIN PRIVATE KEY-----TEST-SECRET-----END PRIVATE KEY-----"
host_entitlements="$work_dir/host-entitlements.plist"
mkdir -p \
  "$archive_appex/Contents" \
  "$appex/Contents" \
  "$export_inspection" \
  "$mock_bin"
printf 'package\n' > "$pkg"
printf 'archive app\n' > "$archive_app/binary"
printf 'archive appex\n' > "$archive_appex/extension-binary"
printf 'app\n' > "$app/binary"
printf 'appex\n' > "$appex/extension-binary"

python3 - \
  "$archive_app" \
  "$app" \
  "$host_entitlements" \
  "$team_id" <<'PY'
import datetime as dt
import plistlib
import sys
from pathlib import Path

archive_app, exported_app, entitlements_path, team_id = sys.argv[1:]
app_group = "group.com.openburnbar.app"
keychain_group = f"{team_id}.com.openburnbar.app"
signed_entitlements = {
    "com.apple.application-identifier": f"{team_id}.com.openburnbar.app",
    "com.apple.developer.team-identifier": team_id,
    "com.apple.security.app-sandbox": True,
    "com.apple.security.network.client": True,
    "com.apple.security.application-groups": [app_group],
    "keychain-access-groups": [keychain_group],
    "com.apple.developer.applesignin": ["Default"],
    "com.apple.security.get-task-allow": False,
}


def profile(bundle_id: str) -> dict:
    return {
        "ExpirationDate": dt.datetime(2099, 1, 1, tzinfo=dt.timezone.utc),
        "Platform": ["OSX"],
        "TeamIdentifier": [team_id],
        "DeveloperCertificates": [b"fixture-cert"],
        "Entitlements": {
            "com.apple.application-identifier": f"{team_id}.{bundle_id}",
            "com.apple.developer.team-identifier": team_id,
            "com.apple.security.application-groups": [f"{team_id}.*"],
            "keychain-access-groups": [f"{team_id}.*"],
        },
    }


for raw_app in (archive_app, exported_app):
    app = Path(raw_app)
    appex = app / "Contents" / "PlugIns" / "OpenBurnBarSafariExtension.appex"
    info = app / "Contents" / "Info.plist"
    host_profile = app / "Contents" / "embedded.provisionprofile"
    appex_profile = appex / "Contents" / "embedded.provisionprofile"
    info.parent.mkdir(parents=True, exist_ok=True)
    appex_profile.parent.mkdir(parents=True, exist_ok=True)
    with info.open("wb") as file:
        plistlib.dump(
            {
                "CFBundleIdentifier": "com.openburnbar.app",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "456",
            },
            file,
        )
    with host_profile.open("wb") as file:
        plistlib.dump(profile("com.openburnbar.app"), file)
    with appex_profile.open("wb") as file:
        plistlib.dump(profile("com.openburnbar.app.safari-extension"), file)

with Path(entitlements_path).open("wb") as file:
    plistlib.dump(signed_entitlements, file)
PY

cat > "$mock_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GIT_LOG"
if [[ "${1:-}" == "-C" ]]; then
  repo_root="$2"
  shift 2
fi
case "${1:-}" in
  rev-parse)
    case "${2:-}" in
      --show-toplevel) printf '%s\n' "$repo_root" ;;
      HEAD^{commit}) printf '%s\n' "${MOCK_GIT_COMMIT:-1111111111111111111111111111111111111111}" ;;
      HEAD^{tree}|1111111111111111111111111111111111111111^{tree})
        printf '%s\n' "${MOCK_GIT_TREE:-2222222222222222222222222222222222222222}"
        ;;
      *) echo "unexpected rev-parse: ${2:-}" >&2; exit 97 ;;
    esac
    ;;
  status)
    printf '%s' "${MOCK_GIT_STATUS:-}"
    ;;
  *)
    echo "unexpected git command: $*" >&2
    exit 97
    ;;
esac
SH

cat > "$mock_bin/codesign" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --verify "* ]]; then
  exit 0
fi
if [[ "${1:-}" == "-d" && " $* " == *" --entitlements :- "* ]]; then
  cat "$MOCK_HOST_ENTITLEMENTS"
  exit 0
fi
if [[ "${1:-}" == "-dv" ]]; then
  cat <<EOF
Identifier=com.openburnbar.app
Authority=Apple Distribution: OpenBurnBar Test ($MOCK_TEAM)
TeamIdentifier=$MOCK_TEAM
flags=0x30000(runtime,library-validation)
EOF
  exit 0
fi
echo "unexpected codesign arguments: $*" >&2
exit 97
SH

cat > "$mock_bin/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
for ((index = 0; index < ${#arguments[@]}; index += 1)); do
  if [[ "${arguments[$index]}" == "-i" ]]; then
    cat "${arguments[$((index + 1))]}"
    exit 0
  fi
done
echo "security fixture received no input profile" >&2
exit 97
SH

cat > "$mock_bin/pkgutil" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
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
echo "accepted"
SH

cat > "$mock_bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$XCRUN_LOG"
printf '%s\n' "$API_PRIVATE_KEYS_DIR" > "$AUTH_DIR_CAPTURE"
key_path="$API_PRIVATE_KEYS_DIR/AuthKey_${APP_STORE_ASC_KEY_ID}.p8"
[[ -d "$API_PRIVATE_KEYS_DIR" ]]
[[ "$(stat -f '%Lp' "$API_PRIVATE_KEYS_DIR")" == "700" ]]
[[ -s "$key_path" ]]
[[ "$(stat -f '%Lp' "$key_path")" == "600" ]]
[[ -z "${APP_STORE_ASC_KEY_P8:-}" ]]
[[ -z "${APP_STORE_ASC_KEY_PATH:-}" ]]
case " $* " in
  *" --validate-app "*)
    printf '{"status":"success"}\n'
    ;;
  *" --upload-app "*)
    printf '{"data":{"deliveryId":"DELIVERY-1","requestId":"REQUEST-1"}}\n'
    ;;
  *" --delivery-id "*)
    printf '{"data":{"delivery-status":"Complete"}}\n'
    ;;
  *" --apple-id "*)
    printf '{"data":{"attributes":{"appAppleId":"1234567890","bundleId":"com.openburnbar.app","bundleShortVersionString":"1.2.3","bundleVersion":"456","platform":"MAC_OS","processingState":"VALID"}}}\n'
    ;;
  *)
    echo "unexpected xcrun arguments: $*" >&2
    exit 97
    ;;
esac
SH

cat > "$work_dir/profile-verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SH

cat > "$work_dir/safari-verifier" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$2" == "mas" ]]
SH

chmod +x \
  "$mock_bin/git" \
  "$mock_bin/codesign" \
  "$mock_bin/security" \
  "$mock_bin/pkgutil" \
  "$mock_bin/spctl" \
  "$mock_bin/xcrun" \
  "$work_dir/profile-verifier" \
  "$work_dir/safari-verifier"

export PATH="$mock_bin:$PATH"
export XCRUN_LOG="$xcrun_log"
export GIT_LOG="$git_log"
export AUTH_DIR_CAPTURE="$work_dir/auth-dir.txt"
export APP_STORE_ASC_KEY_ID="$key_id"
export APP_STORE_ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
export APP_STORE_ASC_KEY_P8="$secret"
export OPENBURNBAR_ASC_APPLE_ID="1234567890"
export OPENBURNBAR_GIT_BIN="$mock_bin/git"
export MOCK_HOST_ENTITLEMENTS="$host_entitlements"
export MOCK_TEAM="$team_id"
export OPENBURNBAR_MAS_PROFILE_CERTIFICATE_VERIFIER="$work_dir/profile-verifier"
export OPENBURNBAR_MAS_SAFARI_VERIFIER="$work_dir/safari-verifier"

python3 "$repo_root/scripts/ci/verify-openburnbar-mas-app-store-connect.py" \
  artifact-receipt \
  --candidate-commit "1111111111111111111111111111111111111111" \
  --candidate-tree "2222222222222222222222222222222222222222" \
  --team-id "$team_id" \
  --version "1.2.3" \
  --build "456" \
  --archive "$archive" \
  --archive-app "$archive_app" \
  --export-inspection "$export_inspection" \
  --exported-app "$app" \
  --pkg "$pkg" \
  --artifact-verifier \
    "$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh" \
  --output "$artifact_receipt"

bash "$repo_root/scripts/ci/upload-openburnbar-mas-and-verify.sh" \
  "$pkg" \
  "$archive" \
  "$app" \
  "$artifact_receipt" \
  "$team_id" \
  "1.2.3" \
  "456" \
  "1111111111111111111111111111111111111111" \
  "2222222222222222222222222222222222222222" \
  "$evidence"

receipt="$evidence/app-store-connect-receipt.json"
test -s "$receipt"
test "$(stat -f '%Lp' "$evidence")" = "700"
test "$(stat -f '%Lp' "$receipt")" = "600"
grep -Fq -- "--delivery-id DELIVERY-1 --wait" "$xcrun_log"
grep -Fq -- "--platform macos --wait" "$xcrun_log"
if rg -F "TEST-SECRET" "$evidence" >/dev/null; then
  echo "FAIL: App Store Connect evidence leaked private key material." >&2
  exit 1
fi
python3 - "$receipt" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    receipt = json.load(file)
assert receipt["platform"] == "MAC_OS"
assert receipt["deliveryId"] == "DELIVERY-1"
assert receipt["requestId"] == "REQUEST-1"
assert receipt["readbackQuery"]["platform"] == "macos"
assert receipt["readbackIdentity"] == {
    "appAppleId": "1234567890",
    "bundleIdentifier": "com.openburnbar.app",
    "version": "1.2.3",
    "build": "456",
    "platform": "MAC_OS",
}
assert receipt["candidate"]["commit"] == "1" * 40
assert receipt["candidate"]["tree"] == "2" * 40
assert len(receipt["artifacts"]["archiveExportReceiptSha256"]) == 64
PY

auth_dir="$(cat "$AUTH_DIR_CAPTURE")"
if [[ -d "$auth_dir" ]]; then
  echo "FAIL: ephemeral App Store Connect key directory survived cleanup." >&2
  exit 1
fi

invoke_upload() {
  local output_dir="$1"
  bash "$repo_root/scripts/ci/upload-openburnbar-mas-and-verify.sh" \
    "$pkg" \
    "$archive" \
    "$app" \
    "$artifact_receipt" \
    "$team_id" \
    "1.2.3" \
    "456" \
    "1111111111111111111111111111111111111111" \
    "2222222222222222222222222222222222222222" \
    "$output_dir"
}

dirty_evidence="$work_dir/dirty-evidence"
set +e
MOCK_GIT_STATUS=" M candidate.txt" \
  invoke_upload "$dirty_evidence" \
    >"$work_dir/dirty.stdout" \
    2>"$work_dir/dirty.stderr"
dirty_status=$?
set -e
if [[ "$dirty_status" -eq 0 ]]; then
  echo "FAIL: dirty exact candidate was accepted for App Store upload." >&2
  exit 1
fi
grep -Fq "requires a clean exact candidate checkout" "$work_dir/dirty.stderr"
if [[ -e "$dirty_evidence" ]]; then
  echo "FAIL: dirty candidate reached evidence materialization." >&2
  exit 1
fi

existing_evidence="$work_dir/existing-evidence"
mkdir -m 700 "$existing_evidence"
set +e
invoke_upload "$existing_evidence" \
  >"$work_dir/existing.stdout" \
  2>"$work_dir/existing.stderr"
existing_status=$?
set -e
if [[ "$existing_status" -eq 0 ]]; then
  echo "FAIL: pre-existing App Store Connect evidence directory was accepted." >&2
  exit 1
fi
grep -Fq "must not already exist" "$work_dir/existing.stderr"

symlink_target="$work_dir/symlink-target"
mkdir -m 700 "$symlink_target"
symlink_evidence="$work_dir/symlink-evidence"
ln -s "$symlink_target" "$symlink_evidence"
set +e
invoke_upload "$symlink_evidence" \
  >"$work_dir/symlink.stdout" \
  2>"$work_dir/symlink.stderr"
symlink_status=$?
set -e
if [[ "$symlink_status" -eq 0 ]]; then
  echo "FAIL: symlinked App Store Connect evidence directory was accepted." >&2
  exit 1
fi
grep -Fq "must not already exist" "$work_dir/symlink.stderr"

missing_receipt="$work_dir/missing-receipt.json"
missing_receipt_calls_before="$(wc -l < "$xcrun_log" | tr -d ' ')"
mv "$artifact_receipt" "$missing_receipt"
set +e
invoke_upload "$work_dir/missing-receipt-evidence" \
  >"$work_dir/missing-receipt.stdout" \
  2>"$work_dir/missing-receipt.stderr"
missing_receipt_status=$?
set -e
mv "$missing_receipt" "$artifact_receipt"
if [[ "$missing_receipt_status" -eq 0 ]]; then
  echo "FAIL: MAS upload accepted a missing archive/export receipt." >&2
  exit 1
fi
grep -Fq "MAS archive/export receipt must be a real file" \
  "$work_dir/missing-receipt.stderr"
missing_receipt_calls_after="$(wc -l < "$xcrun_log" | tr -d ' ')"
if [[ "$missing_receipt_calls_after" != "$missing_receipt_calls_before" ]]; then
  echo "FAIL: missing MAS archive/export receipt reached App Store tooling." >&2
  exit 1
fi

cp "$pkg" "$work_dir/pkg.backup"
cp -R "$archive" "$work_dir/archive.backup"
cp -R "$app" "$work_dir/app.backup"

expect_substitution_rejected() {
  local label="$1"
  local mutate="$2"
  local restore="$3"
  local output_dir="$work_dir/substituted-$label-evidence"
  local stdout_path="$work_dir/substituted-$label.stdout"
  local stderr_path="$work_dir/substituted-$label.stderr"
  local calls_before
  local calls_after
  calls_before="$(wc -l < "$xcrun_log" | tr -d ' ')"
  eval "$mutate"
  set +e
  invoke_upload "$output_dir" >"$stdout_path" 2>"$stderr_path"
  local status=$?
  set -e
  eval "$restore"
  if [[ "$status" -eq 0 ]]; then
    echo "FAIL: substituted $label was accepted for App Store upload." >&2
    exit 1
  fi
  grep -Fq "artifact bindings do not match" "$stderr_path"
  calls_after="$(wc -l < "$xcrun_log" | tr -d ' ')"
  if [[ "$calls_after" != "$calls_before" ]]; then
    echo "FAIL: substituted $label reached App Store tooling." >&2
    exit 1
  fi
  if [[ ! -f "$output_dir/mas-upload-artifact-preflight.json" ]]; then
    :
  else
    echo "FAIL: substituted $label emitted a successful artifact preflight." >&2
    exit 1
  fi
}

expect_substitution_rejected \
  "package" \
  "printf 'substituted package\\n' > \"\$pkg\"" \
  "cp \"\$work_dir/pkg.backup\" \"\$pkg\""
expect_substitution_rejected \
  "archive" \
  "printf 'substituted archive\\n' > \"\$archive/substitution-marker\"" \
  "rm -f \"\$archive/substitution-marker\""
expect_substitution_rejected \
  "host-app" \
  "printf 'substituted host\\n' > \"\$app/binary\"" \
  "cp \"\$work_dir/app.backup/binary\" \"\$app/binary\""
expect_substitution_rejected \
  "safari-appex" \
  "printf 'substituted appex\\n' > \"\$appex/extension-binary\"" \
  "cp \"\$work_dir/app.backup/Contents/PlugIns/OpenBurnBarSafariExtension.appex/extension-binary\" \"\$appex/extension-binary\""

echo "PASS: App Store upload is archive/export-receipt-bound, substitution-safe, and emits owner-only sanitized processed/readback evidence."
