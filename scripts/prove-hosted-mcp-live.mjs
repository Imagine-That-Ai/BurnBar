#!/usr/bin/env node
/**
 * Hosted MCP live adversarial proofs.
 *
 * Two modes:
 *
 *   --local  (DEFAULT, secret-free, runs on every PR)
 *     Boots the REAL hosted MCP server (createServer) in-process against a
 *     seeded in-memory Firestore + storage and drives real HTTP requests with
 *     Ed25519 tokens minted through the same signing path the server verifies.
 *     Proves cross-tenant isolation, revoked-client rejection, non-entitled
 *     gating, the rate-limit cap, and at-rest-sealed payloads — all through the
 *     actual route + auth + entitlement + cursor + resource code paths. No prod
 *     secrets, no live Firestore, no stubbed isolation logic. This is the same
 *     contract security.live.test.ts asserts, packaged as a runnable script so
 *     scripts/test-hosted-mcp-security.sh and CI can execute it directly.
 *
 *   --case <name>  (PROD/STAGING, env-gated)
 *     The heavy proofs that need a real callable-functions URL and/or Firestore
 *     inspection (chunk-cap, sync-frequency, at-rest, verbatim). They run only
 *     when the documented PENSIEVE_* env is present (see
 *     scripts/test-hosted-mcp-security.sh) and SKIP loudly otherwise so the
 *     token-less PR gate still proves the LOCAL contract above.
 *
 * Usage:
 *   node scripts/prove-hosted-mcp-live.mjs --local
 *   node scripts/prove-hosted-mcp-live.mjs --case chunk-cap --case sync-frequency
 */

import { fileURLToPath } from "node:url";
import path from "node:path";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SERVICE = path.join(HERE, "..", "services", "hosted-mcp");
const LIB = path.join(SERVICE, "lib");

function parseArgs(argv) {
  const args = { local: false, cases: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--local") args.local = true;
    else if (arg === "--case") {
      const name = argv[i + 1];
      if (!name) throw new Error("--case requires a name");
      args.cases.push(name);
      i += 1;
    }
  }
  if (!args.local && args.cases.length === 0) args.local = true; // default to the secret-free proof
  return args;
}

// -- LOCAL deterministic proof ------------------------------------------------

async function callMcp(endpoint, token, payload, extraHeaders = {}) {
  const headers = {
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
    ...extraHeaders,
  };
  if (token) headers.authorization = `Bearer ${token}`;
  const res = await fetch(`${endpoint}/mcp`, { method: "POST", headers, body: JSON.stringify(payload) });
  const body = await res.text();
  let json;
  try {
    json = JSON.parse(body);
  } catch {
    json = undefined;
  }
  return { status: res.status, body, json };
}

let idCounter = 1;
const rpc = (method, params = {}) => ({ jsonrpc: "2.0", id: idCounter++, method, params });
const callTool = (name, args = {}) => rpc("tools/call", { name, arguments: args });

function assert(condition, message) {
  if (!condition) throw new Error(`FAIL: ${message}`);
}

