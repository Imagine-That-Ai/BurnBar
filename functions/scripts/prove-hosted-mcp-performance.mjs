#!/usr/bin/env node
import { createHmac, randomUUID } from "node:crypto";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

const ALL_SCOPES = ["search:read", "conversation:read", "usage:read", "index:status"];
const SEARCH_P50_TARGET_MS = 300;
const SEARCH_P95_TARGET_MS = 900;
const BODY_P95_TARGET_MS = 2500;

function usage() {
  return `Usage:
  OPENBURNBAR_MCP_TOKEN_HMAC_SECRET=<secret> node functions/scripts/prove-hosted-mcp-performance.mjs --endpoint <url> [options]

Options:
  --project <id>          Google/Firebase project id. Default: GOOGLE_CLOUD_PROJECT, then burnbar.
  --endpoint <url>        Hosted MCP endpoint. Default: https://mcp.openburnbar.com/mcp.
  --audience <url>        MCP token audience. Default: https://mcp.openburnbar.com/mcp.
  --bucket <name>         Storage bucket for encrypted body proof. Default: OPENBURNBAR_STORAGE_BUCKET.
  --proof-id <id>         Stable proof id. Default: generated.
  --documents <n>         Total seeded corpus documents. Default: 1000.
  --matches <n>           Matching candidate chunks for the searched hash. Default: 100.
  --iterations <n>        Warm search/body iterations. Default: 20.
  --skip-body             Skip body-fetch proof when no Storage bucket is configured.
`;
}

function parseArgs(argv) {
  const opts = {
    project: process.env.GOOGLE_CLOUD_PROJECT || "burnbar",
    endpoint: "https://mcp.openburnbar.com/mcp",
    audience: "https://mcp.openburnbar.com/mcp",
    bucket: process.env.OPENBURNBAR_STORAGE_BUCKET || process.env.FIREBASE_STORAGE_BUCKET || "",
    proofId: `remote-mcp-perf-${Date.now()}`,
    documents: 1000,
    matches: 100,
    iterations: 20,
    skipBody: false
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
      case "--help":
      case "-h":
        console.log(usage());
        process.exit(0);
        break;
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
      case "--documents":
        opts.documents = Number(next());
        break;
      case "--matches":
        opts.matches = Number(next());
        break;
      case "--iterations":
        opts.iterations = Number(next());
        break;
      case "--skip-body":
        opts.skipBody = true;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }
  if (!Number.isInteger(opts.documents) || opts.documents < 100 || opts.documents > 5000) {
    throw new Error("--documents must be an integer from 100 to 5000");
  }
  if (!Number.isInteger(opts.matches) || opts.matches < 1 || opts.matches > 120 || opts.matches > opts.documents) {
    throw new Error("--matches must be an integer from 1 to 120 and no larger than --documents");
  }
  if (!Number.isInteger(opts.iterations) || opts.iterations < 5 || opts.iterations > 100) {
    throw new Error("--iterations must be an integer from 5 to 100");
  }
  if (!opts.skipBody && !opts.bucket) {
    throw new Error("--bucket or OPENBURNBAR_STORAGE_BUCKET is required unless --skip-body is set");
  }
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

function post(url, body, headers = {}) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
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
      res.on("end", () => resolve({
        status: res.statusCode,
        body: Buffer.concat(chunks).toString("utf8"),
        latencyMs: performance.now() - started
      }));
    });
    req.on("error", reject);
    req.end(JSON.stringify(body));
  });
}

function parseToolText(label, result) {
  if (result.status !== 200) {
    throw new Error(`${label} expected HTTP 200, got ${result.status}: ${result.body.slice(0, 500)}`);
  }
  const envelope = JSON.parse(result.body);
  const text = envelope?.result?.content?.[0]?.text;
  if (typeof text !== "string") throw new Error(`${label} missing MCP text content`);
  return JSON.parse(text);
}

function percentile(values, p) {
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[index];
}

function summary(values) {
  return {
    count: values.length,
    minMs: Math.round(Math.min(...values)),
    p50Ms: Math.round(percentile(values, 50)),
    p95Ms: Math.round(percentile(values, 95)),
    maxMs: Math.round(Math.max(...values))
  };
}

async function commitBatches(db, writes) {
  for (let index = 0; index < writes.length; index += 450) {
    const batch = db.batch();
    for (const write of writes.slice(index, index + 450)) {
      batch.set(write.ref, write.data, write.options ?? {});
    }
    await batch.commit();
  }
}

function hex32(number) {
  return number.toString(16).padStart(32, "0").slice(-32);
}

