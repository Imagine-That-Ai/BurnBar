#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/docs/linux-port/evidence/mission-001-ipc-cli-gateway}"
BUILD_DIR="${OPENBURNBAR_LINUX_BUILD_DIR:-$ROOT/OpenBurnBarDaemon/.build-linux-ipc-cli-gateway}"
LINUX_IMAGE="${OPENBURNBAR_LINUX_TOOLCHAIN_IMAGE:-openburnbar-linux-toolchain:mission-001}"

if [[ "$(uname -s)" != "Linux" && "${OPENBURNBAR_IPC_EVIDENCE_INNER:-0}" != "1" ]]; then
  mkdir -p "$EVIDENCE_DIR"
  LOG="$EVIDENCE_DIR/docker-ipc-cli-gateway-evidence.log"
  TMP_LOG="$(mktemp "${TMPDIR:-/tmp}/openburnbar-ipc-cli-gateway.XXXXXX.log")"
  set +e
  docker run --rm \
    -v "$ROOT:/workspace" \
    -w /workspace \
    -e OPENBURNBAR_IPC_EVIDENCE_INNER=1 \
    -e EVIDENCE_DIR=/workspace/docs/linux-port/evidence/mission-001-ipc-cli-gateway \
    -e OPENBURNBAR_LINUX_BUILD_DIR=/tmp/openburnbar-ipc-cli-gateway-build \
    -e OPENBURNBAR_LINUX_TOOLCHAIN_IMAGE="$LINUX_IMAGE" \
    "$LINUX_IMAGE" \
    bash /workspace/scripts/linux-port/run-ipc-cli-gateway-evidence.sh \
    > "$TMP_LOG" 2>&1
  rc=$?
  set -e
  cp "$TMP_LOG" "$LOG"
  rm -f "$TMP_LOG"
  cat "$LOG"
  exit "$rc"
fi

TMP_ROOT="$(mktemp -d)"
SOCKET_DIR="$TMP_ROOT/socket"
SOCKET_PATH="$SOCKET_DIR/openburnbar.sock"
SOCKET_TOKEN="socket-evidence-token"
GATEWAY_TOKEN="gateway-evidence-token"
PORT="${OPENBURNBAR_EVIDENCE_GATEWAY_PORT:-$((18317 + (RANDOM % 1200)))}"
FAKE_OUTPUTS="$TMP_ROOT/fake-provider-output.json"
RUN_ID_FILE="$TMP_ROOT/run_id.txt"
SUBSCRIPTION_FILE="$TMP_ROOT/subscription.txt"
DAEMON_PID=""
NEGATIVE_DAEMON_PID=""

