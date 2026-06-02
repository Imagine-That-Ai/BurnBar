#!/usr/bin/env node
/**
 * Read-only production proof for BurnBar Cloud and BurnBar Cloud Pro.
 *
 * The purchase itself must happen through Stripe Checkout, StoreKit, or Google
 * Play. This command proves the provider verifier produced the Firestore
 * entitlement state that unlocks the paid tier.
 */

import process from "node:process";
import { createHash } from "node:crypto";
import { initializeApp, getApps } from "firebase-admin/app";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { fileURLToPath } from "node:url";

export const PRODUCTS = Object.freeze({
  cloud: {
    entitlementID: "burnbar_pro",
    products: {
      apple: ["com.openburnbar.pro.monthly", "com.openburnbar.pro.annual"],
      stripe: ["com.openburnbar.pro.monthly", "com.openburnbar.pro.annual"],
      google_play: ["com.openburnbar.pro.monthly", "com.openburnbar.pro.annual"],
    },
    requiredFeatures: ["hostedQuota", "hostedLLM", "encryptedSessionLogBackup", "cloudConversationSearch"],
    forbiddenFeatures: ["floo", "agentControl"],
  },
  "cloud-pro": {
    entitlementID: "burnbar_pro_max",
    products: {
      apple: [
        "com.openburnbar.proMax.v2.monthly",
        "com.openburnbar.proMax.annual",
        "com.openburnbar.proMax.bundle.monthly",
      ],
      stripe: ["com.openburnbar.proMax.v2.monthly", "com.openburnbar.proMax.annual"],
      google_play: ["com.openburnbar.promax.v2.monthly", "com.openburnbar.promax.annual"],
    },
    requiredFeatures: [
      "hostedQuota",
      "hostedLLM",
      "encryptedSessionLogBackup",
      "cloudConversationSearch",
      "floo",
      "agentControl",
    ],
    forbiddenFeatures: [],
  },
  "legacy-hosted-quota": {
    entitlementID: "hosted_quota_sync",
    products: {
      apple: ["com.openburnbar.hostedQuotaSync.cloud.monthly"],
      stripe: [],
      google_play: [],
    },
    requiredFeatures: [],
    forbiddenFeatures: ["floo", "agentControl"],
  },
});

export const CHANNEL_SOURCES = Object.freeze({
  apple: new Set(["apple_jws_verified", "client_callable", "apple_s2s", "scheduled_reconcile"]),
  stripe: new Set(["stripe_webhook_verified", "stripe_checkout"]),
  google_play: new Set(["google_play_verified"]),
});

export const CHANNELS = new Set(Object.keys(CHANNEL_SOURCES));

function usage() {
  return `Usage:
  OPENBURNBAR_PROOF_UID=<firebase_uid> npm --prefix functions run prove:paid-tier -- --tier cloud --channel apple [options]

Options:
  --uid <uid>                         Firebase Auth UID to inspect.
  --tier <cloud|cloud-pro|legacy-hosted-quota>
  --channel <apple|stripe|google_play>
  --project <projectId>               Defaults to FIREBASE_PROJECT, GCLOUD_PROJECT, GOOGLE_CLOUD_PROJECT, then burnbar.
  --product-id <id>                   Require the entitlement productID/sourceProductID to match.
  --external-subscription-id <id>     Require externalSubscriptionID to match.
  --purchase-token-hash <hash>        Require Google Play purchaseTokenHash to match.
  --google-play-audit-record          Prove Google Play via billing audit record instead of canonical entitlement.
  --environment <Production|Sandbox>  Required provider environment to prove.
  --allow-sandbox                     Permit Sandbox as well as Production.
  --require-allowance-ledger          Require current-month Cloud Pro allowance doc. Default for --tier cloud-pro.
  --skip-allowance-ledger             Do not require current-month allowance evidence.
  --self-test                         Validate proof command configuration and exit.

Examples:
  npm --prefix functions run prove:paid-tier -- --uid abc123 --tier cloud --channel apple --environment Production
  npm --prefix functions run prove:paid-tier -- --uid abc123 --tier cloud-pro --channel stripe --environment Production --external-subscription-id sub_123
`;
}

