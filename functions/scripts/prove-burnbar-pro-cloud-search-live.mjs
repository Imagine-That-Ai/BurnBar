#!/usr/bin/env node
/**
 * Read-only production proof for BurnBar Pro encrypted cloud search.
 *
 * This does not create purchases or mutate data. It verifies that a paid user
 * has encrypted session-log search artifacts in Firestore and that the hosted
 * index contains semantic posting edges without plaintext fields.
 */

import process from "node:process";
import { createHash } from "node:crypto";
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const PRO_ENTITLEMENT = "burnbar_pro";
const HOSTED_ENTITLEMENT = "hosted_quota_sync";
const PLAINTEXT_FIELDS = ["title", "snippet", "body", "text", "payloadCiphertext", "data"];

function usage() {
  return `Usage:
  OPENBURNBAR_PROOF_UID=<firebase_uid> npm --prefix functions run prove:cloud-search -- [options]

Options:
  --uid <uid>            Firebase Auth UID to inspect.
  --project <projectId>  Firebase project id. Defaults to FIREBASE_PROJECT, GCLOUD_PROJECT, GOOGLE_CLOUD_PROJECT, then burnbar.
  --min-docs <n>         Minimum encrypted search documents. Default: 1.
  --min-chunks <n>       Minimum encrypted search chunks. Default: 1.
  --min-postings <n>     Minimum semantic posting edges. Default: 1.
`;
}

function parseArgs(argv) {
  const out = {
    uid: process.env.OPENBURNBAR_PROOF_UID || "",
    project: process.env.FIREBASE_PROJECT ||
      process.env.GCLOUD_PROJECT ||
      process.env.GOOGLE_CLOUD_PROJECT ||
      "burnbar",
    minDocs: 1,
    minChunks: 1,
    minPostings: 1,
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
      case "--uid":
        out.uid = next();
        break;
      case "--project":
        out.project = next();
        break;
      case "--min-docs":
        out.minDocs = Number(next());
        break;
      case "--min-chunks":
        out.minChunks = Number(next());
        break;
      case "--min-postings":
        out.minPostings = Number(next());
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }
  if (!out.uid) throw new Error("OPENBURNBAR_PROOF_UID or --uid is required");
  return out;
}

