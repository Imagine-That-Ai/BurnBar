#!/usr/bin/env node

/**
 * Backfills legacy `session_logs/{doc}/chunks` plaintext rows into the encrypted
 * hosted search collections. This is an operator-only migration for accounts
 * that had cockpit manifests before the hosted encrypted cloud index existed.
 *
 * Dry-run by default:
 *   npm run backfill:cloud-search-v4 -- --uid <uid> --device-id <device-id>
 *
 * Apply:
 *   npm run backfill:cloud-search-v4 -- --uid <uid> --device-id <device-id> --apply --skip-postings
 */

import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import process from "node:process";
import { pathToFileURL } from "node:url";

import admin from "firebase-admin";

import { buildCloudSearchPostingEdges } from "../lib/callables/encryptedSearchIndex.js";

const PROJECT_ID = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "burnbar";
const STORAGE_BUCKET = process.env.OPENBURNBAR_STORAGE_BUCKET || "burnbar-hosted-mcp-bodies-246956661961";
const INDEX_VERSION = 4;
const CHUNK_MAX_BYTES = 16_000;
const CHUNK_TOKEN_HASH_LIMIT = 1_024;
const COMMIT_ID = crypto.randomBytes(16).toString("hex");

const stopwords = new Set([
  "the", "and", "for", "with", "that", "this", "from", "how", "what", "where",
  "when", "why", "are", "was", "were", "you", "your", "have", "has", "had",
  "into", "onto", "can", "could", "should", "would",
]);

