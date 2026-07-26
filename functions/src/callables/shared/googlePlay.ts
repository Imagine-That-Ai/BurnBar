/**
 * @fileoverview Google Play subscription catalog and entitlement helpers.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { getConfig } from "../../config.js";
import { jsonObject } from "../../guards.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
} from "./entitlements.js";

export const GOOGLE_PLAY_ACTIVE_STATES = new Set<string>([
  "SUBSCRIPTION_STATE_ACTIVE",
  "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
  // A user who turns off renewal keeps access until the paid-through expiry.
  "SUBSCRIPTION_STATE_CANCELED",
]);

interface GooglePlaySubscriptionEntitlementTarget {
  entitlementID: string;
  canonicalProductID: string;
  tierRank: number;
}

interface GooglePlaySubscriptionSelection {
  lineItem: Record<string, unknown>;
  target: GooglePlaySubscriptionEntitlementTarget;
  expiresAtMillis: number;
}

function googlePlaySubscriptionEntitlement(productID: string): GooglePlaySubscriptionEntitlementTarget {
  const cfg = getConfig();
  const cloudProductIDs = new Set([
    cfg.googlePlaySubscriptionProductID,
    cfg.googlePlayCloudMonthlyProductID,
    cfg.googlePlayCloudAnnualProductID,
    cfg.burnBarProProductID,
    cfg.burnBarProAnnualProductID,
  ]);
  const cloudProProductIDs = new Set([
    cfg.googlePlayCloudProMonthlyProductID,
    cfg.googlePlayCloudProAnnualProductID,
    cfg.burnBarProMaxProductID,
    cfg.burnBarProMaxAnnualProductID,
  ]);
  const ultraProductIDs = new Set([
    cfg.googlePlayUltraMonthlyProductID,
    cfg.googlePlayUltraAnnualProductID,
    cfg.burnBarUltraProductID,
    cfg.burnBarUltraAnnualProductID,
  ]);
  if (cloudProductIDs.has(productID)) {
    return {
      entitlementID: BURNBAR_PRO_ENTITLEMENT_ID,
      canonicalProductID: productID,
      tierRank: 1,
    };
  }
  if (cloudProProductIDs.has(productID)) {
    return {
      entitlementID: BURNBAR_PRO_MAX_ENTITLEMENT_ID,
      canonicalProductID: productID,
      tierRank: 2,
    };
  }
  if (ultraProductIDs.has(productID)) {
    return {
      entitlementID: BURNBAR_ULTRA_ENTITLEMENT_ID,
      canonicalProductID: productID,
      tierRank: 3,
    };
  }
  throw new HttpsError("invalid-argument", "Unsupported Google Play subscription product.");
}

function googlePlayExpiryMillisOrUndefined(lineItem: Record<string, unknown>): number | undefined {
  const expiryTime = lineItem.expiryTime;
  if (typeof expiryTime !== "string") return undefined;
  const parsed = Date.parse(expiryTime);
  return Number.isFinite(parsed) ? parsed : undefined;
}

function entitlementTargetOrUndefined(productID: string): GooglePlaySubscriptionEntitlementTarget | undefined {
  try {
    return googlePlaySubscriptionEntitlement(productID);
  } catch {
    return undefined;
  }
}

/**
 * Selects the authoritative supported line item from a subscriptionsv2 response.
 *
 * The RTDN product ID is preferred when present. Otherwise the client-claimed
 * product is preferred, then the longest-lived supported tier wins.
 */
export function selectGooglePlaySubscriptionLineItem(
  purchase: Record<string, unknown>,
  preferredProductIDs: readonly string[] = [],
): GooglePlaySubscriptionSelection {
  const candidates = (Array.isArray(purchase.lineItems) ? purchase.lineItems : [])
    .map((raw) => jsonObject(raw))
    .map((lineItem) => {
      const productID = typeof lineItem.productId === "string" ? lineItem.productId : undefined;
      const expiresAtMillis = googlePlayExpiryMillisOrUndefined(lineItem);
      if (!productID || expiresAtMillis === undefined) return undefined;
      const target = entitlementTargetOrUndefined(productID);
      return target ? { lineItem, target, expiresAtMillis } : undefined;
    })
    .filter((candidate): candidate is GooglePlaySubscriptionSelection => candidate !== undefined);

  for (const preferredProductID of preferredProductIDs) {
    const preferred = candidates
      .filter((candidate) => candidate.target.canonicalProductID === preferredProductID)
      .sort((left, right) => right.expiresAtMillis - left.expiresAtMillis)[0];
    if (preferred) return preferred;
  }

  const selected = candidates.sort(
    (left, right) => right.expiresAtMillis - left.expiresAtMillis || right.target.tierRank - left.target.tierRank,
  )[0];
  if (!selected) {
    throw new HttpsError("failed-precondition", "Google Play did not return a supported subscription line item.");
  }
  return selected;
}
