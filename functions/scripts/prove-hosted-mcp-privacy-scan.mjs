#!/usr/bin/env node
/**
 * Read-only production privacy proof for hosted Remote MCP.
 *
 * This script intentionally never prints Firestore field values or Storage
 * object contents. It reports collection counts, sampled document counts, and
 * field/path violations only.
 */

import process from "node:process";
import { createHash } from "node:crypto";
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

const DEFAULT_COLLECTION_SAMPLE_LIMIT = 500;
const DEFAULT_STORAGE_SAMPLE_LIMIT = 500;

const HEX_64 = /^[a-f0-9]{64}$/;
const HASH_32 = /^[a-f0-9]{32}$/;
const STORAGE_PATH_RE = /^users\/([^/]+)\/session_logs\/([^/]+)\/bodies\/([a-f0-9]{64})\.json\.aesgcm$/;

const SENSITIVE_VALUE_PATTERNS = [
  { name: "bearer_token", re: /Bearer\s+[A-Za-z0-9._-]{20,}/i },
  { name: "raw_remote_mcp_refresh_token", re: /\bobbr_[A-Za-z0-9_-]{20,}\b/ },
  { name: "raw_remote_mcp_jti", re: /\bmcp_[a-f0-9]{32}\b/i },
  { name: "firebase_or_google_api_key", re: /\bAIza[0-9A-Za-z_-]{20,}\b/ },
  { name: "private_key", re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/ },
  { name: "common_provider_secret", re: /\b(sk-ant|sk-proj|sk-|xoxb-|ghp_)[A-Za-z0-9_-]{16,}/i },
  { name: "signed_storage_url", re: /X-Goog-(Algorithm|Credential|Signature)=/i },
];