mkdir -p "$EVIDENCE_DIR"
rm -f "$EVIDENCE_DIR"/*.txt "$EVIDENCE_DIR"/*.json "$EVIDENCE_DIR"/*.jsonl "$EVIDENCE_DIR"/*.log 2>/dev/null || true
mkdir -p "$SOCKET_DIR"
chmod 700 "$SOCKET_DIR"

if [[ "$BUILD_DIR" == "$ROOT"/OpenBurnBarDaemon/.build-linux-ipc-cli-gateway || "$BUILD_DIR" == /tmp/openburnbar-ipc-cli-gateway-build* ]]; then
  rm -rf "$BUILD_DIR"
fi

{
  echo "### swift build daemon/cli/gateway evidence products"
  echo "image=$LINUX_IMAGE"
  echo "build_dir=$BUILD_DIR"
  echo "product=OpenBurnBarDaemon"
  swift build \
    --disable-index-store \
    --jobs 1 \
    --package-path "$ROOT/OpenBurnBarDaemon" \
    --build-path "$BUILD_DIR" \
    --product OpenBurnBarDaemon
  echo "daemon_product_build_exit_code=$?"
  echo
  echo "product=OpenBurnBarCLI"
  swift build \
    --disable-index-store \
    --jobs 1 \
    --package-path "$ROOT/OpenBurnBarDaemon" \
    --build-path "$BUILD_DIR" \
    --product OpenBurnBarCLI
  echo "cli_product_build_exit_code=$?"
} > "$EVIDENCE_DIR/build.log" 2>&1

cleanup() {
  terminate_pid "${DAEMON_PID:-}"
  terminate_pid "${NEGATIVE_DAEMON_PID:-}"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

terminate_pid() {
  local pid="${1:-}"
  [[ -z "$pid" ]] && return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.25
  done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

find_binary() {
  local label="$1"
  shift
  local name
  local path
  for name in "$@"; do
    path="$(find "$BUILD_DIR" -path "*/debug/$name" -type f -perm -111 | head -n 1 || true)"
    if [[ -n "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  echo "missing built binary for $label under $BUILD_DIR; tried: $*" >&2
  exit 127
}

DAEMON_BIN="$(find_binary daemon OpenBurnBarDaemon OpenBurnBarDaemonExecutable openburnbar-daemon)"
CLI_BIN="$(find_binary cli OpenBurnBarCLI)"

{
  echo "daemon_bin=$DAEMON_BIN"
  echo "cli_bin=$CLI_BIN"
  file "$DAEMON_BIN" "$CLI_BIN"
  sha256sum "$DAEMON_BIN" "$CLI_BIN"
} > "$EVIDENCE_DIR/binaries.txt"

cat > "$FAKE_OUTPUTS" <<'JSON'
{"outputs":["{\"action\":\"respond\",\"rationale\":\"Linux daemon evidence mock provider completed.\",\"message\":\"Linux daemon evidence mock provider completed.\"}"]}
JSON

wait_for_socket() {
  local socket_path="$1"
  local pid="$2"
  for _ in $(seq 1 80); do
    if [[ -S "$socket_path" ]]; then
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
  done
  return 1
}

wait_for_gateway() {
  for _ in $(seq 1 80); do
    if http_get "/health" "" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

http_get() {
  local path="$1"
  local authorization="${2:-}"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PORT" "$path" "$authorization" <<'PY'
import socket
import sys

port = int(sys.argv[1])
path = sys.argv[2]
authorization = sys.argv[3]

request = f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
if authorization:
    request += f"Authorization: {authorization}\r\n"
request += "\r\n"

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    sock.sendall(request.encode("utf-8"))
    sock.shutdown(socket.SHUT_WR)
    chunks = []
    while True:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        chunks.append(chunk)

sys.stdout.write(b"".join(chunks).decode("utf-8", errors="replace"))
PY
    return $?
  fi

  if command -v curl >/dev/null 2>&1; then
    if [[ -n "$authorization" ]]; then
      timeout 6 curl --http1.0 -sS -m 5 -i -H "Authorization: $authorization" -H "Connection: close" "http://127.0.0.1:$PORT$path"
    else
      timeout 6 curl --http1.0 -sS -m 5 -i -H "Connection: close" "http://127.0.0.1:$PORT$path"
    fi
    return $?
  fi

  {
    exec 3<>"/dev/tcp/127.0.0.1/$PORT"
    printf 'GET %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n' "$path" >&3
    if [[ -n "$authorization" ]]; then
      printf 'Authorization: %s\r\n' "$authorization" >&3
    fi
    printf '\r\n' >&3
    cat <&3
  }
}

http_post_json() {
  local path="$1"
  local authorization="$2"
  local body="$3"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$PORT" "$path" "$authorization" "$body" <<'PY'
import socket
import sys

port = int(sys.argv[1])
path = sys.argv[2]
authorization = sys.argv[3]
body = sys.argv[4].encode("utf-8")

request_head = (
    f"POST {path} HTTP/1.1\r\n"
    "Host: 127.0.0.1\r\n"
    "Connection: close\r\n"
    f"Authorization: {authorization}\r\n"
    "Content-Type: application/json\r\n"
    f"Content-Length: {len(body)}\r\n\r\n"
).encode("utf-8")

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    sock.settimeout(3)
    sock.sendall(request_head + body)
    sock.shutdown(socket.SHUT_WR)
    chunks = []
    while True:
        try:
            chunk = sock.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        chunks.append(chunk)

sys.stdout.write(b"".join(chunks).decode("utf-8", errors="replace"))
PY
    return $?
  fi

  if command -v curl >/dev/null 2>&1; then
    timeout 6 curl --http1.0 -sS -m 5 -i \
      -H "Authorization: $authorization" \
      -H "Connection: close" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "http://127.0.0.1:$PORT$path"
    return $?
  fi

  {
    exec 3<>"/dev/tcp/127.0.0.1/$PORT"
    printf 'POST %s HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n' "$path" >&3
    printf 'Authorization: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
      "$authorization" "${#body}" "$body" >&3
    cat <&3
  }
}

capture_cli() {
  local title="$1"
  shift
  local output
  local rc
  set +e
  output="$(
    OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
    "$CLI_BIN" "$@" 2>&1
  )"
  rc=$?
  set -e
  {
    echo "### $title"
    echo "command=openburnbar-cli $*"
    printf '%s\n' "$output"
    echo "exit_code=$rc"
    echo
  } >> "$EVIDENCE_DIR/cli-transcript.txt"
  printf '%s\n' "$output"
  return "$rc"
}

capture_cli_expected_failure() {
  local title="$1"
  shift
  local output
  local rc
  set +e
  output="$("$@" 2>&1)"
  rc=$?
  set -e
  {
    echo "### $title"
    printf '%s\n' "$output"
    echo "exit_code=$rc"
    echo
  } >> "$EVIDENCE_DIR/negative-cases.txt"
  if [[ "$rc" -eq 0 ]]; then
    echo "expected failure but command exited 0: $title" >&2
    exit 1
  fi
}

start_positive_daemon() {
  {
    echo "starting positive daemon"
    echo "socket=$SOCKET_PATH"
    echo "gateway=127.0.0.1:$PORT"
    echo "peer_codesig=disabled-debug-only"
  } > "$EVIDENCE_DIR/daemon-positive.log"
  OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1 \
  OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
  OPENBURNBAR_GATEWAY_ENABLED=1 \
  OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \
  OPENBURNBAR_GATEWAY_PORT="$PORT" \
  OPENBURNBAR_GATEWAY_AUTH_TOKEN="$GATEWAY_TOKEN" \
  OPENBURNBAR_INDEX_DATABASE_PATH="$TMP_ROOT/index.sqlite" \
  BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE="$FAKE_OUTPUTS" \
  "$DAEMON_BIN" --version evidence-daemon \
    >> "$EVIDENCE_DIR/daemon-positive.log" 2>&1 &
  DAEMON_PID=$!
  if ! wait_for_socket "$SOCKET_PATH" "$DAEMON_PID"; then
    cat "$EVIDENCE_DIR/daemon-positive.log" >&2
    exit 1
  fi
  if ! wait_for_gateway; then
    cat "$EVIDENCE_DIR/daemon-positive.log" >&2
    exit 1
  fi
}

restart_positive_daemon() {
  {
    echo
    echo "restarting positive daemon"
    echo "socket=$SOCKET_PATH"
    echo "gateway=127.0.0.1:$PORT"
    echo "peer_codesig=disabled-debug-only"
  } >> "$EVIDENCE_DIR/daemon-positive.log"

  terminate_pid "$DAEMON_PID"
  rm -f "$SOCKET_PATH"
  OPENBURNBAR_DAEMON_DISABLE_PEER_CODESIG=1 \
  OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
  OPENBURNBAR_GATEWAY_ENABLED=1 \
  OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \
  OPENBURNBAR_GATEWAY_PORT="$PORT" \
  OPENBURNBAR_GATEWAY_AUTH_TOKEN="$GATEWAY_TOKEN" \
  OPENBURNBAR_INDEX_DATABASE_PATH="$TMP_ROOT/index.sqlite" \
  BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE="$FAKE_OUTPUTS" \
  "$DAEMON_BIN" --version evidence-daemon-restarted \
    >> "$EVIDENCE_DIR/daemon-positive.log" 2>&1 &
  DAEMON_PID=$!
  if ! wait_for_socket "$SOCKET_PATH" "$DAEMON_PID"; then
    cat "$EVIDENCE_DIR/daemon-positive.log" >&2
    exit 1
  fi
  if ! wait_for_gateway; then
    cat "$EVIDENCE_DIR/daemon-positive.log" >&2
    exit 1
  fi
}

start_negative_daemon() {
  local neg_socket="$TMP_ROOT/negative/openburnbar.sock"
  mkdir -p "$(dirname "$neg_socket")"
  chmod 700 "$(dirname "$neg_socket")"
  {
    echo "starting negative daemon"
    echo "socket=$neg_socket"
    echo "peer_codesig=enforced"
  } > "$EVIDENCE_DIR/daemon-negative.log"
  OPENBURNBAR_DAEMON_SOCKET_PATH="$neg_socket" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
  OPENBURNBAR_INDEX_DATABASE_PATH="$TMP_ROOT/negative.sqlite" \
  BURNBAR_FAKE_PROVIDER_OUTPUTS_FILE="$FAKE_OUTPUTS" \
  "$DAEMON_BIN" --version negative-daemon \
    >> "$EVIDENCE_DIR/daemon-negative.log" 2>&1 &
  NEGATIVE_DAEMON_PID=$!
  if ! wait_for_socket "$neg_socket" "$NEGATIVE_DAEMON_PID"; then
    cat "$EVIDENCE_DIR/daemon-negative.log" >&2
    exit 1
  fi
  printf '%s\n' "$neg_socket"
}

record_permissions() {
  {
    echo "### socket and parent permissions"
    stat -c 'socket path=%n mode=%a type=%F' "$SOCKET_PATH"
    stat -c 'parent path=%n mode=%a type=%F' "$(dirname "$SOCKET_PATH")"
  } > "$EVIDENCE_DIR/socket-permissions.txt"
}

record_raw_socket_roundtrip() {
  if ! command -v node >/dev/null 2>&1; then
    {
      echo "node unavailable in container"
      echo "AF_UNIX round-trip evidence captured through OpenBurnBarCLI in cli-transcript.txt"
    } > "$EVIDENCE_DIR/socket-roundtrip.jsonl"
    return 0
  fi

  SOCKET_PATH="$SOCKET_PATH" SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" node > "$EVIDENCE_DIR/socket-roundtrip.jsonl" <<'NODE'
const net = require("node:net");

const socketPath = process.env.SOCKET_PATH;
const token = process.env.SOCKET_AUTH_TOKEN;

function send(label, request) {
  return new Promise((resolve) => {
    const client = net.createConnection(socketPath);
    let data = "";
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      console.log(JSON.stringify({ label, ...result }));
      resolve();
    };
    client.setTimeout(2000, () => {
      client.destroy();
      finish({ event: "timeout", data });
    });
    client.on("connect", () => {
      client.end(`${JSON.stringify(request)}\n`);
    });
    client.on("data", (chunk) => {
      data += chunk.toString("utf8");
    });
    client.on("end", () => {
      finish({ event: "end", data: data.trim() });
    });
    client.on("error", (error) => {
      finish({ event: "error", error: error.message, data });
    });
    client.on("close", () => {
      finish({ event: "close", data: data.trim() });
    });
  });
}

(async () => {
  await send("raw-health", { id: "raw-health-1", method: "daemon.health", authToken: token });
  await send("raw-invalid-method", { id: "raw-invalid-1", method: "daemon.nope", authToken: token });
  await send("raw-oversize", {
    id: "raw-oversize-1",
    method: "daemon.health",
    authToken: token,
    pad: "x".repeat(70000)
  });
})();
NODE
}

