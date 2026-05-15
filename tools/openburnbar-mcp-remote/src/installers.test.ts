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
