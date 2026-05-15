#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

npm ci --prefix tools/openburnbar-mcp-remote
npm --prefix tools/openburnbar-mcp-remote run build

node tools/openburnbar-mcp-remote/lib/index.js mcp install codex | grep -q 'openburnbar'
node tools/openburnbar-mcp-remote/lib/index.js mcp install claude | grep -q 'openburnbar'
node tools/openburnbar-mcp-remote/lib/index.js mcp install droid | grep -q '"mcpServers"'
node tools/openburnbar-mcp-remote/lib/index.js mcp install kimi | grep -q '"mcpServers"'
node tools/openburnbar-mcp-remote/lib/index.js mcp install forge | grep -q '"mcpServers"'
node tools/openburnbar-mcp-remote/lib/index.js mcp install generic | grep -q '"mcpServers"'

echo "hosted MCP compatibility config smoke passed"