async function seedCorpus({ db, uid, clientId, opts, searchedHash, bodyHash, bodyPath }) {
  const now = Timestamp.now();
  const expiresAt = Timestamp.fromDate(new Date(Date.now() + 60 * 60 * 1000));
  const writes = [
    {
      ref: db.doc(`users/${uid}/entitlements/burnbar_pro`),
      data: { active: true, expiresAt, source: "performance-proof", updatedAt: now }
    },
    {
      ref: db.doc(`users/${uid}/remote_mcp_clients/${clientId}`),
      data: {
        clientId,
        displayName: "Performance proof client",
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
        activeCommitIDsByDevice: { performanceProof: "perf-proof-commit" },
        latestCommittedAt: new Date().toISOString(),
        documentCount: opts.documents,
        chunkCount: opts.documents,
        tokenPostingCount: opts.documents,
        semanticPostingCount: 0,
        stale: false,
        compactionStatus: "proof"
      }
    }
  ];

  for (let index = 0; index < opts.documents; index += 1) {
    const documentID = `perf-doc-${index}`;
    const chunkID = `perf-chunk-${index}`;
    const isMatch = index < opts.matches;
    const hash = isMatch ? searchedHash : hex32(index + 1);
    const storagePath = index === 0 ? bodyPath : `users/${uid}/session_logs/${documentID}/bodies/${hex32(index + 5000)}.json.aesgcm`;
    const effectiveBodyHash = index === 0 ? bodyHash : hex32(index + 7000);
    writes.push(
      {
        ref: db.doc(`users/${uid}/cloud_search_documents/${documentID}`),
        data: {
          sourceID: `Performance proof session ${index}`,
          storagePath,
          bodyHash: effectiveBodyHash,
          projectName: index % 2 === 0 ? "burnbar" : "proof",
          provider: "proof",
          model: "proof-model",
          harness: "proof-harness",
          sealedTitle: { alg: "proof", ciphertext: `sealed-title-${index}` },
          sealedBodyPreview: { alg: "proof", ciphertext: `sealed-preview-${index}` },
          createdAt: now
        }
      },
      {
        ref: db.doc(`users/${uid}/cloud_search_chunks/${chunkID}`),
        data: {
          documentID,
          sourceKind: "session",
          sourceID: `Performance proof session ${index}`,
          provider: "proof",
          projectName: index % 2 === 0 ? "burnbar" : "proof",
          model: "proof-model",
          harness: "proof-harness",
          commitID: "perf-proof-commit",
          storagePath,
          bodyHash: effectiveBodyHash,
          tokenHashes: [hash],
          semanticHashes: [],
          sealedSnippet: { alg: "proof", ciphertext: `sealed-snippet-${index}` },
          ordinal: index
        }
      },
      {
        ref: db.doc(`users/${uid}/cloud_search_postings/token_${hash}_${chunkID}`),
        data: {
          postingKey: `token_${hash}`,
          kind: "token",
          hash,
          chunkID,
          documentID,
          sourceKind: "session",
          sourceID: `Performance proof session ${index}`,
          provider: "proof",
          projectName: index % 2 === 0 ? "burnbar" : "proof",
          model: "proof-model",
          harness: "proof-harness",
          commitID: "perf-proof-commit",
          storagePath,
          bodyHash: effectiveBodyHash,
          sealedSnippet: { alg: "proof", ciphertext: `sealed-snippet-${index}` },
          ordinal: index
        }
      }
    );
  }
  await commitBatches(db, writes);
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const secret = process.env.OPENBURNBAR_MCP_TOKEN_HMAC_SECRET;
  if (!secret) throw new Error("OPENBURNBAR_MCP_TOKEN_HMAC_SECRET is required");
  if (getApps().length === 0) {
    initializeApp(opts.bucket ? { projectId: opts.project, storageBucket: opts.bucket } : { projectId: opts.project });
  }
  const db = getFirestore();
  const uid = `${opts.proofId}-user`;
  const clientId = "performance-proof-client";
  const searchedHash = "11111111111111111111111111111111";
  const bodyHash = "22222222222222222222222222222222";
  const bodyPath = `users/${uid}/session_logs/perf-doc-0/bodies/${bodyHash}.json.aesgcm`;
  const authHeader = {
    authorization: `Bearer ${mintProofToken({ uid, clientId, secret, scopes: ALL_SCOPES, audience: opts.audience })}`
  };
  const bodyLatencies = [];
  const searchLatencies = [];
  let lastSearchBody;
  let lastBodyBody;

  try {
    await seedCorpus({ db, uid, clientId, opts, searchedHash, bodyHash, bodyPath });
    if (!opts.skipBody) {
      const bodyBytes = Buffer.from(JSON.stringify({
        alg: "AES-256-GCM",
        nonce: "proof",
        ciphertext: "x".repeat(24_000),
        tag: "proof"
      }));
      await getStorage().bucket(opts.bucket).file(bodyPath).save(bodyBytes, {
        resumable: false,
        contentType: "application/octet-stream"
      });
    }

    const warmSearch = await post(opts.endpoint, {
      jsonrpc: "2.0",
      id: "warm-search",
      method: "tools/call",
      params: {
        name: "burnbar_search_conversations",
        arguments: { tokenHashes: [searchedHash], provider: "proof", limit: 25 }
      }
    }, authHeader);
    parseToolText("warm search", warmSearch);

    if (!opts.skipBody) {
      const warmBody = await post(opts.endpoint, {
        jsonrpc: "2.0",
        id: "warm-body",
        method: "tools/call",
        params: {
          name: "burnbar_get_conversation_body",
          arguments: { resourceUri: "burnbar://conversation/perf-doc-0", maxChars: 24_000 }
        }
      }, authHeader);
      parseToolText("warm body", warmBody);
    }

    for (let index = 0; index < opts.iterations; index += 1) {
      const search = await post(opts.endpoint, {
        jsonrpc: "2.0",
        id: `search-${index}`,
        method: "tools/call",
        params: {
          name: "burnbar_search_conversations",
          arguments: { tokenHashes: [searchedHash], provider: "proof", limit: 25 }
        }
      }, authHeader);
      lastSearchBody = parseToolText("search", search);
      searchLatencies.push(search.latencyMs);
      const budget = lastSearchBody.readBudget;
      if (!budget?.withinSearchReadBudget || budget.storageReads !== 0 || budget.firestoreDocumentReads > 150) {
        throw new Error(`search read budget failed: ${JSON.stringify(budget)}`);
      }
      if (!Array.isArray(lastSearchBody.hits) || lastSearchBody.hits.length !== 25) {
        throw new Error(`search expected 25 hits, got ${lastSearchBody.hits?.length}`);
      }

      if (!opts.skipBody) {
        const body = await post(opts.endpoint, {
          jsonrpc: "2.0",
          id: `body-${index}`,
          method: "tools/call",
          params: {
            name: "burnbar_get_conversation_body",
            arguments: { resourceUri: "burnbar://conversation/perf-doc-0", maxChars: 24_000 }
          }
        }, authHeader);
        lastBodyBody = parseToolText("body", body);
        bodyLatencies.push(body.latencyMs);
        const bodyBudget = lastBodyBody.readBudget;
        if (!bodyBudget?.withinBodyReadBudget || bodyBudget.storageReads !== 1 || bodyBudget.firestoreDocumentReads !== 1) {
          throw new Error(`body read budget failed: ${JSON.stringify(bodyBudget)}`);
        }
      }
    }

    const searchSummary = summary(searchLatencies);
    const bodySummary = bodyLatencies.length > 0 ? summary(bodyLatencies) : undefined;
    const ok = searchSummary.p50Ms < SEARCH_P50_TARGET_MS
      && searchSummary.p95Ms < SEARCH_P95_TARGET_MS
      && (opts.skipBody || bodySummary.p95Ms < BODY_P95_TARGET_MS);
    if (!ok) {
      throw new Error(`performance target failed: ${JSON.stringify({ search: searchSummary, body: bodySummary })}`);
    }
    console.log(JSON.stringify({
      ok: true,
      endpoint: opts.endpoint,
      proofId: opts.proofId,
      corpus: { documents: opts.documents, matchingCandidates: opts.matches, iterations: opts.iterations },
      targets: {
        searchP50Ms: SEARCH_P50_TARGET_MS,
        searchP95Ms: SEARCH_P95_TARGET_MS,
        bodyP95Ms: BODY_P95_TARGET_MS
      },
      search: searchSummary,
      body: bodySummary,
      readBudget: {
        search: lastSearchBody?.readBudget,
        body: lastBodyBody?.readBudget
      }
    }, null, 2));
  } finally {
    await db.recursiveDelete(db.doc(`users/${uid}`)).catch(() => undefined);
    if (!opts.skipBody && opts.bucket) {
      await getStorage().bucket(opts.bucket).deleteFiles({ prefix: `users/${uid}/session_logs/` }).catch(() => undefined);
    }
  }
}

main().catch((error) => {
  console.error(JSON.stringify({ ok: false, error: error.message }, null, 2));
  process.exit(1);
});
