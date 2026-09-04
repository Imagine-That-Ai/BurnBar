#!/usr/bin/env bash
set -euo pipefail

LABEL="com.openburnbar.remote-access-agent"
PLIST_PATH="/Library/LaunchDaemons/$LABEL.plist"
BIN_PATH="/Library/Application Support/OpenBurnBar/RemoteAccess/openburnbar-remote-access-agent"
SOCKET_PATH="/var/run/openburnbar-remote-access-agent.sock"

if [[ ! -f "$PLIST_PATH" ]]; then
  echo "error: missing LaunchDaemon plist: $PLIST_PATH" >&2
  exit 1
fi

if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: missing executable agent: $BIN_PATH" >&2
  exit 1
fi

# The agent runs as root and receives the macOS login password over this
# socket, so an unsigned / ad-hoc deployed binary is a trust failure for every
# client (the app authenticates the server against the first-party designated
# requirement before writing). Fail closed unless an ad-hoc install was made
# explicitly on this host. A secure timestamp is required too: AMFI kills
# timestamped-less Developer ID daemons at spawn (OS_REASON_CODESIGNING).
if [[ "${OPENBURNBAR_AGENT_ADHOC:-0}" != "1" ]]; then
  # `codesign -d` only DISPLAYS the embedded metadata; it does not check that
  # the signature still matches the file bytes. A tampered-after-signing
  # binary would pass the display checks below while SecCodeCheckValidity (the
  # client's live gate) rejects it. Verify cryptographic validity first, then
  # assert the identity metadata.
  if ! codesign --verify --strict --verbose=2 "$BIN_PATH" >/dev/null 2>&1; then
    echo "error: deployed agent signature fails strict verification (binary modified after signing?)" >&2
    codesign --verify --strict --verbose=2 "$BIN_PATH" >&2 || true
    exit 1
  fi
  SIGNATURE="$(codesign -d --verbose=4 "$BIN_PATH" 2>&1 || true)"
  if ! grep -q "Identifier=com.openburnbar.remote-access-agent" <<<"$SIGNATURE"; then
    echo "error: deployed agent has the wrong signing identifier" >&2
    printf '%s\n' "$SIGNATURE" >&2
    exit 1
  fi
  if ! grep -q "Authority=Developer ID Application" <<<"$SIGNATURE" \
    || ! grep -q "^TeamIdentifier=4Y367DF25B" <<<"$SIGNATURE" \
    || ! grep -q "flags=.*runtime" <<<"$SIGNATURE" \
    || ! grep -q "flags=.*library-validation" <<<"$SIGNATURE" \
    || ! grep -q "^Timestamp=" <<<"$SIGNATURE"; then
    echo "error: deployed agent must be Developer ID signed by the OpenBurnBar team (4Y367DF25B) with hardened runtime, library validation, and a secure timestamp." >&2
    printf '%s\n' "$SIGNATURE" >&2
    exit 1
  fi
fi

if ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
  echo "error: LaunchDaemon is not loaded: $LABEL" >&2
  exit 1
fi

if ! launchctl print "system/$LABEL" | grep -q "state = running"; then
  echo "error: LaunchDaemon is loaded but not running: $LABEL" >&2
  launchctl print "system/$LABEL" | sed -n '1,80p' >&2
  exit 1
fi

if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "error: missing Unix socket: $SOCKET_PATH" >&2
  exit 1
fi

console_owner="$(
  scutil <<< 'show State:/Users/ConsoleUser' 2>/dev/null \
    | awk -F ' : ' '/Name :/ { print $2; exit }'
)"
if [[ -z "$console_owner" || "$console_owner" == "loginwindow" || "$console_owner" == "root" ]]; then
  console_owner="$(stat -f '%Su' /dev/console)"
fi
socket_owner="$(stat -f '%Su' "$SOCKET_PATH")"
socket_mode="$(stat -f '%Lp' "$SOCKET_PATH")"

if [[ "$socket_owner" != "$console_owner" ]]; then
  echo "error: socket owner '$socket_owner' does not match console owner '$console_owner'" >&2
  exit 1
fi

if [[ "$socket_mode" != "600" ]]; then
  echo "error: socket mode is $socket_mode, expected 600" >&2
  exit 1
fi

responses="$(
  python3 - <<'PY'
import json
import socket

path = "/var/run/openburnbar-remote-access-agent.sock"
def send(operation):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2.0)
    client.connect(path)
    client.sendall(json.dumps({"operation": operation, "password": ""}).encode("utf-8") + b"\n")
    response = client.recv(4096).decode("utf-8").strip()
    client.close()
    return response

print(send("health"))
print(send("wakeDisplay"))
PY
)"
health="$(printf '%s\n' "$responses" | sed -n '1p')"
wake_probe="$(printf '%s\n' "$responses" | sed -n '2p')"

if ! python3 - "$health" "$wake_probe" <<'PY'
import json
import sys

for line in sys.argv[1:]:
    payload = json.loads(line)
    if payload.get("ok") is not True or payload.get("version") != "1":
        raise SystemExit(1)
PY
then
  echo "error: unexpected agent probe response: health=$health wakeDisplay=$wake_probe" >&2
  exit 1
fi

printf 'Remote access agent healthy: %s owner=%s mode=%s health=%s wakeDisplay=%s\n' "$LABEL" "$socket_owner" "$socket_mode" "$health" "$wake_probe"
