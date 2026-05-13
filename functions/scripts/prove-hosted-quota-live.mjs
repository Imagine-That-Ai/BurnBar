#!/usr/bin/env node
/**
 * Read-only production proof for the paid Hosted Quota Sync path.
 *
 * This script is intentionally post-purchase evidence, not a purchase driver:
 * App Store purchases must still happen through StoreKit in the iOS/iPadOS app.
 * After a live or sandbox purchase, run this command with the Firebase UID to
 * prove that Apple verification produced the Firestore entitlement state that
 * gates paid cloud backup and hosted quota refresh.
 */

import process from "node:process";
import { createHash } from "node:crypto";
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const PRODUCT_ID = "com.openburnbar.hostedQuotaSync.cloud.monthly";
const ENTITLEMENT_PATH = "entitlements/hosted_quota_sync";

function usage() {
  return `Usage:
  OPENBURNBAR_PROOF_UID=<firebase_uid> npm --prefix functions run prove:hosted-quota -- [options]

Options:
  --uid <uid>                         Firebase Auth UID to inspect.
  --project <projectId>               Firebase project id. Defaults to FIREBASE_PROJECT, GCLOUD_PROJECT, GOOGLE_CLOUD_PROJECT, then burnbar.
  --transaction-id <id>               Require the entitlement transactionID to match.
  --original-transaction-id <id>      Require the entitlement originalTransactionID to match.
  --environment <Production|Sandbox>  Require the Apple environment. Defaults to Production.
  --allow-sandbox                     Permit Sandbox as well as Production.
  --require-audit-event               Require a matching entitlement_events row. Default: true.
  --require-backup                    Require paid Firestore backup content evidence.
  --require-hosted-quota              Require a server_private provider account and quota snapshot.

Examples:
  OPENBURNBAR_PROOF_UID=abc123 npm --prefix functions run prove:hosted-quota
  npm --prefix functions run prove:hosted-quota -- --uid abc123 --original-transaction-id 2000000123456789 --require-backup
`;
}

