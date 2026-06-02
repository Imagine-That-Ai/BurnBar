#!/usr/bin/env bash
# Opt-in privileged socket red-team (P0.c). Requires P0+ daemons and the probe binary.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"

export RUN_PRIVILEGED_SOCKET_REDTEAM=1

SOCKET_PATH="/var/run/openburnbar-virtual-hid.sock"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="${repo_root}/launch-evidence"
EVIDENCE_FILE="${EVIDENCE_DIR}/privileged-redteam-rc-${TIMESTAMP}.txt"
mkdir -p "${EVIDENCE_DIR}"

log() { echo "$@" | tee -a "${EVIDENCE_FILE}"; }

log "==> Privileged socket red-team RC gate"
log "timestamp_utc=${TIMESTAMP}"
log "socket_path=${SOCKET_PATH}"

if [[ -S "${SOCKET_PATH}" ]]; then
  log "socket_present=yes"
else
  log "socket_present=no"
fi

log ""
log "==> Building OpenBurnBarPrivilegedSocketRedTeamProbe"
swift build \
  --package-path OpenBurnBarDaemon \
  --product OpenBurnBarPrivilegedSocketRedTeamProbe \
  -c debug 2>&1 | tee -a "${EVIDENCE_FILE}"

PROBE_PATH="${repo_root}/OpenBurnBarDaemon/.build/debug/OpenBurnBarPrivilegedSocketRedTeamProbe"
if [[ -x "${PROBE_PATH}" ]]; then
  log "probe_built=yes path=${PROBE_PATH}"
  set +e
  "${PROBE_PATH}" "${SOCKET_PATH}" input 2>&1 | tee -a "${EVIDENCE_FILE}"
  PROBE_EXIT=$?
  set -e
  log "probe_exit_code=${PROBE_EXIT}"
else
  log "probe_built=no"
  PROBE_EXIT=2
fi

log ""
log "==> Running PrivilegedSocketRedTeamIntegrationTests"
set +e
(
  cd "${repo_root}/OpenBurnBarDaemon"
  swift test --filter PrivilegedSocketRedTeamIntegrationTests
) 2>&1 | tee -a "${EVIDENCE_FILE}"
XCTEST_EXIT=$?
set -e
log "xctest_exit_code=${XCTEST_EXIT}"

if [[ "${PROBE_EXIT}" -eq 0 ]]; then
  log "FAIL: probe was accepted (pre-P0 vulnerability)"
  exit 1
fi

if [[ "${XCTEST_EXIT}" -ne 0 ]]; then
  log "FAIL: XCTest did not pass"
  exit "${XCTEST_EXIT}"
fi

log "PASS: privileged socket red-team gate"
log "evidence_file=${EVIDENCE_FILE}"