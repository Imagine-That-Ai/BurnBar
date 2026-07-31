#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scanner="$repo_root/scripts/ci/verify-apple-release-firebase-config.sh"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/openburnbar-firebase-config-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

write_google_plist() {
  local app="$1"
  local reversed_client_id="${2:-com.googleusercontent.apps.246956661961-h48alif674cr67ojj4li9og8gbcjinbv}"
  local platform="${3:-macos}"
  local resource_dir
  if [[ "$platform" == "ios" ]]; then
    resource_dir="$app"
  else
    resource_dir="$app/Contents/Resources"
  fi
  mkdir -p "$resource_dir"
  cat >"$resource_dir/GoogleService-Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>GOOGLE_APP_ID</key>
  <string>1:246956661961:macos:abcdef1234567890</string>
  <key>PROJECT_ID</key>
  <string>openburnbar-prod</string>
  <key>REVERSED_CLIENT_ID</key>
  <string>${reversed_client_id}</string>
  <key>CLIENT_ID</key>
  <string>246956661961-h48alif674cr67ojj4li9og8gbcjinbv.apps.googleusercontent.com</string>
  <key>API_KEY</key>
  <string>AIzaSyD-real-looking-public-client-key</string>
</dict>
</plist>
PLIST
}

valid_app="$tmpdir/valid/OpenBurnBar.app"
write_google_plist "$valid_app"
bash "$scanner" "$valid_app" >/dev/null

valid_ios_app="$tmpdir/valid-ios/OpenBurnBarMobile.app"
write_google_plist "$valid_ios_app" \
  "com.googleusercontent.apps.246956661961-h48alif674cr67ojj4li9og8gbcjinbv" \
  "ios"
bash "$scanner" "$valid_ios_app" >/dev/null

missing_app="$tmpdir/missing/OpenBurnBar.app"
mkdir -p "$missing_app/Contents/Resources"
if bash "$scanner" "$missing_app" >/dev/null 2>&1; then
  echo "expected missing GoogleService-Info.plist to fail" >&2
  exit 1
fi

embedded_placeholder_app="$tmpdir/embedded-placeholder/OpenBurnBar.app"
write_google_plist "$embedded_placeholder_app" "com.googleusercontent.apps.YOUR_CLIENT_ID_SUFFIX"
if bash "$scanner" "$embedded_placeholder_app" >/dev/null 2>&1; then
  echo "expected embedded Firebase placeholder to fail" >&2
  exit 1
fi

debug_flag_app="$tmpdir/debug-flag/OpenBurnBar.app"
write_google_plist "$debug_flag_app"
python3 - "$debug_flag_app/Contents/Resources/GoogleService-Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
payload = plistlib.loads(path.read_bytes())
payload["OpenBurnBarUseDebugAppCheck"] = True
path.write_bytes(plistlib.dumps(payload))
PY
if bash "$scanner" "$debug_flag_app" >/dev/null 2>&1; then
  echo "expected debug App Check flag to fail" >&2
  exit 1
fi

missing_ios_app="$tmpdir/missing-ios/OpenBurnBarMobile.app"
mkdir -p "$missing_ios_app"
if bash "$scanner" "$missing_ios_app" >/dev/null 2>&1; then
  echo "expected missing iOS GoogleService-Info.plist to fail" >&2
  exit 1
fi

echo "PASS: Apple Firebase release config scanner macOS/iOS positive and negative controls"
