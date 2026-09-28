/**
 * @fileoverview `redeemPromoCode` — campaign-code redemption that grants a
 * promotional entitlement with no payment instrument involved.
 *
 * Built for the X launch free-Ultra beta claim: a signed-in visitor submits a
 * campaign code on https://burnbar.ai/beta and receives a real
 * `users/{uid}/entitlements/burnbar_ultra` document (dual-written to the
 * `burnbar_pro_max` mirror by the shared writer), with no Stripe charge, no
 * App Store auto-renewing trial, and no card on file.
 *
 * Ordering and failure model
 * --------------------------
 * The redemption ledger is reserved in a transaction, then the entitlement is
 * written. Those cannot be one atomic unit because the shared entitlement
 * writer runs its own transaction, so a crash between the two steps would
 * otherwise leave a consumed code with no grant. The repeat path closes that
 * hole: a uid whose ledger entry already exists re-asserts the entitlement it
 * recorded and returns `already_redeemed`, checked before current campaign
 * eligibility so a full, ended, or paused campaign cannot strand the grant.
 * That makes a retry self-healing and keeps the callable idempotent under
 * double-submits.
 *
 * Trust posture
 * -------------
 * - Auth + App Check + a single-use high-risk nonce (same attestation sequence
 *   as `completeCliLink`, driven by the site's `attestedCallable` helper).
 * - Per-uid burst and daily rate limits, plus a failure-lockout so the code
 *   space cannot be enumerated by a signed-in attacker.
 * - Codes are never compared in plaintext against Firestore: the canonical code
 *   is hashed and used as a document id, so redemption is one point-read.
 * - A promotional grant never overwrites a live provider-verified entitlement
 *   (checked here, and enforced again inside the entitlement write guards).
 */

import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";

import { db } from "@openburnbar/functions-shared/adminRuntime.js";
import { enforceHighRiskComputerUseCallableWithNonce } from "@openburnbar/functions-shared/appCheckAttestation.js";
import { getConfig } from "@openburnbar/functions-shared/config.js";
import { stringField } from "@openburnbar/functions-shared/guards.js";
import { logInfo, onCallProduction } from "@openburnbar/functions-shared/logging.js";
import {
  canonicalizePromoCode,
  promoCampaignDocPath,
  promoCodeDigest,
  promoCodeDocPath,
  promoRedemptionDocPath,
  promoRejectionMessage,
  PROMO_SCHEMA_VERSION,
  resolvePromoCampaign,
  resolvePromoCode,
  resolveRecordedPromoGrant,
  type PromoGrantPlan,
  type PromoRejectionReason,
} from "./promoCampaigns.js";
import { FUNCTIONS_REGION } from "@openburnbar/functions-shared/runtimeOptions.js";
import {
  assertCallableApprovalNotLocked,
  checkPromoRedeemRateLimit,
  recordCallableApprovalFailure,
} from "@openburnbar/functions-shared/callables/publicRateLimit.js";
import {
  entitlementExpiryMillis,
  writeBurnBarProEntitlement,
} from "@openburnbar/functions-shared/shared/entitlements.js";
import { PROMO_ENTITLEMENT_SOURCE } from "@openburnbar/functions-shared/shared/entitlementWriteSource.js";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

/**
 * Outcome reported to the caller:
 * - `granted` — a promotional entitlement was written for this uid.
 * - `already_redeemed` — this uid had redeemed before; the grant was re-asserted.
 * - `already_entitled` — a provider-verified entitlement already holds the doc.
 */
type PromoRedemptionStatus = "granted" | "already_redeemed" | "already_entitled";

/** `expiresAt` is the ISO-8601 expiry of the entitlement now in force. */
interface RedeemPromoCodeResponse {
  status: PromoRedemptionStatus;
  campaignID: string;
  entitlementID: string;
  productID: string;
  expiresAt: string;
  label?: string;
}

/**
 * Maps a refusal to a callable error. `not-found` for an unusable code lets the
 * landing page distinguish "wrong code" from "offer closed" without parsing
 * message text, matching how `/link` branches on `completeCliLink` codes.
 */