record_subscription_phase() {
  local phase="$1"
  local mode="$2"
  local after_seq="${3:-1}"
  SOCKET_PATH="$SOCKET_PATH" SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" SUB_PHASE="$phase" SUB_MODE="$mode" SUB_AFTER_SEQ="$after_seq" node <<'NODE'
const net = require("node:net");

const socketPath = process.env.SOCKET_PATH;
const token = process.env.SOCKET_AUTH_TOKEN;
const phase = process.env.SUB_PHASE;
const mode = process.env.SUB_MODE;
const afterSeq = Number(process.env.SUB_AFTER_SEQ || "1");
const subscriptionID = "ipc-evidence-health-subscription";

function redact(request) {
  return { ...request, authToken: request.authToken ? "redacted-present" : null };
}

function send(label, request) {
  return new Promise((resolve) => {
    const client = net.createConnection(socketPath);
    let data = "";
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      const parsed = result.data ? JSON.parse(result.data) : null;
      console.log(JSON.stringify({
        phase,
        label,
        socketPath,
        authContext: {
          token: "redacted-present",
          capability: "run",
          peerCodesign: "disabled-debug-only"
        },
        request: redact(request),
        response: parsed
      }));
      resolve(parsed);
    };
    client.setTimeout(3000, () => {
      client.destroy();
      finish({ data: JSON.stringify({ error: "timeout" }) });
    });
    client.on("connect", () => {
      client.end(`${JSON.stringify(request)}\n`);
    });
    client.on("data", (chunk) => {
      data += chunk.toString("utf8");
    });
    client.on("end", () => {
      finish({ data: data.trim() });
    });
    client.on("error", (error) => {
      finish({ data: JSON.stringify({ error: error.message }) });
    });
  });
}