function digest(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

function asDate(value) {
  if (!value) return null;
  if (value instanceof Timestamp) return value.toDate();
  if (typeof value.toDate === "function") return value.toDate();
  if (typeof value === "string") {
    const time = Date.parse(value);
    return Number.isFinite(time) ? new Date(time) : null;
  }
  return null;
}

function fail(message, details = undefined) {
  const error = new Error(message);
  error.details = details;
  throw error;
}

function activeEntitlement(data) {
  if (!data || data.active !== true) return false;
  const expiry = asDate(data.expireAt) || asDate(data.expiresAt);
  return Boolean(expiry && expiry.getTime() > Date.now());
}

function assertNoPlaintextFields(data, label) {
  for (const field of PLAINTEXT_FIELDS) {
    if (Object.prototype.hasOwnProperty.call(data, field)) {
      fail(`${label} contains forbidden plaintext-looking field`, field);
    }
  }
}

function assertSealedText(value, label) {
  if (!value || typeof value !== "object" || value.algorithm !== "AES-256-GCM") {
    fail(`${label} is not an AES-GCM sealed text envelope`);
  }
  for (const field of ["nonce", "ciphertext", "tag"]) {
    if (typeof value[field] !== "string" || value[field].length === 0) {
      fail(`${label}.${field} is missing`);
    }
  }
}

function assertHashList(value, label) {
  if (!Array.isArray(value) || value.length === 0 || value.length > 250) {
    fail(`${label} must be a non-empty bounded hash list`);
  }
  for (const hash of value) {
    if (typeof hash !== "string" || !/^[a-f0-9]{32}$/.test(hash)) {
      fail(`${label} contains invalid hash`, hash);
    }
  }
}

async function count(collectionRef) {
  const aggregate = await collectionRef.count().get();
  return aggregate.data().count;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (getApps().length === 0) initializeApp({ projectId: opts.project });
  const db = getFirestore();

  const [proSnap, hostedSnap] = await Promise.all([
    db.doc(`users/${opts.uid}/entitlements/${PRO_ENTITLEMENT}`).get(),
    db.doc(`users/${opts.uid}/entitlements/${HOSTED_ENTITLEMENT}`).get(),
  ]);
  if (!activeEntitlement(proSnap.data()) && !activeEntitlement(hostedSnap.data())) {
    fail("No active BurnBar Pro or hosted cloud entitlement found.");
  }

  const docsRef = db.collection(`users/${opts.uid}/cloud_search_documents`);
  const chunksRef = db.collection(`users/${opts.uid}/cloud_search_chunks`);
  const postingsRef = db.collection(`users/${opts.uid}/cloud_search_postings`);
  const wrappersRef = db.collection(`users/${opts.uid}/cloud_vault_key_wrappers`);

  const [documentCount, chunkCount, semanticPostingCount, wrapperCount] = await Promise.all([
    count(docsRef),
    count(chunksRef),
    count(postingsRef.where("kind", "==", "semantic")),
    count(wrappersRef.where("status", "==", "active")),
  ]);
  if (documentCount < opts.minDocs) fail("Not enough encrypted search documents", { documentCount, min: opts.minDocs });
  if (chunkCount < opts.minChunks) fail("Not enough encrypted search chunks", { chunkCount, min: opts.minChunks });
  if (semanticPostingCount < opts.minPostings) {
    fail("Not enough semantic posting edges", { semanticPostingCount, min: opts.minPostings });
  }
  if (wrapperCount < 1) fail("No active cloud vault key wrapper found.");

  const [sampleDocSnap, sampleChunkSnap, samplePostingSnap] = await Promise.all([
    docsRef.limit(1).get(),
    chunksRef.limit(1).get(),
    postingsRef.where("kind", "==", "semantic").limit(1).get(),
  ]);
  const sampleDoc = sampleDocSnap.docs[0]?.data();
  const sampleChunk = sampleChunkSnap.docs[0]?.data();
  const samplePosting = samplePostingSnap.docs[0]?.data();
  if (!sampleDoc || !sampleChunk || !samplePosting) fail("Sample encrypted search artifacts are missing.");

  assertNoPlaintextFields(sampleDoc, "cloud_search_documents sample");
  assertNoPlaintextFields(sampleChunk, "cloud_search_chunks sample");
  assertNoPlaintextFields(samplePosting, "cloud_search_postings sample");
  assertSealedText(sampleDoc.sealedTitle, "sealedTitle");
  assertSealedText(sampleDoc.sealedBodyPreview, "sealedBodyPreview");
  assertSealedText(sampleChunk.sealedSnippet, "sealedSnippet");
  assertHashList(sampleChunk.tokenHashes, "tokenHashes");
  assertHashList(sampleChunk.semanticHashes, "semanticHashes");
  if (samplePosting.kind !== "semantic" || !/^[a-f0-9]{32}$/.test(samplePosting.hash)) {
    fail("semantic posting edge is malformed");
  }

  console.log(JSON.stringify({
    ok: true,
    project: opts.project,
    uidHash: digest(opts.uid),
    counts: {
      encryptedSearchDocuments: documentCount,
      encryptedSearchChunks: chunkCount,
      semanticPostingEdges: semanticPostingCount,
      activeVaultWrappers: wrapperCount,
    },
    sample: {
      documentID: sampleDoc.documentID,
      chunkID: sampleChunk.chunkID,
      postingKey: samplePosting.postingKey,
      indexVersion: sampleChunk.indexVersion,
      semanticHashVersion: sampleChunk.semanticHashVersion,
    },
  }, null, 2));
}

main().catch((error) => {
  console.error(JSON.stringify({
    ok: false,
    error: error.message,
    details: error.details,
  }, null, 2));
  process.exit(1);
});