const COLLECTIONS = {
  cloud_search_documents: {
    allowedTopLevel: new Set([
      "uid",
      "documentID",
      "deviceId",
      "sourceKind",
      "sourceID",
      "sourceVersionID",
      "provider",
      "projectName",
      "bodyHash",
      "storagePath",
      "sealedTitle",
      "sealedBodyPreview",
      "byteCount",
      "encryptedByteCount",
      "indexVersion",
      "tokenHashVersion",
      "semanticHashVersion",
      "commitID",
      "updatedAt",
      "schemaVersion",
    ]),
    forbiddenTopLevel: new Set(["title", "snippet", "body", "text", "query", "rawQuery", "prompt", "transcript", "messages"]),
    sealedFields: ["sealedTitle", "sealedBodyPreview"],
    storagePath: true,
  },
  cloud_search_chunks: {
    allowedTopLevel: new Set([
      "uid",
      "chunkID",
      "documentID",
      "deviceId",
      "sourceKind",
      "sourceID",
      "provider",
      "projectName",
      "ordinal",
      "startOffset",
      "endOffset",
      "contentHash",
      "bodyHash",
      "storagePath",
      "sealedSnippet",
      "tokenHashes",
      "semanticHashes",
      "indexVersion",
      "tokenHashVersion",
      "semanticHashVersion",
      "commitID",
      "updatedAt",
      "schemaVersion",
    ]),
    forbiddenTopLevel: new Set(["title", "snippet", "body", "text", "query", "rawQuery", "prompt", "transcript", "messages"]),
    sealedFields: ["sealedSnippet"],
    storagePath: true,
    hashArrays: ["tokenHashes", "semanticHashes"],
  },
  cloud_search_postings: {
    allowedTopLevel: new Set([
      "uid",
      "postingKey",
      "edgeID",
      "kind",
      "hash",
      "chunkID",
      "documentID",
      "sourceKind",
      "sourceID",
      "provider",
      "projectName",
      "ordinal",
      "bodyHash",
      "storagePath",
      "sealedSnippet",
      "updatedAt",
      "indexVersion",
      "commitID",
      "schemaVersion",
    ]),
    forbiddenTopLevel: new Set(["title", "snippet", "body", "text", "query", "rawQuery", "prompt", "transcript", "messages"]),
    sealedFields: ["sealedSnippet"],
    storagePath: true,
  },
  cloud_search_index_manifest: {
    forbiddenAnyField: new Set(["title", "snippet", "body", "text", "query", "rawQuery", "prompt", "transcript", "messages", "accessToken", "refreshToken", "idToken", "authorization"]),
  },
  cloud_search_index_state: {
    forbiddenAnyField: new Set(["title", "snippet", "body", "text", "query", "rawQuery", "prompt", "transcript", "messages", "accessToken", "refreshToken", "idToken", "authorization"]),
  },
  cloud_vault_key_wrappers: {
    forbiddenTopLevel: new Set(["vaultKey", "plaintext", "privateKey", "secret", "body", "text", "accessToken", "refreshToken", "idToken", "authorization"]),
    sealedFields: ["wrappedVaultKey"],
  },
  remote_mcp_clients: {
    allowedTopLevel: new Set([
      "clientId",
      "displayName",
      "clientType",
      "installFingerprintHash",
      "allowedScopes",
      "grantMode",
      "createdAt",
      "updatedAt",
      "lastUsedAt",
      "revokedAt",
      "schemaVersion",
    ]),
    forbiddenTopLevel: new Set(["installFingerprint", "accessToken", "refreshToken", "idToken", "authorization", "bearer", "query", "body", "text", "snippet", "title"]),
  },
  remote_mcp_grants: {
    allowedTopLevel: new Set([
      "grantId",
      "clientId",
      "scopes",
      "tokenFamilyHash",
      "refreshTokenHash",
      "expiresAt",
      "revokedAt",
      "entitlementSnapshot",
      "createdAt",
      "updatedAt",
      "schemaVersion",
    ]),
    forbiddenTopLevel: new Set(["accessToken", "refreshToken", "idToken", "authorization", "bearer", "query", "body", "text", "snippet", "title"]),
  },
  remote_mcp_audit_events: {
    allowedTopLevel: new Set([
      "eventKind",
      "traceID",
      "hashedClientID",
      "hashedIPPrefix",
      "hashedUserAgent",
      "scopes",
      "toolName",
      "resultCount",
      "denyReason",
      "entitlementSource",
      "tokenJtiHash",
      "opaqueQueryHashCount",
      "latencyBucket",
      "costBucket",
      "createdAt",
      "schemaVersion",
    ]),
    forbiddenTopLevel: new Set(["clientId", "ip", "userAgent", "tokenJti", "accessToken", "refreshToken", "idToken", "authorization", "bearer", "requestBody", "responseBody", "input", "output", "query", "body", "text", "snippet", "title"]),
  },
  remote_mcp_rate_limits: {
    forbiddenAnyField: new Set(["accessToken", "refreshToken", "idToken", "authorization", "bearer", "query", "body", "text", "snippet", "title"]),
  },
};

function usage() {
  return `Usage:
  npm --prefix functions run prove:hosted-mcp-privacy -- [options]

Options:
  --project <projectId>             Defaults to FIREBASE_PROJECT, GCLOUD_PROJECT, GOOGLE_CLOUD_PROJECT, then burnbar.
  --collection-limit <n>            Max sampled docs per collection group. Default: ${DEFAULT_COLLECTION_SAMPLE_LIMIT}.
  --storage-bucket <bucket>         Bucket to inspect. Defaults to OPENBURNBAR_STORAGE_BUCKET or FIREBASE_STORAGE_BUCKET.
  --storage-limit <n>               Max Storage objects to inspect. Default: ${DEFAULT_STORAGE_SAMPLE_LIMIT}.
  --skip-storage                    Only scan Firestore collection groups.
`;
}