function promoRejection(reason: PromoRejectionReason): HttpsError {
  const message = promoRejectionMessage(reason);
  switch (reason) {
    case "unknown_code":
    case "code_disabled":
    case "campaign_missing":
      return new HttpsError("not-found", message);
    case "campaign_exhausted":
      return new HttpsError("resource-exhausted", message);
    default:
      return new HttpsError("failed-precondition", message);
  }
}

/**
 * True when the target entitlement document is currently held by a
 * provider-verified purchase. Such a document is left untouched: overwriting it
 * would drop the subscription identifiers its own webhooks reconcile against.
 */
function heldByVerifiedPurchase(raw: Record<string, unknown> | undefined, nowMillis: number): boolean {
  if (!raw || raw.active !== true) return false;
  if (raw.source === PROMO_ENTITLEMENT_SOURCE) return false;
  const expiry = entitlementExpiryMillis(raw);
  return expiry > nowMillis;
}

/**
 * Redeems `rawCode` for `uid`. Split from the callable so the redemption rules
 * — lookup, eligibility, ledger reservation, entitlement grant — can be
 * exercised against a real Firestore in `scripts/test-promo-redemption.mjs`
 * without standing up callable auth and App Check. The callable below is a thin
 * attestation shell over this function.
 */
export async function redeemPromoCodeForUid(uid: string, rawCode: unknown): Promise<RedeemPromoCodeResponse> {
  await assertCallableApprovalNotLocked(uid, "promo_redeem_fail");
  await checkPromoRedeemRateLimit(uid);

  const canonicalCode = canonicalizePromoCode(rawCode);
  if (!canonicalCode) {
    // A malformed code is charged against the lockout budget too: otherwise
    // the cheapest enumeration strategy would be to send garbage until the
    // shape is inferred from which inputs are rejected before lookup.
    await recordCallableApprovalFailure(uid, "promo_redeem_fail");
    throw new HttpsError("invalid-argument", "Enter the code from the announcement.");
  }

  const codeSnap = await db.doc(promoCodeDocPath(promoCodeDigest(canonicalCode))).get();
  const resolvedCode = resolvePromoCode(codeSnap.data());
  if (!resolvedCode.ok) {
    await recordCallableApprovalFailure(uid, "promo_redeem_fail");
    throw promoRejection(resolvedCode.reason);
  }

  const { campaignID } = resolvedCode.value;
  const campaignRef = db.doc(promoCampaignDocPath(campaignID));
  const redemptionRef = db.doc(promoRedemptionDocPath(campaignID, uid));
  const [campaignSnap, redemptionSnap] = await Promise.all([campaignRef.get(), redemptionRef.get()]);
  const campaignRaw = campaignSnap.data();

  // A uid that already holds a ledger slot is owed the grant it reserved, so
  // it is re-asserted from the recorded fields before current eligibility is
  // consulted. Otherwise a retry after a failed entitlement write would be
  // refused once the campaign fills, ends, or is paused, leaving a consumed
  // redemption with no grant.
  const recordedGrant = redemptionSnap.exists
    ? resolveRecordedPromoGrant(redemptionSnap.data(), campaignID)
    : undefined;
  if (recordedGrant) {
    return grantPromo(uid, { ...recordedGrant, label: stringField(campaignRaw ?? {}, "label") }, true);
  }

  const nowMillis = Date.now();
  const resolvedCampaign = resolvePromoCampaign(campaignRaw, { nowMillis });
  if (!resolvedCampaign.ok) throw promoRejection(resolvedCampaign.reason);

  const plan = resolvedCampaign.value;
  const { entitlementID, productID, grantExpiresAtMillis } = plan;
  const entitled = await verifiedPurchaseResponse(uid, plan, nowMillis);
  if (entitled) return entitled;

  const alreadyRedeemed = await db.runTransaction(async (transaction) => {
    // Re-read the campaign inside the transaction so a campaign disabled or
    // exhausted between the pre-check and here cannot be raced through.
    const [freshCampaignSnap, freshRedemptionSnap] = await Promise.all([
      transaction.get(campaignRef),
      transaction.get(redemptionRef),
    ]);
    if (freshRedemptionSnap.exists) return true;

    const freshCampaign = resolvePromoCampaign(freshCampaignSnap.data(), { nowMillis: Date.now() });
    if (!freshCampaign.ok) throw promoRejection(freshCampaign.reason);

    transaction.set(redemptionRef, {
      uid,
      campaignID,
      entitlementID,
      productID,
      grantExpiresAt: Timestamp.fromMillis(grantExpiresAtMillis),
      redeemedAt: Timestamp.now(),
      schemaVersion: PROMO_SCHEMA_VERSION,
    });
    transaction.set(
      campaignRef,
      { redemptionCount: FieldValue.increment(1), updatedAt: Timestamp.now() },
      { merge: true },
    );
    return false;
  });

  return grantPromo(uid, plan, alreadyRedeemed, { paidChecked: true });
}

