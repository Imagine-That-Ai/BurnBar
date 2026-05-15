import assert from "node:assert/strict";
import test from "node:test";
import { MCP_RESOURCE } from "./config.js";
import { mintDevelopmentToken, verifyBearerToken } from "./auth.js";
import { signCursor, verifyCursor } from "./cursors.js";
import { redact } from "./redaction.js";
import { listMcpTools } from "./toolRegistry.js";

test("verifies HMAC bearer token claims and rejects wrong audience", () => {
  process.env.MCP_TOKEN_HMAC_SECRET = "unit-secret";
  const token = mintDevelopmentToken({
    sub: "user-1",
    aud: MCP_RESOURCE,
    client_id: "client-1",
    scopes: ["search:read", "conversation:read", "usage:read", "index:status"],
    entitlement_family: "burnbar_pro",
    grant_mode: "local_decrypt_shim",
    exp: Math.floor(Date.now() / 1000) + 60,
    jti: "jti-1"
  }, "unit-secret");
  assert.equal(verifyBearerToken(`Bearer ${token}`).sub, "user-1");

  const bad = mintDevelopmentToken({
    sub: "user-1",
    aud: "https://example.invalid/mcp",
    client_id: "client-1",
    scopes: ["search:read"],
    entitlement_family: "burnbar_pro",
    grant_mode: "local_decrypt_shim",
    exp: Math.floor(Date.now() / 1000) + 60,
    jti: "jti-2"
  }, "unit-secret");
  assert.throws(() => verifyBearerToken(`Bearer ${bad}`), /audience/);
});

test("cursor signing rejects tampering and scope mismatch", () => {
  process.env.MCP_CURSOR_HMAC_SECRET = "cursor-secret";
  const cursor = signCursor({ uid: "u1", tool: "burnbar_search_conversations", offset: 10, exp: Date.now() + 60_000 });
  assert.equal(verifyCursor(cursor, "u1", "burnbar_search_conversations").offset, 10);
  assert.throws(() => verifyCursor(`${cursor}x`, "u1", "burnbar_search_conversations"), /signature|Malformed/);
  assert.throws(() => verifyCursor(cursor, "u2", "burnbar_search_conversations"), /does not match/);
});

test("registry exposes required tool surface and redaction strips raw content", () => {
  const names = listMcpTools().tools.map((tool) => tool.name).sort();
  assert.deepEqual(names, [
    "burnbar_get_conversation_body",
    "burnbar_list_search_facets",
    "burnbar_list_search_index_status",
    "burnbar_recent_usage",
    "burnbar_resolve_capabilities",
    "burnbar_search_conversations"
  ].sort());
  assert.deepEqual(redact({ query: "secret words", nested: { body: "plaintext" } }), {
    query: "[REDACTED]",
    nested: { body: "[REDACTED]" }
  });
});
