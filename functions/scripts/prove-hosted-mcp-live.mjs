#!/usr/bin/env node
import { createHmac, randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import admin from "firebase-admin";

function parseArgs(argv) {
  const parsed = {};
  for (let index = 0; index < argv.length; index += 1) {
    const item = argv[index];
    if (!item.startsWith("--")) continue;
    const key = item.slice(2);
    const next = argv[index + 1];
    if (!next || next.startsWith("--")) {
      parsed[key] = "true";
    } else {
      parsed[key] = next;
      index += 1;
    }
  }
  return parsed;
}

const args = parseArgs(process.argv.slice(2));
const endpoint = args.endpoint ?? "https://mcp.openburnbar.com/mcp";
const token = process.env.OPENBURNBAR_MCP_PROOF_TOKEN;

function post(url, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const request = url.startsWith("http://") ? httpRequest : httpsRequest;
    const req = request(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "accept": "application/json, text/event-stream",
        ...headers
      }
    }, (res) => {
      const chunks = [];
      res.on("data", (chunk) => chunks.push(chunk));
      res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}

function assertStatus(label, result, status, code) {
  if (result.status !== status || (code && !result.body.includes(code))) {
    throw new Error(`${label} expected ${status}${code ? ` ${code}` : ""}, got ${result.status} ${result.body.slice(0, 500)}`);
  }
}

function mintProofToken({ uid, clientId, secret, scopes }) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    sub: uid,
    aud: args.audience ?? "https://mcp.openburnbar.com/mcp",
    client_id: clientId,
    scopes,
    entitlement_family: "burnbar_pro",
    grant_mode: "local_decrypt_shim",
    exp: now + 900,
    jti: randomUUID()
  };
  const body = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const sig = createHmac("sha256", secret).update(body).digest("base64url");
  return `${body}.${sig}`;
}

async function proveMissingAuth() {
  const missing = await post(endpoint, { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} });
  if (missing.status !== 401) throw new Error(`missing auth expected 401, got ${missing.status}`);
  return missing.status;
}

async function proveProvidedToken(missingAuthStatus) {
  const tools = await post(endpoint, { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }, { authorization: `Bearer ${token}` });
  if (tools.status !== 200 || !tools.body.includes("burnbar_search_conversations")) {
    throw new Error(`tools/list failed: ${tools.status} ${tools.body.slice(0, 500)}`);
  }
  console.log(JSON.stringify({ ok: true, endpoint, missingAuthStatus, toolsStatus: tools.status }, null, 2));
}

