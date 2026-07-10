#!/usr/bin/env bash
# Starts OpenBurnBarDaemon for packaged desktop session evidence, or records an honest blocker.
set -euo pipefail

usage() {
  echo "usage: $0 <workspace-root> <out-dir> <work-dir>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
ROOT="$1"
OUT_DIR="$2"
WORK_DIR="$3"

ORACLE_PATH="$OUT_DIR/daemon-session-oracle.json"
LOG_PATH="$OUT_DIR/daemon-shell-session.log"
HOME_DIR="$WORK_DIR/home"
RUNTIME_DIR="$WORK_DIR/runtime"
DATA_DIR="$HOME_DIR/.local/share/openburnbar"
SOCKET_PATH="$DATA_DIR/openburnbar-daemon.sock"
TOKEN_FILE="$DATA_DIR/daemon-socket-auth-token"
SOCKET_TOKEN="${OB_SHELL_SOCKET_AUTH_TOKEN:-shell-session-$(date +%s)-$RANDOM}"
DAEMON_VERSION="${OB_SHELL_DAEMON_VERSION:-shell-session-evidence}"
HEALTH_CLIENT="${OB_SHELL_HEALTH_CLIENT_BIN:-}"
HEALTH_PATH="$OUT_DIR/daemon-health-readback.json"

mkdir -p "$DATA_DIR" "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
printf '%s\n' "$SOCKET_TOKEN" >"$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
rm -f "$LOG_PATH" "$ORACLE_PATH" "$HEALTH_PATH" "$SOCKET_PATH"

find_daemon_bin() {
  local candidate
  if [[ -n "${OB_SHELL_DAEMON_BIN:-}" && -x "${OB_SHELL_DAEMON_BIN}" ]]; then
    printf '%s\n' "${OB_SHELL_DAEMON_BIN}"
    return 0
  fi
  local build_dirs=(
    "$WORK_DIR/daemon-build"
    "$ROOT/OpenBurnBarDaemon"/.build-linux-*
  )
  for build_dir in "${build_dirs[@]}"; do
    candidate="$(find "$build_dir" -path '*/debug/OpenBurnBarDaemon' -type f -perm -111 2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    candidate="$(find "$build_dir" -path '*/release/OpenBurnBarDaemon' -type f -perm -111 2>/dev/null | head -n 1 || true)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

daemon_stale_source() {
  local daemon_bin="$1"
  find \
    "$ROOT/OpenBurnBarDaemon/Sources" \
    "$ROOT/OpenBurnBarCore/Sources" \
    "$ROOT/OpenBurnBarDaemon/Package.swift" \
    "$ROOT/OpenBurnBarCore/Package.swift" \
    -type f -newer "$daemon_bin" -print -quit 2>/dev/null || true
}

build_daemon_if_missing() {
  local build_dir="$WORK_DIR/daemon-build"
  local daemon_bin stale_source
  daemon_bin="$(find_daemon_bin 2>/dev/null || true)"
  if [[ -n "$daemon_bin" ]]; then
    stale_source="$(daemon_stale_source "$daemon_bin")"
  fi
  if [[ -n "$daemon_bin" && -z "${stale_source:-}" ]]; then
    return 0
  fi
  if [[ -n "$daemon_bin" && -n "${stale_source:-}" ]]; then
    echo "== existing OpenBurnBarDaemon is stale for shell session ==" >&2
    echo "daemon_bin=$daemon_bin" >&2
    echo "newer_source=$stale_source" >&2
  fi
  echo "== build OpenBurnBarDaemon for shell session ==" >&2
  (
    cd "$ROOT/OpenBurnBarDaemon"
    swift build --build-path "$build_dir" --product OpenBurnBarDaemon
  ) >>"$OUT_DIR/daemon-build-for-shell-session.log" 2>&1
}

write_oracle() {
  local mode="$1"
  local status="$2"
  local detail="$3"
  local guidance
  case "$mode" in
    openburnbar-daemon-af-unix)
      guidance='Tray reconnect exercised a real OpenBurnBarDaemon AF_UNIX health round-trip.'
      ;;
    *)
      guidance='Real daemon unavailable; do not treat shell session as daemon-backed proof.'
      ;;
  esac
  ORACLE_PATH="$ORACLE_PATH" ORACLE_HOST="${OB_MISSION_WORKTREE_HOST:-}" ORACLE_MODE="$mode" ORACLE_STATUS="$status" ORACLE_DETAIL="$detail" ORACLE_GUIDANCE="$guidance" ORACLE_SOCKET="$SOCKET_PATH" ORACLE_TOKEN="$TOKEN_FILE" ORACLE_LOG="$LOG_PATH" ORACLE_ROOT="${OB_MISSION_WORKTREE_HOST:-$ROOT}" ORACLE_DAEMON_BIN="${DAEMON_BIN:-}" ORACLE_EXPECTED_VERSION="$DAEMON_VERSION" node -e '
const fs = require("fs");
const payload = {
  generatedAt: new Date().toISOString(),
  lane: "W06ShellEvidenceRepair",
  mode: process.env.ORACLE_MODE,
  status: process.env.ORACLE_STATUS,
  detail: process.env.ORACLE_DETAIL,
  socketPath: process.env.ORACLE_SOCKET,
  authTokenFile: process.env.ORACLE_TOKEN,
  logPath: process.env.ORACLE_LOG,
  daemonBinary: process.env.ORACLE_DAEMON_BIN || null,
  expectedVersion: process.env.ORACLE_EXPECTED_VERSION,
  healthReadback: "daemon-health-readback.json",
  missionWorktree: process.env.ORACLE_ROOT,
  missionWorktreeHost: process.env.ORACLE_HOST || null,
  validatorGuidance: process.env.ORACLE_GUIDANCE
};
fs.writeFileSync(process.env.ORACLE_PATH, JSON.stringify(payload, null, 2) + "\n");
';
}

