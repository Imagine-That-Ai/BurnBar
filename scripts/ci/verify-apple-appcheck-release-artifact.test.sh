#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

scanner="scripts/ci/verify-apple-appcheck-release-artifact.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

write_plist() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
items = sys.argv[2:]
payload = {}
for index in range(0, len(items), 2):
    key = items[index]
    value = items[index + 1]
    if value == "__TRUE__":
        payload[key] = True
    elif value == "__FALSE__":
        payload[key] = False
    else:
        payload[key] = value
path.parent.mkdir(parents=True, exist_ok=True)
path.write_bytes(plistlib.dumps(payload))
PY
}

make_app() {
  local app="$1"
  mkdir -p "$app/Contents/Resources"
  write_plist "$app/Contents/Info.plist" \
    CFBundleIdentifier com.openburnbar.app \
    OpenBurnBarDirectUpdateFeedURL https://downloads.burnbar.ai/latest-macos.json \
    SUFeedURL https://downloads.burnbar.ai/appcast.xml \
    OpenBurnBarUseDebugAppCheck __FALSE__
}

expect_fail_redacted() {
  local expected="$1"
  local forbidden="$2"
  shift 2
  local output="$tmpdir/fail-output.txt"
  if "$scanner" "$@" >"$output" 2>&1; then
    echo "FAIL: scanner unexpectedly passed: $*" >&2
    cat "$output" >&2
    exit 1
  fi
  if ! grep -q "$expected" "$output"; then
    echo "FAIL: scanner output did not include expected key '$expected'" >&2
    cat "$output" >&2
    exit 1
  fi
  if [[ -n "$forbidden" ]] && grep -q "$forbidden" "$output"; then
    echo "FAIL: scanner output leaked a forbidden value" >&2
    cat "$output" >&2
    exit 1
  fi
}

clean_app="$tmpdir/Clean/OpenBurnBar.app"
make_app "$clean_app"
"$scanner" "$clean_app" >/dev/null

for key in FirebaseAppCheckDebugToken FIRAAppCheckDebugToken; do
  token_app="$tmpdir/${key}/OpenBurnBar.app"
  make_app "$token_app"
  write_plist "$token_app/Contents/Resources/GoogleService-Info.plist" "$key" "super-secret-$key"
  expect_fail_redacted "$key" "super-secret-$key" "$token_app"
done

flag_app="$tmpdir/TruthyFlag/OpenBurnBar.app"
make_app "$flag_app"
write_plist "$flag_app/Contents/Info.plist" \
  CFBundleIdentifier com.openburnbar.app \
  OpenBurnBarDirectUpdateFeedURL https://downloads.burnbar.ai/latest-macos.json \
  SUFeedURL https://downloads.burnbar.ai/appcast.xml \
  OpenBurnBarUseDebugAppCheck YES
expect_fail_redacted OpenBurnBarUseDebugAppCheck YES "$flag_app"

zip_root="$tmpdir/ZipRoot"
zip_app="$zip_root/OpenBurnBar.app"
make_app "$zip_app"
write_plist "$zip_app/Contents/Resources/GoogleService-Info.plist" FirebaseAppCheckDebugToken zip-secret
zip_path="$tmpdir/OpenBurnBar.zip"
if command -v ditto >/dev/null 2>&1; then
  (cd "$zip_root" && ditto -c -k --keepParent OpenBurnBar.app "$zip_path")
else
  (cd "$zip_root" && zip -qry "$zip_path" OpenBurnBar.app)
fi
expect_fail_redacted FirebaseAppCheckDebugToken zip-secret "$zip_path"

if command -v hdiutil >/dev/null 2>&1; then
  dmg_root="$tmpdir/DmgRoot"
  dmg_app="$dmg_root/OpenBurnBar.app"
  make_app "$dmg_app"
  write_plist "$dmg_app/Contents/Resources/GoogleService-Info.plist" FIRAAppCheckDebugToken dmg-secret
  dmg_path="$tmpdir/OpenBurnBar.dmg"
  if hdiutil create -quiet -volname OpenBurnBar -srcfolder "$dmg_root" -ov -format UDZO "$dmg_path"; then
    expect_fail_redacted FIRAAppCheckDebugToken dmg-secret "$dmg_path"
  else
    echo "SKIP: hdiutil could not create a synthetic DMG in this environment"
  fi
fi

archive_path="$tmpdir/OpenBurnBar.xcarchive"
archive_app="$archive_path/Products/Applications/OpenBurnBar.app"
make_app "$archive_app"
write_plist "$archive_app/Contents/Resources/GoogleService-Info.plist" FirebaseAppCheckDebugToken archive-secret
expect_fail_redacted FirebaseAppCheckDebugToken archive-secret "$archive_path"

export_path="$tmpdir/export"
export_app="$export_path/OpenBurnBar.app"
make_app "$export_app"
write_plist "$export_app/Contents/Info.plist" \
  CFBundleIdentifier com.openburnbar.app \
  OpenBurnBarDirectUpdateFeedURL https://downloads.burnbar.ai/latest-macos.json \
  SUFeedURL https://downloads.burnbar.ai/appcast.xml \
  OpenBurnBarUseDebugAppCheck __TRUE__
expect_fail_redacted OpenBurnBarUseDebugAppCheck "" "$export_path"

legacy_feed_app="$tmpdir/LegacyFeed/OpenBurnBar.app"
make_app "$legacy_feed_app"
write_plist "$legacy_feed_app/Contents/Info.plist" \
  CFBundleIdentifier com.openburnbar.app \
  OpenBurnBarDirectUpdateFeedURL https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/latest-macos.json \
  SUFeedURL https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/appcast.xml \
  OpenBurnBarUseDebugAppCheck __FALSE__
expect_fail_redacted OpenBurnBarDirectUpdateFeedURL "" "$legacy_feed_app"

echo "PASS: Apple App Check release artifact scanner positive controls"
