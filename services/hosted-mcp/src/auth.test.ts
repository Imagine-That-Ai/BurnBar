import assert from "node:assert/strict";
import test from "node:test";
import { MCP_PROTOCOL_VERSION, MCP_RESOURCE } from "./config.js";
import { mintDevelopmentToken, verifyBearerToken } from "./auth.js";
import { signCursor, verifyCursor } from "./cursors.js";
import { requireActiveRemoteMcpClient } from "./entitlements.js";
import { handleMcpRequest } from "./mcp.js";
import { redact } from "./redaction.js";
import { listMcpTools, tools } from "./toolRegistry.js";
import type { HostedMcpFirestore, McpTransaction, RemoteMcpClientFirestore } from "./firestoreTypes.js";

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
    "burnbar_get_knowledge_document",
    "burnbar_list_resumable_conversations",
    "burnbar_list_search_facets",
    "burnbar_list_search_index_status",
    "burnbar_recent_usage",
    "burnbar_resume_conversation",
    "burnbar_resolve_capabilities",
    "burnbar_search_conversations",
    "burnbar_search_knowledge"
  ].sort());
  assert.deepEqual(redact({ query: "secret words", nested: { body: "plaintext" } }), {
    query: "[REDACTED]",
    nested: { body: "[REDACTED]" }
  });
  const resumeTool = tools.find((tool) => tool.name === "burnbar_resume_conversation");
  assert.deepEqual(resumeTool?.requiredScopes, ["conversation:read", "search:read"]);
});

test("remote MCP client revocation fails closed", async () => {
  const writes: unknown[] = [];
  const db: RemoteMcpClientFirestore = {
    doc(path: string) {
      return {
        async get() {
          if (path.endsWith("/active-client")) {
            return { exists: true, data: () => ({ displayName: "Active", allowedScopes: ["search:read"] }) };
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

  await requireActiveRemoteMcpClient("user-1", "active-client", db);
  assert.equal(writes.length, 1);
  await requireActiveRemoteMcpClient("user-1", "active-client", db);
  assert.equal(writes.length, 1);
  await assert.rejects(
    () => requireActiveRemoteMcpClient("user-1", "revoked-client", db),
    /revoked/
  );
  await assert.rejects(
    () => requireActiveRemoteMcpClient("user-1", "missing-client", db),
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

  const db: HostedMcpFirestore = {
    doc(path: string) {
      return {
        async get() {
          if (path.endsWith("/remote_mcp_clients/active-client")) {
            return { exists: true, data: () => ({ displayName: "Active", allowedScopes: claims.scopes }) };
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
    async runTransaction<T>(fn: (tx: McpTransaction) => Promise<T>): Promise<T> {
      return fn({
        async get() {
          return { get: () => 0 };
        },
        set() {}
      });
    }
  };

  const listed: unknown = await handleMcpRequest(db, claims, {
    jsonrpc: "2.0",
    id: 1,
    method: "resources/list",
    params: {}
  });
  assert.ok(isRecord(listed));
  assert.ok(isRecord(listed.result));
  const resources = listed.result.resources;
  assert.ok(Array.isArray(resources));
  assert.ok(isRecord(resources[0]));
  assert.equal(resources[0].uri, "burnbar://conversation/doc-1");

  await assert.rejects(
    () => handleMcpRequest(db, { ...claims, scopes: ["search:read"] }, {
      jsonrpc: "2.0",
      id: 2,
      method: "resources/read",
      params: { uri: "burnbar://conversation/doc-1" }
    }),
    /Missing required scope conversation:read/
  );

  const revokedDb: HostedMcpFirestore = {
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
    },
    collection() {
      throw new Error("collection should not be called");
    },
    async runTransaction<T>(fn: (tx: McpTransaction) => Promise<T>): Promise<T> {
      return fn({
        async get() {
          return { get: () => 0 };
        },
        set() {}
      });
    }
  };
  await assert.rejects(
    () => handleMcpRequest(revokedDb, claims, {
      jsonrpc: "2.0",
      id: 3,
      method: "resources/list",
      params: {}
    }),
    /revoked/
  );
});

test("MCP metadata methods require active client, Pro entitlement, and current client scopes", async () => {
  const claims = {
    sub: "metadata-user",
    aud: MCP_RESOURCE,
    client_id: "active-client",
    scopes: ["search:read", "conversation:read", "usage:read", "index:status"],
    entitlement_family: "burnbar_pro" as const,
    grant_mode: "local_decrypt_shim" as const,
    exp: Math.floor(Date.now() / 1000) + 60,
    jti: "metadata-jti"
  };

  function dbForClient(clientData: Record<string, unknown> | undefined, entitled = true): HostedMcpFirestore {
    return {
      doc(path: string) {
        return {
          async get() {
            if (path.endsWith("/remote_mcp_clients/active-client")) {
              return { exists: !!clientData, data: () => clientData };
            }
            if (path.endsWith("/entitlements/burnbar_pro")) {
              return {
                exists: entitled,
                data: () => entitled
                  ? { active: true, expiresAt: new Date(Date.now() + 60_000).toISOString() }
                  : undefined
              };
            }
            return { exists: false, data: () => undefined };
          },
          async set() {}
        };
      },
      collection() {
        throw new Error("collection should not be called");
      },
      async runTransaction<T>(fn: (tx: McpTransaction) => Promise<T>): Promise<T> {
        return fn({
          async get() {
            return { get: () => 0 };
          },
          set() {}
        });
      }
    };
  }

  const activeDb = dbForClient({ displayName: "Active", allowedScopes: claims.scopes });
  const initialized: unknown = await handleMcpRequest(activeDb, claims, {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {}
  });
  assert.ok(isRecord(initialized));
  assert.ok(isRecord(initialized.result));
  assert.equal(initialized.result.protocolVersion, MCP_PROTOCOL_VERSION);

  const listed: unknown = await handleMcpRequest(activeDb, claims, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/list",
    params: {}
  });
  assert.ok(isRecord(listed));
  assert.ok(isRecord(listed.result));
  assert.ok(Array.isArray(listed.result.tools));

  await assert.rejects(
    () => handleMcpRequest(dbForClient({ revokedAt: new Date().toISOString(), allowedScopes: claims.scopes }), claims, {
      jsonrpc: "2.0",
      id: 3,
      method: "initialize",
      params: {}
    }),
    /revoked/
  );

  const noProClaims = { ...claims, sub: "metadata-no-pro", jti: "metadata-no-pro" };
  await assert.rejects(
    () => handleMcpRequest(dbForClient({ displayName: "No Pro", allowedScopes: noProClaims.scopes }, false), noProClaims, {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/list",
      params: {}
    }),
    /BurnBar Pro/
  );

  await assert.rejects(
    () => handleMcpRequest(dbForClient({ displayName: "Downgraded", allowedScopes: ["search:read"] }), claims, {
      jsonrpc: "2.0",
      id: 5,
      method: "tools/list",
      params: {}
    }),
    /exceed the registered client grant/
  );
});

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