function parseArgs(argv) {
  const opts = {
    project: process.env.FIREBASE_PROJECT || process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "burnbar",
    collectionLimit: DEFAULT_COLLECTION_SAMPLE_LIMIT,
    storageBucket: process.env.OPENBURNBAR_STORAGE_BUCKET || process.env.FIREBASE_STORAGE_BUCKET || "",
    storageLimit: DEFAULT_STORAGE_SAMPLE_LIMIT,
    skipStorage: false,
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      const value = argv[i + 1];
      if (!value || value.startsWith("--")) throw new Error(`${arg} requires a value`);
      i += 1;
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
      case "--collection-limit":
        opts.collectionLimit = Number(next());
        break;
      case "--storage-bucket":
        opts.storageBucket = next();
        break;
      case "--storage-limit":
        opts.storageLimit = Number(next());
        break;
      case "--skip-storage":
        opts.skipStorage = true;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }
  if (!Number.isInteger(opts.collectionLimit) || opts.collectionLimit < 1 || opts.collectionLimit > 5000) {
    throw new Error("--collection-limit must be an integer from 1 to 5000");
  }
  if (!Number.isInteger(opts.storageLimit) || opts.storageLimit < 1 || opts.storageLimit > 5000) {
    throw new Error("--storage-limit must be an integer from 1 to 5000");
  }
  if (!opts.skipStorage && !opts.storageBucket) {
    throw new Error("--storage-bucket or OPENBURNBAR_STORAGE_BUCKET is required unless --skip-storage is set");
  }
  return opts;
}

function digest(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function ownerUidFromPath(path) {
  const match = /^users\/([^/]+)\//.exec(path);
  return match?.[1] ?? "";
}

function fieldPaths(value, prefix = "") {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  const out = [];
  for (const [key, item] of Object.entries(value)) {
    const path = prefix ? `${prefix}.${key}` : key;
    out.push(path);
    out.push(...fieldPaths(item, path));
  }
  return out;
}

function collectStrings(value, prefix = "", out = []) {
  if (typeof value === "string") {
    out.push({ path: prefix, value });
    return out;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => collectStrings(item, `${prefix}[${index}]`, out));
    return out;
  }
  if (value && typeof value === "object") {
    for (const [key, item] of Object.entries(value)) {
      collectStrings(item, prefix ? `${prefix}.${key}` : key, out);
    }
  }
  return out;
}

function isSealedEnvelope(value) {
  return Boolean(
    value &&
    typeof value === "object" &&
    value.algorithm === "AES-256-GCM" &&
    typeof value.nonce === "string" &&
    typeof value.ciphertext === "string" &&
    typeof value.tag === "string"
  );
}

function addViolation(violations, docPath, fieldPath, reason) {
  violations.push({
    docPathHash: digest(docPath),
    collectionGroup: docPath.split("/").at(-2) ?? "unknown",
    fieldPath,
    reason,
  });
}

