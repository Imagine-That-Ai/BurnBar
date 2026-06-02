#!/usr/bin/env node

/**
 * Operator migration: upload local OpenBurnBar SQLite conversations into the
 * encrypted hosted search v4 collections for the signed-in account.
 *
 * Dry-run:
 *   node scripts/upload-local-sqlite-session-logs-v4.mjs --uid <uid> --device-id <device-id>
 *
 * Apply and mark uploaded local rows as synced:
 *   node scripts/upload-local-sqlite-session-logs-v4.mjs --uid <uid> --device-id <device-id> --apply --mark-synced
 */

import { spawnSync } from "node:child_process";
import crypto from "node:crypto";
import os from "node:os";
import process from "node:process";
import { pathToFileURL } from "node:url";

import admin from "firebase-admin";

import { buildCloudSearchPostingEdges } from "../lib/callables/encryptedSearchIndex.js";

const PROJECT_ID = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "burnbar";
const STORAGE_BUCKET = process.env.OPENBURNBAR_STORAGE_BUCKET || "burnbar-hosted-mcp-bodies-246956661961";
const DEFAULT_SQLITE_PATH = `${os.homedir()}/Library/Application Support/OpenBurnBar/openburnbar.sqlite`;
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
  const args = {
    apply: false,
    markSynced: false,
    includeSynced: false,
    limit: 0,
    batchSize: 100,
    sqlitePath: DEFAULT_SQLITE_PATH,
  };
  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--apply") {
      args.apply = true;
    } else if (arg === "--mark-synced") {
      args.markSynced = true;
    } else if (arg === "--include-synced") {
      args.includeSynced = true;
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
  args.batchSize = Number(args.batchSize || 100);
  if (!Number.isFinite(args.limit) || args.limit < 0) throw new Error("--limit must be a non-negative number.");
  if (!Number.isFinite(args.batchSize) || args.batchSize < 1 || args.batchSize > 500) {
    throw new Error("--batch-size must be 1...500.");
  }
  return args;
}

