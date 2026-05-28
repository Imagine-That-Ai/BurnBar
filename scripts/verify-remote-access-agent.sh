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

console_owner="$(stat -f '%Su' /dev/console)"
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

health="$(
  python3 - <<'PY'
import json
import socket

path = "/var/run/openburnbar-remote-access-agent.sock"
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(2.0)
client.connect(path)
client.sendall(json.dumps({"operation": "health", "password": ""}).encode("utf-8") + b"\n")
print(client.recv(4096).decode("utf-8").strip())
PY
)"

if ! python3 - "$health" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
if payload.get("ok") is not True or payload.get("version") != "1":
    raise SystemExit(1)
PY
then
  echo "error: unexpected health response: $health" >&2
  exit 1
fi

printf 'Remote access agent healthy: %s owner=%s mode=%s health=%s\n' "$LABEL" "$socket_owner" "$socket_mode" "$health"
