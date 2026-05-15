import assert from "node:assert/strict";
import test from "node:test";
import { MCP_RESOURCE } from "./config.js";
import { mintDevelopmentToken, verifyBearerToken } from "./auth.js";
import { signCursor, verifyCursor } from "./cursors.js";
import { requireActiveRemoteMcpClient } from "./entitlements.js";
import { handleMcpRequest } from "./mcp.js";
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

  const unsafeClient = mintDevelopmentToken({
    sub: "user-1",
    aud: MCP_RESOURCE,
    client_id: "../client",
    scopes: ["search:read"],
    entitlement_family: "burnbar_pro",
    grant_mode: "local_decrypt_shim",
    exp: Math.floor(Date.now() / 1000) + 60,
    jti: "jti-3"
  }, "unit-secret");
  assert.throws(() => verifyBearerToken(`Bearer ${unsafeClient}`), /client ID/);
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

test("remote MCP client revocation fails closed", async () => {
  const writes: unknown[] = [];
  const db = {
    doc(path: string) {
      return {
        async get() {
          if (path.endsWith("/active-client")) {
            return { exists: true, data: () => ({ displayName: "Active" }) };
          }
          if (path.endsWith("/revoked-client")) {
            return { exists: true, data: () => ({ revokedAt: new Date().toISOString() }) };
          }
          return { exists: false, data: () => undefined };
        },
        async set(value: unknown) {
          writes.push(value);
        }
      };
    }
  };

  await requireActiveRemoteMcpClient("user-1", "active-client", db as never);
  assert.equal(writes.length, 1);
  await assert.rejects(
    () => requireActiveRemoteMcpClient("user-1", "revoked-client", db as never),
    /revoked/
  );
  await assert.rejects(
    () => requireActiveRemoteMcpClient("user-1", "missing-client", db as never),
    /not found/
  );
});

test("MCP resources enforce scope, entitlement, and client revocation gates", async () => {
  const claims = {
    sub: "resource-user",
    aud: MCP_RESOURCE,
    client_id: "active-client",
    scopes: ["search:read", "conversation:read", "usage:read", "index:status"],
    entitlement_family: "burnbar_pro" as const,
    grant_mode: "local_decrypt_shim" as const,
    exp: Math.floor(Date.now() / 1000) + 60,
    jti: "resource-jti"
  };

  const db = {
    doc(path: string) {
      return {
        async get() {
          if (path.endsWith("/remote_mcp_clients/active-client")) {
            return { exists: true, data: () => ({ displayName: "Active" }) };
          }
          if (path.endsWith("/entitlements/burnbar_pro")) {
            return { exists: true, data: () => ({ active: true, expiresAt: new Date(Date.now() + 60_000).toISOString() }) };
          }
          return { exists: false, data: () => undefined };
        },
        async set() {}
      };
    },
    collection(path: string) {
      assert.equal(path, "users/resource-user/cloud_search_documents");
      return {
        limit() {
          return {
            async get() {
              return {
                docs: [{
                  id: "doc-1",
                  get(field: string) {
                    return field === "sourceID" ? "Session One" : undefined;
                  }
                }]
              };
            }
          };
        }
      };
    },
    async runTransaction(fn: (tx: unknown) => Promise<void>) {
      await fn({
        async get() {
          return { get: () => 0 };
        },
        set() {}
      });
    }
  };

  const listed = await handleMcpRequest(db as never, claims, {
    jsonrpc: "2.0",
    id: 1,
    method: "resources/list",
    params: {}
  }) as { result: { resources: Array<{ uri: string }> } };
  assert.equal(listed.result.resources[0]?.uri, "burnbar://conversation/doc-1");

  await assert.rejects(
    () => handleMcpRequest(db as never, { ...claims, scopes: ["search:read"] }, {
      jsonrpc: "2.0",
      id: 2,
      method: "resources/read",
      params: { uri: "burnbar://conversation/doc-1" }
    }),
    /Missing required scope conversation:read/
  );

  const revokedDb = {
    doc(path: string) {
      return {
        async get() {
          if (path.endsWith("/remote_mcp_clients/active-client")) {
            return { exists: true, data: () => ({ revokedAt: new Date().toISOString() }) };
          }
          return { exists: false, data: () => undefined };
        },
        async set() {}
      };
    }
  };
  await assert.rejects(
    () => handleMcpRequest(revokedDb as never, claims, {
      jsonrpc: "2.0",
      id: 3,
      method: "resources/list",
      params: {}
    }),
    /revoked/
  );
});
