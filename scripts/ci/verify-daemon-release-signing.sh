#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?Usage: verify-daemon-release-signing.sh <OpenBurnBar.app> [expected-team-id]}"
expected_team_id="${2:-}"
daemon_path="$app_path/Contents/Helpers/OpenBurnBarDaemon"
watchdog_path="$app_path/Contents/Helpers/OpenBurnBarPrivilegedInputKillSwitchWatchdog"

if [[ ! -d "$app_path" || ! -x "$daemon_path" || ! -x "$watchdog_path" ]]; then
  echo "ERROR: OpenBurnBar app, daemon, or kill-switch watchdog is missing: $app_path" >&2
  exit 1
fi

signature_field() {
  local path="$1"
  local field="$2"
  codesign -d --verbose=4 "$path" 2>&1 | sed -n "s/^${field}=//p" | head -n 1
}

designated_requirement() {
  codesign -dr - "$1" 2>&1 \
    | sed -n -e 's/^designated => //p' -e 's/^# designated => //p' \
    | head -n 1
}

authority_chain() {
  sed -n 's/^Authority=//p'
}

codesign --verify --strict --verbose=2 "$app_path"
codesign --verify --strict --verbose=2 "$daemon_path"

app_identifier="$(signature_field "$app_path" Identifier)"
daemon_identifier="$(signature_field "$daemon_path" Identifier)"
app_team_id="$(signature_field "$app_path" TeamIdentifier)"
daemon_team_id="$(signature_field "$daemon_path" TeamIdentifier)"
app_signature="$(codesign -d --verbose=4 "$app_path" 2>&1)"
daemon_signature="$(codesign -d --verbose=4 "$daemon_path" 2>&1)"
watchdog_signature="$(codesign -d --verbose=4 "$watchdog_path" 2>&1)"
app_authority_chain="$(authority_chain <<<"$app_signature")"
daemon_authority_chain="$(authority_chain <<<"$daemon_signature")"

if [[ "$app_identifier" != "com.openburnbar.app" ]]; then
  echo "ERROR: App must use signing identifier com.openburnbar.app; found '$app_identifier'." >&2
  exit 1
fi
if [[ "$daemon_identifier" != "com.openburnbar.daemon" ]]; then
  echo "ERROR: Daemon must use signing identifier com.openburnbar.daemon; found '$daemon_identifier'." >&2
  exit 1
fi
if [[ -z "$app_team_id" || -z "$daemon_team_id" || "$daemon_team_id" != "$app_team_id" ]]; then
  echo "ERROR: App and daemon are signed by different teams; app='${app_team_id:-missing}' daemon='${daemon_team_id:-missing}'." >&2
  exit 1
fi
if [[ -n "$expected_team_id" && "$app_team_id" != "$expected_team_id" ]]; then
  echo "ERROR: App and daemon must be signed by team $expected_team_id; found '${app_team_id:-missing}'." >&2
  exit 1
fi
if [[ -n "$app_authority_chain" || -n "$daemon_authority_chain" ]]; then
  if [[ -z "$app_authority_chain" || -z "$daemon_authority_chain" || "$daemon_authority_chain" != "$app_authority_chain" ]]; then
    echo "ERROR: App and daemon must have the same ordered signing-certificate authority chain." >&2
    echo "app authorities: ${app_authority_chain:-missing}" >&2
    echo "daemon authorities: ${daemon_authority_chain:-missing}" >&2
    exit 1
  fi
fi
if ! grep -q 'flags=.*runtime' <<<"$app_signature" || ! grep -q 'flags=.*library-validation' <<<"$app_signature"; then
  echo "ERROR: App must use hardened runtime and library validation so the daemon can authenticate its RPC peer." >&2
  printf '%s\n' "$app_signature" >&2
  exit 1
fi
if ! grep -q 'flags=.*runtime' <<<"$daemon_signature" || ! grep -q 'flags=.*library-validation' <<<"$daemon_signature"; then
  echo "ERROR: Daemon must use hardened runtime and library validation." >&2
  printf '%s\n' "$daemon_signature" >&2
  exit 1
fi

watchdog_identifier="$(signature_field "$watchdog_path" Identifier)"
watchdog_team_id="$(signature_field "$watchdog_path" TeamIdentifier)"
if [[ "$watchdog_identifier" != "com.openburnbar.privileged-input-killswitch-watchdog" ]]; then
  echo "ERROR: Kill-switch watchdog has the wrong signing identifier: '$watchdog_identifier'." >&2
  exit 1
fi
if [[ "$watchdog_team_id" != "$app_team_id" ]]; then
  echo "ERROR: App and kill-switch watchdog are signed by different teams; app='${app_team_id:-missing}' watchdog='${watchdog_team_id:-missing}'." >&2
  exit 1
fi
if ! grep -q 'flags=.*runtime' <<<"$watchdog_signature" || ! grep -q 'flags=.*library-validation' <<<"$watchdog_signature"; then
  echo "ERROR: Kill-switch watchdog must use hardened runtime and library validation." >&2
  printf '%s\n' "$watchdog_signature" >&2
  exit 1
fi
if grep -q '^Authority=Developer ID Application:' <<<"$(codesign -d --verbose=4 "$app_path" 2>&1)"; then
  if ! grep -q '^Authority=Developer ID Application:' <<<"$watchdog_signature" \
    || ! grep -q '^Timestamp=' <<<"$watchdog_signature"; then
    echo "ERROR: Release kill-switch watchdog must have a timestamped Developer ID signature." >&2
    printf '%s\n' "$watchdog_signature" >&2
    exit 1
  fi
fi
codesign --verify --strict --verbose=2 "$watchdog_path"

daemon_entitlements="$(mktemp -t openburnbar-daemon-entitlements.XXXXXX)"
trap 'rm -f "$daemon_entitlements"' EXIT
codesign -d --entitlements :- "$daemon_path" > "$daemon_entitlements" 2>/dev/null
if grep -Eq '<key>(keychain-access-groups|com\.apple\.application-identifier|com\.apple\.developer\.team-identifier)</key>' "$daemon_entitlements"; then
  echo "ERROR: Bare daemon helper has restricted identity/Keychain entitlements; macOS will kill it before main()." >&2
  cat "$daemon_entitlements" >&2
  exit 1
fi

if [[ "$app_team_id" != "not set" ]]; then
  app_requirement="$(designated_requirement "$app_path")"
  daemon_requirement="$(designated_requirement "$daemon_path")"
  if [[ -z "$app_requirement" || -z "$daemon_requirement" ]]; then
    echo "ERROR: App and daemon must each have a designated requirement." >&2
    echo "app: ${app_requirement:-missing}" >&2
    echo "daemon: ${daemon_requirement:-missing}" >&2
    exit 1
  fi
fi

python3 - "$daemon_path" <<'PY'
import subprocess
import sys

daemon = sys.argv[1]
try:
    result = subprocess.run(
        [daemon, "--help"],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
except subprocess.TimeoutExpired as error:
    raise SystemExit(f"ERROR: Signed daemon did not finish --help within 10 seconds: {error}")

output = result.stdout + result.stderr
if result.returncode != 0 or "Usage: OpenBurnBarDaemon" not in output:
    raise SystemExit(
        f"ERROR: Signed daemon failed executable launch gate (exit {result.returncode}).\n{output}"
    )
PY

echo "PASS: signed daemon launches with its fixed identifier and shared trusted signing chain; release watchdog trust is valid"
