#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

"$repo_root/scripts/test-burnbar-swift.sh"
"$repo_root/scripts/test-burnbar-retrieval-evals.sh"
"$repo_root/scripts/test-burnbar-ts.sh"
"$repo_root/scripts/test-burnbar-replay-evals.sh"
"$repo_root/scripts/test-burnbar-extension-host.sh"
bash -lc "cd \"$repo_root/extensions/burnbar\" && npm run test:cursor-smoke"

uid="$(id -u)"
daemon_bin_dir="$(swift build --package-path "$repo_root/BurnBarDaemon" --show-bin-path)"
daemon_bin="$daemon_bin_dir/BurnBarDaemon"
socket_path="/tmp/burnbar-release-smoke-$uid.sock"
launch_plist="/tmp/burnbar-release-smoke-$uid.plist"
launch_label="com.burnbar.daemon.release-smoke"
log_path="/tmp/burnbar-release-smoke-$uid.log"

python3 - <<PY
from pathlib import Path
import plistlib

plist = {
    "Label": "${launch_label}",
    "ProgramArguments": ["${daemon_bin}", "--socket-path", "${socket_path}", "--version", "release-smoke"],
    "RunAtLoad": True,
    "KeepAlive": True,
    "WorkingDirectory": "/tmp",
    "StandardOutPath": "${log_path}",
    "StandardErrorPath": "${log_path}",
}

with Path("${launch_plist}").open("wb") as fh:
    plistlib.dump(plist, fh)
PY

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
for _ in range(50):
    try:
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(path)
        client.sendall(json.dumps({"id": "health-smoke", "method": "daemon.health"}).encode() + b"\\n")
        response = client.recv(65536).decode().strip()
        client.close()
        if not response:
            raise SystemExit("BurnBar daemon returned an empty health response")
        print(response)
        break
    except Exception:
        time.sleep(0.1)
else:
    raise SystemExit("Timed out waiting for BurnBar daemon launchd smoke health response")
PY
