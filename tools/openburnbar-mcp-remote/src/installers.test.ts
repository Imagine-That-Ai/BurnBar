import assert from "node:assert/strict";
import test from "node:test";
import { installer } from "./installers.js";
import { decryptSearchResultJson } from "./decrypt.js";

test("installers cover every required client", () => {
  for (const kind of ["codex", "claude", "droid", "kimi", "forge", "generic"] as const) {
    assert.match(installer(kind), /openburnbar/);
  }
  assert.match(installer("generic"), /mcpServers/);
});

test("sealed result decrypt is no-op without a local vault key", () => {
  delete process.env.OPENBURNBAR_CLOUD_VAULT_KEY_BASE64;
  const input = JSON.stringify({ hits: [{ sealedTitle: { algorithm: "AES-256-GCM" } }] });
  const output = JSON.parse(decryptSearchResultJson(input)) as { hits: Array<{ title?: string }> };
  assert.equal(output.hits[0].title, undefined);
});
