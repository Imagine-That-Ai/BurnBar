import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";
import { installer } from "./installers.js";
import { decryptSearchResultJson } from "./decrypt.js";

test("installers cover every required client", () => {
  for (const kind of ["codex", "claude", "droid", "kimi", "forge", "generic"] as const) {
    assert.match(installer(kind), /openburnbar/);
  }
  assert.match(installer("generic"), /mcpServers/);
  assert.match(installer("generic"), /https:\/\/mcp\.burnbar\.ai\/mcp/);
});

test("codex installer emits hosted + local + http TOML blocks", () => {
  const out = installer("codex");
  assert.match(out, /\[mcp_servers\.openburnbar\]/);
  assert.match(out, /command = "openburnbar-mcp-remote"/);
  assert.match(out, /args = \["mcp", "serve"\]/);
  assert.match(out, /# \[mcp_servers\.openburnbar-http\]/);
  assert.match(out, /# url = "https:\/\/mcp\.burnbar\.ai\/mcp"/);
  assert.match(out, /# bearer_token_env_var = "OPENBURNBAR_MCP_ACCESS_TOKEN"/);
  assert.match(out, /\[mcp_servers\.openburnbar-local\]/);
  assert.match(out, /server\.py/);
  assert.match(out, /codex mcp add openburnbar -- openburnbar-mcp-remote mcp serve/);
});

test("codex installer keeps openburnbar-http commented out by default", () => {
  const out = installer("codex");
  const activeOpenburnbarHttp = out
    .split(/\n/u)
    .filter((line) => !line.trimStart().startsWith("#"))
    .some((line) => line.includes("[mcp_servers.openburnbar-http]"));
  assert.equal(activeOpenburnbarHttp, false, "openburnbar-http block must remain commented");
});

test("codex installer balances [section] count with body lines", () => {
  const out = installer("codex");
  const activeSections = out
    .split(/\n/u)
    .filter((line) => !line.trimStart().startsWith("#"))
    .filter((line) => /^\[mcp_servers\./u.test(line));
  assert.deepEqual(activeSections, [
    "[mcp_servers.openburnbar]",
    "[mcp_servers.openburnbar-local]"
  ]);
});

test("non-codex installers stay byte-identical", () => {
  assert.equal(installer("claude"), "claude mcp add openburnbar -- openburnbar-mcp-remote mcp serve");
  for (const kind of ["droid", "kimi", "forge", "generic"] as const) {
    const parsed = JSON.parse(installer(kind)) as { mcpServers: { openburnbar: { command: string; args: string[]; env: Record<string, string> } } };
    assert.equal(parsed.mcpServers.openburnbar.command, "openburnbar-mcp-remote");
    assert.deepEqual(parsed.mcpServers.openburnbar.args, ["mcp", "serve"]);
    assert.equal(parsed.mcpServers.openburnbar.env.OPENBURNBAR_MCP_ENDPOINT, "https://mcp.burnbar.ai/mcp");
  }
});

test("sealed result decrypt is no-op without a local vault key", () => {
  delete process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64;
  const input = JSON.stringify({ hits: [{ sealedTitle: { algorithm: "AES-256-GCM" } }] });
  const output = JSON.parse(decryptSearchResultJson(input)) as { hits: Array<{ title?: string }> };
  assert.equal(output.hits[0].title, undefined);
});

test("stdio shim ignores JSON-RPC notifications", async () => {
  const child = spawn(process.execPath, ["lib/index.js", "mcp", "serve"], {
    cwd: process.cwd(),
    stdio: ["pipe", "pipe", "pipe"]
  });
  let stdout = "";
  child.stdout.setEncoding("utf8");
  child.stdout.on("data", (chunk) => {
    stdout += chunk;
  });
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} })}\n`);
  await new Promise((resolve) => setTimeout(resolve, 150));
  child.kill();
  assert.equal(stdout, "");
});
