#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

guard="scripts/ci/verify-apple-appcheck-release-env.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

clean_plist="$(
  python3 - <<'PY'
import base64
import plistlib

payload = {
    "GOOGLE_APP_ID": "1:1234567890:ios:abcdef123456",
    "PROJECT_ID": "burnbar-ci",
    "REVERSED_CLIENT_ID": "com.googleusercontent.apps.1234567890-abcdef",
}
print(base64.b64encode(plistlib.dumps(payload)).decode())
PY
)"

dirty_plist="$(
  python3 - <<'PY'
import base64
import plistlib

payload = {
    "GOOGLE_APP_ID": "1:1234567890:ios:abcdef123456",
    "PROJECT_ID": "burnbar-ci",
    "REVERSED_CLIENT_ID": "com.googleusercontent.apps.1234567890-abcdef",
    "FirebaseAppCheckDebugToken": "super-secret-debug-token",
    "Nested": {
        "FIRAAppCheckDebugToken": "nested-secret-debug-token",
        "OpenBurnBarUseDebugAppCheck": "YES",
    },
}
print(base64.b64encode(plistlib.dumps(payload)).decode())
PY
)"

FIREBASE_PLIST_BASE64="$clean_plist" "$guard" >"$tmpdir/pass.out"

expect_fail_redacted() {
  local label="$1"
  local forbidden="$2"
  shift 2
  local output="$tmpdir/${label}.out"

  if "$@" >"$output" 2>&1; then
    echo "FAIL: guard unexpectedly passed for $label" >&2
    cat "$output" >&2
    exit 1
  fi
  if [[ -n "$forbidden" ]] && grep -q "$forbidden" "$output"; then
    echo "FAIL: guard leaked forbidden value for $label" >&2
    cat "$output" >&2
    exit 1
  fi
}

expect_fail_redacted \
  debug-flag \
  "" \
  env OPENBURNBAR_USE_DEBUG_APP_CHECK=YES "$guard"

expect_fail_redacted \
  token-env \
  super-secret-env-token \
  env FIREBASE_APP_CHECK_DEBUG_TOKEN=super-secret-env-token "$guard"

expect_fail_redacted \
  plist-token \
  super-secret-debug-token \
  env FIREBASE_PLIST_BASE64="$dirty_plist" "$guard"

echo "PASS: Apple App Check public release env guard"
