#!/usr/bin/env node
/**
 * End-to-end proof for the free-Ultra beta claim path, against a real Firestore.
 *
 *   npm run test:promo-redemption --prefix functions
 *
 * Runs the shipped redemption logic (`redeemPromoCodeForUid`) and the shipped
 * entitlement writer (`writeBurnBarProEntitlement`) against the Firestore
 * emulator — no mocked database, no stubbed entitlement write. Campaign and
 * code documents are seeded by invoking the operator script
 * (`scripts/promo/seed-promo-campaign.mjs`), so the documented runbook is under
 * test too, not just the callable.
 *
 * The load-bearing claim it proves: a fresh uid that redeems the campaign code
 * ends up with an ACTIVE Ultra entitlement carrying NO payment instrument of
 * any kind — no Stripe subscription id, no Play purchase token, no App Store
 * transaction — and the shipped Ultra predicate agrees.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

assert.ok(
  process.env.FIRESTORE_EMULATOR_HOST,
  "FIRESTORE_EMULATOR_HOST must be set; run through `firebase emulators:exec`",
);
process.env.GCLOUD_PROJECT ||= "openburnbar-rules-test";
process.env.GOOGLE_CLOUD_PROJECT ||= process.env.GCLOUD_PROJECT;

const { db } = await import("../lib/adminRuntime.js");
const { redeemPromoCodeForUid } = await import("../lib/callables/promoRedemption.js");
const { isActiveBurnBarUltraEntitlement, writeBurnBarProEntitlement } = await import(
  "../lib/callables/shared/entitlements.js"
);
const { canonicalizePromoCode, promoCodeDigest, PROMO_ENTITLEMENT_SOURCE } = await import(
  "../lib/promoCampaigns.js"
);

const CAMPAIGN_ID = "xopen-ultra";
const CODE = "XOPEN-ULTRA";
const ULTRA_DOC = "burnbar_ultra";
const PRO_MAX_DOC = "burnbar_pro_max";

/** Runs the operator seed script against the emulator. */
function seed(extraArgs = []) {
  return execFileSync(
    process.execPath,
    [
      path.join(repoRoot, "scripts", "promo", "seed-promo-campaign.mjs"),
      "--campaign",
      CAMPAIGN_ID,
      "--project",
      process.env.GCLOUD_PROJECT,
      ...extraArgs,
    ],
    { encoding: "utf8", env: process.env },
  );
}

async function entitlement(uid, docID = ULTRA_DOC) {
  return (await db.doc(`users/${uid}/entitlements/${docID}`).get()).data();
}

async function campaign() {
  return (await db.doc(`promo_campaigns/${CAMPAIGN_ID}`).get()).data();
}

/** Fresh uid per scenario: redemption ledger and rate limits are keyed per uid. */
let uidCounter = 0;
const freshUid = (label) => `promo-test-${label}-${++uidCounter}-${Date.now()}`;

async function resetCampaign(overrides = {}) {
  await db.doc(`promo_campaigns/${CAMPAIGN_ID}`).set({ redemptionCount: 0, active: true, ...overrides }, { merge: true });
}

test("seed script writes campaign policy and a hashed code", async () => {
  const output = seed();
  assert.match(output, /policy written/);
  assert.match(output, /code seeded/);
  assert.doesNotMatch(output, new RegExp(CODE), "the seed script must never print the live code");

  const doc = await campaign();
  assert.equal(doc.active, true);
  assert.equal(doc.entitlementID, ULTRA_DOC);
  assert.equal(doc.productID, "com.openburnbar.ultra.annual.v2");
  assert.ok(doc.grantExpiresAtMillis > Date.now() + 50 * 365 * 24 * 3600 * 1000, "grant must be far-future");

  // The code lives only as a digest; the plaintext is not a document id anywhere.
  const digest = promoCodeDigest(canonicalizePromoCode(CODE));
  const codeDoc = (await db.doc(`promo_codes/${digest}`).get()).data();
  assert.equal(codeDoc.campaignID, CAMPAIGN_ID);
  assert.equal(codeDoc.active, true);
});