/**
 * The `already_entitled` response when a provider-verified purchase holds the
 * plan's entitlement document, else `undefined`. Such a user keeps their
 * subscription and no redemption is consumed or re-asserted over it.
 */
async function verifiedPurchaseResponse(
  uid: string,
  plan: PromoGrantPlan,
  nowMillis: number,
): Promise<RedeemPromoCodeResponse | undefined> {
  const existingEntitlement = (await db.doc(`users/${uid}/entitlements/${plan.entitlementID}`).get()).data();
  if (!heldByVerifiedPurchase(existingEntitlement, nowMillis)) return undefined;
  logInfo({ event: "promo.redeem_skipped_paid", uid, campaignID: plan.campaignID, entitlementID: plan.entitlementID });
  return {
    status: "already_entitled",
    campaignID: plan.campaignID,
    entitlementID: plan.entitlementID,
    productID: typeof existingEntitlement?.productID === "string" ? existingEntitlement.productID : plan.productID,
    expiresAt: new Date(entitlementExpiryMillis(existingEntitlement ?? {})).toISOString(),
    label: plan.label,
  };
}

/**
 * Writes the promotional entitlement for `plan`. Runs on both the first grant
 * and a repeat call: re-asserting repairs the window where the ledger was
 * reserved but the entitlement write failed.
 */
async function grantPromo(
  uid: string,
  plan: PromoGrantPlan,
  alreadyRedeemed: boolean,
  options: { paidChecked?: boolean } = {},
): Promise<RedeemPromoCodeResponse> {
  const { campaignID, entitlementID, productID, grantExpiresAtMillis, label } = plan;
  if (!options.paidChecked) {
    const entitled = await verifiedPurchaseResponse(uid, plan, Date.now());
    if (entitled) return entitled;
  }

  await writeBurnBarProEntitlement({
    uid,
    productID,
    expiresAtMillis: grantExpiresAtMillis,
    source: PROMO_ENTITLEMENT_SOURCE,
    platform: "web",
    entitlementID,
    activeOverride: true,
    promoGrant: { campaignID, redemptionID: uid },
  });

  logInfo({
    event: alreadyRedeemed ? "promo.redeem_reasserted" : "promo.redeem_granted",
    uid,
    campaignID,
    entitlementID,
    productID,
  });

  return {
    status: alreadyRedeemed ? "already_redeemed" : "granted",
    campaignID,
    entitlementID,
    productID,
    expiresAt: new Date(grantExpiresAtMillis).toISOString(),
    label,
  };
}

export const redeemPromoCode = onCallProduction(
  "redeemPromoCode",
  { region: FUNCTIONS_REGION, enforceAppCheck: getConfig().enforceAppCheck, maxInstances: 50 },
  async (request: CallableRequest<{ code?: unknown; nonce?: unknown }>): Promise<RedeemPromoCodeResponse> => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in to claim this offer.");
    await enforceHighRiskComputerUseCallableWithNonce(request, uid, request.data.nonce);
    return redeemPromoCodeForUid(uid, request.data.code);
  },
);
