/**
 * RR-11 — hosted MCP live adversarial proofs, deterministic LOCAL edition.
 *
 * Boots the REAL hosted MCP HTTP server in-process against a seeded in-memory
 * Firestore + storage (services/hosted-mcp/src/securityFixtures.ts) and drives
 * real HTTP requests with Ed25519 tokens minted through the same signing path
 * the server verifies. Every adversarial property — cross-tenant isolation,
 * revoked-client rejection, non-entitled gating, rate-limit caps, and
 * at-rest-sealed payloads — is asserted through the actual route + auth +
 * entitlement + cursor + resource code paths. No prod secrets, no live
 * Firestore, no stubbing of the isolation logic.
 *
 * The PROD live suite (scripts/test-hosted-mcp-security.sh + the env-gated
 * prove-hosted-mcp-live.mjs cases) stays as-is for staging; THIS suite runs on
 * every PR via `npm test --prefix services/hosted-mcp`.
 */

import assert from "node:assert/strict";
import test, { after, before } from "node:test";
import type { AddressInfo } from "node:net";
import type { Server } from "node:http";

import { MCP_PROTOCOL_VERSION } from "./config.js";
import type { ServerOverrides } from "./server.js";
import {
  seedTwoTenantWorld,
  vec384,
  PLAINTEXT_MARKERS,
  type SeededWorld,
} from "./securityFixtures.js";

// Ed25519 verification requires the public key; legacy HMAC must be disabled so
// the suite proves the asymmetric path exactly as production runs it. Set before
// importing server.js, whose module-load guard reads the runtime posture.
const previousEnv = {
  NODE_ENV: process.env.NODE_ENV,
  pub: process.env.MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64,
  legacy: process.env.MCP_ALLOW_LEGACY_HMAC_TOKENS,
  cursor: process.env.MCP_CURSOR_HMAC_SECRET,
  origins: process.env.MCP_ALLOWED_ORIGINS,
};
process.env.NODE_ENV = "test"; // suppress server.js auto-listen on import
process.env.MCP_CURSOR_HMAC_SECRET = "live-suite-cursor-secret";
process.env.MCP_ALLOWED_ORIGINS = "https://mcp.burnbar.ai";
delete process.env.MCP_ALLOW_LEGACY_HMAC_TOKENS;

let world: SeededWorld;
let server: Server;
let endpoint: string;

interface McpHttpResult {
  status: number;
  body: string;
  json: unknown;
}

/** POST a JSON-RPC envelope to /mcp with the given bearer; return status + parsed body. */
async function callMcp(token: string | undefined, payload: unknown, extraHeaders: Record<string, string> = {}): Promise<McpHttpResult> {
  const headers: Record<string, string> = {
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
    ...extraHeaders,
  };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(`${endpoint}/mcp`, { method: "POST", headers, body: JSON.stringify(payload) });
  const body = await res.text();
  let json: unknown;
  try {
    json = JSON.parse(body);
  } catch {
    json = undefined;
  }
  return { status: res.status, body, json };
}

function resultOf(json: unknown): Record<string, unknown> {
  assert.ok(json && typeof json === "object", "expected a JSON-RPC object");
  const result = (json as Record<string, unknown>).result;
  assert.ok(result && typeof result === "object", `expected a JSON-RPC result, got ${JSON.stringify(json)}`);
  return result as Record<string, unknown>;
}

/** Parse the tools/call envelope ({content:[{text}]}) back into the tool's JSON payload. */
function toolPayload(json: unknown): Record<string, unknown> {
  const result = resultOf(json);
  const content = result.content;
  assert.ok(Array.isArray(content) && content.length > 0, "expected tools/call content");
  const text = (content[0] as Record<string, unknown>).text;
  assert.equal(typeof text, "string");
  return JSON.parse(text as string) as Record<string, unknown>;
}

let nextId = 1;
const rpc = (method: string, params: Record<string, unknown> = {}) => ({ jsonrpc: "2.0", id: nextId++, method, params });
const callTool = (name: string, args: Record<string, unknown> = {}) => rpc("tools/call", { name, arguments: args });