async function proveControlled(missingAuthStatus) {
  const secret = process.env.OPENBURNBAR_MCP_TOKEN_HMAC_SECRET;
  if (!secret) {
    console.log(JSON.stringify({
      ok: false,
      skippedLivePaidProof: true,
      reason: "OPENBURNBAR_MCP_PROOF_TOKEN or OPENBURNBAR_MCP_TOKEN_HMAC_SECRET not set",
      missingAuthStatus
    }, null, 2));
    process.exit(2);
  }

  const projectId = args.project ?? process.env.GOOGLE_CLOUD_PROJECT ?? "burnbar";
  if (admin.apps.length === 0) admin.initializeApp({ projectId });
  const db = admin.firestore();
  const proofId = args.proofId ?? `remote-mcp-proof-${Date.now()}`;
  const clientId = "live-proof-client";
  const expires = admin.firestore.Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000));
  const users = {
    paidA: `${proofId}-paid-a`,
    paidB: `${proofId}-paid-b`,
    unpaid: `${proofId}-unpaid`,
    revoked: `${proofId}-revoked`
  };
  const targetDoc = "cross-tenant-target-doc";
  const allScopes = ["search:read", "conversation:read", "usage:read", "index:status"];

  const authHeader = (uid, scopes = allScopes) => ({
    authorization: `Bearer ${mintProofToken({ uid, clientId, secret, scopes })}`
  });

  try {
    for (const uid of [users.paidA, users.paidB, users.revoked]) {
      await db.doc(`users/${uid}/entitlements/burnbar_pro`).set({ active: true, expiresAt: expires });
      await db.doc(`users/${uid}/remote_mcp_clients/${clientId}`).set({
        clientId,
        displayName: "Live proof client",
        clientType: "proof",
        allowedScopes: allScopes,
        grantMode: "local_decrypt_shim",
        createdAt: admin.firestore.Timestamp.now(),
        updatedAt: admin.firestore.Timestamp.now(),
        schemaVersion: 1
      });
    }
    await db.doc(`users/${users.revoked}/remote_mcp_clients/${clientId}`).set({ revokedAt: admin.firestore.Timestamp.now() }, { merge: true });
    await db.doc(`users/${users.unpaid}/remote_mcp_clients/${clientId}`).set({
      clientId,
      displayName: "Unpaid proof client",
      clientType: "proof",
      allowedScopes: allScopes,
      grantMode: "local_decrypt_shim",
      createdAt: admin.firestore.Timestamp.now(),
      updatedAt: admin.firestore.Timestamp.now(),
      schemaVersion: 1
    });
    await db.doc(`users/${users.paidB}/cloud_search_documents/${targetDoc}`).set({
      sourceID: "Tenant B proof session",
      storagePath: `users/${users.paidB}/session_logs/${targetDoc}/bodies/body.json.enc`,
      bodyHash: "proof-body-hash",
      projectName: "proof",
      provider: "proof",
      createdAt: admin.firestore.Timestamp.now()
    });

    const paidCapabilities = await post(endpoint, {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: { name: "burnbar_resolve_capabilities", arguments: {} }
    }, authHeader(users.paidA));
    assertStatus("paid capabilities", paidCapabilities, 200, "hostedMcpAvailable");

    const unpaidCapabilities = await post(endpoint, {
      jsonrpc: "2.0",
      id: 4,
      method: "tools/call",
      params: { name: "burnbar_resolve_capabilities", arguments: {} }
    }, authHeader(users.unpaid));
    assertStatus("unpaid denial", unpaidCapabilities, 403, "burnbar_pro_required");

    const revokedCapabilities = await post(endpoint, {
      jsonrpc: "2.0",
      id: 5,
      method: "tools/call",
      params: { name: "burnbar_resolve_capabilities", arguments: {} }
    }, authHeader(users.revoked));
    assertStatus("revoked denial", revokedCapabilities, 403, "client_revoked");

    const paidBList = await post(endpoint, {
      jsonrpc: "2.0",
      id: 6,
      method: "resources/list",
      params: {}
    }, authHeader(users.paidB));
    assertStatus("paid tenant B resources/list", paidBList, 200, targetDoc);

    const crossRead = await post(endpoint, {
      jsonrpc: "2.0",
      id: 7,
      method: "resources/read",
      params: { uri: `burnbar://conversation/${targetDoc}` }
    }, authHeader(users.paidA));
    assertStatus("cross-tenant resources/read denial", crossRead, 404, "resource_not_found");

    const missingScope = await post(endpoint, {
      jsonrpc: "2.0",
      id: 8,
      method: "resources/read",
      params: { uri: `burnbar://conversation/${targetDoc}` }
    }, authHeader(users.paidB, ["search:read"]));
    assertStatus("missing conversation scope denial", missingScope, 403, "insufficient_scope");

    console.log(JSON.stringify({
      ok: true,
      endpoint,
      proofId,
      missingAuthStatus,
      paidCapabilitiesStatus: paidCapabilities.status,
      unpaidCapabilitiesStatus: unpaidCapabilities.status,
      revokedCapabilitiesStatus: revokedCapabilities.status,
      paidBListStatus: paidBList.status,
      crossTenantReadStatus: crossRead.status,
      missingScopeStatus: missingScope.status
    }, null, 2));
  } finally {
    await Promise.all(Object.values(users).map((uid) => db.recursiveDelete(db.doc(`users/${uid}`)).catch(() => undefined)));
  }
}

const missingAuthStatus = await proveMissingAuth();
if (token) {
  await proveProvidedToken(missingAuthStatus);
} else {
  await proveControlled(missingAuthStatus);
}
