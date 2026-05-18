const command = "openburnbar-mcp-remote";
const endpoint = "https://mcp.burnbar.ai/mcp";
const tokenEnvVar = "OPENBURNBAR_MCP_ACCESS_TOKEN";
const localPythonPath = "/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/.venv/bin/python";
const localServerPath = "/absolute/path/to/OpenBurnBar/tools/openburnbar-mcp/server.py";

export type ClientKind = "codex" | "claude" | "droid" | "kimi" | "forge" | "generic";

function codexConfig(): string {
  return [
    "# OpenBurnBar MCP — Codex CLI config",
    "# Paste this into ~/.codex/config.toml (or a trusted project's .codex/config.toml).",
    "",
    "# Option A (recommended) — stdio shim over the hosted MCP.",
    "# Forwards JSON-RPC to https://mcp.burnbar.ai/mcp, decrypts sealed search",
    "# results locally, and pins MCP-Protocol-Version to 2025-11-25 to match the",
    "# server. The shim reads the bearer from macOS Keychain or",
    `# ${tokenEnvVar}. Run \`openburnbar mcp login <bearer>\` once first.`,
    "[mcp_servers.openburnbar]",
    `command = "${command}"`,
    'args = ["mcp", "serve"]',
    "startup_timeout_sec = 15",
    "tool_timeout_sec = 60",
    "",
    "# Option B — native streamable HTTP, no subprocess.",
    "# Sealed search/body fields arrive as ciphertext (no local decrypt). Set",
    `# ${tokenEnvVar} in your shell before launching codex.`,
    "# Requires a Codex build whose MCP client negotiates protocolVersion",
    "# \"2025-11-25\" — otherwise the server returns 400 unsupported_protocol_version.",
    "# [mcp_servers.openburnbar-http]",
    `# url = "${endpoint}"`,
    `# bearer_token_env_var = "${tokenEnvVar}"`,
    "# startup_timeout_sec = 15",
    "# tool_timeout_sec = 60",
    "",
    "# Option C — local SQLite MCP, no network, no auth.",
    "# Read-only access to ~/Library/Application Support/OpenBurnBar/openburnbar.sqlite.",
    "# Replace the paths with your clone location.",
    "[mcp_servers.openburnbar-local]",
    `command = "${localPythonPath}"`,
    `args = ["${localServerPath}"]`,
    "",
    "# Quick-add for Option A via CLI (skips manual TOML editing):",
    `#   codex mcp add openburnbar -- ${command} mcp serve`,
    ""
  ].join("\n");
}

export function installer(kind: ClientKind): string {
  const json = JSON.stringify({
    mcpServers: {
      openburnbar: {
        command,
        args: ["mcp", "serve"],
        env: {
          OPENBURNBAR_MCP_ENDPOINT: endpoint
        }
      }
    }
  }, null, 2);
  switch (kind) {
    case "codex":
      return codexConfig();
    case "claude":
      return `claude mcp add openburnbar -- ${command} mcp serve`;
    case "droid":
      return json;
    case "kimi":
      return json;
    case "forge":
      return json;
    case "generic":
      return json;
  }
}