(async () => {
  if (mode === "start") {
    const started = await send("subscription.start", {
      id: `${phase}-subscription-start`,
      method: "subscription.start",
      authToken: token,
      params: {
        topic: "health",
        requested_subscription_id: subscriptionID,
        client_id: "ipc-evidence-cli"
      }
    });
    const seq = started && started.result && Number.isFinite(started.result.seq) ? started.result.seq : 1;
    await send("subscription.resume", {
      id: `${phase}-subscription-resume`,
      method: "subscription.resume",
      authToken: token,
      params: {
        subscription_id: subscriptionID,
        topic: "health",
        after_seq: seq,
        client_id: "ipc-evidence-cli"
      }
    });
    return;
  }
  await send("subscription.resume", {
    id: `${phase}-subscription-resume`,
    method: "subscription.resume",
    authToken: token,
    params: {
      subscription_id: subscriptionID,
      topic: "health",
      after_seq: afterSeq,
      client_id: "ipc-evidence-cli"
    }
  });
})();
NODE
}

record_subscription_e2e() {
  : > "$EVIDENCE_DIR/subscription-e2e-transcript.jsonl"
  {
    echo "{\"phase\":\"setup\",\"socket_path\":\"$SOCKET_PATH\",\"gateway\":\"127.0.0.1:$PORT\",\"transport\":\"AF_UNIX newline-framed BurnBarRPC\",\"gateway_health\":\"$(http_get "/health" "Bearer $GATEWAY_TOKEN" | head -n 1 | tr -d '\r')\"}"
    record_subscription_phase "before-restart" "start" "0"
  } >> "$EVIDENCE_DIR/subscription-e2e-transcript.jsonl"
  restart_positive_daemon
  {
    echo "{\"phase\":\"after-restart-setup\",\"socket_path\":\"$SOCKET_PATH\",\"gateway\":\"127.0.0.1:$PORT\",\"transport\":\"AF_UNIX newline-framed BurnBarRPC\",\"gateway_health\":\"$(http_get "/health" "Bearer $GATEWAY_TOKEN" | head -n 1 | tr -d '\r')\"}"
    record_subscription_phase "after-restart" "resume" "2"
  } >> "$EVIDENCE_DIR/subscription-e2e-transcript.jsonl"
}

