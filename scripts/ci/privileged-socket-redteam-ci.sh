#!/usr/bin/env bash
# Nightly CI red-team gate for the privileged-input socket boundary (P0-6).
#
# Boots the real virtual-HID bridge as root on a live socket, then proves an
# UNSIGNED (ad-hoc) probe is rejected by peer authentication. CI builds are
# ad-hoc signed, so every probe here models the attacker: a console-user
# process without the first-party Developer-ID signature. Acceptance = the
# probe is REFUSED. This is the gate the 2026-06-11 diligence review found
# missing: the committed socket lane had shipped with peer auth that could
# never pass (wrong LOCAL_PEERTOKEN constant) and no CI ever exercised a live
# socket.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

SOCKET_PATH="/var/run/openburnbar-virtual-hid.sock"
BRIDGE_LOG="$(mktemp -t openburnbar-bridge-log)"

echo "==> Building bridge + red-team probe (debug, ad-hoc signed)"
swift build --package-path OpenBurnBarDaemon \
  --product OpenBurnBarVirtualHIDBridge \
  --product OpenBurnBarPrivilegedSocketRedTeamProbe \
  -c debug

BRIDGE="OpenBurnBarDaemon/.build/debug/OpenBurnBarVirtualHIDBridge"
PROBE="OpenBurnBarDaemon/.build/debug/OpenBurnBarPrivilegedSocketRedTeamProbe"
[[ -x "$BRIDGE" && -x "$PROBE" ]] || { echo "FAIL: binaries missing"; exit 2; }

echo "==> Starting bridge as root on $SOCKET_PATH"
sudo rm -f "$SOCKET_PATH"
sudo env BRIDGE="$BRIDGE" SOCKET_PATH="$SOCKET_PATH" BRIDGE_LOG="$BRIDGE_LOG" \
  bash -c 'exec "$BRIDGE" --socket "$SOCKET_PATH" >"$BRIDGE_LOG" 2>&1' &
BRIDGE_PID=$!
cleanup() {
  sudo kill "$BRIDGE_PID" 2>/dev/null || true
  sudo rm -f "$SOCKET_PATH"
  echo "==> bridge log tail:"
  tail -20 "$BRIDGE_LOG" || true
}
trap cleanup EXIT

for _ in $(seq 1 40); do
  [[ -S "$SOCKET_PATH" ]] && break
  sleep 0.25
done
if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "FAIL: bridge socket never appeared"
  exit 2
fi

echo "==> Probing with unsigned client (must be rejected)"
set +e
sudo -u "$(id -un)" "$PROBE" "$SOCKET_PATH" input
PROBE_EXIT=$?
set -e
echo "probe_exit_code=$PROBE_EXIT"
if [[ "$PROBE_EXIT" -eq 0 ]]; then
  echo "FAIL: unsigned probe was ACCEPTED by the privileged socket (peer auth broken)"
  exit 1
fi

echo "==> Running PrivilegedSocketRedTeamIntegrationTests against the live socket"
RUN_PRIVILEGED_SOCKET_REDTEAM=1 swift test \
  --package-path OpenBurnBarDaemon \
  --filter PrivilegedSocketRedTeamIntegrationTests

echo "PASS: privileged socket red-team gate (unsigned peer rejected on live socket)"
