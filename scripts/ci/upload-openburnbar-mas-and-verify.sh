#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/exact-candidate-git.sh
source "$repo_root/scripts/lib/exact-candidate-git.sh"
openburnbar_configure_exact_candidate_git "$repo_root"

if [[ $# -ne 10 ]]; then
  echo "usage: $0 PKG ARCHIVE APP ARTIFACT_RECEIPT TEAM_ID VERSION BUILD CANDIDATE_COMMIT CANDIDATE_TREE OUTPUT_DIR" >&2
  exit 64
fi

pkg="$1"
archive="$2"
app="$3"
artifact_receipt="$4"
team_id="$5"
version="$6"
build="$7"
candidate_commit="$8"
candidate_tree="$9"
output_dir="${10}"
key_id="${APP_STORE_ASC_KEY_ID:-${ASC_KEY_ID:-}}"
issuer_id="${APP_STORE_ASC_ISSUER_ID:-${ASC_ISSUER_ID:-}}"
app_apple_id="${OPENBURNBAR_ASC_APPLE_ID:-${APP_STORE_ASC_APPLE_ID:-}}"
key_source="${APP_STORE_ASC_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
key_payload="${APP_STORE_ASC_KEY_P8:-}"

if [[ ! -f "$pkg" || -L "$pkg" ]]; then
  echo "ERROR: App Store package must be a real file: $pkg" >&2
  exit 66
fi
if [[ ! -d "$archive" || -L "$archive" ]]; then
  echo "ERROR: App Store archive must be a real directory: $archive" >&2
  exit 66
fi
if [[ ! -d "$app" || -L "$app" ]]; then
  echo "ERROR: App Store app must be a real directory: $app" >&2
  exit 66
fi
if [[ ! -f "$artifact_receipt" || -L "$artifact_receipt" ]]; then
  echo "ERROR: MAS archive/export receipt must be a real file: $artifact_receipt" >&2
  exit 66
fi
if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: App Store upload team ID must be exactly 10 uppercase letters/digits." >&2
  exit 64
fi
if [[ ! "$candidate_commit" =~ ^[0-9a-f]{40}$ \
  || ! "$candidate_tree" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: App Store upload candidate commit and tree must be lowercase 40-character Git object IDs." >&2
  exit 64
fi
actual_candidate_commit="$(openburnbar_candidate_git rev-parse 'HEAD^{commit}')"
actual_candidate_tree="$(openburnbar_candidate_git rev-parse 'HEAD^{tree}')"
commit_tree="$(openburnbar_candidate_git rev-parse "$candidate_commit^{tree}")"
if [[ "$actual_candidate_commit" != "$candidate_commit" \
  || "$actual_candidate_tree" != "$candidate_tree" \
  || "$commit_tree" != "$candidate_tree" ]]; then
  echo "ERROR: App Store upload candidate binding does not match the exact Git authority." >&2
  echo "  supplied: $candidate_commit $candidate_tree" >&2
  echo "  actual:   $actual_candidate_commit $actual_candidate_tree" >&2
  exit 1
fi
if [[ -n "$(openburnbar_candidate_git status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "ERROR: App Store upload requires a clean exact candidate checkout." >&2
  exit 1
fi
if [[ ! "$key_id" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "ERROR: APP_STORE_ASC_KEY_ID is required and must be alphanumeric." >&2
  exit 64
fi
if [[ -z "$issuer_id" ]]; then
  echo "ERROR: APP_STORE_ASC_ISSUER_ID is required." >&2
  exit 64
fi
if [[ ! "$app_apple_id" =~ ^[0-9]+$ ]]; then
  echo "ERROR: OPENBURNBAR_ASC_APPLE_ID is required and must be numeric." >&2
  exit 64
fi
if [[ -n "$key_source" && -n "$key_payload" ]]; then
  echo "ERROR: Provide APP_STORE_ASC_KEY_PATH or APP_STORE_ASC_KEY_P8, not both." >&2
  exit 64
fi
if [[ -z "$key_source" && -z "$key_payload" ]]; then
  candidates=(
    "$PWD/private_keys/AuthKey_${key_id}.p8" \
    "$HOME/private_keys/AuthKey_${key_id}.p8" \
    "$HOME/.private_keys/AuthKey_${key_id}.p8" \
    "$HOME/.appstoreconnect/private_keys/AuthKey_${key_id}.p8"
  )
  if [[ -n "${API_PRIVATE_KEYS_DIR:-}" ]]; then
    candidates+=("$API_PRIVATE_KEYS_DIR/AuthKey_${key_id}.p8")
  fi
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" && ! -L "$candidate" ]]; then
      if [[ -n "$key_source" ]]; then
        echo "ERROR: Multiple discoverable App Store Connect keys match AuthKey_${key_id}.p8." >&2
        exit 1
      fi
      key_source="$candidate"
    fi
  done
fi
if [[ -z "$key_source" && -z "$key_payload" ]]; then
  echo "ERROR: App Store Connect private key is unavailable." >&2
  exit 64
fi
if [[ -n "$key_source" && ( ! -s "$key_source" || -L "$key_source" ) ]]; then
  echo "ERROR: App Store Connect key path must be a real file: $key_source" >&2
  exit 66
fi

if [[ "$output_dir" != /* ]]; then
  echo "ERROR: App Store Connect evidence directory must be an absolute fresh path: $output_dir" >&2
  exit 64
fi
if [[ -e "$output_dir" || -L "$output_dir" ]]; then
  echo "ERROR: App Store Connect evidence directory must not already exist: $output_dir" >&2
  exit 66
fi
output_parent="$(dirname "$output_dir")"
if [[ ! -d "$output_parent" || -L "$output_parent" ]]; then
  echo "ERROR: App Store Connect evidence parent must be a real existing directory: $output_parent" >&2
  exit 66
fi
output_parent="$(cd "$output_parent" && pwd -P)"
output_dir="$output_parent/$(basename "$output_dir")"
mkdir -m 700 "$output_dir"
umask 077

artifact_preflight="$output_dir/mas-upload-artifact-preflight.json"
python3 "$repo_root/scripts/ci/verify-openburnbar-mas-app-store-connect.py" upload-preflight \
  --artifact-receipt "$artifact_receipt" \
  --candidate-commit "$candidate_commit" \
  --candidate-tree "$candidate_tree" \
  --team-id "$team_id" \
  --version "$version" \
  --build "$build" \
  --archive "$archive" \
  --app "$app" \
  --pkg "$pkg" \
  --artifact-verifier "$repo_root/scripts/ci/verify-openburnbar-mas-artifact.sh" \
  --output "$artifact_preflight"

tmp_root="${TMPDIR:-/tmp}"
if ! auth_dir="$(mktemp -d "$tmp_root/openburnbar-asc-auth.XXXXXX" 2>/dev/null)"; then
  auth_dir="$(mktemp -d "/tmp/openburnbar-asc-auth.XXXXXX")"
fi
cleanup() {
  rm -rf "$auth_dir"
}
exit_for_signal() {
  local signal_number="$1"
  exit "$((128 + signal_number))"
}
trap cleanup EXIT
trap 'exit_for_signal 1' HUP
trap 'exit_for_signal 2' INT
trap 'exit_for_signal 15' TERM
chmod 700 "$auth_dir"
auth_key="$auth_dir/AuthKey_${key_id}.p8"
if [[ -n "$key_payload" ]]; then
  printf '%s' "$key_payload" > "$auth_key"
else
  cp "$key_source" "$auth_key"
fi
chmod 600 "$auth_key"
if [[ ! -s "$auth_key" ]]; then
  echo "ERROR: App Store Connect private key is empty." >&2
  exit 1
fi
unset APP_STORE_ASC_KEY_P8 APP_STORE_ASC_KEY_PATH ASC_PRIVATE_KEY_PATH
key_payload=""
key_source=""
export API_PRIVATE_KEYS_DIR="$auth_dir"

validation_response="$output_dir/app-store-connect-validation.json"
validation_verification="$output_dir/app-store-connect-validation-verification.json"
upload_response="$output_dir/app-store-connect-upload.json"
upload_verification="$output_dir/app-store-connect-upload-verification.json"
delivery_status="$output_dir/app-store-connect-delivery-status.json"
build_readback="$output_dir/app-store-connect-build-readback.json"
receipt="$output_dir/app-store-connect-receipt.json"

capture_exclusive_response() {
  local output_path="$1"
  shift
  python3 - "$output_path" "$@" <<'PY'
import os
import subprocess
import sys
from pathlib import Path

output = Path(sys.argv[1])
command = sys.argv[2:]
if not command:
    raise SystemExit("response capture command is missing")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(output, flags, 0o600)
try:
    with os.fdopen(descriptor, "wb") as stream:
        completed = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=stream)
        stream.flush()
        os.fsync(stream.fileno())
    if completed.returncode != 0:
        try:
            output.unlink()
        except OSError:
            pass
        raise SystemExit(completed.returncode)
except BaseException:
    try:
        os.close(descriptor)
    except OSError:
        pass
    raise
PY
}

capture_exclusive_response "$validation_response" xcrun altool --validate-app "$pkg" \
  --type macos \
  --api-key "$key_id" \
  --api-issuer "$issuer_id" \
  --output-format json
capture_exclusive_response "$upload_response" xcrun altool --upload-app -f "$pkg" \
  --type macos \
  --api-key "$key_id" \
  --api-issuer "$issuer_id" \
  --output-format json

python3 "$repo_root/scripts/ci/verify-openburnbar-mas-app-store-connect.py" validation \
  --response "$validation_response" \
  --output "$validation_verification"
python3 "$repo_root/scripts/ci/verify-openburnbar-mas-app-store-connect.py" upload \
  --response "$upload_response" \
  --output "$upload_verification"
delivery_id="$(
  python3 - "$upload_verification" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)
delivery_id = value.get("deliveryId")
if not isinstance(delivery_id, str) or not delivery_id:
    raise SystemExit("upload verification contained no delivery ID")
print(delivery_id)
PY
)"

capture_exclusive_response "$delivery_status" xcrun altool --build-status \
  --delivery-id "$delivery_id" \
  --wait \
  --api-key "$key_id" \
  --api-issuer "$issuer_id" \
  --output-format json
capture_exclusive_response "$build_readback" xcrun altool --build-status \
  --apple-id "$app_apple_id" \
  --bundle-version "$build" \
  --bundle-short-version-string "$version" \
  --platform macos \
  --wait \
  --api-key "$key_id" \
  --api-issuer "$issuer_id" \
  --output-format json

python3 "$repo_root/scripts/ci/verify-openburnbar-mas-app-store-connect.py" receipt \
  --validation-response "$validation_response" \
  --upload-response "$upload_response" \
  --delivery-status "$delivery_status" \
  --build-readback "$build_readback" \
  --delivery-id "$delivery_id" \
  --app-apple-id "$app_apple_id" \
  --version "$version" \
  --build "$build" \
  --candidate-commit "$candidate_commit" \
  --candidate-tree "$candidate_tree" \
  --team-id "$team_id" \
  --artifact-receipt "$artifact_receipt" \
  --archive "$archive" \
  --app "$app" \
  --pkg "$pkg" \
  --output "$receipt"

echo "PASS: App Store Connect accepted and processed OpenBurnBar $version ($build)."
echo "Receipt: $receipt"