verify_subscription_e2e() {
  SUBSCRIPTION_TRANSCRIPT="$EVIDENCE_DIR/subscription-e2e-transcript.jsonl" \
  SUBSCRIPTION_ASSERTION="$EVIDENCE_DIR/subscription-e2e-assertion.json" \
  node <<'NODE'
const fs = require("node:fs");

const transcript = process.env.SUBSCRIPTION_TRANSCRIPT;
const assertionPath = process.env.SUBSCRIPTION_ASSERTION;
const rows = fs.readFileSync(transcript, "utf8")
  .split("\n")
  .map((line) => line.trim())
  .filter(Boolean)
  .map((line) => JSON.parse(line));

function fail(message) {
  throw new Error(message);
}

function findRow(phase, label) {
  const row = rows.find((entry) => entry.phase === phase && entry.label === label);
  if (!row) fail(`missing subscription transcript row ${phase}/${label}`);
  return row;
}

function requireResult(row) {
  if (row.response?.error) {
    fail(`${row.phase}/${row.label} returned RPC error ${JSON.stringify(row.response.error)}`);
  }
  if (!row.response?.result) {
    fail(`${row.phase}/${row.label} missing result`);
  }
  return row.response.result;
}

const setup = rows.find((entry) => entry.phase === "setup");
const restarted = rows.find((entry) => entry.phase === "after-restart-setup");
if (!setup || !/^HTTP\/1\.1 200/.test(setup.gateway_health || "")) {
  fail("initial gateway setup/health row missing");
}
if (!restarted || !/^HTTP\/1\.1 200/.test(restarted.gateway_health || "")) {
  fail("after-restart gateway setup/health row missing");
}

const start = requireResult(findRow("before-restart", "subscription.start"));
const beforeResume = requireResult(findRow("before-restart", "subscription.resume"));
const afterResume = requireResult(findRow("after-restart", "subscription.resume"));

if (start.subscription_id !== "ipc-evidence-health-subscription") {
  fail(`unexpected subscription_id ${start.subscription_id}`);
}
if (start.first_snapshot !== true) {
  fail("subscription.start did not deliver first snapshot");
}
if (!Array.isArray(start.events) || start.events.length === 0) {
  fail("subscription.start delivered no events");
}
if (!Number.isInteger(start.seq) || start.seq < 1) {
  fail("subscription.start seq missing");
}
if (!Number.isInteger(beforeResume.seq) || beforeResume.seq <= start.seq) {
  fail("subscription.resume before restart did not advance seq");
}
if (!Number.isInteger(afterResume.seq) || afterResume.seq <= 2) {
  fail("subscription.resume after restart did not resume past requested seq");
}
if (afterResume.recovered_after_restart !== true) {
  fail("after-restart resume did not record recovery");
}
if (afterResume.disconnect_detected !== true) {
  fail("after-restart resume did not record disconnect detection");
}
if (afterResume.terminal_state_delivered !== true) {
  fail("after-restart resume did not record terminal-state delivery");
}
for (const result of [start, beforeResume, afterResume]) {
  if (result.degraded_fallback !== true) {
    fail(`subscription result ${result.subscription_id} missing explicit degraded fallback row`);
  }
  if (result.backpressure !== "coalesce_latest_per_topic") {
    fail(`subscription result ${result.subscription_id} missing backpressure semantics`);
  }
}

const assertion = {
  ok: true,
  transcript,
  rowCount: rows.length,
  setupGatewayHealth: setup.gateway_health,
  afterRestartGatewayHealth: restarted.gateway_health,
  subscriptionID: start.subscription_id,
  startSeq: start.seq,
  beforeRestartResumeSeq: beforeResume.seq,
  afterRestartResumeSeq: afterResume.seq,
  recoveredAfterRestart: afterResume.recovered_after_restart,
  disconnectDetected: afterResume.disconnect_detected,
  terminalStateDelivered: afterResume.terminal_state_delivered,
  degradedFallback: afterResume.degraded_fallback,
  backpressure: afterResume.backpressure
};
fs.writeFileSync(assertionPath, `${JSON.stringify(assertion, null, 2)}\n`);
console.log(`subscription_e2e_assertion=${assertionPath}`);
NODE
}