start_real_daemon() {
  local daemon_bin="$1"
  {
    echo "starting real OpenBurnBarDaemon"
    echo "binary=$daemon_bin"
    echo "socket=$SOCKET_PATH"
    echo "peer_codesig=disabled-debug-only"
  } >"$LOG_PATH"
  OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1 \
  OPENBURNBAR_DAEMON_LINUX_PEER_ROOTS="/usr/bin:/usr/local/bin:/opt/openburnbar/bin" \
  OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
  OPENBURNBAR_INDEX_DATABASE_PATH="$WORK_DIR/index.sqlite" \
  HOME="$HOME_DIR" \
  XDG_DATA_HOME="$HOME_DIR/.local/share" \
  XDG_RUNTIME_DIR="$RUNTIME_DIR" \
  "$daemon_bin" --version "$DAEMON_VERSION" >>"$LOG_PATH" 2>&1 &
  echo $! >"$WORK_DIR/daemon.pid"
}

probe_daemon_health() {
  if [[ -z "$HEALTH_CLIENT" || ! -x "$HEALTH_CLIENT" ]]; then
    echo "Package-owned health client is missing: ${HEALTH_CLIENT:-unset}" >&2
    return 1
  fi
  local health_raw
  health_raw="$(
    HOME="$HOME_DIR" \
    XDG_DATA_HOME="$HOME_DIR/.local/share" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    OPENBURNBAR_SOCKET_PATH="$SOCKET_PATH" \
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
    "$HEALTH_CLIENT" --daemon-health
  )"
  HEALTH_RAW="$health_raw" HEALTH_PATH="$HEALTH_PATH" EXPECTED_VERSION="$DAEMON_VERSION" node <<'NODE'
const fs = require('node:fs');
const result = JSON.parse(process.env.HEALTH_RAW);
const expected = process.env.EXPECTED_VERSION;
const passed = result.ok === true
  && typeof result.daemonVersion === 'string'
  && result.daemonVersion.includes(expected)
  && Number.isInteger(result.protocolVersion);
const report = {
  generatedAt: new Date().toISOString(),
  expectedVersion: expected,
  response: { result },
  passed
};
fs.writeFileSync(process.env.HEALTH_PATH, `${JSON.stringify(report, null, 2)}\n`);
if (!passed) process.exit(1);
NODE
}

wait_for_socket() {
  local pid
  pid="$(cat "$WORK_DIR/daemon.pid")"
  for _ in $(seq 1 80); do
    if [[ -S "$SOCKET_PATH" ]]; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

echo "== daemon socket for shell session ==" >&2
build_daemon_if_missing
DAEMON_BIN=""
if DAEMON_BIN="$(find_daemon_bin)"; then
  echo "daemon_bin=$DAEMON_BIN" >&2
  start_real_daemon "$DAEMON_BIN"
  if wait_for_socket && probe_daemon_health; then
    write_oracle openburnbar-daemon-af-unix ready "Real OpenBurnBarDaemon listening on AF_UNIX socket for packaged shell session."
    printf '%s\n' "$SOCKET_PATH"
    exit 0
  fi
  echo "Real OpenBurnBarDaemon failed to create socket; see $LOG_PATH" >&2
fi

write_oracle blocked blocked "Could not start OpenBurnBarDaemon from mission worktree."
cat "$LOG_PATH" >&2 || true
exit 1