export function parseArgs(argv) {
  const out = {
    uid: process.env.OPENBURNBAR_PROOF_UID || "",
    tier: process.env.OPENBURNBAR_PROOF_TIER || "cloud",
    channel: process.env.OPENBURNBAR_PROOF_CHANNEL || "apple",
    project:
      process.env.FIREBASE_PROJECT || process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || "burnbar",
    productID: process.env.OPENBURNBAR_PROOF_PRODUCT_ID || "",
    externalSubscriptionID: process.env.OPENBURNBAR_PROOF_EXTERNAL_SUBSCRIPTION_ID || "",
    purchaseTokenHash: process.env.OPENBURNBAR_PROOF_PURCHASE_TOKEN_HASH || "",
    googlePlayAuditRecord: process.env.OPENBURNBAR_PROOF_GOOGLE_PLAY_AUDIT_RECORD === "1",
    environment: process.env.OPENBURNBAR_PROOF_ENVIRONMENT || "",
    allowSandbox: false,
    requireAllowanceLedger: null,
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
      case "--self-test":
        out.selfTest = true;
        break;
      case "--uid":
        out.uid = next();
        break;
      case "--tier":
        out.tier = next();
        break;
      case "--channel":
        out.channel = next();
        break;
      case "--project":
        out.project = next();
        break;
      case "--product-id":
        out.productID = next();
        break;
      case "--external-subscription-id":
        out.externalSubscriptionID = next();
        break;
      case "--purchase-token-hash":
        out.purchaseTokenHash = next();
        break;
      case "--google-play-audit-record":
        out.googlePlayAuditRecord = true;
        break;
      case "--environment":
        out.environment = next();
        break;
      case "--allow-sandbox":
        out.allowSandbox = true;
        break;
      case "--require-allowance-ledger":
        out.requireAllowanceLedger = true;
        break;
      case "--skip-allowance-ledger":
        out.requireAllowanceLedger = false;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  if (!PRODUCTS[out.tier]) throw new Error(`Unsupported tier: ${out.tier}`);
  if (!CHANNELS.has(out.channel)) throw new Error(`Unsupported channel: ${out.channel}`);
  if (out.requireAllowanceLedger === null) out.requireAllowanceLedger = out.tier === "cloud-pro";
  if (!out.selfTest && !out.environment) {
    throw new Error("OPENBURNBAR_PROOF_ENVIRONMENT or --environment is required");
  }
  if (out.environment && !["Production", "Sandbox"].includes(out.environment)) {
    throw new Error("environment must be Production or Sandbox");
  }
  if (out.googlePlayAuditRecord && out.channel !== "google_play") {
    throw new Error("--google-play-audit-record requires --channel google_play");
  }
  if (out.googlePlayAuditRecord && !out.purchaseTokenHash) {
    throw new Error("--google-play-audit-record requires --purchase-token-hash");
  }
  if (!out.selfTest && !out.uid) throw new Error("OPENBURNBAR_PROOF_UID or --uid is required");
  return out;
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

function fail(message, details) {
  const error = new Error(message);
  error.details = details;
  throw error;
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

function monthKey(date = new Date()) {
  return date.toISOString().slice(0, 7);
}

function assertProduct(tier, channel, entitlement, explicitProductID) {
  const actual = entitlement.productID || entitlement.sourceProductID || "";
  const allowed = PRODUCTS[tier].products[channel];
  if (explicitProductID) {
    if (actual !== explicitProductID && entitlement.sourceProductID !== explicitProductID) {
      fail("entitlement productID mismatch", { actual, expected: explicitProductID });
    }
    return actual;
  }

  if (!allowed.includes(actual)) {
    fail("entitlement productID is not valid for tier/channel", { actual, allowed });
  }
  return actual;
}

function assertFeatures(tier, entitlement) {
  const features = entitlement.features || {};
  for (const feature of PRODUCTS[tier].requiredFeatures) {
    if (features[feature] !== true) fail(`entitlement feature ${feature} must be true`);
  }
  for (const feature of PRODUCTS[tier].forbiddenFeatures) {
    if (features[feature] === true) fail(`entitlement feature ${feature} must not be true`);
  }
}

export function assertPaidTierEntitlement(entitlement, opts) {
  const target = PRODUCTS[opts.tier];
  if (entitlement.id !== target.entitlementID) fail("entitlement.id mismatch", entitlement.id);
  if (entitlement.active !== true) fail("entitlement is not active", entitlement.active);

  const source = entitlement.source || "";
  if (!CHANNEL_SOURCES[opts.channel].has(source)) {
    fail("entitlement source does not match channel", {
      source,
      allowed: [...CHANNEL_SOURCES[opts.channel]],
    });
  }

  const allowedEnvironments = new Set([opts.environment]);
  if (opts.allowSandbox) allowedEnvironments.add("Sandbox");
  if (!entitlement.environment) {
    fail("entitlement environment is missing");
  }
  if (!allowedEnvironments.has(entitlement.environment)) {
    fail("entitlement environment mismatch", {
      got: entitlement.environment,
      allowed: [...allowedEnvironments],
    });
  }

  const expiresAt = asDate(entitlement.expireAt) || asDate(entitlement.expiresAt);
  if (!expiresAt) fail("entitlement expiry is missing or unreadable");
  if (expiresAt.getTime() <= Date.now()) fail("entitlement is expired", expiresAt.toISOString());

  if (opts.externalSubscriptionID && entitlement.externalSubscriptionID !== opts.externalSubscriptionID) {
    fail("externalSubscriptionID mismatch");
  }
  if (opts.purchaseTokenHash && entitlement.purchaseTokenHash !== opts.purchaseTokenHash) {
    fail("purchaseTokenHash mismatch");
  }

  const productID = assertProduct(opts.tier, opts.channel, entitlement, opts.productID);
  assertFeatures(opts.tier, entitlement);

  return {
    productID,
    source,
    expiresAt: expiresAt.toISOString(),
    externalSubscriptionIDHash: entitlement.externalSubscriptionID ? digest(entitlement.externalSubscriptionID) : null,
    externalCustomerIDHash: entitlement.externalCustomerID ? digest(entitlement.externalCustomerID) : null,
    purchaseTokenHash: entitlement.purchaseTokenHash || null,
  };
}

export function assertGooglePlayAuditRecord(record, opts) {
  if (opts.channel !== "google_play") fail("Google Play audit proof requires google_play channel");
  const target = PRODUCTS[opts.tier];
  if (record.entitlementID !== target.entitlementID) fail("Google Play audit entitlementID mismatch", record.entitlementID);
  const actual = record.productID || record.lineItemProductID || "";
  const allowed = target.products.google_play;
  if (opts.productID) {
    if (actual !== opts.productID && record.lineItemProductID !== opts.productID) {
      fail("Google Play audit productID mismatch", { actual, expected: opts.productID });
    }
  } else if (!allowed.includes(actual)) {
    fail("Google Play audit productID is not valid for tier", { actual, allowed });
  }
  if (record.purchaseTokenHash !== opts.purchaseTokenHash) fail("Google Play audit purchaseTokenHash mismatch");
  if (record.subscriptionState !== "SUBSCRIPTION_STATE_ACTIVE") {
    fail("Google Play audit subscription is not active", record.subscriptionState);
  }
  const expiresAt = asDate(record.expiresAt);
  if (!expiresAt) fail("Google Play audit expiry is missing or unreadable");
  if (expiresAt.getTime() <= Date.now()) fail("Google Play audit subscription is expired", expiresAt.toISOString());
  return {
    productID: actual,
    lineItemProductID: record.lineItemProductID || null,
    purchaseTokenHash: record.purchaseTokenHash,
    subscriptionState: record.subscriptionState,
    expiresAt: expiresAt.toISOString(),
  };
}

async function proveAllowanceLedger(db, uid) {
  const path = `users/${uid}/billing/allowances/months/${monthKey()}`;
  const snap = await db.doc(path).get();
  if (!snap.exists) fail("current-month Cloud Pro allowance ledger is missing", redactPath(path));
  const data = snap.data() || {};
  const required = {
    includedHostedActions: 500,
    includedRelayGB: 50,
    monthlyHostedActionCap: 2000,
    monthlyRelayGBCap: 300,
  };
  for (const [key, expected] of Object.entries(required)) {
    if (data[key] !== expected) fail(`allowance ledger ${key} mismatch`, { actual: data[key], expected });
  }
  return redactPath(path);
}

export function selfTest() {
  for (const [tier, config] of Object.entries(PRODUCTS)) {
    if (!config.entitlementID) fail(`missing entitlementID for ${tier}`);
    for (const channel of CHANNELS) {
      if (!Array.isArray(config.products[channel])) fail(`missing ${tier}/${channel} products`);
    }
  }
  return { ok: true, tiers: Object.keys(PRODUCTS), channels: [...CHANNELS] };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.selfTest) {
    console.log(JSON.stringify(selfTest(), null, 2));
    return;
  }

  if (getApps().length === 0) initializeApp({ projectId: opts.project });
  const db = getFirestore();

  if (opts.googlePlayAuditRecord) {
    const auditPath = `users/${opts.uid}/billing/google_play_purchases/tokens/${opts.purchaseTokenHash}`;
    const auditSnap = await db.doc(auditPath).get();
    if (!auditSnap.exists) fail("Google Play billing audit record does not exist", redactPath(auditPath));
    const googlePlayAuditRecord = assertGooglePlayAuditRecord(auditSnap.data() || {}, opts);
    const result = {
      ok: true,
      project: opts.project,
      uidHash: digest(opts.uid),
      uidHash16: shortDigest(opts.uid),
      tier: opts.tier,
      channel: opts.channel,
      googlePlayAuditPath: redactPath(auditPath),
      googlePlayAuditRecord,
    };
    console.log(`# proof-subject uid_sha256_16=${result.uidHash16}`);
    console.log(JSON.stringify(result, null, 2));
    return;
  }

  const entitlementPath = `users/${opts.uid}/entitlements/${PRODUCTS[opts.tier].entitlementID}`;
  const snap = await db.doc(entitlementPath).get();
  if (!snap.exists) fail("paid-tier entitlement document does not exist", redactPath(entitlementPath));

  const entitlement = assertPaidTierEntitlement(snap.data() || {}, opts);
  const result = {
    ok: true,
    project: opts.project,
    uidHash: digest(opts.uid),
    uidHash16: shortDigest(opts.uid),
    tier: opts.tier,
    channel: opts.channel,
    entitlementPath: redactPath(entitlementPath),
    entitlement,
    allowanceLedgerPath: null,
  };

  if (opts.requireAllowanceLedger) {
    result.allowanceLedgerPath = await proveAllowanceLedger(db, opts.uid);
  }

  console.log(`# proof-subject uid_sha256_16=${result.uidHash16}`);
  console.log(JSON.stringify(result, null, 2));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main().catch((error) => {
    console.error(JSON.stringify({ ok: false, error: error.message, details: error.details }, null, 2));
    process.exitCode = 1;
  });
}