record_http_gateway() {
  {
    echo "### GET /health without auth"
    http_get "/health" ""
    echo
    echo "### GET /health wrong bearer"
    http_get "/health" "Bearer wrong-token"
    echo
    echo "### GET /health correct bearer"
    http_get "/health" "Bearer $GATEWAY_TOKEN"
    echo
    echo "### GET /v1/models correct bearer"
    http_get "/v1/models" "Bearer $GATEWAY_TOKEN"
    echo
    echo "### POST /v1/chat/completions correct bearer"
    http_post_json "/v1/chat/completions" "Bearer $GATEWAY_TOKEN" '{"model":"glm-5","messages":[{"role":"user","content":"hello"}]}'
  } > "$EVIDENCE_DIR/http-transcript.txt"
}

record_gateway_bind_safety() {
  local port_hex
  port_hex="$(printf '%04X' "$PORT")"
  {
    echo "### listener bind trace"
    echo "expected_loopback=127.0.0.1:$PORT"
    if [[ -r /proc/net/tcp ]]; then
      awk -v port="$port_hex" '$2 ~ ":" port { print }' /proc/net/tcp
    fi
    echo
    echo "### wildcard bind rejected"
  } > "$EVIDENCE_DIR/gateway-bind.txt"

  local bind_pid
  OPENBURNBAR_DAEMON_SOCKET_PATH="$TMP_ROOT/wildcard.sock" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
  OPENBURNBAR_GATEWAY_ENABLED=1 \
  OPENBURNBAR_GATEWAY_HOST=0.0.0.0 \
  OPENBURNBAR_GATEWAY_PORT="$((PORT + 1))" \
  OPENBURNBAR_GATEWAY_AUTH_TOKEN="$GATEWAY_TOKEN" \
  "$DAEMON_BIN" --version wildcard-bind-negative \
    >> "$EVIDENCE_DIR/gateway-bind.txt" 2>&1 &
  bind_pid=$!
  if ! wait_for_log "$EVIDENCE_DIR/gateway-bind.txt" "Gateway wildcard bind addresses are not allowed"; then
    terminate_pid "$bind_pid"
    echo "wildcard bind rejection log missing" >&2
    exit 1
  fi
  terminate_pid "$bind_pid"
  echo "wildcard_rejected=true" >> "$EVIDENCE_DIR/gateway-bind.txt"

  {
    echo
    echo "### loopback without auth rejected"
  } >> "$EVIDENCE_DIR/gateway-bind.txt"
  OPENBURNBAR_DAEMON_SOCKET_PATH="$TMP_ROOT/noauth.sock" \
  OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
  OPENBURNBAR_GATEWAY_ENABLED=1 \
  OPENBURNBAR_GATEWAY_HOST=127.0.0.1 \
  OPENBURNBAR_GATEWAY_PORT="$((PORT + 2))" \
  "$DAEMON_BIN" --version noauth-gateway-negative \
    >> "$EVIDENCE_DIR/gateway-bind.txt" 2>&1 &
  bind_pid=$!
  if ! wait_for_log "$EVIDENCE_DIR/gateway-bind.txt" "The gateway requires an auth token"; then
    terminate_pid "$bind_pid"
    echo "unauthenticated gateway rejection log missing" >&2
    exit 1
  fi
  terminate_pid "$bind_pid"
  echo "noauth_rejected=true" >> "$EVIDENCE_DIR/gateway-bind.txt"
}