before(async () => {
  world = seedTwoTenantWorld();
  process.env.MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64 = world.publicKeyBase64;
  const { createServer } = await import("./server.js");
  const { db, download } = world;
  // The in-memory firestore satisfies exactly the surface the request path
  // touches (doc/collection/runTransaction/collectionGroup); cast at the seam.
  server = createServer({ db: db as unknown as ServerOverrides["db"], download });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as AddressInfo;
  endpoint = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  await new Promise<void>((resolve, reject) => server.close((err) => (err ? reject(err) : resolve())));
  if (previousEnv.NODE_ENV === undefined) delete process.env.NODE_ENV;
  else process.env.NODE_ENV = previousEnv.NODE_ENV;
  if (previousEnv.pub === undefined) delete process.env.MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64;
  else process.env.MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64 = previousEnv.pub;
  if (previousEnv.legacy === undefined) delete process.env.MCP_ALLOW_LEGACY_HMAC_TOKENS;
  else process.env.MCP_ALLOW_LEGACY_HMAC_TOKENS = previousEnv.legacy;
  if (previousEnv.cursor === undefined) delete process.env.MCP_CURSOR_HMAC_SECRET;
  else process.env.MCP_CURSOR_HMAC_SECRET = previousEnv.cursor;
  if (previousEnv.origins === undefined) delete process.env.MCP_ALLOWED_ORIGINS;
  else process.env.MCP_ALLOWED_ORIGINS = previousEnv.origins;
});

const KNOWLEDGE_SCOPES = ["search:read", "conversation:read", "usage:read", "index:status", "knowledge:read"];

test("baseline: a real Ed25519 token reaches initialize over the live server", async () => {
  const token = world.tenantA.token(KNOWLEDGE_SCOPES);
  const res = await callMcp(token, rpc("initialize"));
  assert.equal(res.status, 200);
  assert.equal(resultOf(res.json).protocolVersion, MCP_PROTOCOL_VERSION);
});

