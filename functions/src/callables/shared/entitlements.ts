/**
 * @fileoverview BurnBar Pro / Cloud Pro / Ultra entitlement predicates, writes, and the
 * Cloud Pro allowance ledger + top-up crediting logic.
 */

import { FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import * as entitlementsPackage from "@openburnbar/entitlements";
import type { EntitlementCatalog } from "@openburnbar/entitlements";

const { isActiveEntitlement } = entitlementsPackage;
import { getConfig } from "../../config.js";
import { stripUndefinedObject } from "../../guards.js";
import { db } from "../../adminRuntime.js";
import {
  allowanceDocPath,
  cloudProTopUpReceiptDocPath,
  CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
  monthKeyForDate,
  unitsForCloudProTopUp,
  type CloudProTopUpKind,
} from "../../cloudProAllowanceCore.js";
import { loadCloudProAllowanceConfig } from "../../cloudProAllowanceRemoteConfig.js";
import { assertCloudFeatureNotSuspended } from "../../cloudFeatureSuspensions.js";
import {
  disputeTopUpReversalUnits,
  proportionalTopUpReversalUnits,
  stripeTopUpAmount,
  stripeTopUpIncrementField,
  stripeTopUpReceiptState,
  stripeTopUpReversalState,
  type StripeTopUpDisputeStatus,
} from "./stripeTopUpReversal.js";
import {
  paidEntitlementWriteWouldDowngrade,
  paidEntitlementWriteWouldRewindSourceEvent,
} from "./entitlementWriteGuards.js";
import { PROMO_ENTITLEMENT_SOURCE } from "../../promoCampaigns.js";
import { nowISO, requiredIdentifier } from "./validators.js";

// Re-exported so existing importers (`callables/shared.ts`, the write-ordering
// tests) keep their single entitlement entry point after the guards moved out.
export { paidEntitlementWriteWouldDowngrade, paidEntitlementWriteWouldRewindSourceEvent };

export const BURNBAR_PRO_ENTITLEMENT_ID = "burnbar_pro";
export const BURNBAR_PRO_MAX_ENTITLEMENT_ID = "burnbar_pro_max";
export const BURNBAR_ULTRA_ENTITLEMENT_ID = "burnbar_ultra";

export async function assertActiveHostedQuotaEntitlement(uid: string): Promise<void> {
  await assertCloudFeatureNotSuspended(db, uid, "hosted_quota");
  const [hostedSnap, proSnap, proMaxSnap, ultraSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveHostedQuotaEntitlement(hostedSnap.data())) return;
  if (isActivePremiumEntitlement(proSnap.data())) return;
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return;
  if (isActiveBurnBarUltraEntitlement(ultraSnap.data())) return;
  throw new HttpsError("permission-denied", "Hosted Quota Sync or BurnBar Pro subscription required.");
}

export async function assertActiveBurnBarProEntitlement(uid: string): Promise<void> {
  await assertCloudFeatureNotSuspended(db, uid, "burnbar_cloud");
  const [proSnap, hostedSnap, proMaxSnap, ultraSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/hosted_quota_sync`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActivePremiumEntitlement(proSnap.data())) return;
  if (isActivePremiumEntitlement(hostedSnap.data())) return;
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return;
  if (isActiveBurnBarUltraEntitlement(ultraSnap.data())) return;
  throw new HttpsError(
    "permission-denied",
    "BurnBar Pro is required for hosted LLM, encrypted session-log backup, and cloud search.",
  );
}

type BurnBarCloudProEntitlementTier = "cloud_pro" | "ultra";

async function activeBurnBarCloudProEntitlementTier(uid: string): Promise<BurnBarCloudProEntitlementTier> {
  await assertCloudFeatureNotSuspended(db, uid, "burnbar_cloud_pro");
  const [ultraSnap, proMaxSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveBurnBarUltraEntitlement(ultraSnap.data())) return "ultra";
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return "cloud_pro";
  throw new HttpsError(
    "permission-denied",
    "BurnBar Cloud Pro or Ultra is required for Floo, hosted Agent Control, and Elder Wand Fusion search.",
  );
}

export async function assertActiveBurnBarCloudProEntitlement(uid: string): Promise<void> {
  await activeBurnBarCloudProEntitlementTier(uid);
}

/**
 * Resolves the allowance tier for fulfilling an already-captured Cloud Pro
 * top-up payment. Unlike {@link activeBurnBarCloudProEntitlementTier} this
 * never throws: eligibility is asserted at purchase time (checkout-session or
 * Play-purchase creation), and by the time the asynchronous payment webhook
 * lands the entitlement may have lapsed or the account may be suspended — the
 * customer's money is captured either way, so the credit must still land
 * instead of failing the webhook forever. The tier only shapes fusion
 * allowance defaults; with no active entitlement, fall back to the tier whose
 * entitlement doc exists (Ultra wins), defaulting to cloud_pro.
 */
async function cloudProTopUpFulfillmentTier(uid: string): Promise<BurnBarCloudProEntitlementTier> {
  const [ultraSnap, proMaxSnap] = await Promise.all([
    db.doc(`users/${uid}/entitlements/${BURNBAR_ULTRA_ENTITLEMENT_ID}`).get(),
    db.doc(`users/${uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`).get(),
  ]);
  if (isActiveBurnBarUltraEntitlement(ultraSnap.data())) return "ultra";
  if (isActiveBurnBarCloudProEntitlement(proMaxSnap.data())) return "cloud_pro";
  return ultraSnap.exists ? "ultra" : "cloud_pro";
}

/**
 * Builds the {@link EntitlementCatalog} the shared predicate matches against from
 * this backend's resolved config. The product IDs are env / remote-config overridable
 * (see `functions/src/config.ts`), so the catalog is resolved per call rather than
 * frozen at import; the shared package's `DEFAULT_ENTITLEMENT_CATALOG` carries the
 * same compiled-in fallbacks for callers without overrides.
 */
function entitlementCatalogFromConfig(): EntitlementCatalog {
  const cfg = getConfig();
  return {
    hostedQuotaProductID: cfg.hostedQuotaProductID,
    burnBarProProductID: cfg.burnBarProProductID,
    burnBarProAnnualProductID: cfg.burnBarProAnnualProductID,
    burnBarProMaxProductID: cfg.burnBarProMaxProductID,
    burnBarProMaxAnnualProductID: cfg.burnBarProMaxAnnualProductID,
    burnBarUltraProductID: cfg.burnBarUltraProductID,
    burnBarUltraAnnualProductID: cfg.burnBarUltraAnnualProductID,
    googlePlaySubscriptionProductID: cfg.googlePlaySubscriptionProductID,
    googlePlayCloudMonthlyProductID: cfg.googlePlayCloudMonthlyProductID,
    googlePlayCloudAnnualProductID: cfg.googlePlayCloudAnnualProductID,
    googlePlayCloudProMonthlyProductID: cfg.googlePlayCloudProMonthlyProductID,
    googlePlayCloudProAnnualProductID: cfg.googlePlayCloudProAnnualProductID,
    googlePlayUltraMonthlyProductID: cfg.googlePlayUltraMonthlyProductID,
    googlePlayUltraAnnualProductID: cfg.googlePlayUltraAnnualProductID,
  };
}

export function isActiveHostedQuotaEntitlement(raw: Record<string, unknown> | undefined): boolean {
  return isActiveEntitlement(raw, "hostedQuota", { catalog: entitlementCatalogFromConfig() });
}

export function isActivePremiumEntitlement(raw: Record<string, unknown> | undefined): boolean {
  return isActiveEntitlement(raw, "premium", { catalog: entitlementCatalogFromConfig() });
}

export function isActiveBurnBarCloudProEntitlement(raw: Record<string, unknown> | undefined): boolean {
  return isActiveEntitlement(raw, "cloudPro", { catalog: entitlementCatalogFromConfig() });
}

/**
 * Strict Ultra check. The burnbar_ultra source doc carries the Ultra SKU
 * productID (the proMax MIRROR carries it too, but the mirror lives at a
 * different doc path). Accepts Apple + Google Play Ultra product ids.
 */
export function isActiveBurnBarUltraEntitlement(raw: Record<string, unknown> | undefined): boolean {
  return isActiveEntitlement(raw, "ultra", { catalog: entitlementCatalogFromConfig() });
}

/**
 * Resolves an entitlement document's expiry in epoch millis. Delegates to the shared
 * @openburnbar/entitlements math; the one behavior difference preserved here is the
 * legacy `0` sentinel (rather than the package's `NaN`) for an unparseable/missing
 * expiry, since existing callers branch on `Number.isFinite(expiry) && expiry > now`.
 */
export function entitlementExpiryMillis(raw: Record<string, unknown>): number {
  const millis = entitlementsPackage.entitlementExpiryMillis(raw);
  return Number.isFinite(millis) ? millis : 0;
}

function burnBarProFeatures(): Record<string, boolean> {
  return {
    hostedQuota: true,
    hostedLLM: true,
    encryptedSessionLogBackup: true,
    cloudConversationSearch: true,
  };
}

function burnBarProMaxFeatures(): Record<string, boolean> {
  return {
    ...burnBarProFeatures(),
    floo: true,
    agentControl: true,
  };
}

export async function writeBurnBarProEntitlement(args: {
  uid: string;
  productID: string;
  expiresAtMillis: number;
  source: string;
  platform: "ios" | "android" | "macos" | "web" | "stripe";
  entitlementID?: string;
  externalSubscriptionID?: string;
  externalCustomerID?: string;
  purchaseTokenHash?: string;
  rawStatus?: string;
  environment?: string;
  activeOverride?: boolean;
  sourceEventID?: string;
  sourceEventCreatedMillis?: number;
  /**
   * Provenance for a promotional campaign grant. Present only when `source` is
   * {@link PROMO_ENTITLEMENT_SOURCE}; carries no provider receipt, so support
   * and analytics can tell a campaign grant from a paid subscription without
   * inferring it from the absence of a subscription id.
   */
  promoGrant?: { campaignID: string; redemptionID?: string };
}): Promise<Record<string, unknown>> {
  const now = nowISO();
  const active = args.activeOverride ?? (Number.isFinite(args.expiresAtMillis) && args.expiresAtMillis > Date.now());
  const expiresAt = new Date(args.expiresAtMillis).toISOString();
  const entitlementID = args.entitlementID || BURNBAR_PRO_ENTITLEMENT_ID;
  const doc = stripUndefinedObject({
    id: entitlementID,
    active,
    productID: args.productID,
    entitlementFamily: entitlementID,
    features:
      entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID || entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID
        ? burnBarProMaxFeatures()
        : burnBarProFeatures(),
    expiresAt,
    expireAt: Timestamp.fromMillis(args.expiresAtMillis),
    source: args.source,
    platform: args.platform,
    externalSubscriptionID: args.externalSubscriptionID,
    externalCustomerID: args.externalCustomerID,
    purchaseTokenHash: args.purchaseTokenHash,
    rawStatus: args.rawStatus,
    environment: args.environment,
    sourceEventID: args.sourceEventID,
    sourceEventCreatedMillis: args.sourceEventCreatedMillis,
    promoCampaignID: args.promoGrant?.campaignID,
    promoRedemptionID: args.promoGrant?.redemptionID,
    promoGrantedAt: args.promoGrant ? now : undefined,
    verificationVersion: 1,
    schemaVersion: 1,
    lastVerifiedAt: now,
    updatedAt: now,
  });
  const ref = db.doc(`users/${args.uid}/entitlements/${entitlementID}`);

  // The source-event ordering watermark (sourceEventID/sourceEventCreatedMillis)
  // is PRESERVED — not deleted — when a caller writes without one (LB-5): the
  // checkout.session path used to erase it here, after which any buffered
  // stale subscription event sailed past paidEntitlementWriteWouldRewindSourceEvent
  // and could resurrect a cancelled entitlement. Watermarked callers overwrite
  // it via `doc`; the merge write leaves it untouched for everyone else.
  const writeDoc = {
    ...doc,
    // A verified provider lifecycle replaces the mutable entitlement snapshot.
    // Remove operator-only provenance left by a temporary support bridge so the
    // document cannot claim both provider verification and an active operator
    // grant at the same time. Ultra mirrors restore their own source fields
    // below after this cleanup is applied.
    ...(args.source === "internal_operator_grant"
      ? {}
      : {
          operatorGrant: FieldValue.delete(),
          operatorGrantedAt: FieldValue.delete(),
          operatorGrantReason: FieldValue.delete(),
          sourceEntitlementID: FieldValue.delete(),
          sourceProductID: FieldValue.delete(),
        }),
    // Same rule for promotional provenance: once a real receipt (or an operator
    // bridge) owns this document, it must not still advertise the campaign that
    // previously granted it, or support would read a paid subscriber as a
    // promo claimant forever.
    ...(args.source === PROMO_ENTITLEMENT_SOURCE
      ? {}
      : {
          promoCampaignID: FieldValue.delete(),
          promoRedemptionID: FieldValue.delete(),
          promoGrantedAt: FieldValue.delete(),
        }),
    externalSubscriptionID: args.externalSubscriptionID ?? FieldValue.delete(),
    externalCustomerID: args.externalCustomerID ?? FieldValue.delete(),
    purchaseTokenHash: args.purchaseTokenHash ?? FieldValue.delete(),
  };

  // Shared shape for both conflict guards, evaluated against the primary doc
  // AND (for Ultra writes) the burnbar_pro_max mirror doc.
  const incomingGuardWrite = {
    source: args.source,
    expiresAtMillis: args.expiresAtMillis,
    active,
    externalSubscriptionID: args.externalSubscriptionID,
    purchaseTokenHash: args.purchaseTokenHash,
    sourceEventID: args.sourceEventID,
    sourceEventCreatedMillis: args.sourceEventCreatedMillis,
  };

  const written = await db.runTransaction(async (transaction) => {
    const mirrorRef =
      entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID
        ? db.doc(`users/${args.uid}/entitlements/${BURNBAR_PRO_MAX_ENTITLEMENT_ID}`)
        : undefined;
    const existingData = (await transaction.get(ref)).data();
    // Firestore transactions require every read to happen before any write,
    // so the mirror doc is read up front even though its guard runs later.
    const existingMirrorData = mirrorRef ? (await transaction.get(mirrorRef)).data() : undefined;
    if (
      paidEntitlementWriteWouldDowngrade(existingData, incomingGuardWrite) ||
      paidEntitlementWriteWouldRewindSourceEvent(existingData, incomingGuardWrite)
    ) {
      return existingData || doc;
    }

    transaction.set(ref, writeDoc, { merge: true });
    // Ultra mirrors into burnbar_pro_max, matching the App Store reconciler's
    // dual-write: firestore.rules hosted-quota gates only inspect the
    // hosted_quota_sync / burnbar_pro / burnbar_pro_max docs, so a Google Play
    // or Stripe Ultra purchase without this mirror would be denied session
    // backup and every other Cloud Pro Max client capability. The mirror is
    // written in the same transaction so the pair stays consistent, and it is
    // guarded against the MIRROR doc's own state: when burnbar_pro_max is an
    // independently paid entitlement (different source/subscription/token),
    // an expiring or voided Ultra write must not clobber it. A true mirror
    // (written by this dual-write) carries the same source and subscription
    // identifiers, so its guards evaluate exactly like the primary's and
    // legitimate mirror updates — including cancellations — still land.
    if (
      mirrorRef &&
      !paidEntitlementWriteWouldDowngrade(existingMirrorData, incomingGuardWrite) &&
      !paidEntitlementWriteWouldRewindSourceEvent(existingMirrorData, incomingGuardWrite)
    ) {
      transaction.set(
        mirrorRef,
        {
          ...writeDoc,
          id: BURNBAR_PRO_MAX_ENTITLEMENT_ID,
          entitlementFamily: BURNBAR_PRO_MAX_ENTITLEMENT_ID,
          sourceEntitlementID: BURNBAR_ULTRA_ENTITLEMENT_ID,
        },
        { merge: true },
      );
    }
    return doc;
  });
  if ((entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID || entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID) && active) {
    await ensureCloudProAllowanceLedger(args.uid, cloudProAllowanceTierForEntitlement(entitlementID, args.productID));
  }
  return written;
}

function cloudProAllowanceTierForEntitlement(entitlementID: string, productID: string): BurnBarCloudProEntitlementTier {
  const cfg = getConfig();
  if (
    entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID ||
    productID === cfg.burnBarUltraProductID ||
    productID === cfg.burnBarUltraAnnualProductID ||
    productID === cfg.googlePlayUltraMonthlyProductID ||
    productID === cfg.googlePlayUltraAnnualProductID
  ) {
    return "ultra";
  }
  return "cloud_pro";
}

function fusionAllowanceDefaultsForTier(
  tier: BurnBarCloudProEntitlementTier,
  allowanceConfig: Awaited<ReturnType<typeof loadCloudProAllowanceConfig>>,
): {
  includedFusionSearches: number;
  monthlyFusionSearchCap: number;
} {
  if (tier === "ultra") {
    return {
      includedFusionSearches: allowanceConfig.includedUltraFusionSearchesMonthly,
      monthlyFusionSearchCap: allowanceConfig.monthlyUltraFusionSearchCap,
    };
  }
  return {
    includedFusionSearches: allowanceConfig.includedFusionSearchesMonthly,
    monthlyFusionSearchCap: allowanceConfig.monthlyFusionSearchCap,
  };
}

async function ensureCloudProAllowanceLedger(
  uid: string,
  tier: BurnBarCloudProEntitlementTier = "cloud_pro",
): Promise<void> {
  const allowanceConfig = await loadCloudProAllowanceConfig();
  const fusionDefaults = fusionAllowanceDefaultsForTier(tier, allowanceConfig);
  await db.doc(allowanceDocPath(uid, monthKeyForDate(new Date()))).set(
    {
      includedHostedActions: allowanceConfig.includedHostedActionsMonthly,
      includedRelayGB: allowanceConfig.includedRelayGBMonthly,
      includedFusionSearches: fusionDefaults.includedFusionSearches,
      monthlyHostedActionCap: allowanceConfig.monthlyHostedActionCap,
      monthlyRelayGBCap: allowanceConfig.monthlyRelayGBCap,
      monthlyFusionSearchCap: fusionDefaults.monthlyFusionSearchCap,
      updatedAt: Timestamp.now(),
      schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
    },
    { merge: true },
  );
}

export async function creditCloudProTopUp(args: {
  uid: string;
  kind: CloudProTopUpKind;
  source: string;
  externalPaymentID: string;
  externalPaymentIntentID?: string;
  externalChargeID?: string;
  externalAmountMinor?: number;
  externalCurrency?: string;
  quantity?: number;
}): Promise<{ credited: boolean; monthKey: string; units: number; kind: CloudProTopUpKind }> {
  // Fulfillment must not re-assert entitlement/suspension state: payment is
  // already captured, so a lapsed subscription between checkout and webhook
  // would otherwise permanently strand a paid top-up.
  const tier = await cloudProTopUpFulfillmentTier(args.uid);
  const monthKey = monthKeyForDate(new Date());
  const allowanceRef = db.doc(allowanceDocPath(args.uid, monthKey));
  const receiptID = requiredIdentifier(`${args.source}_${args.externalPaymentID}`, "externalPaymentID");
  const topUpRef = allowanceRef.collection("topups").doc(receiptID);
  const receiptRef = db.doc(cloudProTopUpReceiptDocPath(args.uid, receiptID));
  const allowanceConfig = await loadCloudProAllowanceConfig();
  const topUp = unitsForCloudProTopUp(args.kind, args.quantity, allowanceConfig);
  const fusionDefaults = fusionAllowanceDefaultsForTier(tier, allowanceConfig);

  return db.runTransaction(async (transaction) => {
    const [existingReceipt, existingMonthlyTopUp] = await Promise.all([
      transaction.get(receiptRef),
      transaction.get(topUpRef),
    ]);
    if (existingReceipt.exists || existingMonthlyTopUp.exists) {
      const now = Timestamp.now();
      if (!existingReceipt.exists) {
        const existing = existingMonthlyTopUp.data();
        transaction.set(
          receiptRef,
          stripUndefinedObject({
            uid: args.uid,
            firstMonthKey: typeof existing?.monthKey === "string" ? existing.monthKey : monthKey,
            latestMonthKey: monthKey,
            kind: typeof existing?.kind === "string" ? existing.kind : args.kind,
            meter: typeof existing?.meter === "string" ? existing.meter : topUp.meter,
            units: typeof existing?.units === "number" ? existing.units : topUp.units,
            source: args.source,
            externalPaymentID: args.externalPaymentID,
            externalPaymentIntentID: args.externalPaymentIntentID,
            externalChargeID: args.externalChargeID,
            externalAmountMinor: args.externalAmountMinor,
            externalCurrency: args.externalCurrency,
            quantity: typeof existing?.quantity === "number" ? existing.quantity : (args.quantity ?? 1),
            creditedAt: existing?.creditedAt,
            receiptBackfilledAt: now,
            updatedAt: now,
            schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
          }),
          { merge: true },
        );
      } else {
        transaction.set(
          receiptRef,
          stripUndefinedObject({
            latestMonthKey: monthKey,
            externalPaymentIntentID: args.externalPaymentIntentID,
            externalChargeID: args.externalChargeID,
            externalAmountMinor: args.externalAmountMinor,
            externalCurrency: args.externalCurrency,
            updatedAt: now,
          }),
          { merge: true },
        );
      }
      if (existingMonthlyTopUp.exists) {
        transaction.set(
          topUpRef,
          stripUndefinedObject({
            externalPaymentIntentID: args.externalPaymentIntentID,
            externalChargeID: args.externalChargeID,
            externalAmountMinor: args.externalAmountMinor,
            externalCurrency: args.externalCurrency,
            updatedAt: now,
          }),
          { merge: true },
        );
      }
      return { credited: false, monthKey, units: topUp.units, kind: args.kind };
    }

    const incrementField =
      topUp.meter === "relay_gb"
        ? "topupRelayGBPurchased"
        : topUp.meter === "fusion_searches"
          ? "topupFusionSearchesPurchased"
          : "topupActionsPurchased";
    const now = Timestamp.now();
    transaction.set(
      allowanceRef,
      {
        includedHostedActions: allowanceConfig.includedHostedActionsMonthly,
        includedRelayGB: allowanceConfig.includedRelayGBMonthly,
        includedFusionSearches: fusionDefaults.includedFusionSearches,
        monthlyHostedActionCap: allowanceConfig.monthlyHostedActionCap,
        monthlyRelayGBCap: allowanceConfig.monthlyRelayGBCap,
        monthlyFusionSearchCap: fusionDefaults.monthlyFusionSearchCap,
        [incrementField]: FieldValue.increment(topUp.units),
        updatedAt: now,
        schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
      },
      { merge: true },
    );
    transaction.set(topUpRef, {
      uid: args.uid,
      monthKey,
      kind: args.kind,
      meter: topUp.meter,
      units: topUp.units,
      source: args.source,
      externalPaymentID: args.externalPaymentID,
      externalPaymentIntentID: args.externalPaymentIntentID,
      externalChargeID: args.externalChargeID,
      externalAmountMinor: args.externalAmountMinor,
      externalCurrency: args.externalCurrency,
      quantity: args.quantity ?? 1,
      creditedAt: now,
      schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
    });
    transaction.set(receiptRef, {
      uid: args.uid,
      firstMonthKey: monthKey,
      latestMonthKey: monthKey,
      kind: args.kind,
      meter: topUp.meter,
      units: topUp.units,
      source: args.source,
      externalPaymentID: args.externalPaymentID,
      externalPaymentIntentID: args.externalPaymentIntentID,
      externalChargeID: args.externalChargeID,
      externalAmountMinor: args.externalAmountMinor,
      externalCurrency: args.externalCurrency,
      quantity: args.quantity ?? 1,
      creditedAt: now,
      updatedAt: now,
      schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
    });
    return { credited: true, monthKey, units: topUp.units, kind: args.kind };
  });
}

/**
 * Reconciles the reversible portion of one credited Cloud Pro top-up.
 *
 * Refunds reverse a proportional number of units (rounded up so a partial
 * refund never leaves more paid allowance than the retained payment covers).
 * Open or lost disputes suspend the full top-up. A won/closed/prevented
 * dispute restores units unless a successful refund independently keeps them
 * reversed. Store-provider voids may force a full reversal independently of
 * refund/dispute amount metadata. Used units remain immutable audit history, so the live allowance
 * may become negative until future included/top-up allowance covers it.
 */
export async function reconcileCloudProTopUpReversal(args: {
  uid: string;
  receiptID: string;
  refundedAmountMinor?: number;
  originalAmountMinor?: number;
  disputeStatus?: StripeTopUpDisputeStatus;
  fullReversalReason?: string;
  sourceEventID?: string;
  sourceEventCreatedMillis?: number;
}): Promise<{
  adjusted: boolean;
  reversedUnits: number;
  deltaUnits: number;
  monthKey?: string;
  receiptMissing?: boolean;
}> {
  const receiptRef = db.doc(cloudProTopUpReceiptDocPath(args.uid, args.receiptID));

  return db.runTransaction(async (transaction) => {
    const receiptSnap = await transaction.get(receiptRef);
    const receipt = receiptSnap.data();
    if (!receiptSnap.exists || !receipt) {
      // Webhook delivery is unordered: a refund/dispute can arrive while the
      // paid Checkout event is still creating this receipt. Surface the miss
      // so the caller can retry instead of silently dropping the reversal.
      return { adjusted: false, reversedUnits: 0, deltaUnits: 0, receiptMissing: true };
    }

    const { monthKey, units, meter, priorRefundUnits, priorDisputeUnits, priorReversedUnits } =
      stripeTopUpReceiptState(receipt);
    const originalAmountMinor = stripeTopUpAmount(args.originalAmountMinor, receipt.externalAmountMinor);
    const refundedAmountMinor = stripeTopUpAmount(args.refundedAmountMinor, receipt.refundedAmountMinor);

    const refundReversedUnits =
      args.refundedAmountMinor === undefined
        ? priorRefundUnits
        : proportionalTopUpReversalUnits(units, refundedAmountMinor, originalAmountMinor);
    const disputeReversedUnits = args.disputeStatus
      ? disputeTopUpReversalUnits(units, args.disputeStatus)
      : priorDisputeUnits;
    const forcedReversalUnits = args.fullReversalReason ? units : 0;
    const reversedUnits = Math.max(refundReversedUnits, disputeReversedUnits, forcedReversalUnits);
    const deltaUnits = reversedUnits - priorReversedUnits;
    const allowanceRef = db.doc(allowanceDocPath(args.uid, monthKey));
    const topUpRef = allowanceRef.collection("topups").doc(args.receiptID);
    const incrementField = stripeTopUpIncrementField(meter);
    const now = Timestamp.now();

    if (deltaUnits !== 0) {
      transaction.set(
        allowanceRef,
        {
          [incrementField]: FieldValue.increment(-deltaUnits),
          updatedAt: now,
          schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
        },
        { merge: true },
      );
    }

    const adjustment = stripUndefinedObject({
      refundedAmountMinor,
      originalAmountMinor,
      refundReversedUnits,
      disputeStatus: args.disputeStatus,
      disputeReversedUnits,
      fullReversalReason: args.fullReversalReason,
      forcedReversalUnits,
      reversedUnits,
      reversalState: stripeTopUpReversalState(reversedUnits, units),
      sourceEventID: args.sourceEventID,
      sourceEventCreatedMillis: args.sourceEventCreatedMillis,
      updatedAt: now,
      schemaVersion: CLOUD_PRO_ALLOWANCE_SCHEMA_VERSION,
    });
    transaction.set(receiptRef, adjustment, { merge: true });
    transaction.set(topUpRef, adjustment, { merge: true });

    return {
      adjusted: deltaUnits !== 0,
      reversedUnits,
      deltaUnits,
      monthKey,
    };
  });
}