test("a fresh uid redeems the code and receives active Ultra with no payment instrument", async () => {
  await resetCampaign();
  const uid = freshUid("fresh");

  const result = await redeemPromoCodeForUid(uid, CODE);
  assert.equal(result.status, "granted");
  assert.equal(result.entitlementID, ULTRA_DOC);

  const doc = await entitlement(uid);
  assert.equal(doc.active, true, "entitlement must be active");
  assert.equal(doc.id, ULTRA_DOC);
  assert.equal(doc.productID, "com.openburnbar.ultra.annual.v2");
  assert.equal(doc.source, PROMO_ENTITLEMENT_SOURCE);
  assert.equal(doc.platform, "web");
  assert.equal(doc.promoCampaignID, CAMPAIGN_ID);
  assert.ok(doc.expireAt.toMillis() > Date.now() + 50 * 365 * 24 * 3600 * 1000, "expiry must be far-future");

  // The whole point of the carve-out: entitlement without any charge.
  for (const paymentField of [
    "externalSubscriptionID",
    "externalCustomerID",
    "purchaseTokenHash",
    "transactionID",
    "originalTransactionID",
    "signedTransactionHash",
  ]) {
    assert.equal(doc[paymentField], undefined, `${paymentField} must be absent on a promo grant`);
  }

  // The shipped predicate every backend gate uses must agree it is Ultra.
  assert.equal(isActiveBurnBarUltraEntitlement(doc), true, "shipped Ultra predicate must accept the grant");

  // Ultra dual-writes the Cloud Pro mirror, which is what the hosted-quota and
  // Floo/Agent-Control gates actually read.
  const mirror = await entitlement(uid, PRO_MAX_DOC);
  assert.equal(mirror.active, true);
  assert.equal(mirror.sourceEntitlementID, ULTRA_DOC);
  assert.equal(mirror.features.floo, true);
  assert.equal(mirror.features.agentControl, true);

  assert.equal((await campaign()).redemptionCount, 1, "one redemption must be counted");
});

test("one-click and hand-typed spellings of the code are the same code", async () => {
  await resetCampaign();
  for (const spelling of ["xopen-ultra", "XOPENULTRA", " XOpen Ultra "]) {
    const uid = freshUid("spelling");
    const result = await redeemPromoCodeForUid(uid, spelling);
    assert.equal(result.status, "granted", `${spelling} must redeem`);
    assert.equal((await entitlement(uid)).active, true);
  }
  assert.equal((await campaign()).redemptionCount, 3);
});

test("redeeming twice is idempotent: no second grant, no double count", async () => {
  await resetCampaign();
  const uid = freshUid("repeat");

  assert.equal((await redeemPromoCodeForUid(uid, CODE)).status, "granted");
  const repeat = await redeemPromoCodeForUid(uid, CODE);

  assert.equal(repeat.status, "already_redeemed");
  assert.equal((await campaign()).redemptionCount, 1, "a repeat must not consume a second redemption");
  assert.equal((await entitlement(uid)).active, true, "the repeat re-asserts the grant");
});

