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

# Deterministic swift resolution: a non-Xcode `swift` earlier on PATH builds the
# bridge against a mismatched SDK, which would surface here as an unexplained
# infra failure. See scripts/lib/swift-toolchain.sh.
# shellcheck source=../lib/swift-toolchain.sh
source "${repo_root}/scripts/lib/swift-toolchain.sh"

SOCKET_PATH="/var/run/openburnbar-virtual-hid.sock"
BRIDGE_LOG="$(mktemp -t openburnbar-bridge-log)"
ARTIFACT_DIR="${OPENBURNBAR_DAST_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/openburnbar-dast-redteam}"
RESULT_PATH="${ARTIFACT_DIR}/privileged-socket-redteam-result.json"
mkdir -p "$ARTIFACT_DIR"

write_result() {
  local status="$1"
  local failure_class="$2"
  local reason_code="$3"
  local failure_class_json="null"
  local reason_code_json="null"
  if [[ -n "$failure_class" ]]; then failure_class_json="\"${failure_class}\""; fi
  if [[ -n "$reason_code" ]]; then reason_code_json="\"${reason_code}\""; fi
  cat > "$RESULT_PATH" <<JSON
{
  "schemaVersion": 1,
  "status": "${status}",
  "failureClass": ${failure_class_json},
  "reasonCode": ${reason_code_json}
}
JSON
}

echo "==> Building bridge + red-team probe (debug, ad-hoc signed)"
if ! obb_swift_init; then
  write_result "infra-failed" "infra" "swift-toolchain-unavailable"
  exit 2
fi

if ! "${OBB_SWIFT}" build --package-path OpenBurnBarDaemon \
  --product OpenBurnBarVirtualHIDBridge \
  --product OpenBurnBarPrivilegedSocketRedTeamProbe \
  -c debug; then
  write_result "infra-failed" "infra" "privileged-build-failed"
  exit 2
fi

if ! BIN_PATH="$("${OBB_SWIFT}" build --package-path OpenBurnBarDaemon -c debug --show-bin-path)"; then
  write_result "infra-failed" "infra" "privileged-build-path-unavailable"
  exit 2
fi
BRIDGE="${BIN_PATH}/OpenBurnBarVirtualHIDBridge"
PROBE="${BIN_PATH}/OpenBurnBarPrivilegedSocketRedTeamProbe"
if [[ ! -x "$BRIDGE" || ! -x "$PROBE" ]]; then
  echo "FAIL: binaries missing"
  echo "bridge_path=${BRIDGE}"
  echo "probe_path=${PROBE}"
  write_result "infra-failed" "infra" "privileged-binaries-missing"
  exit 2
fi

echo "==> Starting bridge as root on $SOCKET_PATH"
sudo rm -f "$SOCKET_PATH"
sudo sh -c '"$1" --socket "$2" >"$3" 2>&1' sh "$BRIDGE" "$SOCKET_PATH" "$BRIDGE_LOG" &
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
  write_result "infra-failed" "infra" "privileged-socket-not-ready"
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
  write_result "failed" "product" "privileged-peer-auth-accepted"
  exit 1
fi

echo "==> Running PrivilegedSocketRedTeamIntegrationTests against the live socket"
RUN_PRIVILEGED_SOCKET_REDTEAM=1 OPENBURNBAR_REDTEAM_PROBE_PATH="$PROBE" "${OBB_SWIFT}" test \
  --package-path OpenBurnBarDaemon \
  --filter PrivilegedSocketRedTeamIntegrationTests || {
    write_result "failed" "product" "privileged-redteam-test-failed"
    exit 1
  }

write_result "passed" "" ""
echo "PASS: privileged socket red-team gate (unsigned peer rejected on live socket)"
