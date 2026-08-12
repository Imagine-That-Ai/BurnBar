#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-mas-upload-test.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

pkg="$work_dir/OpenBurnBar.pkg"
archive="$work_dir/OpenBurnBar.xcarchive"
app="$archive/Products/Applications/OpenBurnBar.app"
appex="$app/Contents/PlugIns/OpenBurnBarSafariExtension.appex"
evidence="$work_dir/evidence"
mock_bin="$work_dir/mock-bin"
xcrun_log="$work_dir/xcrun.log"
git_log="$work_dir/git.log"
key_id="KEY123"
secret="-----BEGIN PRIVATE KEY-----TEST-SECRET-----END PRIVATE KEY-----"
mkdir -p "$appex" "$mock_bin"
printf 'package\n' > "$pkg"
printf 'app\n' > "$app/binary"
printf 'appex\n' > "$appex/extension-binary"

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
chmod +x "$mock_bin/git" "$mock_bin/xcrun"

export PATH="$mock_bin:$PATH"
export XCRUN_LOG="$xcrun_log"
export GIT_LOG="$git_log"
export AUTH_DIR_CAPTURE="$work_dir/auth-dir.txt"
export APP_STORE_ASC_KEY_ID="$key_id"
export APP_STORE_ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
export APP_STORE_ASC_KEY_P8="$secret"
export OPENBURNBAR_ASC_APPLE_ID="1234567890"
export OPENBURNBAR_GIT_BIN="$mock_bin/git"

bash "$repo_root/scripts/ci/upload-openburnbar-mas-and-verify.sh" \
  "$pkg" \
  "$archive" \
  "$app" \
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
PY

auth_dir="$(cat "$AUTH_DIR_CAPTURE")"
if [[ -d "$auth_dir" ]]; then
  echo "FAIL: ephemeral App Store Connect key directory survived cleanup." >&2
  exit 1
fi

dirty_evidence="$work_dir/dirty-evidence"
set +e
MOCK_GIT_STATUS=" M candidate.txt" \
  bash "$repo_root/scripts/ci/upload-openburnbar-mas-and-verify.sh" \
    "$pkg" \
    "$archive" \
    "$app" \
    "1.2.3" \
    "456" \
    "1111111111111111111111111111111111111111" \
    "2222222222222222222222222222222222222222" \
    "$dirty_evidence" \
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
bash "$repo_root/scripts/ci/upload-openburnbar-mas-and-verify.sh" \
  "$pkg" "$archive" "$app" "1.2.3" "456" \
  "1111111111111111111111111111111111111111" \
  "2222222222222222222222222222222222222222" \
  "$existing_evidence" \
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
bash "$repo_root/scripts/ci/upload-openburnbar-mas-and-verify.sh" \
  "$pkg" "$archive" "$app" "1.2.3" "456" \
  "1111111111111111111111111111111111111111" \
  "2222222222222222222222222222222222222222" \
  "$symlink_evidence" \
  >"$work_dir/symlink.stdout" \
  2>"$work_dir/symlink.stderr"
symlink_status=$?
set -e
if [[ "$symlink_status" -eq 0 ]]; then
  echo "FAIL: symlinked App Store Connect evidence directory was accepted." >&2
  exit 1
fi
grep -Fq "must not already exist" "$work_dir/symlink.stderr"

echo "PASS: App Store upload orchestration uses an owner-only ephemeral key and emits sanitized processed/readback evidence."
