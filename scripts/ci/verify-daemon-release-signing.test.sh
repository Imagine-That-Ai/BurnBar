#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
verifier="$repo_root/scripts/ci/verify-daemon-release-signing.sh"
tmpdir="$(mktemp -d -t openburnbar-daemon-signing-test.XXXXXX)"
trap 'rm -rf "$tmpdir"' EXIT

app="$tmpdir/OpenBurnBar.app"
app_executable="$app/Contents/MacOS/OpenBurnBar"
daemon="$app/Contents/Helpers/OpenBurnBarDaemon"
cli="$app/Contents/Helpers/OpenBurnBarCLI"
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
cat > "$tmpdir/cli.c" <<'C'
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--help") == 0) {
    puts("openburnbar-cli <command> [args]");
    return 0;
  }
  return 2;
}
C
write_info_plist() {
  local version="${1:-}"
  local version_keys=""
  if [[ -n "$version" ]]; then
    version_keys="  <key>CFBundleShortVersionString</key><string>$version</string>"
  fi
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.openburnbar.app</string>
  <key>CFBundleExecutable</key><string>OpenBurnBar</string>
$version_keys
</dict></plist>
PLIST
}
write_info_plist
cat > "$tmpdir/restricted.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>keychain-access-groups</key><array><string>TEST.com.openburnbar.app</string></array>
</dict></plist>
PLIST

clang "$tmpdir/app.c" -o "$app_executable"
clang "$tmpdir/daemon.c" -o "$daemon"
clang "$tmpdir/cli.c" -o "$cli"
clang "$tmpdir/app.c" -o "$watchdog"

sign_pair() {
  local daemon_identifier="$1"
  local entitlements="${2:-}"
  local args=(--force --sign - --options "runtime,library" --identifier "$daemon_identifier")
  if [[ -n "$entitlements" ]]; then
    args+=(--entitlements "$entitlements")
  fi
  codesign "${args[@]}" "$daemon" >/dev/null
  codesign \
    --force \
    --sign - \
    --options runtime,library \
    --identifier com.openburnbar.cli \
    "$cli" >/dev/null
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
  local expected_message="${2:-}"
  if "$verifier" "$app" >"$tmpdir/failure.log" 2>&1; then
    echo "FAIL: verifier accepted $description" >&2
    exit 1
  fi
  if [[ -n "$expected_message" ]] && ! grep -Fq "$expected_message" "$tmpdir/failure.log"; then
    echo "FAIL: verifier rejected $description for the wrong reason; expected '$expected_message'." >&2
    cat "$tmpdir/failure.log" >&2
    exit 1
  fi
}

mkdir -p "$tmpdir/mock-bin"
cat > "$tmpdir/mock-bin/codesign" <<'MOCK_CODESIGN'
#!/usr/bin/env bash
set -euo pipefail

path="${!#}"
name="$(basename "$path")"
scenario="${MOCK_CODESIGN_SCENARIO:-valid}"

if [[ "$*" == *"--verify"* ]]; then
  exit 0
fi
if [[ "$*" == *"--entitlements"* ]]; then
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
  exit 0
fi
if [[ "$*" == *"-dr"* ]]; then
  if [[ "$name" == "OpenBurnBarCLI" ]]; then
    printf '%s\n' 'designated => identifier "com.openburnbar.cli" and anchor apple generic'
  else
    printf '%s\n' 'designated => identifier "com.openburnbar.app" and anchor apple generic'
  fi
  exit 0
fi
if [[ "$*" != *"-d"* ]]; then
  echo "unexpected mock codesign invocation: $*" >&2
  exit 64
fi

case "$name" in
  OpenBurnBar.app)
    identifier="com.openburnbar.app"
    team="TEAMAPP001"
    ;;
  OpenBurnBarDaemon)
    identifier="com.openburnbar.app"
    team="$([[ "$scenario" == "mismatched_team" ]] && printf TEAMDAEM01 || printf TEAMAPP001)"
    ;;
  OpenBurnBarCLI)
    identifier="com.openburnbar.cli"
    team="$([[ "$scenario" == "mismatched_cli_team" ]] && printf TEAMCLI0001 || printf TEAMAPP001)"
    ;;
  OpenBurnBarPrivilegedInputKillSwitchWatchdog)
    identifier="com.openburnbar.privileged-input-killswitch-watchdog"
    team="TEAMAPP001"
    ;;
  *)
    echo "unexpected mock signing target: $path" >&2
    exit 64
    ;;
esac

printf 'Identifier=%s\n' "$identifier"
if [[ "$scenario" != "missing_team" ]]; then
  printf 'TeamIdentifier=%s\n' "$team"
fi
printf '%s\n' 'Format=Mach-O thin (arm64)' 'CodeDirectory v=20500 size=1 flags=0x12000(runtime,library-validation)'
if [[ "$name" == "OpenBurnBarDaemon" && "$scenario" == "mismatched_authority" ]] \
  || [[ "$name" == "OpenBurnBarCLI" && "$scenario" == "mismatched_cli_authority" ]]; then
  printf '%s\n' \
    'Authority=Developer ID Application: Different Signer (TEAMAPP001)' \
    'Authority=Developer ID Certification Authority' \
    'Authority=Apple Root CA'