function inspectDocument(config, doc, violations) {
  const data = doc.data();
  const topLevelFields = Object.keys(data);
  const allFieldPaths = fieldPaths(data);
  const uid = ownerUidFromPath(doc.ref.path);

  for (const field of topLevelFields) {
    if (config.allowedTopLevel && !config.allowedTopLevel.has(field)) {
      addViolation(violations, doc.ref.path, field, "unexpected_top_level_field");
    }
    if (config.forbiddenTopLevel?.has(field)) {
      addViolation(violations, doc.ref.path, field, "forbidden_plaintext_field");
    }
  }
  for (const path of allFieldPaths) {
    const leaf = path.split(".").at(-1) ?? path;
    if (config.forbiddenAnyField?.has(leaf)) {
      addViolation(violations, doc.ref.path, path, "forbidden_plaintext_field");
    }
  }
  for (const field of config.sealedFields ?? []) {
    if (data[field] !== undefined && !isSealedEnvelope(data[field])) {
      addViolation(violations, doc.ref.path, field, "sealed_field_is_not_aes_gcm_envelope");
    }
  }
  if (config.storagePath) {
    const storagePath = data.storagePath;
    const bodyHash = data.bodyHash;
    const documentID = data.documentID;
    const match = typeof storagePath === "string" ? STORAGE_PATH_RE.exec(storagePath) : null;
    if (!match || match[1] !== uid || match[2] !== documentID || match[3] !== bodyHash) {
      addViolation(violations, doc.ref.path, "storagePath", "invalid_owner_scoped_encrypted_body_path");
    }
    if (typeof bodyHash !== "string" || !HEX_64.test(bodyHash)) {
      addViolation(violations, doc.ref.path, "bodyHash", "invalid_body_hash");
    }
  }
  for (const field of config.hashArrays ?? []) {
    const value = data[field];
    if (value === undefined) continue;
    if (!Array.isArray(value) || value.some((item) => typeof item !== "string" || !HASH_32.test(item))) {
      addViolation(violations, doc.ref.path, field, "invalid_opaque_hash_array");
    }
  }
  for (const { path, value } of collectStrings(data)) {
    for (const pattern of SENSITIVE_VALUE_PATTERNS) {
      if (pattern.re.test(value)) {
        addViolation(violations, doc.ref.path, path, `sensitive_value_pattern:${pattern.name}`);
      }
    }
  }
}

async function scanCollectionGroup(db, name, config, limit) {
  const query = db.collectionGroup(name);
  const [countSnap, sampleSnap] = await Promise.all([
    query.count().get(),
    query.limit(limit).get(),
  ]);
  const violations = [];
  for (const doc of sampleSnap.docs) inspectDocument(config, doc, violations);
  return {
    count: countSnap.data().count,
    sampled: sampleSnap.size,
    violations,
  };
}

async function scanStorage(bucketName, limit) {
  const bucket = getStorage().bucket(bucketName);
  const [files] = await bucket.getFiles({ prefix: "users/", maxResults: limit, autoPaginate: false });
  const violations = [];
  for (const file of files) {
    const name = file.name;
    if (!STORAGE_PATH_RE.test(name)) {
      violations.push({ objectNameHash: digest(name), reason: "unexpected_storage_object_path" });
    }
    const [metadata] = await file.getMetadata();
    if (metadata.contentType && metadata.contentType !== "application/octet-stream") {
      violations.push({ objectNameHash: digest(name), reason: "unexpected_storage_content_type" });
    }
    const size = Number(metadata.size ?? 0);
    if (!Number.isFinite(size) || size < 1) {
      violations.push({ objectNameHash: digest(name), reason: "empty_or_invalid_storage_object_size" });
    }
  }
  return {
    bucket: bucketName,
    sampledObjects: files.length,
    violations,
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (getApps().length === 0) initializeApp({ projectId: opts.project, storageBucket: opts.storageBucket || undefined });
  const db = getFirestore();

  const collectionEntries = await Promise.all(
    Object.entries(COLLECTIONS).map(async ([name, config]) => [name, await scanCollectionGroup(db, name, config, opts.collectionLimit)])
  );
  const collections = Object.fromEntries(collectionEntries);
  const firestoreViolationCount = Object.values(collections).reduce((sum, result) => sum + result.violations.length, 0);

  const storage = opts.skipStorage ? null : await scanStorage(opts.storageBucket, opts.storageLimit);
  const storageViolationCount = storage?.violations.length ?? 0;
  const ok = firestoreViolationCount === 0 && storageViolationCount === 0;

  console.log(JSON.stringify({
    ok,
    project: opts.project,
    limits: {
      collectionSampleLimit: opts.collectionLimit,
      storageSampleLimit: opts.skipStorage ? 0 : opts.storageLimit,
    },
    collections,
    storage,
    summary: {
      firestoreViolationCount,
      storageViolationCount,
    },
  }, null, 2));

  if (!ok) process.exit(1);
}

main().catch((error) => {
  console.error(JSON.stringify({
    ok: false,
    error: error.message,
  }, null, 2));
  process.exit(1);
});