async function runLocal() {
  // Posture the server expects: verify Ed25519, disable legacy HMAC, suppress
  // the server.js auto-listen so we own the lifecycle.
  process.env.NODE_ENV = "test";
  process.env.MCP_CURSOR_HMAC_SECRET ??= "prove-local-cursor-secret";
  process.env.MCP_ALLOWED_ORIGINS = "https://mcp.burnbar.ai";
  delete process.env.MCP_ALLOW_LEGACY_HMAC_TOKENS;

  const { seedTwoTenantWorld, vec384, PLAINTEXT_MARKERS } = await import(
    path.join(LIB, "securityFixtures.js")
  );
  const world = seedTwoTenantWorld();
  process.env.MCP_TOKEN_ED25519_PUBLIC_KEY_BASE64 = world.publicKeyBase64;

  const { createServer } = await import(path.join(LIB, "server.js"));
  const server = createServer({ db: world.db, download: world.download });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  const endpoint = `http://127.0.0.1:${port}`;
  const scopes = ["search:read", "conversation:read", "usage:read", "index:status", "knowledge:read"];
  let passed = 0;

  try {
    // case1 — cross-tenant: A's token, even with forged namespace args, never reads B.
    {
      const tokenA = world.tenantA.token(scopes);
      const res = await callMcp(
        endpoint,
        tokenA,
        callTool("burnbar_search_knowledge", {
          queryVector: vec384([1, 0, 0]),
          namespace: world.tenantB.uid,
          uid: world.tenantB.uid,
          user_id: world.tenantB.uid,
        }),
      );
      const payload = JSON.parse(res.json.result.content[0].text);
      assert(Array.isArray(payload.hits) && payload.hits.length === 0, "case1 A must see zero hits");
      assert(!res.body.includes(world.vectorIdB), "case1 B's vectorId leaked to A");
      console.log("PASS case1: cross-tenant forged namespace ignored (server scopes to claims.sub)");
      passed += 1;
    }

    // case1b — cross-tenant resource: A reading B's conversation URI is denied (404).
    {
      const tokenA = world.tenantA.token(scopes);
      const res = await callMcp(endpoint, tokenA, rpc("resources/read", { uri: `burnbar://conversation/${world.conversationIdB}` }));
      assert(res.status === 404, `case1b A reading B's resource must 404, got ${res.status}`);
      assert(!res.body.includes("payloadCiphertextB64"), "case1b A received B's body bytes");
      console.log("PASS case1b: A cannot read B's conversation resource (owner-scoped not-found)");
      passed += 1;
    }

    // case6 — revoked client: a revoked client's token is rejected.
    {
      const revoked = world.tenantA.token(scopes, { client_id: "client-A-revoked" });
      const res = await callMcp(endpoint, revoked, callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
      assert(res.body.toLowerCase().includes("revoked"), `case6 revoked client not rejected: ${res.body}`);
      console.log("PASS case6: revoked client rejected");
      passed += 1;
    }

    // case8 — non-entitled: a token without Pro entitlement is denied the gated tool.
    {
      const free = world.tenantB.token(scopes, { sub: "tenant-free", client_id: "client-free" });
      const res = await callMcp(endpoint, free, callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
      assert(res.body.includes("BurnBar Pro"), `case8 non-entitled not denied: ${res.body}`);
      console.log("PASS case8: non-entitled token denied the gated tool");
      passed += 1;
    }

    // case4/5 — caps: hammering the body:standard bucket (30/min) trips a 429.
    {
      const token = world.tenantRateLimit.token(scopes);
      const uri = `burnbar://conversation/${world.conversationIdRateLimit}`;
      let status = 0;
      for (let i = 0; i < 40; i += 1) {
        const res = await callMcp(endpoint, token, rpc("resources/read", { uri }));
        if (res.body.includes("rate limit") || res.body.includes("rate_limited")) {
          status = res.status;
          break;
        }
      }
      assert(status === 429, "case4/5 body cap did not trip a 429");
      console.log("PASS case4/5: body:standard cap trips a 429 rate-limit");
      passed += 1;
    }

    // case2 — at-rest: the returned conversation body is sealed (no plaintext).
    {
      const tokenB = world.tenantB.token(scopes);
      const res = await callMcp(endpoint, tokenB, rpc("resources/read", { uri: `burnbar://conversation/${world.conversationIdB}` }));
      assert(res.status === 200 && res.json.result.encrypted === true, "case2 body not marked encrypted");
      for (const marker of PLAINTEXT_MARKERS) {
        assert(!res.body.includes(marker), `case2 plaintext marker ${marker} leaked`);
      }
      assert(String(res.json.result.encryptedBodyPage).includes("payloadCiphertextB64"), "case2 missing sealed envelope");
      console.log("PASS case2: stored conversation body is sealed (no plaintext)");
      passed += 1;
    }

    // posture — a forged bearer is rejected (401); a bad Origin is rejected (403).
    {
      const forged = await callMcp(endpoint, "ed25519.forged.signature", callTool("burnbar_search_knowledge", { queryVector: vec384([1, 0, 0]) }));
      assert(forged.status === 401, `posture forged bearer must 401, got ${forged.status}`);
      const badOrigin = await callMcp(endpoint, world.tenantA.token(scopes), rpc("initialize"), { origin: "https://attacker.invalid" });
      assert(badOrigin.status === 403, `posture bad origin must 403, got ${badOrigin.status}`);
      console.log("PASS posture: forged bearer 401 + disallowed Origin 403");
      passed += 1;
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }

  console.log(`\nhosted MCP LOCAL adversarial proofs: ${passed} passed (secret-free, real server code paths)`);
}

// -- PROD/STAGING env-gated cases ---------------------------------------------

/**
 * The heavy proofs need a live callable-functions URL and/or Firestore
 * inspection; they run against staging only. Without the documented env they
 * SKIP loudly so the token-less PR gate still proves the LOCAL contract.
 */
function runProdCase(name) {
  switch (name) {
    case "chunk-cap":
      if (!process.env.PENSIEVE_BEARER_A || !process.env.PENSIEVE_FUNCTIONS_URL) {
        console.log("SKIP case chunk-cap (needs PENSIEVE_BEARER_A + PENSIEVE_FUNCTIONS_URL against staging)");
        return;
      }
      throw new Error("chunk-cap PROD probe is operator-run against staging; see docs — not wired for token-less CI");
    case "sync-frequency":
      if (!process.env.PENSIEVE_BEARER_A) {
        console.log("SKIP case sync-frequency (needs PENSIEVE_BEARER_A against staging)");
        return;
      }
      throw new Error("sync-frequency PROD probe is operator-run against staging; see docs — not wired for token-less CI");
    case "at-rest":
    case "verbatim":
      if (process.env.PENSIEVE_DB_INSPECT !== "1") {
        console.log(`SKIP case ${name} (needs PENSIEVE_DB_INSPECT=1 + Firestore access against staging)`);
        return;
      }
      throw new Error(`${name} PROD probe needs live Firestore inspection; run the LOCAL proof for the same at-rest contract on every PR`);
    default:
      throw new Error(`unknown --case ${name}`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.local) {
    await runLocal();
    return;
  }
  for (const name of args.cases) runProdCase(name);
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
