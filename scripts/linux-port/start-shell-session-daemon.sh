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

mkdir -p "$DATA_DIR" "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
printf '%s\n' "$SOCKET_TOKEN" >"$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
rm -f "$LOG_PATH" "$ORACLE_PATH" "$SOCKET_PATH"

find_daemon_bin() {
  local candidate
  if [[ -n "${OB_SHELL_DAEMON_BIN:-}" && -x "${OB_SHELL_DAEMON_BIN}" ]]; then
    printf '%s\n' "${OB_SHELL_DAEMON_BIN}"
    return 0
  fi
  for build_dir in \
    "$ROOT/OpenBurnBarDaemon/.build-linux-shell-session" \
    "$ROOT/OpenBurnBarDaemon/.build-linux-ipc-cli-gateway" \
    "$ROOT/OpenBurnBarDaemon/.build-linux-ipc-cli-gateway-validator"; do
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

build_daemon_if_missing() {
  local build_dir="$ROOT/OpenBurnBarDaemon/.build-linux-shell-session"
  if find_daemon_bin >/dev/null 2>&1; then
    return 0
  fi
  echo "== build OpenBurnBarDaemon for shell session ==" >&2
  (
    cd "$ROOT/OpenBurnBarDaemon"
    swift build --build-path "$build_dir" --target OpenBurnBarDaemon
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
    accepted-fixture-af-unix)
      guidance='Explicit accepted fixture only; does not satisfy VAL-CLI-001 / live daemon contracts.'
      ;;
    *)
      guidance='Real daemon unavailable; do not treat shell session as daemon-backed proof.'
      ;;
  esac
  ORACLE_PATH="$ORACLE_PATH" ORACLE_HOST="${OB_MISSION_WORKTREE_HOST:-}" ORACLE_MODE="$mode" ORACLE_STATUS="$status" ORACLE_DETAIL="$detail" ORACLE_GUIDANCE="$guidance" ORACLE_SOCKET="$SOCKET_PATH" ORACLE_TOKEN="$TOKEN_FILE" ORACLE_LOG="$LOG_PATH" ORACLE_ROOT="${OB_MISSION_WORKTREE_HOST:-$ROOT}" node -e '
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
  missionWorktree: process.env.ORACLE_ROOT,
  missionWorktreeHost: process.env.ORACLE_HOST || null,
  validatorGuidance: process.env.ORACLE_GUIDANCE
};
fs.writeFileSync(process.env.ORACLE_PATH, JSON.stringify(payload, null, 2) + "\n");
';
}

start_fixture_daemon() {
  cat >"$WORK_DIR/fake-daemon.mjs" <<'NODE'
import fs from 'node:fs';
import net from 'node:net';

const socketPath = process.env.OPENBURNBAR_SOCKET_PATH;
const logPath = process.env.OPENBURNBAR_DAEMON_LOG;
try { fs.unlinkSync(socketPath); } catch {}
const server = net.createServer((connection) => {
  let buffer = '';
  connection.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    const index = buffer.indexOf('\n');
    if (index < 0) return;
    const started = process.hrtime.bigint();
    const line = buffer.slice(0, index).trim();
    let request = {};
    try { request = JSON.parse(line); } catch (error) { request = { parseError: String(error) }; }
    const response = {
      protocolVersion: 1,
      id: request.id ?? 'missing-id',
      result: {
        ok: true,
        protocolVersion: 1,
        daemonVersion: 'accepted-fixture-shell-session-0.0.0',
        socketPath,
        gatewayEnabled: false,
        gatewayHost: '127.0.0.1',
        gatewayPort: 0
      }
    };
    connection.write(JSON.stringify(response) + '\n', () => {
      const ended = process.hrtime.bigint();
      fs.appendFileSync(logPath, JSON.stringify({
        at: new Date().toISOString(),
        method: request.method ?? null,
        id: request.id ?? null,
        traceId: request.traceId ?? null,
        handlingMs: Number(ended - started) / 1_000_000,
        oracle: 'accepted-fixture-af-unix'
      }) + '\n');
      connection.end();
    });
  });
});
server.listen(socketPath, () => {
  fs.chmodSync(socketPath, 0o600);
  fs.writeFileSync(`${socketPath}.ready`, 'ready\n');
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
NODE
  OPENBURNBAR_SOCKET_PATH="$SOCKET_PATH" \
  OPENBURNBAR_DAEMON_LOG="$LOG_PATH" \
  node "$WORK_DIR/fake-daemon.mjs" >>"$LOG_PATH" 2>&1 &
  echo $! >"$WORK_DIR/daemon.pid"
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
  OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
  OPENBURNBAR_INDEX_DATABASE_PATH="$WORK_DIR/index.sqlite" \
  "$daemon_bin" --version shell-session-evidence >>"$LOG_PATH" 2>&1 &
  echo $! >"$WORK_DIR/daemon.pid"
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
build_daemon_if_missing || true
DAEMON_BIN=""
if DAEMON_BIN="$(find_daemon_bin)"; then
  echo "daemon_bin=$DAEMON_BIN" >&2
  start_real_daemon "$DAEMON_BIN"
  if wait_for_socket; then
    write_oracle openburnbar-daemon-af-unix ready "Real OpenBurnBarDaemon listening on AF_UNIX socket for packaged shell session."
    printf '%s\n' "$SOCKET_PATH"
    exit 0
  fi
  echo "Real OpenBurnBarDaemon failed to create socket; see $LOG_PATH" >&2
fi

if [[ "${OB_ACCEPT_SHELL_DAEMON_FIXTURE:-0}" == "1" ]]; then
  echo "OB_ACCEPT_SHELL_DAEMON_FIXTURE=1 — starting explicit accepted Node AF_UNIX fixture (not real daemon proof)." >&2
  start_fixture_daemon
  if wait_for_socket; then
    write_oracle accepted-fixture-af-unix accepted-fixture "Real OpenBurnBarDaemon unavailable; explicit accepted fixture answers daemon.health for tray reconnect only."
    printf '%s\n' "$SOCKET_PATH"
    exit 0
  fi
fi

write_oracle blocked blocked "Could not start OpenBurnBarDaemon from mission worktree and fixture mode was not explicitly accepted."
cat "$LOG_PATH" >&2 || true
exit 1