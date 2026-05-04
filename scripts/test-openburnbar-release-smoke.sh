#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

"$repo_root/scripts/test-openburnbar-swift.sh"
"$repo_root/scripts/test-openburnbar-app.sh"
"$repo_root/scripts/test-openburnbar-retrieval-evals.sh"
"$repo_root/scripts/test-openburnbar-ts.sh"
"$repo_root/scripts/test-openburnbar-replay-evals.sh"
"$repo_root/scripts/test-openburnbar-extension-host.sh"
npm --prefix "$repo_root/extensions/openburnbar" run test:cursor-smoke

uid="$(id -u)"
app_path="$repo_root/.derived-data/Build/Products/Release/OpenBurnBar.app"
daemon_bin="$app_path/Contents/Helpers/OpenBurnBarDaemon"
daemon_core_dylib="$app_path/Contents/Helpers/libOpenBurnBarCore.dylib"
app_core_framework="$app_path/Contents/Frameworks/OpenBurnBarCore.framework"
socket_path="/tmp/openburnbar-release-smoke-$uid.sock"
launch_plist="/tmp/openburnbar-release-smoke-$uid.plist"
launch_label="com.openburnbar.daemon.release-smoke"
log_path="/tmp/openburnbar-release-smoke-$uid.log"
socket_auth_token="$(uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]')"

make -C "$repo_root" build

if [[ ! -d "$app_path" ]]; then
  echo "Release app bundle not found at $app_path" >&2
  exit 1
fi

if [[ ! -x "$daemon_bin" ]]; then
  echo "Embedded daemon helper not found at $daemon_bin" >&2
  exit 1
fi

if [[ ! -f "$daemon_core_dylib" ]]; then
  echo "Embedded daemon support library not found at $daemon_core_dylib" >&2
  exit 1
fi

if [[ ! -d "$app_core_framework" ]]; then
  echo "Embedded app framework not found at $app_core_framework" >&2
  exit 1
fi

python3 - <<PY
from pathlib import Path
import plistlib

plist = {
    "Label": "${launch_label}",
    "ProgramArguments": ["${daemon_bin}", "--socket-path", "${socket_path}", "--version", "release-smoke"],
    "EnvironmentVariables": {
        "OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN": "${socket_auth_token}"
    },
    "RunAtLoad": True,
    "KeepAlive": True,
    "WorkingDirectory": "/tmp",
    "StandardOutPath": "${log_path}",
    "StandardErrorPath": "${log_path}",
}

with Path("${launch_plist}").open("wb") as fh:
    plistlib.dump(plist, fh)
PY
chmod 600 "$launch_plist"

cleanup() {
  launchctl bootout "gui/$uid" "$launch_plist" >/dev/null 2>&1 || true
  rm -f "$launch_plist" "$socket_path" "$log_path"
}
trap cleanup EXIT

launchctl bootout "gui/$uid" "$launch_plist" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$uid" "$launch_plist"
launchctl kickstart -k "gui/$uid/$launch_label"

python3 - <<PY
import json
import socket
import time

path = "${socket_path}"
auth_token = "${socket_auth_token}"
for _ in range(50):
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(path)
        client.sendall(json.dumps({
            "id": "health-smoke",
            "method": "daemon.health",
            "authToken": auth_token
        }).encode() + b"\\n")
        response = client.recv(65536).decode().strip()
        client.close()
        if not response:
            raise SystemExit("OpenBurnBar daemon returned an empty health response")
        payload = json.loads(response)
        if payload.get("error"):
            raise SystemExit(f"OpenBurnBar daemon health smoke failed: {payload['error']}")
        print(response)
        break
    except Exception:
        time.sleep(0.1)
else:
    raise SystemExit("Timed out waiting for OpenBurnBar daemon launchd smoke health response")
PY