function parseArgs(argv) {
  const args = { apply: false, limit: 0, offset: 0, skipPostings: false };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--apply") {
      args.apply = true;
    } else if (arg === "--skip-postings") {
      args.skipPostings = true;
    } else if (arg.startsWith("--")) {
      const key = arg.slice(2).replace(/-([a-z])/gu, (_, char) => char.toUpperCase());
      const value = argv[index + 1];
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a value.`);
      args[key] = value;
      index += 1;
    }
  }
  if (!args.uid) throw new Error("--uid is required.");
  if (!args.deviceId) throw new Error("--device-id is required.");
  args.limit = Number(args.limit || 0);
  if (!Number.isFinite(args.limit) || args.limit < 0) throw new Error("--limit must be a non-negative number.");
  args.offset = Number(args.offset || 0);
  if (!Number.isFinite(args.offset) || args.offset < 0) throw new Error("--offset must be a non-negative number.");
  return args;
}

function securityPasswordHex(service, account) {
  const result = spawnSync("security", ["find-generic-password", "-s", service, "-a", account, "-g"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 3_000,
  });
  if (result.status !== 0) {
    throw new Error(`Keychain lookup failed for ${service} ${account}.`);
  }
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  const match = output.match(/password:\s*0x([0-9a-fA-F]+)/u);
  if (!match) throw new Error(`No keychain password hex found for ${service} ${account}.`);
  return match[1].toLowerCase();
}

async function loadVaultKey({ db, uid, deviceId }) {
  if (process.env.CLOUD_VAULT_KEY_HEX) {
    const key = Buffer.from(process.env.CLOUD_VAULT_KEY_HEX, "hex");
    if (key.length !== 32) throw new Error("CLOUD_VAULT_KEY_HEX must decode to 32 bytes.");
    return key;
  }

  const cachedHex = (() => {
    try {
      return securityPasswordHex("com.openburnbar.cloud-vault", `vault-key:${uid}`);
    } catch {
      return undefined;
    }
  })();
  if (cachedHex) {
    const key = Buffer.from(cachedHex, "hex");
    if (key.length === 32) return key;
  }

  const privateKeyHex = process.env.CLOUD_VAULT_DEVICE_PRIVATE_KEY_HEX
    || securityPasswordHex("com.openburnbar.device-escrow", `cloud-vault-device:${deviceId}`);
  const privateKey = Buffer.from(privateKeyHex, "hex");
  if (privateKey.length !== 32) throw new Error("Device escrow private key must be 32 bytes.");

  const wrappers = await db.collection(`users/${uid}/cloud_vault_key_wrappers`)
    .where("targetDeviceId", "==", deviceId)
    .where("status", "==", "active")
    .limit(5)
    .get();
  for (const wrapper of wrappers.docs) {
    const wrappedBase64 = wrapper.get("wrappedVaultKey");
    if (typeof wrappedBase64 !== "string") continue;
    try {
      return unwrapVaultKey(Buffer.from(wrappedBase64, "base64"), privateKey);
    } catch {
      // Try the next active wrapper, if any.
    }
  }
  throw new Error(`No decryptable active vault wrapper found for ${uid}/${deviceId}.`);
}

function unwrapVaultKey(wrapped, privateKey) {
  if (wrapped.length <= 65) throw new Error("Wrapped vault key is too short.");
  const peerPublicKey = wrapped.subarray(0, 65);
  const sealed = wrapped.subarray(65);
  const ecdh = crypto.createECDH("prime256v1");
  ecdh.setPrivateKey(privateKey);
  const sharedSecret = ecdh.computeSecret(peerPublicKey);
  const wrappingKey = Buffer.from(crypto.hkdfSync(
    "sha256",
    sharedSecret,
    Buffer.alloc(0),
    Buffer.from("OpenBurnBar-Escrow-v1", "utf8"),
    32
  ));
  const key = aesGcmOpenCombined(sealed, wrappingKey);
  if (key.length !== 32) throw new Error("Unwrapped vault key has an invalid length.");
  return key;
}

function aesGcmOpenCombined(combined, key) {
  const nonce = combined.subarray(0, 12);
  const ciphertext = combined.subarray(12, combined.length - 16);
  const tag = combined.subarray(combined.length - 16);
  const decipher = crypto.createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]);
}

function sealText(text, key) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([cipher.update(Buffer.from(text, "utf8")), cipher.final()]);
  return {
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    nonce: nonce.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
    tag: cipher.getAuthTag().toString("base64"),
  };
}

function sealBlob(data, key) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, nonce);
  const ciphertext = Buffer.concat([cipher.update(data), cipher.final()]);
  const combined = Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]);
  return {
    schemaVersion: 1,
    algorithm: "AES-256-GCM",
    keyVersion: 1,
    plaintextSHA256: sha256Hex(data),
    sealedBoxBase64: combined.toString("base64"),
    createdAt: new Date().toISOString(),
  };
}

function sha256Hex(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

function searchKey(vaultKey) {
  return Buffer.from(crypto.hkdfSync(
    "sha256",
    vaultKey,
    Buffer.from("OpenBurnBar-CloudSearch-Salt-v1", "utf8"),
    Buffer.from("OpenBurnBar-CloudSearch-TokenHash-v1", "utf8"),
    32
  ));
}

function semanticSearchKey(vaultKey) {
  return Buffer.from(crypto.hkdfSync(
    "sha256",
    vaultKey,
    Buffer.from("OpenBurnBar-CloudSearch-Semantic-Salt-v1", "utf8"),
    Buffer.from("OpenBurnBar-CloudSearch-SemanticHash-v1", "utf8"),
    32
  ));
}

function normalizedTokens(text) {
  return text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((token) => token.length >= 2 && !stopwords.has(token));
}

function exactPhraseTokens(text) {
  return text
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((token) => (token.length >= 2 || token === "x") && !stopwords.has(token));
}

function hmacToken(term, key) {
  return crypto.createHmac("sha256", key).update(term, "utf8").digest().subarray(0, 16).toString("hex");
}

function uniqueNormalizedTokens(text) {
  const seen = new Set();
  const tokens = [];
  for (const token of normalizedTokens(text)) {
    if (seen.has(token)) continue;
    seen.add(token);
    tokens.push(token);
  }
  return tokens;
}

function searchIndexPrefixTerms(tokens) {
  const terms = [];
  for (const token of tokens) {
    const characters = Array.from(token);
    if (characters.length < 4) continue;
    const maxPrefixLength = Math.min(16, characters.length - 1);
    for (let length = 3; length <= maxPrefixLength; length += 1) {
      terms.push(`prefix:v1:${characters.slice(0, length).join("")}`);
    }
  }
  return terms;
}

function exactPhraseTerms(text) {
  const tokens = exactPhraseTokens(text);
  if (tokens.length < 2) return [];
  const terms = [];
  for (let index = 0; index < tokens.length; index += 1) {
    if (index + 1 < tokens.length) {
      terms.push(`phrase:v1:${tokens.slice(index, index + 2).join("_")}`);
    }
    if (index + 2 < tokens.length) {
      terms.push(`phrase:v1:${tokens.slice(index, index + 3).join("_")}`);
    }
  }
  return terms;
}

function searchIndexTokenHashes(text, vaultKey, limit = 250) {
  const key = searchKey(vaultKey);
  const seen = new Set();
  const hashes = [];
  const tokens = uniqueNormalizedTokens(text);
  const terms = tokens.concat(searchIndexPrefixTerms(tokens), exactPhraseTerms(text));
  for (const term of terms) {
    if (seen.has(term)) continue;
    seen.add(term);
    hashes.push(hmacToken(term, key));
    if (hashes.length >= limit) break;
  }
  return hashes;
}

function semanticHashes(text, vaultKey, limit = 24) {
  const tokens = exactPhraseTokens(text);
  if (tokens.length === 0 || limit <= 0) return [];
  const key = semanticSearchKey(vaultKey);
  const features = semanticFeatures(tokens);
  const dimensions = 64;
  const accumulator = Array.from({ length: dimensions }, () => 0);
  for (const feature of features) {
    const mac = crypto.createHmac("sha256", key).update(feature.name, "utf8").digest();
    const index = (((mac[0] << 8) | mac[1]) % dimensions);
    const sign = (mac[2] & 1) === 0 ? 1 : -1;
    accumulator[index] += sign * feature.weight;
  }
  const hashes = [];
  const seen = new Set();
  const appendBucket = (bucket) => {
    if (hashes.length >= limit) return;
    const hash = crypto.createHmac("sha256", key).update(bucket, "utf8").digest().subarray(0, 16).toString("hex");
    if (!seen.has(hash)) {
      seen.add(hash);
      hashes.push(hash);
    }
  };
  for (let band = 0; band < dimensions / 8; band += 1) {
    let value = 0;
    for (let bit = 0; bit < 8; bit += 1) {
      if (accumulator[(band * 8) + bit] >= 0) value |= (1 << bit);
    }
    appendBucket(`simhash:v1:band:${band}:${value.toString(16).padStart(2, "0")}`);
  }
  for (const feature of features.slice(0, Math.max(0, limit - hashes.length))) {
    appendBucket(`feature:v1:${feature.name}`);
  }
  return hashes;
}

function semanticFeatures(tokens) {
  const features = [];
  const seen = new Set();
  const append = (name, weight) => {
    if (!name || seen.has(name)) return;
    seen.add(name);
    features.push({ name, weight });
  };
  for (const concept of semanticConcepts(tokens)) {
    append(`concept:${concept}`, 3.2);
  }
  for (const token of tokens) {
    append(`token:${token}`, 2.4);
    const stem = simpleSemanticStem(token);
    if (stem !== token) append(`stem:${stem}`, 1.8);
    if (token.length >= 5) append(`prefix:${token.slice(0, 5)}`, 0.8);
  }
  for (let index = 0; index < tokens.length - 1; index += 1) {
    append(`bigram:${tokens[index]}_${tokens[index + 1]}`, 1.3);
  }
  return features;
}

function semanticConcepts(tokens) {
  const concepts = [];
  const seen = new Set();
  const append = (concept) => {
    if (seen.has(concept)) return;
    seen.add(concept);
    concepts.push(concept);
  };

  for (const token of tokens) {
    switch (token) {
      case "x":
      case "twitter":
      case "tweets":
      case "tweet":
      case "xcom":
        append("x-platform");
        append("social-platform");
        break;
      case "ads":
      case "ad":
      case "advertising":
      case "advertise":
      case "campaign":
      case "campaigns":
      case "marketing":
        append("advertising");
        break;
      case "api":
      case "apis":
      case "endpoint":
      case "endpoints":
      case "sdk":
      case "webhook":
      case "webhooks":
      case "integration":
      case "integrations":
        append("api-integration");
        break;
      case "oauth":
      case "auth":
      case "login":
      case "signin":
      case "token":
      case "tokens":
      case "credential":
      case "credentials":
        append("authentication");
        break;
      case "billing":
      case "invoice":
      case "invoices":
      case "pricing":
      case "price":
      case "cost":
      case "spend":
      case "quota":
      case "usage":
        append("billing-usage");
        break;
      case "backup":
      case "sync":
      case "mirror":
      case "cache":
      case "restore":
      case "download":
      case "upload":
        append("backup-sync");
        break;
      default:
        break;
    }
  }

  if (concepts.includes("x-platform") && concepts.includes("advertising")) append("x-ads");
  if (concepts.includes("advertising") && concepts.includes("api-integration")) append("ads-api");
  if (concepts.includes("x-platform") && concepts.includes("api-integration")) append("x-api");
  return concepts;
}

function simpleSemanticStem(token) {
  for (const suffix of ["ization", "ations", "ation", "ments", "ment", "ingly", "edly", "ing", "ies", "ied", "ers", "er", "ed", "s"]) {
    if (token.length > suffix.length + 3 && token.endsWith(suffix)) {
      const stem = token.slice(0, -suffix.length);
      return suffix === "ies" || suffix === "ied" ? `${stem}y` : stem;
    }
  }
  return token;
}

function chunkUTF8String(text, maxBytes) {
  const chunks = [];
  let current = "";
  let currentBytes = 0;
  for (const char of text) {
    const charBytes = Buffer.byteLength(char, "utf8");
    if (current && currentBytes + charBytes > maxBytes) {
      chunks.push(current);
      current = "";
      currentBytes = 0;
    }
    current += char;
    currentBytes += charBytes;
  }
  if (current) chunks.push(current);
  return chunks.length > 0 ? chunks : [text];
}

function trimmedSnippet(text) {
  return text.replace(/\n/gu, " ").trim().slice(0, 500);
}

async function readLegacyBody(logRef) {
  const chunks = await logRef.collection("chunks").orderBy("index", "asc").get();
  const bodies = [];
  let title;
  let model;
  let provider;
  let projectName;
  for (const chunk of chunks.docs) {
    const data = chunk.data();
    if (typeof data.body === "string") bodies.push(data.body);
    title ||= typeof data.title === "string" ? data.title : undefined;
    model ||= typeof data.model === "string" ? data.model : undefined;
    provider ||= typeof data.provider === "string" ? data.provider : undefined;
    projectName ||= typeof data.projectName === "string" ? data.projectName : undefined;
  }
  return {
    body: bodies.join(""),
    legacyChunkCount: chunks.size,
    title,
    model,
    provider,
    projectName,
  };
}

async function commitBatch(db, writes, apply) {
  if (!apply || writes.length === 0) return;
  for (let start = 0; start < writes.length; start += 400) {
    const batch = db.batch();
    for (const write of writes.slice(start, start + 400)) {
      batch.set(write.ref, write.data, { merge: true });
    }
    await batch.commit();
  }
}

async function main() {
  const args = parseArgs(process.argv);
  admin.initializeApp({ projectId: PROJECT_ID, storageBucket: STORAGE_BUCKET });
  const db = admin.firestore();
  const bucket = admin.storage().bucket();
  const uid = args.uid;
  const deviceId = args.deviceId;
  const apply = args.apply;
  console.log(`loading vault key for ${uid.slice(0, 8)} / ${deviceId}...`);
  const vaultKey = await loadVaultKey({ db, uid, deviceId });
  console.log("vault key loaded; scanning legacy session logs...");
  let query = db.collection(`users/${uid}/session_logs`).orderBy("updatedAt", "desc");
  if (args.offset > 0) query = query.offset(args.offset);
  if (args.limit > 0) query = query.limit(args.limit);
  const snapshot = await query.get();
  console.log(`loaded ${snapshot.size} legacy session logs (${apply ? "apply" : "dry-run"})`);

  const totals = { scanned: 0, skipped: 0, documents: 0, chunks: 0, postings: 0, uploads: 0, writes: 0 };
  for (const log of snapshot.docs) {
    totals.scanned += 1;
    const manifest = log.data();
    if (
      manifest.cloudSearchIndexVersion === INDEX_VERSION
      && manifest.bodyStorage === "firebase_storage_encrypted"
      && typeof manifest.storagePath === "string"
    ) {
      totals.skipped += 1;
      continue;
    }
    const legacy = await readLegacyBody(log.ref);
    if (!legacy.body) {
      totals.skipped += 1;
      continue;
    }

    const bodyData = Buffer.from(legacy.body, "utf8");
    const bodyHash = sha256Hex(bodyData);
    const sealedBody = sealBlob(bodyData, vaultKey);
    const sealedBodyData = Buffer.from(JSON.stringify(sealedBody), "utf8");
    const storagePath = `users/${uid}/session_logs/${log.id}/bodies/${bodyHash}.json.aesgcm`;
    const title = typeof manifest.summaryTitle === "string"
      ? manifest.summaryTitle
      : legacy.title || (typeof manifest.inferredTaskTitle === "string" ? manifest.inferredTaskTitle : "Encrypted session");
    const provider = typeof manifest.provider === "string" ? manifest.provider : legacy.provider || "unknown";
    const projectName = typeof manifest.projectName === "string" ? manifest.projectName : legacy.projectName || "";
    const model = typeof manifest.model === "string" ? manifest.model : legacy.model || "unknown";
    const sourceID = typeof manifest.id === "string" ? manifest.id : log.id;
    const chunks = chunkUTF8String(legacy.body, CHUNK_MAX_BYTES);
    const sealedTitle = sealText(title, vaultKey);
    const sealedPreview = sealText(legacy.body.slice(0, 500), vaultKey);
    const chunkHashes = chunks.map((chunk) => sha256Hex(Buffer.from(chunk, "utf8")));
    const writes = [];

    writes.push({
      ref: log.ref,
      data: {
        bodyStorage: "firebase_storage_encrypted",
        storagePath,
        sealedTitle,
        sealedBodyPreview: sealedPreview,
        encryption: {
          algorithm: "AES-256-GCM",
          keyVersion: 1,
          tokenHashVersion: 1,
          semanticHashVersion: 1,
        },
        searchChunkCount: chunks.length,
        byteCount: bodyData.length,
        encryptedByteCount: sealedBodyData.length,
        bodyHash,
        chunkHashes,
        chunkMetadataVersion: 1,
        cloudSearchIndexVersion: INDEX_VERSION,
        cloudSearchIndexedAt: admin.firestore.FieldValue.serverTimestamp(),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
    });
    writes.push({
      ref: db.collection(`users/${uid}/cloud_search_documents`).doc(log.id),
      data: {
        uid,
        documentID: log.id,
        deviceId,
        sourceKind: "conversation",
        sourceID,
        sourceVersionID: bodyHash,
        provider,
        projectName,
        bodyHash,
        storagePath,
        sealedTitle,
        sealedBodyPreview: sealedPreview,
        byteCount: bodyData.length,
        encryptedByteCount: sealedBodyData.length,
        indexVersion: INDEX_VERSION,
        tokenHashVersion: 1,
        semanticHashVersion: 1,
        commitID: COMMIT_ID,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        schemaVersion: 1,
      },
    });

    let offset = 0;
    for (const [index, chunk] of chunks.entries()) {
      const indexedText = `${chunk} ${title} ${projectName} ${model}`;
      const chunkHash = chunkHashes[index];
      const sealedSnippet = sealText(trimmedSnippet(chunk), vaultKey);
      const tokenHashList = searchIndexTokenHashes(indexedText, vaultKey, CHUNK_TOKEN_HASH_LIMIT);
      const semanticHashList = semanticHashes(indexedText, vaultKey, 24);
      const chunkID = `${log.id}_${index}`;
      const chunkData = {
        uid,
        chunkID,
        documentID: log.id,
        deviceId,
        sourceKind: "conversation",
        sourceID,
        provider,
        projectName,
        ordinal: index,
        startOffset: offset,
        endOffset: offset + Buffer.byteLength(chunk, "utf8"),
        contentHash: chunkHash,
        bodyHash,
        storagePath,
        sealedSnippet,
        tokenHashes: tokenHashList,
        semanticHashes: semanticHashList,
        indexVersion: INDEX_VERSION,
        tokenHashVersion: 1,
        semanticHashVersion: 1,
        commitID: COMMIT_ID,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        schemaVersion: 1,
      };
      writes.push({ ref: db.collection(`users/${uid}/cloud_search_chunks`).doc(chunkID), data: chunkData });
      if (!args.skipPostings) {
        const edges = buildCloudSearchPostingEdges({
          source: {
            uid,
            chunkID,
            documentID: log.id,
            sourceKind: "conversation",
            sourceID,
            provider,
            projectName,
            ordinal: index,
            bodyHash,
            storagePath,
            sealedSnippet,
            indexVersion: INDEX_VERSION,
            commitID: COMMIT_ID,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          },
          tokenHashes: tokenHashList,
          semanticHashes: semanticHashList,
        });
        for (const edge of edges) {
          writes.push({ ref: db.collection(`users/${uid}/cloud_search_postings`).doc(edge.edgeID), data: edge.data });
        }
        totals.postings += edges.length;
      }
      totals.chunks += 1;
      offset += Buffer.byteLength(chunk, "utf8");
    }

    writes.push({
      ref: db.doc(`users/${uid}/cloud_search_index_state/${deviceId}`),
      data: {
        uid,
        deviceId,
        indexVersion: INDEX_VERSION,
        activeCommitID: COMMIT_ID,
        lastCommittedAt: admin.firestore.FieldValue.serverTimestamp(),
        schemaVersion: 1,
      },
    });

    if (apply) {
      await bucket.file(storagePath).save(sealedBodyData, { contentType: "application/octet-stream", resumable: false });
      totals.uploads += 1;
      await commitBatch(db, writes, true);
    }
    totals.documents += 1;
    totals.writes += writes.length;
    if (totals.documents % 25 === 0) {
      console.log(`${apply ? "backfilled" : "dry-run"} ${totals.documents}/${snapshot.size} docs...`);
    }
  }
  console.log(JSON.stringify({ apply, uidPrefix: uid.slice(0, 8), deviceId, commitID: COMMIT_ID, totals }, null, 2));
}

export {
  commitBatch,
  parseArgs,
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main()
    .then(() => setTimeout(() => process.exit(0), 100))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
