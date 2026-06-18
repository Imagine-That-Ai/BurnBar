#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'MCP_HEALTH_PATH:-/readyz' scripts/deploy-hosted-mcp.sh || \
  fail "hosted MCP deploy health gate must default to /readyz"

grep -q 'url.pathname === "/readyz"' services/hosted-mcp/src/server.ts || \
  fail "hosted MCP server must expose /readyz for deploy and uptime probes"

echo "PASS: hosted MCP deploy health gate defaults to /readyz"