wait_for_log() {
  local file="$1"
  local pattern="$2"
  for _ in $(seq 1 40); do
    if grep -q "$pattern" "$file" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

record_negative_cases() {
  : > "$EVIDENCE_DIR/negative-cases.txt"

  capture_cli_expected_failure "socket auth rejects wrong token" \
    env OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
      OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="wrong-token" \
      "$CLI_BIN" health

  local neg_socket
  neg_socket="$(start_negative_daemon)"

  capture_cli_expected_failure "peer trust rejects non-first-party executable name" \
    bash -c 'cp "$0" "$1" && chmod +x "$1" && OPENBURNBAR_DAEMON_SOCKET_PATH="$2" OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$3" "$1" health' \
    "$CLI_BIN" "$TMP_ROOT/NotOpenBurnBarClient" "$neg_socket" "$SOCKET_TOKEN"

  capture_cli_expected_failure "cli capability profile denies config credential write during mock-provider seed" \
    env OPENBURNBAR_DAEMON_SOCKET_PATH="$neg_socket" \
      OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
      "$CLI_BIN" run create --prompt "capability denial" --mock-provider
}

record_cli_flow() {
  : > "$EVIDENCE_DIR/cli-transcript.txt"

  capture_cli "health" health >/dev/null
  capture_cli "health json" health --json >/dev/null
  capture_cli "service status" service status >/dev/null
  capture_cli "service foreground" service foreground >/dev/null

  local restart_output
  set +e
  restart_output="$(
    OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
    "$CLI_BIN" service restart 2>&1
  )"
  local restart_rc=$?
  set -e
  {
    echo "### service restart unsupported foreground"
    echo "command=openburnbar-cli service restart"
    printf '%s\n' "$restart_output"
    echo "exit_code=$restart_rc"
    echo
  } >> "$EVIDENCE_DIR/cli-transcript.txt"
  if [[ "$restart_rc" -ne 69 ]]; then
    echo "expected service restart exit 69, got $restart_rc" >&2
    exit 1
  fi

  capture_cli "capabilities json" capabilities --json >/dev/null
  capture_cli "diagnostics bundle" diagnostics --output "$TMP_ROOT/diagnostics" >/dev/null
  cp "$TMP_ROOT/diagnostics/diagnostics.json" "$EVIDENCE_DIR/diagnostics.json"
  if grep -q "$SOCKET_TOKEN" "$EVIDENCE_DIR/diagnostics.json" "$EVIDENCE_DIR/cli-transcript.txt"; then
    echo "socket token leaked into diagnostics evidence" >&2
    exit 1
  fi

  local sub_output
  sub_output="$(capture_cli "subscribe health" subscribe health)"
  printf '%s\n' "$sub_output" > "$SUBSCRIPTION_FILE"
  local sub_id
  local sub_seq
  sub_id="$(awk -F= '/subscription_id=/{print $2; exit}' "$SUBSCRIPTION_FILE")"
  sub_seq="$(awk -F= '/^(last_)?seq=/{print $2; exit}' "$SUBSCRIPTION_FILE")"
  if [[ -z "$sub_id" || -z "$sub_seq" ]]; then
    echo "could not parse subscription output" >&2
    exit 1
  fi
  capture_cli "subscription resume health" subscription-resume "$sub_id" --topic health --after-seq "$sub_seq" >/dev/null
  restart_positive_daemon
  capture_cli "subscription resume health after daemon restart" subscription-resume "$sub_id" --topic health --after-seq "$sub_seq" >/dev/null

  local run_output
  run_output="$(capture_cli "run create mock provider" run create --prompt "linux evidence run" --model gpt-5.5 --mock-provider)"
  printf '%s\n' "$run_output" > "$RUN_ID_FILE"
  local run_id
  run_id="$(awk -F'[ =]' '/run_id=/{print $2; exit}' "$RUN_ID_FILE")"
  if [[ -z "$run_id" ]]; then
    echo "could not parse run id" >&2
    exit 1
  fi
  capture_cli "run list" run list >/dev/null
  capture_cli "run get" run get "$run_id" >/dev/null
  capture_cli "run poll" run poll "$run_id" >/dev/null
  capture_cli "subscribe run" subscribe run "$run_id" >/dev/null
}

