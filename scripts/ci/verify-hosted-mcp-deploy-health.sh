#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

grep -q 'MCP_HEALTH_PATH:-/readyz' scripts/deploy-hosted-mcp.sh || \
  fail "hosted MCP deploy health gate must default to /readyz"

grep -q 'DEPLOY_SOURCE_DIR' scripts/deploy-hosted-mcp.sh || \
  fail "hosted MCP deploy script must support artifact-scoped deploy source directories"

grep -q 'OPENBURNBAR_HOSTED_MCP_SKIP_LOCAL_BUILD:-false' scripts/deploy-hosted-mcp.sh || \
  fail "hosted MCP deploy script must support skipping local build/test in credentialed artifact deploys"

grep -q 'OPENBURNBAR_HOSTED_MCP_ALLOW_SECRET_UPSERT:-false' scripts/deploy-hosted-mcp.sh || \
  fail "hosted MCP deploy script must default signer-secret upsert off"

grep -q 'url.pathname === "/readyz"' services/hosted-mcp/src/server.ts || \
  fail "hosted MCP server must expose /readyz for deploy and uptime probes"

echo "PASS: hosted MCP deploy health and artifact-boundary defaults are present"
