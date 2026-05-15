#!/usr/bin/env node
import { spawn } from "node:child_process";
import { createHmac, randomUUID } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

const ALL_SCOPES = ["search:read", "conversation:read", "usage:read", "index:status"];
const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const SHIM_ENTRYPOINT = resolve(REPO_ROOT, "tools/openburnbar-mcp-remote/lib/index.js");

function parseArgs(argv) {
  const opts = {
    project: process.env.GOOGLE_CLOUD_PROJECT || "burnbar",
    endpoint: process.env.OPENBURNBAR_MCP_ENDPOINT || "https://mcp.burnbar.ai/mcp",
    audience: process.env.OPENBURNBAR_MCP_AUDIENCE || "https://mcp.burnbar.ai/mcp",
    bucket: process.env.OPENBURNBAR_STORAGE_BUCKET || process.env.FIREBASE_STORAGE_BUCKET || "",
    proofId: `remote-mcp-shim-${Date.now()}`
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => {
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a value`);
      index += 1;
      return value;
    };
    switch (arg) {
      case "--project":
        opts.project = next();
        break;
      case "--endpoint":
        opts.endpoint = next();
        break;
      case "--audience":
        opts.audience = next();
        break;
      case "--bucket":
        opts.bucket = next();
        break;
      case "--proof-id":
        opts.proofId = next();
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }
  if (!opts.bucket) throw new Error("--bucket or OPENBURNBAR_STORAGE_BUCKET is required");
  return opts;
}

function mintProofToken({ uid, clientId, secret, scopes, audience }) {
  const now = Math.floor(Date.now() / 1000);
  const claims = {
    sub: uid,
    aud: audience,
    client_id: clientId,
    scopes,
    entitlement_family: "burnbar_pro",
    grant_mode: "local_decrypt_shim",
    exp: now + 3600,
    jti: randomUUID()
  };
  const body = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const sig = createHmac("sha256", secret).update(body).digest("base64url");
  return `${body}.${sig}`;
}

function sealed(value) {
  return { algorithm: "AES-256-GCM", nonce: "proof", ciphertext: value, tag: "proof" };
}

async function commitBatches(db, writes) {
  for (let index = 0; index < writes.length; index += 450) {
    const batch = db.batch();
    for (const write of writes.slice(index, index + 450)) {
      batch.set(write.ref, write.data, { merge: true });
    }
    await batch.commit();
  }
}

async function seedCorpus({ db, uid, clientId, opts, searchedHash, bodyHash, bodyPath }) {
  const now = Timestamp.now();
  const expiresAt = Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000));
  const documentID = "shim-doc-0";
  const chunkID = "shim-chunk-0";
  const storagePath = bodyPath;
  const sealedSnippet = sealed("sealed-shim-snippet");
  const writes = [
    {
      ref: db.doc(`users/${uid}/entitlements/burnbar_pro`),
      data: { active: true, expiresAt, source: "shim-proof", updatedAt: now }
    },
    {
      ref: db.doc(`users/${uid}/remote_mcp_clients/${clientId}`),
      data: {
        clientId,
        displayName: "Shim proof client",
        clientType: "proof",
        allowedScopes: ALL_SCOPES,
        grantMode: "local_decrypt_shim",
        createdAt: now,
        updatedAt: now,
        schemaVersion: 1
      }
    },
    {
      ref: db.doc(`users/${uid}/cloud_search_index_manifest/current`),
      data: {
        schemaVersion: 1,
        indexVersion: 1,
        activeCommitIDsByDevice: { shimProof: "shim-proof-commit" },
        latestCommittedAt: new Date().toISOString(),
        documentCount: 1,
        chunkCount: 1,
        tokenPostingCount: 1,
        semanticPostingCount: 0,
        stale: false,
        compactionStatus: "proof"
      }
    },
    {
      ref: db.doc(`users/${uid}/cloud_search_documents/${documentID}`),
      data: {
        sourceID: "Shim proof session",
        sourceKind: "session",
        documentID,
        storagePath,
        bodyHash,
        projectName: "burnbar",
        provider: "proof",
        model: "proof-model",
        harness: "proof-harness",
        sealedTitle: sealed("sealed-shim-title"),
        sealedBodyPreview: sealed("sealed-shim-preview"),
        createdAt: now
      }
    },
    {
      ref: db.doc(`users/${uid}/cloud_search_chunks/${chunkID}`),
      data: {
        documentID,
        sourceKind: "session",
        sourceID: "Shim proof session",
        provider: "proof",
        projectName: "burnbar",
        model: "proof-model",
        harness: "proof-harness",
        commitID: "shim-proof-commit",
        storagePath,
        bodyHash,
        tokenHashes: [searchedHash],
        semanticHashes: [],
        sealedSnippet,
        ordinal: 0
      }
    },
    {
      ref: db.doc(`users/${uid}/cloud_search_postings/token_${searchedHash}_${chunkID}`),
      data: {
        postingKey: `token_${searchedHash}`,
        kind: "token",
        hash: searchedHash,
        chunkID,
        documentID,
        sourceKind: "session",
        sourceID: "Shim proof session",
        provider: "proof",
        projectName: "burnbar",
        model: "proof-model",
        harness: "proof-harness",
        commitID: "shim-proof-commit",
        storagePath,
        bodyHash,
        sealedSnippet,
        ordinal: 0
      }
    }
  ];
  await commitBatches(db, writes);
  await getStorage().bucket(opts.bucket).file(bodyPath).save(Buffer.from(JSON.stringify({
    alg: "AES-256-GCM",
    nonce: "shim-proof",
    ciphertext: "shim-body-ciphertext",
    tag: "shim-proof"
  })), {
    resumable: false,
    contentType: "application/octet-stream"
  });
}

async function sendStdioMessages({ endpoint, token, messages }) {
  const child = spawn("node", [SHIM_ENTRYPOINT, "mcp", "serve"], {
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      OPENBURNBAR_MCP_ENDPOINT: endpoint,
      OPENBURNBAR_MCP_ACCESS_TOKEN: token
    },
    stdio: ["pipe", "pipe", "pipe"]
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
  child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  for (const message of messages) {
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }
  child.stdin.end();
  const code = await new Promise((resolve) => child.on("close", resolve));
  if (code !== 0) throw new Error(`shim exited ${code}: ${stderr}`);
  const lines = stdout.trim().split(/\n/u).filter(Boolean);
  if (lines.length !== messages.length) throw new Error(`expected ${messages.length} shim responses, got ${lines.length}: ${stdout}`);
  return lines.map((line) => JSON.parse(line));
}

async function runDoctor({ endpoint, token }) {
  const child = spawn("node", [SHIM_ENTRYPOINT, "mcp", "doctor"], {
    cwd: REPO_ROOT,
    env: {
      ...process.env,
      OPENBURNBAR_MCP_ENDPOINT: endpoint,
      OPENBURNBAR_MCP_ACCESS_TOKEN: token
    },
    stdio: ["ignore", "pipe", "pipe"]
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => { stdout += chunk.toString(); });
  child.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  const code = await new Promise((resolve) => child.on("close", resolve));
  if (code !== 0) throw new Error(`doctor exited ${code}: ${stdout}${stderr}`);
  return stdout.trim().split(/\n/u).filter(Boolean);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const secret = process.env.OPENBURNBAR_MCP_TOKEN_HMAC_SECRET;
  if (!secret) throw new Error("OPENBURNBAR_MCP_TOKEN_HMAC_SECRET is required");
  if (getApps().length === 0) {
    initializeApp({ projectId: opts.project, storageBucket: opts.bucket });
  }
  const db = getFirestore();
  const uid = `${opts.proofId}-user`;
  const clientId = "shim-proof-client";
  const searchedHash = "33333333333333333333333333333333";
  const bodyHash = "4444444444444444444444444444444444444444444444444444444444444444";
  const bodyPath = `users/${uid}/session_logs/shim-doc-0/bodies/${bodyHash}.json.aesgcm`;
  const token = mintProofToken({ uid, clientId, secret, scopes: ALL_SCOPES, audience: opts.audience });

  try {
    await seedCorpus({ db, uid, clientId, opts, searchedHash, bodyHash, bodyPath });
    const doctorLines = await runDoctor({ endpoint: opts.endpoint, token });
    const responses = await sendStdioMessages({
      endpoint: opts.endpoint,
      token,
      messages: [
        { jsonrpc: "2.0", id: "tools", method: "tools/list", params: {} },
        {
          jsonrpc: "2.0",
          id: "search",
          method: "tools/call",
          params: {
            name: "burnbar_search_conversations",
            arguments: { tokenHashes: [searchedHash], provider: "proof", limit: 1 }
          }
        },
        {
          jsonrpc: "2.0",
          id: "body",
          method: "tools/call",
          params: {
            name: "burnbar_get_conversation_body",
            arguments: { resourceUri: "burnbar://conversation/shim-doc-0", maxChars: 24_000 }
          }
        }
      ]
    });

    const responseById = new Map(responses.map((response) => [response.id, response]));
    const tools = responseById.get("tools");
    const search = responseById.get("search");
    const body = responseById.get("body");
    if (!tools || !search || !body) throw new Error(`missing shim response id: ${JSON.stringify(responses)}`);
    if (tools.error) throw new Error(`tools/list failed: ${JSON.stringify(tools.error)}`);
    if (search.error) throw new Error(`search failed: ${JSON.stringify(search.error)}`);
    if (body.error) throw new Error(`body failed: ${JSON.stringify(body.error)}`);
    const searchText = JSON.parse(search.result.content[0].text);
    const bodyText = JSON.parse(body.result.content[0].text);
    if (searchText.hits?.length !== 1) throw new Error(`expected one search hit, got ${searchText.hits?.length}`);
    if (searchText.readBudget?.storageReads !== 0 || !searchText.readBudget?.withinSearchReadBudget) {
      throw new Error(`unexpected search budget: ${JSON.stringify(searchText.readBudget)}`);
    }
    if (bodyText.readBudget?.firestoreDocumentReads !== 1 || bodyText.readBudget?.storageReads !== 1 || !bodyText.readBudget?.withinBodyReadBudget) {
      throw new Error(`unexpected body budget: ${JSON.stringify(bodyText.readBudget)}`);
    }
    console.log(JSON.stringify({
      ok: true,
      endpoint: opts.endpoint,
      proofId: opts.proofId,
      shim: "openburnbar-mcp-remote stdio",
      doctor: doctorLines,
      toolsListed: Array.isArray(tools.result.tools) ? tools.result.tools.length : 0,
      searchReadBudget: searchText.readBudget,
      bodyReadBudget: bodyText.readBudget
    }, null, 2));
  } finally {
    await db.recursiveDelete(db.doc(`users/${uid}`)).catch(() => undefined);
    await getStorage().bucket(opts.bucket).deleteFiles({ prefix: `users/${uid}/session_logs/` }).catch(() => undefined);
  }
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error.message }, null, 2));
  process.exit(1);
});