function securityPasswordHex(service, account) {
  const result = spawnSync("security", ["find-generic-password", "-s", service, "-a", account, "-g"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    timeout: 3_000,
  });
  if (result.status !== 0) throw new Error(`Keychain lookup failed for ${service} ${account}.`);
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
      // Try the next active wrapper.
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
  return aesGcmOpenCombined(sealed, wrappingKey);
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

function tokenHashes(text, vaultKey, limit = 250) {
  const key = searchKey(vaultKey);
  const seen = new Set();
  const hashes = [];
  const tokens = uniqueNormalizedTokens(text);
  const terms = tokens.concat(searchIndexPrefixTerms(tokens), exactPhraseTerms(text));
  for (const term of terms) {
    if (seen.has(term)) continue;
    seen.add(term);
    hashes.push(crypto.createHmac("sha256", key).update(term, "utf8").digest().subarray(0, 16).toString("hex"));
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

function sqlString(value) {
  return `'${String(value).replace(/'/gu, "''")}'`;
}

function sqliteJSON(sqlitePath, sql) {
  const result = spawnSync("sqlite3", ["-json", sqlitePath, sql], {
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
  });
  if (result.status !== 0) {
    throw new Error(result.stderr || `sqlite3 exited ${result.status}`);
  }
  return result.stdout.trim() ? JSON.parse(result.stdout) : [];
}

function markRowsSynced(sqlitePath, ids) {
  if (ids.length === 0) return;
  const idList = ids.map(sqlString).join(",");
  const sql = `UPDATE conversations SET logSyncedAt = strftime('%Y-%m-%d %H:%M:%f', 'now') WHERE id IN (${idList});`;
  const result = spawnSync("sqlite3", [sqlitePath, sql], { encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || `sqlite3 exited ${result.status}`);
}

const LOCAL_ROW_ORDER_EXPR = "COALESCE(endTime, startTime, indexedAt, fileModifiedAt, id)";

function readLocalRows(sqlitePath, batchSize, contains, includeSynced, cursor = undefined) {
  const containsClause = contains
    ? `AND (lower(fullText) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(inferredTaskTitle) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(summaryTitle) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(projectName) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(workingDirectory) LIKE ${sqlString(`%${contains.toLowerCase()}%`)})`
    : "";
  const syncClause = includeSynced ? "" : "logSyncedAt IS NULL AND";
  const cursorClause = cursor
    ? `AND (${LOCAL_ROW_ORDER_EXPR} > ${sqlString(cursor.sortKey)} OR (${LOCAL_ROW_ORDER_EXPR} = ${sqlString(cursor.sortKey)} AND id > ${sqlString(cursor.id)}))`
    : "";
  return sqliteJSON(sqlitePath, `
    SELECT id, provider, sessionId, projectName, startTime, endTime,
           messageCount, userWordCount, assistantWordCount, inferredTaskTitle,
           lastAssistantMessage, fullText, indexedAt, fileModifiedAt, summary,
           sourceType, summaryTitle, workingDirectory,
           ${LOCAL_ROW_ORDER_EXPR} AS uploadSortKey
    FROM conversations
    WHERE ${syncClause} isRemote = 0 ${containsClause} ${cursorClause}
    ORDER BY uploadSortKey ASC, id ASC
    LIMIT ${Number(batchSize)}
  `);
}

function localPendingCount(sqlitePath, contains, includeSynced) {
  const containsClause = contains
    ? `AND (lower(fullText) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(inferredTaskTitle) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(summaryTitle) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(projectName) LIKE ${sqlString(`%${contains.toLowerCase()}%`)} OR lower(workingDirectory) LIKE ${sqlString(`%${contains.toLowerCase()}%`)})`
    : "";
  const syncClause = includeSynced ? "" : "logSyncedAt IS NULL AND";
  return Number(sqliteJSON(sqlitePath, `
    SELECT COUNT(*) AS count
    FROM conversations
    WHERE ${syncClause} isRemote = 0 ${containsClause}
  `)[0]?.count ?? 0);
}

function dateOrNull(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : admin.firestore.Timestamp.fromDate(date);
}

function safeDocID(deviceId, recordId) {
  return `${deviceId}_${recordId.replaceAll(":", "_").replaceAll("/", "_")}`;
}

function displayTitle(row) {
  if (row.summaryTitle) return row.summaryTitle;
  if (row.inferredTaskTitle) return row.inferredTaskTitle;
  return `${row.provider || "Session"} ${row.sessionId || row.id}`;
}

function markdownFor(row) {
  if (row.sourceType === "cli_assistant") return row.fullText || "";
  const lines = [`# ${displayTitle(row)}`, ""];
  if (row.summary) {
    lines.push("## Session Summary", "");
    if (row.summaryTitle) lines.push(`**Name:** ${row.summaryTitle}`, "");
    lines.push(row.summary, "", "---", "");
  }
  lines.push("| Field | Value |", "|---|---|");
  lines.push(`| Provider | ${row.provider || "unknown"} |`);
  lines.push(`| Project | ${row.projectName || ""} |`);
  lines.push(`| Session ID | ${row.sessionId || ""} |`);
  if (row.startTime) lines.push(`| Started | ${row.startTime} |`);
  if (row.endTime) lines.push(`| Ended | ${row.endTime} |`);
  lines.push(`| Messages | ${Number(row.messageCount || 0)} |`);
  if (Number(row.userWordCount || 0) > 0 || Number(row.assistantWordCount || 0) > 0) {
    lines.push(`| Words (user / assistant) | ${Number(row.userWordCount || 0)} / ${Number(row.assistantWordCount || 0)} |`);
  }
  lines.push("", "---", "");
  if (row.fullText) lines.push(row.fullText);
  return lines.join("\n");
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

function buildUploadPlan({ db, uid, deviceId, vaultKey, row }) {
  const docId = safeDocID(deviceId, row.id);
  const markdown = markdownFor(row);
  const bodyData = Buffer.from(markdown, "utf8");
  const bodyHash = sha256Hex(bodyData);
  const sealedBody = sealBlob(bodyData, vaultKey);
  const sealedBodyData = Buffer.from(JSON.stringify(sealedBody), "utf8");
  const storagePath = `users/${uid}/session_logs/${docId}/bodies/${bodyHash}.json.aesgcm`;
  const title = displayTitle(row);
  const provider = row.provider || "unknown";
  const projectName = row.projectName || "";
  const model = "unknown";
  const chunks = chunkUTF8String(markdown, CHUNK_MAX_BYTES);
  const sealedTitle = sealText(title, vaultKey);
  const sealedPreview = sealText(markdown.slice(0, 500), vaultKey);
  const chunkHashes = chunks.map((chunk) => sha256Hex(Buffer.from(chunk, "utf8")));
  const manifestRef = db.doc(`users/${uid}/session_logs/${docId}`);
  const writes = [];
  let postings = 0;

  const manifest = {
    id: row.id,
    deviceId,
    provider,
    sessionId: row.sessionId || "",
    sourceType: row.sourceType || "provider_log",
    projectName,
    inferredTaskTitle: "Encrypted session",
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
    chunkCount: 0,
    searchChunkCount: chunks.length,
    byteCount: bodyData.length,
    encryptedByteCount: sealedBodyData.length,
    bodyHash,
    chunkSize: 0,
    chunkHashes,
    chunkMetadataVersion: 1,
    cloudSearchIndexVersion: INDEX_VERSION,
    cloudSearchIndexedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    model,
    totalTokens: Number(row.userWordCount || 0) + Number(row.assistantWordCount || 0),
    costUSD: 0,
    facetSchemaVersion: 2,
  };
  const startTime = dateOrNull(row.startTime);
  const endTime = dateOrNull(row.endTime);
  if (startTime) manifest.startTime = startTime;
  if (endTime) manifest.endTime = endTime;

  writes.push({ ref: manifestRef, data: manifest });
  writes.push({
    ref: db.collection(`users/${uid}/cloud_search_documents`).doc(docId),
    data: {
      uid,
      documentID: docId,
      deviceId,
      sourceKind: "conversation",
      sourceID: row.id,
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
    const sealedSnippet = sealText(chunk.replace(/\n/gu, " ").trim().slice(0, 500), vaultKey);
    const tokenHashList = tokenHashes(indexedText, vaultKey, CHUNK_TOKEN_HASH_LIMIT);
    const semanticHashList = semanticHashes(indexedText, vaultKey, 24);
    const chunkID = `${docId}_${index}`;
    const chunkData = {
      uid,
      chunkID,
      documentID: docId,
      deviceId,
      sourceKind: "conversation",
      sourceID: row.id,
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
    const edges = buildCloudSearchPostingEdges({
      source: {
        uid,
        chunkID,
        documentID: docId,
        sourceKind: "conversation",
        sourceID: row.id,
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
    postings += edges.length;
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

  return {
    docId,
    storagePath,
    sealedBodyData,
    writes,
    chunks: chunks.length,
    postings,
    bytes: bodyData.length,
    encryptedBytes: sealedBodyData.length,
  };
}

async function uploadRow({ db, bucket, uid, deviceId, vaultKey, row, apply }) {
  const plan = buildUploadPlan({ db, uid, deviceId, vaultKey, row });

  if (apply) {
    await bucket.file(plan.storagePath).save(plan.sealedBodyData, { contentType: "application/octet-stream", resumable: false });
    await commitBatch(db, plan.writes, true);
  }
  return {
    chunks: plan.chunks,
    postings: plan.postings,
    writes: plan.writes.length,
    bytes: plan.bytes,
    encryptedBytes: plan.encryptedBytes,
  };
}

async function main() {
  const args = parseArgs(process.argv);
  admin.initializeApp({ projectId: PROJECT_ID, storageBucket: STORAGE_BUCKET });
  const db = admin.firestore();
  const bucket = admin.storage().bucket();
  const vaultKey = await loadVaultKey({ db, uid: args.uid, deviceId: args.deviceId });
  const startingPending = localPendingCount(args.sqlitePath, args.contains, args.includeSynced);
  const maxRecords = args.limit > 0 ? Math.min(args.limit, startingPending) : startingPending;
  const totals = {
    pendingAtStart: startingPending,
    scanned: 0,
    uploaded: 0,
    chunks: 0,
    writes: 0,
    postings: 0,
    bytes: 0,
    encryptedBytes: 0,
  };
  let cursor;

  console.log(JSON.stringify({
    apply: args.apply,
    markSynced: args.markSynced,
    includeSynced: args.includeSynced,
    uidPrefix: args.uid.slice(0, 8),
    deviceId: args.deviceId,
    sqlitePath: args.sqlitePath,
    contains: args.contains || null,
    pendingAtStart: startingPending,
    maxRecords,
    commitID: COMMIT_ID,
  }, null, 2));

  while (totals.uploaded < maxRecords) {
    const remaining = maxRecords - totals.uploaded;
    const rows = readLocalRows(args.sqlitePath, Math.min(args.batchSize, remaining), args.contains, args.includeSynced, cursor);
    if (rows.length === 0) break;
    const syncedIDs = [];
    for (const row of rows) {
      totals.scanned += 1;
      const result = await uploadRow({
        db,
        bucket,
        uid: args.uid,
        deviceId: args.deviceId,
        vaultKey,
        row,
        apply: args.apply,
      });
      totals.uploaded += 1;
      totals.chunks += result.chunks;
      totals.postings += result.postings;
      totals.writes += result.writes;
      totals.bytes += result.bytes;
      totals.encryptedBytes += result.encryptedBytes;
      syncedIDs.push(row.id);
      if (totals.uploaded % 25 === 0) {
        console.log(`${args.apply ? "uploaded" : "dry-run"} ${totals.uploaded}/${maxRecords} local rows...`);
      }
    }
    const lastRow = rows[rows.length - 1];
    cursor = {
      sortKey: String(lastRow.uploadSortKey ?? lastRow.id),
      id: String(lastRow.id),
    };
    if (args.apply && args.markSynced && !args.includeSynced) markRowsSynced(args.sqlitePath, syncedIDs);
    if (!args.apply) break;
  }

  console.log(JSON.stringify({ totals }, null, 2));
  await db.terminate();
}

export {
  buildUploadPlan,
  commitBatch,
  localPendingCount,
  parseArgs,
  readLocalRows,
  uploadRow,
};

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}
