#!/usr/bin/env node
/**
 * Read-only production proof for the two-tier BurnBar Cloud launch.
 *
 * This script does not create purchases or mutate Firestore. It verifies the
 * server-written entitlement and optional Cloud Pro allowance/top-up evidence
 * after Apple, Stripe, or Google Play purchase flows have already completed.
 */

import process from "node:process";
import { createHash } from "node:crypto";
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

const PRODUCTS = Object.freeze({
  cloudMonthly: "com.openburnbar.pro.monthly",
  cloudAnnual: "com.openburnbar.pro.annual",
  cloudProMonthly: "com.openburnbar.proMax.v2.monthly",
  cloudProAnnual: "com.openburnbar.proMax.annual",
  legacyHostedQuota: "com.openburnbar.hostedQuotaSync.cloud.monthly",
  legacyCloudProBundle: "com.openburnbar.proMax.bundle.monthly",
  agentControlActions100: "com.openburnbar.agentControl.actions100",
  flooRelay50GB: "com.openburnbar.floo.relay50gb",
});

const TIER_CONFIG = Object.freeze({
  cloud: {
    entitlementID: "burnbar_pro",
    products: [PRODUCTS.cloudMonthly, PRODUCTS.cloudAnnual, PRODUCTS.legacyHostedQuota],
  },
  "cloud-pro": {
    entitlementID: "burnbar_pro_max",
    products: [
      PRODUCTS.cloudProMonthly,
      PRODUCTS.cloudProAnnual,
      PRODUCTS.legacyCloudProBundle,
    ],
  },
});

const CHANNELS = new Set(["apple", "stripe", "google_play", "any"]);
const TOP_UP_KINDS = new Set(["agent_control_actions_100", "floo_relay_50gb"]);

function usage() {
  return `Usage:
  OPENBURNBAR_PROOF_UID=<firebase_uid> npm --prefix functions run prove:paid-tier -- --tier <cloud|cloud-pro> [options]

Options:
  --uid <uid>                         Firebase Auth UID to inspect.
  --tier <cloud|cloud-pro>            Required paid tier to prove.
  --project <projectId>               Firebase project id. Defaults to FIREBASE_PROJECT, GCLOUD_PROJECT, GOOGLE_CLOUD_PROJECT, then burnbar.
  --channel <apple|stripe|google_play|any>
                                      Require channel-specific evidence. Defaults to any.
  --product-id <id>                   Require the entitlement productID to match.
  --transaction-id <id>               Require Apple transactionID to match.
  --original-transaction-id <id>      Require Apple originalTransactionID to match.
  --purchase-token-hash <sha256>      Require Google Play purchaseTokenHash to match.
  --external-subscription-id <id>     Require Stripe externalSubscriptionID to match.
  --environment <Production|Sandbox>  Require Apple entitlement environment.
  --allow-sandbox                     Permit Sandbox as well as the selected environment.
  --require-audit-event               Require a matching entitlement_events row.
  --require-allowance                 Require current-month Cloud Pro allowance ledger.
  --require-top-up <kind>             Require current-month top-up evidence. Kind: agent_control_actions_100 or floo_relay_50gb.
  --self-test                         Run offline assertion tests.

Examples:
  npm --prefix functions run prove:paid-tier -- --uid abc123 --tier cloud --channel apple --original-transaction-id 2000000123456789 --require-audit-event
  npm --prefix functions run prove:paid-tier -- --uid abc123 --tier cloud-pro --channel google_play --purchase-token-hash HASH --require-allowance --require-top-up agent_control_actions_100
`;
}

