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

node - <<'NODE'
const { execFileSync } = require("node:child_process");
for (const kind of ["droid", "kimi", "forge", "generic"]) {
  const raw = execFileSync("node", ["tools/openburnbar-mcp-remote/lib/index.js", "mcp", "install", kind], { encoding: "utf8" });
  const parsed = JSON.parse(raw);
  const server = parsed.mcpServers && parsed.mcpServers.openburnbar;
  if (!server || server.command !== "openburnbar-mcp-remote" || !Array.isArray(server.args)) {
    throw new Error(`invalid ${kind} installer JSON`);
  }
}
NODE

if [[ "${OPENBURNBAR_MCP_REAL_CLIENTS:-0}" == "1" ]]; then
  for bin in codex claude droid kimi forge; do
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "missing required client binary for real compatibility proof: $bin" >&2
      exit 1
    fi
  done

  temp_home="$(mktemp -d)"
  cleanup() {
    rm -rf "$temp_home"
  }
  trap cleanup EXIT

  HOME="$temp_home" codex mcp add openburnbar -- openburnbar-mcp-remote mcp serve >"$temp_home/codex-mcp-add.out"
  grep -q 'openburnbar-mcp-remote' "$temp_home/.codex/config.toml"

  HOME="$temp_home" claude mcp add -s user openburnbar -- openburnbar-mcp-remote mcp serve >"$temp_home/claude-mcp-add.out"
  grep -q 'openburnbar-mcp-remote' "$temp_home/.claude.json"

  droid_bin="$(command -v droid)"
  if ! HOME="$temp_home" "$droid_bin" mcp add openburnbar openburnbar-mcp-remote mcp serve >"$temp_home/droid-mcp-add.out" 2>"$temp_home/droid-mcp-add.err"; then
    factory_droid_bin="${DROID_REAL_BIN:-$HOME/.local/lib/factory/droid}"
    if [[ ! -x "$factory_droid_bin" ]]; then
      cat "$temp_home/droid-mcp-add.err" >&2
      echo "droid wrapper failed under temporary HOME and no executable DROID_REAL_BIN was found" >&2
      exit 1
    fi
    HOME="$temp_home" "$factory_droid_bin" mcp add openburnbar openburnbar-mcp-remote mcp serve >"$temp_home/droid-mcp-add.out"
  fi
  grep -q 'openburnbar-mcp-remote' "$temp_home/.factory/mcp.json"

  HOME="$temp_home" kimi mcp add --transport stdio openburnbar -- openburnbar-mcp-remote mcp serve >"$temp_home/kimi-mcp-add.out"
  grep -q 'openburnbar-mcp-remote' "$temp_home/.kimi/mcp.json"

  HOME="$temp_home" forge mcp import '{"mcpServers":{"openburnbar":{"command":"openburnbar-mcp-remote","args":["mcp","serve"]}}}' --scope user >"$temp_home/forge-mcp-add.out"
  grep -q 'openburnbar-mcp-remote' "$temp_home/.forge/.mcp.json"

  echo "hosted MCP real client config proof passed"
fi

echo "hosted MCP compatibility config smoke passed"