test("an unknown code is rejected and grants nothing", async () => {
  await resetCampaign();
  const uid = freshUid("unknown");

  await assert.rejects(() => redeemPromoCodeForUid(uid, "NOPE-NOPE"), /isn't valid/);
  assert.equal(await entitlement(uid), undefined, "a rejected redemption must not write an entitlement");
});

test("a paused campaign refuses redemption", async () => {
  await resetCampaign({ active: false });
  const uid = freshUid("paused");

  await assert.rejects(() => redeemPromoCodeForUid(uid, CODE), /no longer available/);
  assert.equal(await entitlement(uid), undefined);
});

test("an exhausted campaign refuses redemption", async () => {
  await resetCampaign({ maxRedemptions: 2, redemptionCount: 2 });
  const uid = freshUid("exhausted");

  await assert.rejects(() => redeemPromoCodeForUid(uid, CODE), /fully claimed/);
  assert.equal(await entitlement(uid), undefined);

  await resetCampaign({ maxRedemptions: 5000 });
});

test("a paying subscriber keeps their subscription and does not burn a redemption", async () => {
  await resetCampaign();
  const uid = freshUid("paid");

  // A real Stripe-verified Ultra subscription, one month out.
  await writeBurnBarProEntitlement({
    uid,
    productID: "com.openburnbar.ultra.annual.v2",
    expiresAtMillis: Date.now() + 30 * 24 * 3600 * 1000,
    source: "stripe_webhook_verified",
    platform: "stripe",
    entitlementID: ULTRA_DOC,
    externalSubscriptionID: "sub_live_123",
    externalCustomerID: "cus_live_123",
  });

  const result = await redeemPromoCodeForUid(uid, CODE);
  assert.equal(result.status, "already_entitled");

  const doc = await entitlement(uid);
  assert.equal(doc.source, "stripe_webhook_verified", "the paid subscription must still own the document");
  assert.equal(doc.externalSubscriptionID, "sub_live_123", "subscription id must survive");
  assert.equal(doc.promoCampaignID, undefined, "no promo provenance may be stamped on a paid document");
  assert.equal((await campaign()).redemptionCount, 0, "no redemption may be consumed");
});

test("a later real purchase supersedes a promo grant", async () => {
  await resetCampaign();
  const uid = freshUid("upgrade");

  assert.equal((await redeemPromoCodeForUid(uid, CODE)).status, "granted");
  assert.equal((await entitlement(uid)).source, PROMO_ENTITLEMENT_SOURCE);

  // A real subscription expires far sooner than the promo grant. The generic
  // downgrade guard would read that as a downgrade; the promo rule must let the
  // verified purchase take ownership so the subscriber's own lifecycle (and
  // eventual cancellation) governs the document.
  const paidExpiry = Date.now() + 30 * 24 * 3600 * 1000;
  await writeBurnBarProEntitlement({
    uid,
    productID: "com.openburnbar.ultra.annual.v2",
    expiresAtMillis: paidExpiry,
    source: "stripe_webhook_verified",
    platform: "stripe",
    entitlementID: ULTRA_DOC,
    externalSubscriptionID: "sub_upgrade_456",
  });

  const doc = await entitlement(uid);
  assert.equal(doc.source, "stripe_webhook_verified", "the purchase must take over the document");
  assert.equal(doc.externalSubscriptionID, "sub_upgrade_456");
  assert.equal(doc.promoCampaignID, undefined, "promo provenance must be scrubbed by the verified write");
  assert.equal(doc.expireAt.toMillis(), paidExpiry, "expiry must follow the real subscription");
});

test("a second campaign grants a different tier with no code change", async () => {
  // The redemption path reads the target tier and SKU off the campaign
  // document, so standing up another offer is a seeding operation, not a code
  // change. This is the property a port to another product depends on, so it
  // is asserted rather than assumed: a second campaign is written directly
  // (no config entry, no new callable) and must grant its own tier.
  await resetCampaign();
  const secondCampaignID = "second-campaign-proof";
  const secondCode = "SECOND-TIER-PROOF";
  const secondDigest = promoCodeDigest(canonicalizePromoCode(secondCode));
  const grantExpiresAtMillis = Date.parse("2099-01-01T00:00:00.000Z");

  await db.doc(`promo_campaigns/${secondCampaignID}`).set({
    campaignID: secondCampaignID,
    label: "second tier proof",
    active: true,
    // A different entitlement document and a different SKU from the Ultra
    // campaign above — nothing about the callable is Ultra-specific.
    entitlementID: PRO_MAX_DOC,
    productID: "com.openburnbar.proMax.v2.monthly",
    grantExpiresAtMillis,
    schemaVersion: 1,
  });
  await db.doc(`promo_codes/${secondDigest}`).set({
    campaignID: secondCampaignID,
    active: true,
    schemaVersion: 1,
  });

  const uid = freshUid("second-campaign");
  const result = await redeemPromoCodeForUid(uid, secondCode);
  assert.equal(result.status, "granted");
  assert.equal(result.entitlementID, PRO_MAX_DOC);

  const doc = await entitlement(uid, PRO_MAX_DOC);
  assert.equal(doc.active, true);
  assert.equal(doc.productID, "com.openburnbar.proMax.v2.monthly");
  assert.equal(doc.source, PROMO_ENTITLEMENT_SOURCE);
  assert.equal(doc.promoCampaignID, secondCampaignID);

  // Campaigns are independent: the second offer must not touch the Ultra doc
  // or spend an Ultra redemption.
  assert.equal(await entitlement(uid, ULTRA_DOC), undefined, "a Cloud Pro campaign must not grant Ultra");
  assert.equal((await campaign()).redemptionCount, 0, "the Ultra campaign's cap must be untouched");
});

test("rotating the code retires the old one without touching granted entitlements", async () => {
  await resetCampaign();
  const grantedUid = freshUid("rotate-existing");
  assert.equal((await redeemPromoCodeForUid(grantedUid, CODE)).status, "granted");

  seed(["--code", "XOPEN-ROUND2", "--deactivate-code", CODE]);

  const retiredUid = freshUid("rotate-old");
  await assert.rejects(() => redeemPromoCodeForUid(retiredUid, CODE), /isn't valid/);

  const rotatedUid = freshUid("rotate-new");
  assert.equal((await redeemPromoCodeForUid(rotatedUid, "XOPEN-ROUND2")).status, "granted");

  assert.equal((await entitlement(grantedUid)).active, true, "rotation must not revoke an existing grant");

  // Restore the launch code for any later run against the same emulator state.
  seed(["--code", CODE, "--deactivate-code", "XOPEN-ROUND2"]);
});