// Case 1 — Cross-tenant: A's verified token, even with a forged namespace/uid in
// args, must NEVER return B's seeded vector (the server scopes to claims.sub).
test("case1 cross-tenant: A's token cannot read B's knowledge vector (forged namespace ignored)", async () => {
  const tokenA = world.tenantA.token(KNOWLEDGE_SCOPES);
  // Forge every namespace-ish arg toward B; the server must scope to claims.sub = A.
  const res = await callMcp(
    tokenA,
    callTool("burnbar_search_knowledge", {
      queryVector: vec384([1, 0, 0]),
      namespace: world.tenantB.uid,
      uid: world.tenantB.uid,
      user_id: world.tenantB.uid,
    }),
  );
  assert.equal(res.status, 200);
  const payload = toolPayload(res.json);
  const hits = payload.hits;
  assert.ok(Array.isArray(hits));
  assert.equal(hits.length, 0, "A must see zero hits in its own empty namespace");
  assert.ok(!res.body.includes(world.vectorIdB), "B's vectorId must never appear in A's response");

  // And B, with its own token, DOES see its vector — proving the seed is real.
  const tokenB = world.tenantB.token(KNOWLEDGE_SCOPES);
  const resB = await callMcp(tokenB, callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
  const payloadB = toolPayload(resB.json);
  assert.deepEqual((payloadB.hits as Array<{ vectorId: string }>).map((h) => h.vectorId), [world.vectorIdB]);
});

// Case 1b — Cross-tenant via the conversation resource path: A cannot read B's doc.
test("case1b cross-tenant: A's token cannot read B's conversation resource", async () => {
  const tokenA = world.tenantA.token(KNOWLEDGE_SCOPES);
  // A lists its own (empty) resources — B's doc must not appear.
  const list = await callMcp(tokenA, rpc("resources/list"));
  const resources = resultOf(list.json).resources;
  assert.ok(Array.isArray(resources));
  assert.equal(resources.length, 0, "A owns no conversation resources");

  // A tries to read B's doc by its real URI; the server scopes the lookup to
  // users/A/... → the doc does not exist there → the HttpError surfaces as 404.
  const read = await callMcp(tokenA, rpc("resources/read", { uri: `burnbar://conversation/${world.conversationIdB}` }));
  assert.equal(read.status, 404, "A reading B's resource must be denied (owner-scoped not-found)");
  assert.ok(!read.body.includes("payloadCiphertextB64"), "A must not receive B's body bytes");
});

// Case 6 — Revoked client: a token whose client grant was revoked must 403.
test("case6 revoked-client: a revoked client's token is rejected", async () => {
  const revoked = world.tenantA.token(KNOWLEDGE_SCOPES, { client_id: "client-A-revoked" });
  const res = await callMcp(revoked, callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
  assert.ok(res.body.toLowerCase().includes("revoked"), `expected a revocation error, got ${res.body}`);
});

// Case 8 — Non-entitled gate: an active client with NO Pro entitlement is denied.
test("case8 non-entitled: a token without Pro entitlement is denied the gated tool", async () => {
  const free = world.tenantB.token(KNOWLEDGE_SCOPES, { sub: "tenant-free", client_id: "client-free" });
  const res = await callMcp(free, callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
  assert.ok(res.body.includes("BurnBar Pro"), `expected a Pro-required denial, got ${res.body}`);
});

// Scope gate — a token missing knowledge:read cannot reach the knowledge tool.
test("scope gate: a token without knowledge:read is denied burnbar_search_knowledge", async () => {
  const noKnowledge = world.tenantA.token(["search:read", "conversation:read", "index:status"]);
  const res = await callMcp(noKnowledge, callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
  assert.ok(res.body.includes("Missing required scope knowledge:read"), `expected a scope denial, got ${res.body}`);
});

// Case 4/5 — Caps/rate-limits trigger: hammering past the body:standard bucket
// (30/min) must surface a 429 rate-limit error, not silently overflow.
test("case4/5 caps: hammering the body bucket past its cap surfaces rate_limited (429)", async () => {
  // Use the dedicated rate-limit tenant so exhausting its body:standard bucket
  // never poisons tenant B's bucket (the at-rest proof reuses tenant B).
  const token = world.tenantRateLimit.token(KNOWLEDGE_SCOPES);
  const uri = `burnbar://conversation/${world.conversationIdRateLimit}`;
  let rateLimitedStatus = 0;
  // body:standard cap is 30/min; 40 calls in the same window must trip it.
  for (let i = 0; i < 40; i += 1) {
    const res = await callMcp(token, rpc("resources/read", { uri }));
    if (res.body.includes("rate limit") || res.body.includes("rate_limited")) {
      rateLimitedStatus = res.status;
      break;
    }
  }
  assert.equal(rateLimitedStatus, 429, "expected the body:standard cap to trip a 429 rate-limit error");
});

// Case 2 — At-rest sealed: the body the server returns is ciphertext-only; no
// plaintext marker ever appears in the wire payload.
test("case2 at-rest: returned conversation body is sealed (no plaintext)", async () => {
  const tokenB = world.tenantB.token(KNOWLEDGE_SCOPES);
  const res = await callMcp(tokenB, rpc("resources/read", { uri: `burnbar://conversation/${world.conversationIdB}` }));
  assert.equal(res.status, 200);
  const result = resultOf(res.json);
  assert.equal(result.encrypted, true);
  assert.equal(result.decryptMode, "local_decrypt_shim");
  for (const marker of PLAINTEXT_MARKERS) {
    assert.ok(!res.body.includes(marker), `sealed body must not contain plaintext marker ${marker}`);
  }
  // The page is the sealed envelope JSON — opaque ciphertext, never cleartext.
  const page = result.encryptedBodyPage;
  assert.equal(typeof page, "string");
  assert.ok((page as string).includes("payloadCiphertextB64"), "expected the at-rest sealed envelope");
});

// Case 2b — At-rest sealed knowledge: a search hit exposes only ciphertext +
// opaque slugHmac, never a plaintext marker or a cleartext sourceSlug.
test("case2b at-rest: knowledge hits expose only sealed ciphertext + opaque slugHmac", async () => {
  const tokenB = world.tenantB.token(KNOWLEDGE_SCOPES);
  const res = await callMcp(tokenB, callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
  const payload = toolPayload(res.json);
  const hits = payload.hits as Array<Record<string, unknown>>;
  assert.equal(hits.length, 1);
  const hit = hits[0];
  assert.equal(hit.decryptMode, "local_decrypt_shim");
  assert.equal(typeof hit.slugHmac, "string");
  assert.ok(!Object.prototype.hasOwnProperty.call(hit, "sourceSlug"), "no cleartext sourceSlug may be returned");
  for (const marker of PLAINTEXT_MARKERS) {
    assert.ok(!res.body.includes(marker), `sealed knowledge hit must not contain plaintext marker ${marker}`);
  }
});

// Token posture — a forged/garbage bearer is rejected (401) before any dispatch.
test("posture: a forged bearer token is rejected with 401", async () => {
  const res = await callMcp("ed25519.forged.signature", callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
  assert.equal(res.status, 401);
});

// Origin gate — a disallowed Origin header is rejected (403) before auth.
test("posture: a disallowed Origin is rejected with 403", async () => {
  const token = world.tenantA.token(KNOWLEDGE_SCOPES);
  const res = await callMcp(token, rpc("initialize"), { origin: "https://attacker.invalid" });
  assert.equal(res.status, 403);
});
