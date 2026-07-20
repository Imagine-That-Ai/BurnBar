#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
verifier="$repo_root/scripts/ci/verify-daemon-release-signing.sh"
tmpdir="$(mktemp -d -t openburnbar-daemon-signing-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

app="$tmpdir/OpenBurnBar.app"
app_executable="$app/Contents/MacOS/OpenBurnBar"
daemon="$app/Contents/Helpers/OpenBurnBarDaemon"
watchdog="$app/Contents/Helpers/OpenBurnBarPrivilegedInputKillSwitchWatchdog"
mkdir -p "$(dirname "$app_executable")" "$(dirname "$daemon")"

cat > "$tmpdir/app.c" <<'C'
int main(void) { return 0; }
C
cat > "$tmpdir/daemon.c" <<'C'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--help") == 0) {
    puts("Usage: OpenBurnBarDaemon [OPTIONS]");
    return 0;
  }
  return 2;
}
C
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.openburnbar.app</string>
  <key>CFBundleExecutable</key><string>OpenBurnBar</string>
</dict></plist>
PLIST
cat > "$tmpdir/restricted.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>keychain-access-groups</key><array><string>TEST.com.openburnbar.app</string></array>
</dict></plist>
PLIST

clang "$tmpdir/app.c" -o "$app_executable"
clang "$tmpdir/daemon.c" -o "$daemon"
clang "$tmpdir/app.c" -o "$watchdog"

sign_pair() {
  local daemon_identifier="$1"
  local entitlements="${2:-}"
  local args=(--force --sign - --options runtime,library --identifier "$daemon_identifier")
  if [[ -n "$entitlements" ]]; then
    args+=(--entitlements "$entitlements")
  fi
  codesign "${args[@]}" "$daemon" >/dev/null
  codesign \
    --force \
    --sign - \
    --options runtime,library \
    --identifier com.openburnbar.privileged-input-killswitch-watchdog \
    "$watchdog" >/dev/null
  codesign --force --sign - --options runtime,library --identifier com.openburnbar.app "$app" >/dev/null
}

expect_failure() {
  local description="$1"
  if "$verifier" "$app" >"$tmpdir/failure.log" 2>&1; then
    echo "FAIL: verifier accepted $description" >&2
    exit 1
  fi
}

sign_pair com.openburnbar.app
"$verifier" "$app" >/dev/null

sign_pair com.openburnbar.daemon
expect_failure "a different daemon signing identifier"

sign_pair com.openburnbar.app "$tmpdir/restricted.plist"
expect_failure "a restricted Keychain entitlement on a bare daemon"

sign_pair com.openburnbar.app
codesign --force --sign - --identifier wrong.watchdog.identifier "$watchdog" >/dev/null
codesign --force --sign - --options runtime,library --identifier com.openburnbar.app "$app" >/dev/null
expect_failure "an ad-hoc or incorrectly identified kill-switch watchdog"

cat > "$tmpdir/daemon.c" <<'C'
int main(void) { return 7; }
C
clang "$tmpdir/daemon.c" -o "$daemon"
sign_pair com.openburnbar.app
expect_failure "a signed daemon that cannot execute its --help contract"

echo "PASS: daemon release signing verifier rejects identity, entitlement, and launch regressions"