function parseArgs(argv) {
  const out = {
    uid: process.env.OPENBURNBAR_PROOF_UID || "",
    project: process.env.FIREBASE_PROJECT ||
      process.env.GCLOUD_PROJECT ||
      process.env.GOOGLE_CLOUD_PROJECT ||
      "burnbar",
    transactionID: process.env.OPENBURNBAR_PROOF_TRANSACTION_ID || "",
    originalTransactionID:
      process.env.OPENBURNBAR_PROOF_ORIGINAL_TRANSACTION_ID || "",
    environment: process.env.OPENBURNBAR_PROOF_ENVIRONMENT || "Production",
    allowSandbox: false,
    requireAuditEvent: true,
    requireBackup: false,
    requireHostedQuota: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      const value = argv[i + 1];
      if (!value || value.startsWith("--")) {
        throw new Error(`${arg} requires a value`);
      }
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
      case "--transaction-id":
        out.transactionID = next();
        break;
      case "--original-transaction-id":
        out.originalTransactionID = next();
        break;
      case "--environment":
        out.environment = next();
        break;
      case "--allow-sandbox":
        out.allowSandbox = true;
        break;
      case "--require-audit-event":
        out.requireAuditEvent = true;
        break;
      case "--skip-audit-event":
        out.requireAuditEvent = false;
        break;
      case "--require-backup":
        out.requireBackup = true;
        break;
      case "--require-hosted-quota":
        out.requireHostedQuota = true;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  if (!out.uid) throw new Error("OPENBURNBAR_PROOF_UID or --uid is required");
  if (!out.project) throw new Error("Firebase project id is required");
  return out;
}

function fail(message, details = undefined) {
  const err = new Error(message);
  err.details = details;
  throw err;
}

function digest(value) {
  return createHash("sha256").update(String(value)).digest("hex");
}

function shortDigest(value) {
  return digest(value).slice(0, 16);
}

function redactPath(path) {
  return String(path).replace(/^users\/[^/]+\//, "users/<uid>/");
}

function redactID(value) {
  return typeof value === "string" && value
    ? { sha256: digest(value), prefix: value.slice(0, 4), suffix: value.slice(-4) }
    : null;
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

function requireString(doc, field) {
  const value = doc[field];
  if (typeof value !== "string" || value.trim() === "") {
    fail(`entitlement.${field} is missing or empty`);
  }
  return value;
}

function assertEntitlement(data, opts) {
  if (data.id !== "hosted_quota_sync") fail("entitlement.id mismatch", data.id);
  if (data.active !== true) fail("entitlement is not active", data.active);
  if (data.productID !== PRODUCT_ID) {
    fail("entitlement productID mismatch", data.productID);
  }

  const allowedEnvironments = new Set([opts.environment]);
  if (opts.allowSandbox) allowedEnvironments.add("Sandbox");
  if (!allowedEnvironments.has(data.environment)) {
    fail("entitlement environment mismatch", {
      got: data.environment,
      allowed: [...allowedEnvironments],
    });
  }

  const transactionID = requireString(data, "transactionID");
  const originalTransactionID = requireString(data, "originalTransactionID");
  requireString(data, "signedTransactionHash");
  requireString(data, "lastVerifiedAt");

  if (!/^[0-9a-f]{64}$/.test(data.signedTransactionHash)) {
    fail("signedTransactionHash is not a SHA-256 hex digest");
  }
  if (opts.transactionID && data.transactionID !== opts.transactionID) {
    fail("transactionID mismatch", {
      got: redactID(data.transactionID),
      want: redactID(opts.transactionID),
    });
  }
  if (
    opts.originalTransactionID &&
    data.originalTransactionID !== opts.originalTransactionID
  ) {
    fail("originalTransactionID mismatch", {
      got: redactID(data.originalTransactionID),
      want: redactID(opts.originalTransactionID),
    });
  }

  const expiry = asDate(data.expireAt) || asDate(data.expiresAt);
  if (!expiry) fail("entitlement expiry is missing or unreadable");
  if (expiry.getTime() <= Date.now()) {
    fail("entitlement is expired", expiry.toISOString());
  }

  if (typeof data.schemaVersion !== "number") {
    fail("entitlement schemaVersion is missing");
  }
  if (typeof data.verificationVersion !== "number") {
    fail("entitlement verificationVersion is missing");
  }

  return {
    transactionID,
    originalTransactionID,
    transactionIDHash: digest(transactionID),
    originalTransactionIDHash: digest(originalTransactionID),
    expiresAt: expiry.toISOString(),
  };
}

async function latestQuerySnap(query) {
  const snap = await query.limit(1).get();
  return snap.empty ? null : snap.docs[0];
}

async function firstMatching(collectionRef, predicate, limit = 50) {
  const snap = await collectionRef.limit(limit).get();
  return snap.docs.find((doc) => predicate(doc.data(), doc)) ?? null;
}

async function proveAuditEvent(db, uid, entitlement) {
  const events = db.collection(`users/${uid}/entitlement_events`);
  const byTx = await firstMatching(
    events.where("transactionId", "==", entitlement.transactionID),
    (data) => data.productId === PRODUCT_ID
  );
  if (byTx) return byTx;

  const byOriginal = await firstMatching(
    events.where("originalTransactionId", "==", entitlement.originalTransactionID),
    (data) => data.productId === PRODUCT_ID
  );
  if (byOriginal) return byOriginal;

  fail("no entitlement_events audit row matched the entitlement transaction");
}

async function proveBackupContent(db, uid) {
  const checks = [
    {
      name: "chat_threads contentIncluded=true",
      query: db
        .collection(`users/${uid}/chat_threads`)
        .where("contentIncluded", "==", true),
    },
    {
      name: "conversations",
      query: db.collection(`users/${uid}/conversations`),
    },
    {
      name: "session_logs",
      query: db.collection(`users/${uid}/session_logs`),
    },
  ];

  const evidence = [];
  for (const check of checks) {
    const doc = await latestQuerySnap(check.query);
    if (doc) evidence.push({ name: check.name, path: doc.ref.path });
  }

  if (evidence.length === 0) {
    fail("no paid Firestore backup content was found for this uid");
  }
  return evidence;
}

async function proveHostedQuota(db, uid) {
  const account = await firstMatching(
    db.collection(`users/${uid}/provider_accounts`).where("providerID", "==", "codex"),
    (data) => data.storageScope === "server_private"
  );
  if (!account) {
    fail("no server_private Codex provider account found");
  }

  const snapshot = await firstMatching(
    db.collection(`users/${uid}/quota_snapshots`).where("providerID", "==", "codex"),
    (data) =>
      data.accountID === account.id &&
      data.accountStorageScope === "server_private"
  );
  if (!snapshot) {
    fail("no hosted Codex quota snapshot found for the server_private account", {
      accountPath: redactPath(account.ref.path),
    });
  }

  return {
    accountPath: account.ref.path,
    snapshotPath: snapshot.ref.path,
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (getApps().length === 0) initializeApp({ projectId: opts.project });
  const db = getFirestore();

  const entitlementRef = db.doc(`users/${opts.uid}/${ENTITLEMENT_PATH}`);
  const entitlementSnap = await entitlementRef.get();
  if (!entitlementSnap.exists) {
    fail(
      "hosted_quota_sync entitlement document does not exist",
      redactPath(entitlementRef.path)
    );
  }

  const entitlement = assertEntitlement(entitlementSnap.data(), opts);
  const result = {
    ok: true,
    project: opts.project,
    uidHash: digest(opts.uid),
    entitlementPath: redactPath(entitlementRef.path),
    entitlement: {
      transactionIDHash: entitlement.transactionIDHash,
      originalTransactionIDHash: entitlement.originalTransactionIDHash,
      expiresAt: entitlement.expiresAt,
    },
    auditEventPath: null,
    backupEvidence: [],
    hostedQuotaEvidence: null,
  };

  if (opts.requireAuditEvent) {
    const audit = await proveAuditEvent(db, opts.uid, entitlement);
    result.auditEventPath = redactPath(audit.ref.path);
  }
  if (opts.requireBackup) {
    result.backupEvidence = (await proveBackupContent(db, opts.uid)).map((item) => ({
      name: item.name,
      path: redactPath(item.path),
    }));
  }
  if (opts.requireHostedQuota) {
    const evidence = await proveHostedQuota(db, opts.uid);
    result.hostedQuotaEvidence = {
      accountPath: redactPath(evidence.accountPath),
      snapshotPath: redactPath(evidence.snapshotPath),
    };
  }

  console.log(`# proof-subject uid_sha256_16=${shortDigest(opts.uid)}`);
  console.log(JSON.stringify(result, null, 2));
}

main().catch((err) => {
  console.error(
    JSON.stringify(
      {
        ok: false,
        error: err.message,
        details: err.details,
      },
      null,
      2
    )
  );
  process.exitCode = 1;
});