function parseArgs(argv) {
  const out = {
    uid: process.env.OPENBURNBAR_PROOF_UID || "",
    tier: process.env.OPENBURNBAR_PROOF_TIER || "",
    project:
      process.env.FIREBASE_PROJECT ||
      process.env.GCLOUD_PROJECT ||
      process.env.GOOGLE_CLOUD_PROJECT ||
      "burnbar",
    channel: process.env.OPENBURNBAR_PROOF_CHANNEL || "any",
    productID: process.env.OPENBURNBAR_PROOF_PRODUCT_ID || "",
    transactionID: process.env.OPENBURNBAR_PROOF_TRANSACTION_ID || "",
    originalTransactionID: process.env.OPENBURNBAR_PROOF_ORIGINAL_TRANSACTION_ID || "",
    purchaseTokenHash: process.env.OPENBURNBAR_PROOF_PURCHASE_TOKEN_HASH || "",
    externalSubscriptionID: process.env.OPENBURNBAR_PROOF_EXTERNAL_SUBSCRIPTION_ID || "",
    environment: process.env.OPENBURNBAR_PROOF_ENVIRONMENT || "",
    allowSandbox: false,
    requireAuditEvent: false,
    requireAllowance: false,
    requireTopUp: "",
    selfTest: false,
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
      case "--tier":
        out.tier = next();
        break;
      case "--project":
        out.project = next();
        break;
      case "--channel":
        out.channel = next();
        break;
      case "--product-id":
        out.productID = next();
        break;
      case "--transaction-id":
        out.transactionID = next();
        break;
      case "--original-transaction-id":
        out.originalTransactionID = next();
        break;
      case "--purchase-token-hash":
        out.purchaseTokenHash = next();
        break;
      case "--external-subscription-id":
        out.externalSubscriptionID = next();
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
      case "--require-allowance":
        out.requireAllowance = true;
        break;
      case "--require-top-up":
        out.requireTopUp = next();
        break;
      case "--self-test":
        out.selfTest = true;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  if (out.selfTest) return out;
  if (!out.uid) throw new Error("OPENBURNBAR_PROOF_UID or --uid is required");
  if (!TIER_CONFIG[out.tier]) throw new Error("--tier must be cloud or cloud-pro");
  if (!CHANNELS.has(out.channel)) throw new Error("--channel must be apple, stripe, google_play, or any");
  if (out.requireTopUp && !TOP_UP_KINDS.has(out.requireTopUp)) {
    throw new Error("--require-top-up must be agent_control_actions_100 or floo_relay_50gb");
  }
  if ((out.requireAllowance || out.requireTopUp) && out.tier !== "cloud-pro") {
    throw new Error("--require-allowance and --require-top-up are Cloud Pro proof options");
  }
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
  if (typeof value === "number") return new Date(value);
  return null;
}

function requireString(doc, field) {
  const value = doc[field];
  if (typeof value !== "string" || value.trim() === "") {
    fail(`entitlement.${field} is missing or empty`);
  }
  return value;
}

function fieldString(doc, field) {
  const value = doc[field];
  return typeof value === "string" ? value : "";
}

function sourceMatchesChannel(data, channel) {
  const source = fieldString(data, "source").toLowerCase();
  const platform = fieldString(data, "platform").toLowerCase();
  switch (channel) {
    case "apple":
      return source.includes("apple") || platform === "ios" || platform === "macos";
    case "stripe":
      return source.includes("stripe") || platform === "stripe" || platform === "web";
    case "google_play":
      return source.includes("google") || platform === "android";
    default:
      return true;
  }
}

function assertPaidEntitlement(data, opts) {
  const tier = TIER_CONFIG[opts.tier];
  if (data.id !== tier.entitlementID) fail("entitlement.id mismatch", data.id);
  if (data.active !== true) fail("entitlement is not active", data.active);
  const productID = requireString(data, "productID");
  if (!tier.products.includes(productID)) {
    fail("entitlement productID is not valid for tier", { productID, tier: opts.tier });
  }
  if (opts.productID && productID !== opts.productID) {
    fail("entitlement productID mismatch", { got: productID, want: opts.productID });
  }
  if (!sourceMatchesChannel(data, opts.channel)) {
    fail("entitlement source/platform does not match required channel", {
      source: data.source,
      platform: data.platform,
      channel: opts.channel,
    });
  }

  const expiry = asDate(data.expireAt) || asDate(data.expiresAt);
  if (!expiry) fail("entitlement expiry is missing or unreadable");
  if (expiry.getTime() <= Date.now()) fail("entitlement is expired", expiry.toISOString());

  if (typeof data.schemaVersion !== "number") fail("entitlement schemaVersion is missing");
  if (typeof data.verificationVersion !== "number") fail("entitlement verificationVersion is missing");
  requireString(data, "lastVerifiedAt");

  const result = {
    productID,
    source: data.source ?? null,
    platform: data.platform ?? null,
    expiresAt: expiry.toISOString(),
  };

  if (opts.channel === "apple" || opts.transactionID || opts.originalTransactionID || opts.environment) {
    const transactionID = requireString(data, "transactionID");
    const originalTransactionID = requireString(data, "originalTransactionID");
    if (opts.transactionID && transactionID !== opts.transactionID) {
      fail("transactionID mismatch", { got: redactID(transactionID), want: redactID(opts.transactionID) });
    }
    if (opts.originalTransactionID && originalTransactionID !== opts.originalTransactionID) {
      fail("originalTransactionID mismatch", {
        got: redactID(originalTransactionID),
        want: redactID(opts.originalTransactionID),
      });
    }
    const allowedEnvironments = new Set(opts.environment ? [opts.environment] : ["Production"]);
    if (opts.allowSandbox) allowedEnvironments.add("Sandbox");
    if (!allowedEnvironments.has(data.environment)) {
      fail("entitlement environment mismatch", {
        got: data.environment,
        allowed: [...allowedEnvironments],
      });
    }
    result.transactionIDHash = digest(transactionID);
    result.originalTransactionIDHash = digest(originalTransactionID);
    result.environment = data.environment;
  }

  if (opts.channel === "google_play" || opts.purchaseTokenHash) {
    const purchaseTokenHash = requireString(data, "purchaseTokenHash");
    if (opts.purchaseTokenHash && purchaseTokenHash !== opts.purchaseTokenHash) {
      fail("purchaseTokenHash mismatch", {
        got: redactID(purchaseTokenHash),
        want: redactID(opts.purchaseTokenHash),
      });
    }
    result.purchaseTokenHash = purchaseTokenHash;
  }

  if (opts.channel === "stripe" || opts.externalSubscriptionID) {
    const externalSubscriptionID = requireString(data, "externalSubscriptionID");
    if (opts.externalSubscriptionID && externalSubscriptionID !== opts.externalSubscriptionID) {
      fail("externalSubscriptionID mismatch", {
        got: redactID(externalSubscriptionID),
        want: redactID(opts.externalSubscriptionID),
      });
    }
    result.externalSubscriptionIDHash = digest(externalSubscriptionID);
    result.externalCustomerIDHash = data.externalCustomerID ? digest(data.externalCustomerID) : null;
  }

  return result;
}

async function firstMatching(collectionRef, predicate, limit = 100) {
  const snap = await collectionRef.limit(limit).get();
  return snap.docs.find((doc) => predicate(doc.data(), doc)) ?? null;
}

async function proveAuditEvent(db, uid, entitlement, opts) {
  const events = db.collection(`users/${uid}/entitlement_events`);
  const doc = await firstMatching(events, (data) => {
    const product = data.productId ?? data.productID;
    if (product !== entitlement.productID) return false;
    if (data.entitlementID && data.entitlementID !== TIER_CONFIG[opts.tier].entitlementID) return false;
    if (opts.transactionID && data.transactionId !== opts.transactionID) return false;
    if (opts.originalTransactionID && data.originalTransactionId !== opts.originalTransactionID) return false;
    return true;
  });
  if (!doc) fail("no entitlement_events audit row matched the paid tier entitlement");
  return doc.ref.path;
}

function allowanceDocPath(uid, monthKey) {
  return `users/${uid}/billing/allowances/months/${monthKey}`;
}

function monthKeyForDate(date) {
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

function assertAllowance(data) {
  const expected = {
    includedHostedActions: 500,
    includedRelayGB: 50,
    monthlyHostedActionCap: 2000,
    monthlyRelayGBCap: 300,
  };
  for (const [field, value] of Object.entries(expected)) {
    if (data[field] !== value) fail(`allowance.${field} mismatch`, { got: data[field], want: value });
  }
  if (typeof data.schemaVersion !== "number") fail("allowance schemaVersion is missing");
  return expected;
}

async function proveAllowance(db, uid) {
  const monthKey = monthKeyForDate(new Date());
  const ref = db.doc(allowanceDocPath(uid, monthKey));
  const snap = await ref.get();
  if (!snap.exists) fail("Cloud Pro allowance document does not exist", redactPath(ref.path));
  return { monthKey, path: ref.path, config: assertAllowance(snap.data()) };
}

async function proveTopUp(db, allowancePath, kind) {
  const doc = await firstMatching(db.doc(allowancePath).collection("topups"), (data) => data.kind === kind);
  if (!doc) fail("no Cloud Pro top-up evidence found for current month", { kind });
  const data = doc.data();
  if (typeof data.units !== "number" || data.units <= 0) fail("top-up units are missing or invalid", data.units);
  return {
    path: doc.ref.path,
    kind: data.kind,
    units: data.units,
    source: data.source ?? null,
  };
}

function runSelfTest() {
  const future = new Date(Date.now() + 86_400_000).toISOString();
  const cloud = assertPaidEntitlement(
    {
      id: "burnbar_pro",
      active: true,
      productID: PRODUCTS.cloudMonthly,
      source: "apple_jws_verified",
      platform: "ios",
      transactionID: "tx-cloud",
      originalTransactionID: "otx-cloud",
      environment: "Production",
      expiresAt: future,
      lastVerifiedAt: new Date().toISOString(),
      verificationVersion: 2,
      schemaVersion: 2,
    },
    { tier: "cloud", channel: "apple", environment: "Production", allowSandbox: false },
  );
  if (cloud.productID !== PRODUCTS.cloudMonthly || !cloud.transactionIDHash) fail("self-test cloud proof failed");

  const cloudPro = assertPaidEntitlement(
    {
      id: "burnbar_pro_max",
      active: true,
      productID: PRODUCTS.cloudProMonthly,
      source: "google_play_verified",
      platform: "android",
      purchaseTokenHash: "a".repeat(64),
      expiresAt: future,
      lastVerifiedAt: new Date().toISOString(),
      verificationVersion: 1,
      schemaVersion: 1,
    },
    { tier: "cloud-pro", channel: "google_play", purchaseTokenHash: "a".repeat(64) },
  );
  if (cloudPro.productID !== PRODUCTS.cloudProMonthly || !cloudPro.purchaseTokenHash) {
    fail("self-test cloud-pro proof failed");
  }

  assertAllowance({
    includedHostedActions: 500,
    includedRelayGB: 50,
    monthlyHostedActionCap: 2000,
    monthlyRelayGBCap: 300,
    schemaVersion: 1,
  });

  console.log("paid-tier-proof: offline assertions passed");
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.selfTest) {
    runSelfTest();
    return;
  }

  if (getApps().length === 0) initializeApp({ projectId: opts.project });
  const db = getFirestore();
  const entitlementID = TIER_CONFIG[opts.tier].entitlementID;
  const entitlementRef = db.doc(`users/${opts.uid}/entitlements/${entitlementID}`);
  const entitlementSnap = await entitlementRef.get();
  if (!entitlementSnap.exists) {
    fail("paid tier entitlement document does not exist", redactPath(entitlementRef.path));
  }

  const entitlement = assertPaidEntitlement(entitlementSnap.data(), opts);
  const result = {
    ok: true,
    project: opts.project,
    uidHash: digest(opts.uid),
    tier: opts.tier,
    channel: opts.channel,
    entitlementPath: redactPath(entitlementRef.path),
    entitlement,
    auditEventPath: null,
    allowanceEvidence: null,
    topUpEvidence: null,
  };

  if (opts.requireAuditEvent) {
    result.auditEventPath = redactPath(await proveAuditEvent(db, opts.uid, entitlement, opts));
  }
  if (opts.requireAllowance || opts.requireTopUp) {
    const allowance = await proveAllowance(db, opts.uid);
    result.allowanceEvidence = {
      monthKey: allowance.monthKey,
      path: redactPath(allowance.path),
      config: allowance.config,
    };
    if (opts.requireTopUp) {
      const topUp = await proveTopUp(db, allowance.path, opts.requireTopUp);
      result.topUpEvidence = {
        ...topUp,
        path: redactPath(topUp.path),
      };
    }
  }

  console.log(`# proof-subject uid_sha256_16=${shortDigest(opts.uid)}`);
  console.log(JSON.stringify(result, null, 2));
}

main().catch((err) => {
  console.error(JSON.stringify({ ok: false, error: err.message, details: err.details }, null, 2));
  process.exitCode = 1;
});