record_ipc_drift() {
  {
    echo "### generator"
    if command -v node >/dev/null 2>&1; then
      echo "generator_source=tools/ipc/generate-burnbarrpc-canon.mjs"
      node tools/ipc/generate-burnbarrpc-canon.mjs
      echo "generator_exit_code=$?"
      echo "generated_swift=OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCIPCCanon.generated.swift"
      echo "generated_typescript=extensions/openburnbar/src/generated/burnbar-rpc-ipc-canon.generated.ts"
      echo "generated_json=docs/linux-port/generated/burnbar-rpc-ipc-canon.linux.json"
      echo
      echo "### method coverage table"
      node - <<'NODE'
const fs = require("node:fs");
const canon = JSON.parse(fs.readFileSync("docs/linux-port/generated/burnbar-rpc-ipc-canon.linux.json", "utf8"));
for (const row of canon.methods) {
  console.log(`${row.id}\tcase=${row.caseName}\tdomain=${row.domain}\tcapability=${row.capability}\tparams=${row.params}\tresult=${row.result}\terror=${row.error}`);
}
NODE
      echo
      echo "### check"
      node tools/ipc/generate-burnbarrpc-canon.mjs --check
      echo "check_exit_code=$?"
      echo
      echo "### negative fixture"
      echo "fixture_path=docs/linux-port/fixtures/burnbarrpc-canon-missing-subscription.fixture.json"
      set +e
      node tools/ipc/generate-burnbarrpc-canon.mjs --fixture docs/linux-port/fixtures/burnbarrpc-canon-missing-subscription.fixture.json
      local fixture_rc=$?
      set -e
      echo "fixture_exit_code=$fixture_rc"
      if [[ "$fixture_rc" -eq 0 ]]; then
        echo "fixture drift check unexpectedly succeeded" >&2
        exit 1
      fi
    else
      echo "node unavailable in container; run host generator/check as separate verification"
    fi
  } > "$EVIDENCE_DIR/ipc-drift.txt" 2>&1
}

record_source_scans() {
  search_source() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
      rg -n "$pattern" "$@" || true
    else
      grep -RInE "$pattern" "$@" || true
    fi
  }

  {
    echo "### forbidden parallel transport names"
    search_source 'DaemonEnvelope|DaemonTransport|UnixSocketTransport|DaemonCore/Transport|NSXPC.*daemon|daemon.*NSXPC' \
      OpenBurnBarDaemon/Sources OpenBurnBarCore/Sources
    echo
    echo "### AF_UNIX hardening scan"
    search_source 'sun_len|MSG_NOSIGNAL|EINTR|chmod|posixPermissions|SO_PEERCRED|S_IFSOCK|S_IFREG|ENAMETOOLONG|readAll|writeAll' \
      OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift \
      OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift \
      OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarDaemonPeerAuthenticator.swift
    echo
    echo "### capability/subscription classification scan"
    search_source 'subscriptionStart|subscriptionResume|case subscription|cliSupport|capability_denied' \
      OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift \
      OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift \
      OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/RPC \
      OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarDaemonServer.swift
  } > "$EVIDENCE_DIR/source-scan.txt"
}

record_strace_or_equivalent() {
  if command -v strace >/dev/null 2>&1; then
    set +e
    OPENBURNBAR_DAEMON_SOCKET_PATH="$SOCKET_PATH" \
    OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN="$SOCKET_TOKEN" \
    strace -f -e trace=connect,read,write -o "$EVIDENCE_DIR/strace-cli-health.log" "$CLI_BIN" health \
      > "$EVIDENCE_DIR/strace-cli-health.stdout.txt" 2>&1
    local rc=$?
    set -e
    echo "strace_exit_code=$rc" > "$EVIDENCE_DIR/strace-summary.txt"
  else
    {
      echo "strace unavailable in container"
      echo "equivalent evidence: socket-permissions.txt, socket-roundtrip.jsonl, cli-transcript.txt, source-scan.txt"
    } > "$EVIDENCE_DIR/strace-summary.txt"
  fi
}

start_positive_daemon
record_permissions
record_raw_socket_roundtrip
record_cli_flow
record_subscription_e2e
verify_subscription_e2e
record_http_gateway
record_gateway_bind_safety
record_negative_cases
record_ipc_drift
record_source_scans
record_strace_or_equivalent

{
  echo "evidence_dir=$EVIDENCE_DIR"
  echo "daemon_pid=$DAEMON_PID"
  echo "gateway_port=$PORT"
  echo "socket_path=$SOCKET_PATH"
  echo "result=complete"
} > "$EVIDENCE_DIR/summary.txt"

echo "evidence written to $EVIDENCE_DIR"