else
  printf '%s\n' \
    'Authority=Developer ID Application: Test Signer (TEAMAPP001)' \
    'Authority=Developer ID Certification Authority' \
    'Authority=Apple Root CA'
fi
printf '%s\n' 'Timestamp=release-test' 'Signature size=9000'
MOCK_CODESIGN
chmod +x "$tmpdir/mock-bin/codesign"

expect_mocked_failure() {
  local scenario="$1"
  local expected_message="$2"
  local description="$3"
  if PATH="$tmpdir/mock-bin:$PATH" MOCK_CODESIGN_SCENARIO="$scenario" \
    "$verifier" "$app" >"$tmpdir/mock-failure.log" 2>&1; then
    echo "FAIL: verifier accepted $description" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" "$tmpdir/mock-failure.log"; then
    echo "FAIL: verifier rejected $description for the wrong reason; expected '$expected_message'." >&2
    cat "$tmpdir/mock-failure.log" >&2
    exit 1
  fi
}

sign_pair com.openburnbar.app
"$verifier" "$app" >/dev/null

codesign --force --sign - --options runtime,library --identifier wrong.cli.identifier "$cli" >/dev/null
codesign --force --sign - --options runtime,library --identifier com.openburnbar.app "$app" >/dev/null
expect_failure \
  "an incorrect daemon CLI signing identifier" \
  "ERROR: Daemon CLI must use the com.openburnbar.cli signing identifier; found 'wrong.cli.identifier'."

sign_pair com.openburnbar.app
codesign --force --sign - --identifier com.openburnbar.cli "$cli" >/dev/null
codesign --force --sign - --options runtime,library --identifier com.openburnbar.app "$app" >/dev/null
expect_failure "a daemon CLI without hardened runtime and library validation"

sign_pair com.openburnbar.app
codesign --force --sign - --options runtime,library --identifier wrong.app.identifier "$app" >/dev/null
expect_failure \
  "an incorrect app signing identifier" \
  "ERROR: App must use the com.openburnbar.app signing identifier; found 'wrong.app.identifier'."

sign_pair com.openburnbar.app
codesign --force --sign - --identifier com.openburnbar.app "$app" >/dev/null
expect_failure "an app without hardened runtime and library validation"

# Shipped releases on the legacy allowlist may keep the pre-shared
# com.openburnbar.daemon identifier; new builds may not.
write_info_plist 1.0.29
sign_pair com.openburnbar.daemon
"$verifier" "$app" >/dev/null

sign_pair com.openburnbar.rogue
expect_failure "a non-legacy daemon identifier on an allowlisted release"

write_info_plist 1.0.99
sign_pair com.openburnbar.daemon
expect_failure "the legacy daemon identifier on a non-allowlisted version"

write_info_plist
sign_pair com.openburnbar.app "$tmpdir/restricted.plist"
expect_failure "a restricted Keychain entitlement on a bare daemon"

sign_pair com.openburnbar.app
codesign --force --sign - --identifier wrong.watchdog.identifier "$watchdog" >/dev/null
codesign --force --sign - --options runtime,library --identifier com.openburnbar.app "$app" >/dev/null
expect_failure "an ad-hoc or incorrectly identified kill-switch watchdog"

sign_pair com.openburnbar.app
expect_mocked_failure \
  mismatched_team \
  "ERROR: App, daemon, and CLI are not signed by the same team; app='TEAMAPP001' daemon='TEAMDAEM01' cli='TEAMAPP001'." \
  "different app and daemon Team IDs"
expect_mocked_failure \
  mismatched_cli_team \
  "ERROR: App, daemon, and CLI are not signed by the same team; app='TEAMAPP001' daemon='TEAMAPP001' cli='TEAMCLI0001'." \
  "different app and daemon CLI Team IDs"
expect_mocked_failure \
  missing_team \
  "ERROR: App, daemon, and CLI are not signed by the same team; app='missing' daemon='missing' cli='missing'." \
  "missing app, daemon, and CLI Team IDs"
expect_mocked_failure \
  mismatched_authority \
  "ERROR: App, daemon, and CLI must have the same ordered signing-certificate authority chain." \
  "different app and daemon certificate authority chains"
expect_mocked_failure \
  mismatched_cli_authority \
  "ERROR: App, daemon, and CLI must have the same ordered signing-certificate authority chain." \
  "different app and daemon CLI certificate authority chains"

cat > "$tmpdir/daemon.c" <<'C'
int main(void) { return 7; }
C
clang "$tmpdir/daemon.c" -o "$daemon"
sign_pair com.openburnbar.app
expect_failure "a signed daemon that cannot execute its --help contract"

cat > "$tmpdir/cli.c" <<'C'
int main(void) { return 9; }
C
clang "$tmpdir/cli.c" -o "$cli"
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
clang "$tmpdir/daemon.c" -o "$daemon"
sign_pair com.openburnbar.app
expect_failure "a signed daemon CLI that cannot execute its --help contract"

echo "PASS: daemon release signing verifier rejects daemon/CLI identity, entitlement, and launch regressions"
