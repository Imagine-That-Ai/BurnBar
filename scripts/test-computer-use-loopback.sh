#!/bin/zsh
# scripts/test-computer-use-loopback.sh
#
# CI smoke test for the Playwright bridge. Spawns the bridge, sends a
# canned set of JSON-RPC requests, validates the responses, and exits
# non-zero on any decode failure or RPC error.
#
# Used by .github/workflows/computer-use-loopback-test.yml.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE="${OPENBURNBAR_PLAYWRIGHT_BRIDGE:-$ROOT/OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js}"

if [[ ! -f "$BRIDGE" ]]; then
  echo "bridge script not found at $BRIDGE" >&2
  exit 2
fi

# Verify node + playwright are reachable.
command -v node >/dev/null 2>&1 || { echo "node missing" >&2; exit 2; }
GLOBAL_NODE_PATH="$(npm root -g 2>/dev/null || true)"
if [[ -n "$GLOBAL_NODE_PATH" ]]; then
  # Prefer the pinned global Playwright from scripts/install-playwright.sh.
  # A pre-existing NODE_PATH may point at a different Playwright version whose
  # browser binary cache is not installed, causing false-negative smoke tests.
  export NODE_PATH="$GLOBAL_NODE_PATH${NODE_PATH:+:$NODE_PATH}"
fi
node -e 'require("playwright")' || { echo "playwright module missing" >&2; exit 2; }

INPUT_FIFO=$(mktemp -u)
OUTPUT_FIFO=$(mktemp -u)
mkfifo "$INPUT_FIFO"
mkfifo "$OUTPUT_FIFO"
trap 'rm -f "$INPUT_FIFO" "$OUTPUT_FIFO"' EXIT

node "$BRIDGE" --headless --session-id "loopback" --per-action-timeout-ms 15000 \
  < "$INPUT_FIFO" > "$OUTPUT_FIFO" 2> /tmp/playwright-bridge-stderr.log &
BRIDGE_PID=$!
trap 'kill $BRIDGE_PID 2>/dev/null || true; rm -f "$INPUT_FIFO" "$OUTPUT_FIFO"' EXIT

# Open both ends of the FIFOs so the bridge does not see EOF.
exec 3>"$INPUT_FIFO"
exec 4<"$OUTPUT_FIFO"

send() {
  echo "$1" >&3
}

read_response() {
  IFS= read -r line <&4
  echo "$line"
}

assert_ok() {
  local resp="$1"
  echo "$resp" | node -e '
    let buf = ""; process.stdin.on("data", d => buf += d).on("end", () => {
      const r = JSON.parse(buf);
      if (!r.ok) { console.error("RPC error:", r.error); process.exit(1); }
      console.log("OK id=" + r.id + " kind=" + (r.result && r.result.kind));
    });
  '
}

# 1. Navigate to about:blank
send '{"id":1,"method":"goto","params":{"url":"about:blank","timeoutMs":5000}}'
RESP1=$(read_response); assert_ok "$RESP1"

# 2. Current URL
send '{"id":2,"method":"current_url","params":{}}'
RESP2=$(read_response); assert_ok "$RESP2"

# 3. Shutdown
send '{"id":3,"method":"shutdown","params":{}}'
RESP3=$(read_response); assert_ok "$RESP3"

wait $BRIDGE_PID || true
echo "playwright bridge loopback smoke: OK"
