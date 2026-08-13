#!/usr/bin/env bash
set -euo pipefail

app_path="${1:?Usage: verify-daemon-release-signing.sh <OpenBurnBar.app> [expected-team-id]}"
expected_team_id="${2:-}"
daemon_path="$app_path/Contents/Helpers/OpenBurnBarDaemon"
execution_path="$app_path/Contents/Helpers/OpenBurnBarPrivilegedInputExecution"
virtual_hid_path="$app_path/Contents/Helpers/OpenBurnBarVirtualHIDBridge"
watchdog_path="$app_path/Contents/Helpers/OpenBurnBarPrivilegedInputKillSwitchWatchdog"

if [[ ! -d "$app_path" ]]; then
  echo "ERROR: OpenBurnBar app is missing: $app_path" >&2
  exit 1
fi
declare -a helper_paths=(
  "$daemon_path"
  "$execution_path"
  "$virtual_hid_path"
  "$watchdog_path"
)
declare -a helper_labels=(
  "daemon"
  "privileged input execution helper"
  "virtual HID bridge"
  "kill-switch watchdog"
)
for ((index = 0; index < ${#helper_paths[@]}; index++)); do
  if [[ ! -x "${helper_paths[$index]}" || -L "${helper_paths[$index]}" ]]; then
    echo "ERROR: OpenBurnBar ${helper_labels[$index]} is missing or symlinked: ${helper_paths[$index]}" >&2
    exit 1
  fi
done

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
for helper_path in "${helper_paths[@]}"; do
  codesign --verify --strict --verbose=2 "$helper_path"
done

app_identifier="$(signature_field "$app_path" Identifier)"
daemon_identifier="$(signature_field "$daemon_path" Identifier)"
app_team_id="$(signature_field "$app_path" TeamIdentifier)"
daemon_team_id="$(signature_field "$daemon_path" TeamIdentifier)"
app_signature="$(codesign -d --verbose=4 "$app_path" 2>&1)"
daemon_signature="$(codesign -d --verbose=4 "$daemon_path" 2>&1)"
execution_signature="$(codesign -d --verbose=4 "$execution_path" 2>&1)"
virtual_hid_signature="$(codesign -d --verbose=4 "$virtual_hid_path" 2>&1)"
watchdog_signature="$(codesign -d --verbose=4 "$watchdog_path" 2>&1)"
app_authority_chain="$(authority_chain <<<"$app_signature")"
daemon_authority_chain="$(authority_chain <<<"$daemon_signature")"

# Releases shipped before the shared daemon signing identifier landed
# sign the daemon as com.openburnbar.daemon. The public trust gate still has
# to verify those immutable artifacts, so accept that identifier only for the
# exact shipped-version allowlist. Every new build must share the app's
# designated requirement so the daemon can read the database-key Keychain ACL.
legacy_daemon_identifier="com.openburnbar.daemon"
legacy_daemon_identifier_versions=" 1.0.24 1.0.25 1.0.26 1.0.29 "

app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist" 2>/dev/null || true)"
legacy_daemon_signing=false
if [[ -n "$app_version" \
  && "$legacy_daemon_identifier_versions" == *" $app_version "* \
  && "$daemon_identifier" == "$legacy_daemon_identifier" ]]; then
  legacy_daemon_signing=true
fi

if [[ "$app_identifier" != "com.openburnbar.app" ]]; then
  echo "ERROR: App must use the com.openburnbar.app signing identifier; found '$app_identifier'." >&2
  exit 1
fi
if [[ "$daemon_identifier" != "$app_identifier" && "$legacy_daemon_signing" != "true" ]]; then
  echo "ERROR: App and daemon must share the com.openburnbar.app signing identifier; app='$app_identifier' daemon='$daemon_identifier'." >&2
  exit 1
fi
if [[ "$legacy_daemon_signing" == "true" ]]; then
  echo "WARN: accepting legacy daemon signing identifier '$legacy_daemon_identifier' for shipped release $app_version."
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
declare -a signed_peer_paths=(
  "$app_path"
  "$daemon_path"
  "$execution_path"
  "$virtual_hid_path"
  "$watchdog_path"
)
declare -a signed_peer_labels=(
  "App"
  "Daemon"
  "Privileged input execution helper"
  "Virtual HID bridge"
  "Kill-switch watchdog"
)
declare -a signed_peer_identifiers=(
  "com.openburnbar.app"
  "$daemon_identifier"
  "com.openburnbar.privileged-input-execution"
  "com.openburnbar.virtual-hid-bridge"
  "com.openburnbar.privileged-input-killswitch-watchdog"
)
declare -a signed_peer_signatures=(
  "$app_signature"
  "$daemon_signature"
  "$execution_signature"
  "$virtual_hid_signature"
  "$watchdog_signature"
)

for ((index = 0; index < ${#signed_peer_paths[@]}; index++)); do
  peer_path="${signed_peer_paths[$index]}"
  peer_label="${signed_peer_labels[$index]}"
  expected_identifier="${signed_peer_identifiers[$index]}"
  peer_signature="${signed_peer_signatures[$index]}"
  peer_identifier="$(signature_field "$peer_path" Identifier)"
  peer_team_id="$(signature_field "$peer_path" TeamIdentifier)"

  if [[ "$peer_identifier" != "$expected_identifier" ]]; then
    echo "ERROR: $peer_label has the wrong signing identifier: '$peer_identifier'; expected '$expected_identifier'." >&2
    exit 1
  fi
  if [[ "$peer_team_id" != "$app_team_id" ]]; then
    echo "ERROR: App and $peer_label are signed by different teams; app='${app_team_id:-missing}' peer='${peer_team_id:-missing}'." >&2
    exit 1
  fi
  peer_authority_chain="$(authority_chain <<<"$peer_signature")"
  if [[ -n "$app_authority_chain" || -n "$peer_authority_chain" ]]; then
    if [[ -z "$app_authority_chain" || -z "$peer_authority_chain" \
      || "$peer_authority_chain" != "$app_authority_chain" ]]; then
      echo "ERROR: App and $peer_label must have the same ordered signing-certificate authority chain." >&2
      echo "app authorities: ${app_authority_chain:-missing}" >&2
      echo "peer authorities: ${peer_authority_chain:-missing}" >&2
      exit 1
    fi
  fi
  if ! grep -q 'flags=.*runtime' <<<"$peer_signature" \
    || ! grep -q 'flags=.*library-validation' <<<"$peer_signature"; then
    echo "ERROR: $peer_label must use hardened runtime and library validation." >&2
    printf '%s\n' "$peer_signature" >&2
    exit 1
  fi
done

if grep -q '^Authority=Developer ID Application:' <<<"$app_signature"; then
  for ((index = 1; index < ${#signed_peer_paths[@]}; index++)); do
    peer_label="${signed_peer_labels[$index]}"
    peer_signature="${signed_peer_signatures[$index]}"
    if ! grep -q '^Authority=Developer ID Application:' <<<"$peer_signature" \
      || ! grep -q '^Timestamp=' <<<"$peer_signature"; then
      echo "ERROR: Release $peer_label must have a timestamped Developer ID signature." >&2
      printf '%s\n' "$peer_signature" >&2
      exit 1
    fi
  done
fi

entitlement_dir="$(mktemp -d -t openburnbar-helper-entitlements.XXXXXX)"
trap 'rm -rf "$entitlement_dir"' EXIT
daemon_entitlements="$entitlement_dir/daemon.plist"
execution_entitlements="$entitlement_dir/execution.plist"
virtual_hid_entitlements="$entitlement_dir/virtual-hid.plist"
watchdog_entitlements="$entitlement_dir/watchdog.plist"

capture_helper_entitlements() {
  local helper_path="$1"
  local destination="$2"
  if ! codesign -d --entitlements :- "$helper_path" >"$destination" 2>/dev/null; then
    echo "ERROR: Could not capture effective helper entitlements: $helper_path" >&2
    exit 1
  fi
  if [[ ! -s "$destination" ]]; then
    printf '%s\n' \
      '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' \
      >"$destination"
  fi
}

capture_helper_entitlements "$daemon_path" "$daemon_entitlements"
capture_helper_entitlements "$execution_path" "$execution_entitlements"
capture_helper_entitlements "$virtual_hid_path" "$virtual_hid_entitlements"
capture_helper_entitlements "$watchdog_path" "$watchdog_entitlements"
python3 - \
  "$daemon_entitlements" \
  "$execution_entitlements" \
  "$virtual_hid_entitlements" \
  "$watchdog_entitlements" <<'PY'
import plistlib
import sys
from pathlib import Path

daemon_path, execution_path, virtual_hid_path, watchdog_path = map(Path, sys.argv[1:])


def load(path: Path, label: str) -> dict:
    try:
        with path.open("rb") as file:
            value = plistlib.load(file)
    except Exception as error:
        raise SystemExit(f"ERROR: {label} effective entitlements are invalid: {error}")
    if not isinstance(value, dict):
        raise SystemExit(f"ERROR: {label} effective entitlements must be a dictionary.")
    return value


daemon = load(daemon_path, "Bare daemon helper")
execution = load(execution_path, "Privileged input execution helper")
virtual_hid = load(virtual_hid_path, "Virtual HID bridge")
watchdog = load(watchdog_path, "Kill-switch watchdog")

restricted_daemon_keys = {
    "keychain-access-groups",
    "com.apple.application-identifier",
    "com.apple.developer.team-identifier",
}
present_restricted_keys = sorted(restricted_daemon_keys.intersection(daemon))
if present_restricted_keys:
    raise SystemExit(
        "ERROR: Bare daemon helper has restricted identity/Keychain entitlements; "
        "macOS will kill it before main(): "
        + ", ".join(present_restricted_keys)
    )

expected_execution = {"com.apple.developer.hid.virtual.device": True}
if execution != expected_execution:
    raise SystemExit(
        "ERROR: Privileged input execution helper entitlements must contain only "
        f"{expected_execution!r}; found {execution!r}."
    )
if virtual_hid:
    raise SystemExit(
        f"ERROR: Virtual HID bridge must not carry entitlements; found {virtual_hid!r}."
    )
if watchdog:
    raise SystemExit(
        f"ERROR: Kill-switch watchdog must not carry entitlements; found {watchdog!r}."
    )
PY

if [[ "$app_team_id" != "not set" ]]; then
  app_requirement="$(designated_requirement "$app_path")"
  daemon_requirement="$(designated_requirement "$daemon_path")"
  if [[ "$legacy_daemon_signing" == "true" ]]; then
    if [[ -z "$daemon_requirement" || "$daemon_requirement" != *"$legacy_daemon_identifier"* ]]; then
      echo "ERROR: Legacy daemon designated requirement is missing or does not pin $legacy_daemon_identifier." >&2
      echo "daemon: ${daemon_requirement:-missing}" >&2
      exit 1
    fi
  elif [[ -z "$app_requirement" || "$daemon_requirement" != "$app_requirement" ]]; then
    echo "ERROR: App and daemon designated requirements differ, so they cannot share the ordinary database-key Keychain ACL." >&2
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

echo "PASS: signed daemon launches, shares the app designated requirement, and privileged-input helper trust is valid"
