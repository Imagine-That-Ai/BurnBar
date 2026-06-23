#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
repo_root="$(pwd)"

tmpdir="$(mktemp -d)"
restore_paths=(
  "AgentLens/Resources/GoogleService-Info.plist"
  "OpenBurnBarMobile/Resources/GoogleService-Info.plist"
  "AgentLens/Resources/.firebase-ci-injected"
  "OpenBurnBarMobile/Resources/.firebase-ci-injected"
)

cleanup() {
  for rel in "${restore_paths[@]}"; do
    rm -f "$rel"
    backup="$tmpdir/backup/${rel}"
    if [[ -f "$backup" ]]; then
      mkdir -p "$(dirname "$rel")"
      mv "$backup" "$rel"
    fi
  done
  rm -rf "$tmpdir"
}
trap cleanup EXIT

for rel in "${restore_paths[@]}"; do
  if [[ -f "$rel" ]]; then
    mkdir -p "$tmpdir/backup/$(dirname "$rel")"
    cp "$rel" "$tmpdir/backup/$rel"
  fi
done

encoded_plist="$(
  python3 - <<'PY'
import base64
import plistlib

payload = {
    "GOOGLE_APP_ID": "1:1234567890:ios:abcdef123456",
    "PROJECT_ID": "burnbar-ci",
    "REVERSED_CLIENT_ID": "com.googleusercontent.apps.1234567890-abcdef",
    "CLIENT_ID": "1234567890-abcdef.apps.googleusercontent.com",
    "FirebaseAppCheckDebugToken": "contaminated-firebase-token",
    "FIRAAppCheckDebugToken": "contaminated-fira-token",
    "OpenBurnBarUseDebugAppCheck": "YES",
}
print(base64.b64encode(plistlib.dumps(payload)).decode())
PY
)"
valid_sentry_dsn='https://public@example.ingest.sentry.io/12345?note=quote%27and%5Cnnewline&marker=$&replacement=%24%7Bnot_code%7D'

assert_clean_plists() {
  python3 - <<'PY'
import plistlib
from pathlib import Path

for rel in (
    "AgentLens/Resources/GoogleService-Info.plist",
    "OpenBurnBarMobile/Resources/GoogleService-Info.plist",
):
    payload = plistlib.loads(Path(rel).read_bytes())
    for key in ("FirebaseAppCheckDebugToken", "FIRAAppCheckDebugToken", "OpenBurnBarUseDebugAppCheck"):
        if key in payload:
            raise SystemExit(f"{rel} still contains {key}")
PY
}

assert_sentry_plists() {
  python3 - "$valid_sentry_dsn" <<'PY'
import plistlib
import sys
from pathlib import Path

expected = sys.argv[1]
for rel in (
    "AgentLens/Resources/GoogleService-Info.plist",
    "OpenBurnBarMobile/Resources/GoogleService-Info.plist",
):
    payload = plistlib.loads(Path(rel).read_bytes())
    if payload.get("sentry.dsn") != expected:
        raise SystemExit(f"{rel} sentry.dsn mismatch: {payload.get('sentry.dsn')!r}")
PY
}

default_env="$tmpdir/github-env-default"
: >"$default_env"
FIREBASE_PLIST_BASE64="$encoded_plist" \
  OPENBURNBAR_SENTRY_DSN="$valid_sentry_dsn" \
  GITHUB_ENV="$default_env" \
  bash "$repo_root/scripts/ci/inject-firebase-config.sh" >"$tmpdir/inject-firebase-config-default.out"
assert_clean_plists
assert_sentry_plists
if [[ -s "$default_env" ]]; then
  echo "FAIL: default injection wrote debug token exports to GITHUB_ENV" >&2
  cat "$default_env" >&2
  exit 1
fi

rm -f AgentLens/Resources/GoogleService-Info.plist OpenBurnBarMobile/Resources/GoogleService-Info.plist
non_repo_env="$tmpdir/github-env-non-repo"
: >"$non_repo_env"
(
  cd "$tmpdir"
  FIREBASE_PLIST_BASE64="$encoded_plist" \
    OPENBURNBAR_SENTRY_DSN="$valid_sentry_dsn" \
    GITHUB_ENV="$non_repo_env" \
    bash "$repo_root/scripts/ci/inject-firebase-config.sh"
) >"$tmpdir/inject-firebase-config-non-repo.out"
assert_clean_plists
assert_sentry_plists

internal_env="$tmpdir/github-env-internal"
: >"$internal_env"
FIREBASE_PLIST_BASE64="$encoded_plist" \
  FIREBASE_APP_CHECK_DEBUG_TOKEN="internal-debug-token" \
  OPENBURNBAR_USE_DEBUG_APP_CHECK=YES \
  GITHUB_ENV="$internal_env" \
  bash "$repo_root/scripts/ci/inject-firebase-config.sh" >"$tmpdir/inject-firebase-config-internal.out"
assert_clean_plists
for expected in \
  "FirebaseAppCheckDebugToken=internal-debug-token" \
  "FIRAAppCheckDebugToken=internal-debug-token" \
  "FIREBASE_APP_CHECK_DEBUG_TOKEN=internal-debug-token" \
  "OPENBURNBAR_USE_DEBUG_APP_CHECK=YES"; do
  if ! grep -qx "$expected" "$internal_env"; then
    echo "FAIL: internal injection did not export expected GitHub env line: $expected" >&2
    cat "$internal_env" >&2
    exit 1
  fi
done

echo "PASS: Firebase config injection strips source debug tokens by default and uses explicit internal export"
