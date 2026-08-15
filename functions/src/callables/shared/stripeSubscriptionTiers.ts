/**
 * @fileoverview Stripe subscription → BurnBar entitlement tier resolution and
 * plan-change cleanup. Maps a subscription's CURRENT price items to the tier
 * it grants, resolves the matching product id, and deactivates the tier docs
 * a Billing Portal plan change left behind on the same subscription.
 */

import Stripe from "stripe";

import { getConfig } from "../../config.js";
import { db } from "../../adminRuntime.js";
import {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  writeBurnBarProEntitlement,
} from "./entitlements.js";

function stripeSubscriptionPriceIDs(subscription: Stripe.Subscription): Set<string> {
  return new Set(
    subscription.items?.data
      ?.map((item) => item.price?.id)
      .filter((priceID): priceID is string => typeof priceID === "string") || [],
  );
}

/**
 * Resolves the entitlement tier from the subscription's CURRENT price items.
 * Checkout stamps `metadata.entitlementID` at purchase time, but a Billing
 * Portal plan change swaps the price without rewriting that metadata, so a
 * Cloud→Ultra upgrade would keep granting burnbar_pro (and a downgrade would
 * keep granting Ultra) if the metadata were authoritative. The metadata is
 * only used as a fallback when no configured price matches.
 */
export function stripeSubscriptionEntitlementID(subscription: Stripe.Subscription): string {
  const cfg = getConfig();
  const priceIDs = stripeSubscriptionPriceIDs(subscription);
  const hasPrice = (priceID: string | undefined): boolean => Boolean(priceID && priceIDs.has(priceID));
  if (hasPrice(cfg.stripeBurnBarUltraMonthlyPriceID) || hasPrice(cfg.stripeBurnBarUltraAnnualPriceID)) {
    return BURNBAR_ULTRA_ENTITLEMENT_ID;
  }
  if (hasPrice(cfg.stripeBurnBarCloudProMonthlyPriceID) || hasPrice(cfg.stripeBurnBarCloudProAnnualPriceID)) {
    return BURNBAR_PRO_MAX_ENTITLEMENT_ID;
  }
  if (
    hasPrice(cfg.stripeBurnBarCloudMonthlyPriceID) ||
    hasPrice(cfg.stripeBurnBarCloudAnnualPriceID) ||
    hasPrice(cfg.stripeBurnBarProPriceID)
  ) {
    return BURNBAR_PRO_ENTITLEMENT_ID;
  }
  const metadataEntitlementID = subscription.metadata?.entitlementID;
  if (metadataEntitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID) return BURNBAR_ULTRA_ENTITLEMENT_ID;
  if (metadataEntitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID) return BURNBAR_PRO_MAX_ENTITLEMENT_ID;
  return BURNBAR_PRO_ENTITLEMENT_ID;
}

/**
 * Deactivates the other tiers' entitlement docs that are still backed by this
 * exact subscription after a plan change. Runs before the current tier's
 * write; each deactivation reuses the doc's own source string so the
 * same-source downgrade guard permits the active→inactive transition, while
 * entitlements from other subscriptions, tokens, or platforms are untouched.
 */
export async function deactivateReplacedStripeTierEntitlements(
  uid: string,
  subscription: Stripe.Subscription,
  currentEntitlementID: string,
  customerID: string | undefined,
  eventContext: { eventID?: string; eventCreatedMillis?: number },
): Promise<void> {
  const retained = new Set<string>([currentEntitlementID]);
  // Ultra dual-writes a burnbar_pro_max mirror; the current write refreshes it.
  if (currentEntitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID) retained.add(BURNBAR_PRO_MAX_ENTITLEMENT_ID);
  const replaced = [BURNBAR_PRO_ENTITLEMENT_ID, BURNBAR_PRO_MAX_ENTITLEMENT_ID, BURNBAR_ULTRA_ENTITLEMENT_ID].filter(
    (entitlementID) => !retained.has(entitlementID),
  );
  for (const entitlementID of replaced) {
    const snap = await db.doc(`users/${uid}/entitlements/${entitlementID}`).get();
    const existing = snap.data();
    if (!existing || existing.active !== true) continue;
    if (existing.externalSubscriptionID !== subscription.id) continue;
    await writeBurnBarProEntitlement({
      uid,
      productID: stripeEntitlementProductID(existing, entitlementID),
      expiresAtMillis: stripeEntitlementExpiryMillis(existing),
      source: typeof existing.source === "string" ? existing.source : "stripe_webhook_verified",
      platform: "stripe",
      entitlementID,
      externalSubscriptionID: subscription.id,
      externalCustomerID: customerID,
      rawStatus: "replaced_by_plan_change",
      environment: "Production",
      activeOverride: false,
      sourceEventID: eventContext.eventID,
      sourceEventCreatedMillis: eventContext.eventCreatedMillis,
    });
  }
}

export function stripeSubscriptionProductID(subscription: Stripe.Subscription, entitlementID: string): string {
  const cfg = getConfig();
  const priceIDs = stripeSubscriptionPriceIDs(subscription);
  if (cfg.stripeBurnBarCloudAnnualPriceID && priceIDs.has(cfg.stripeBurnBarCloudAnnualPriceID)) {
    return cfg.burnBarProAnnualProductID;
  }
  if (cfg.stripeBurnBarCloudProMonthlyPriceID && priceIDs.has(cfg.stripeBurnBarCloudProMonthlyPriceID)) {
    return cfg.burnBarProMaxProductID;
  }
  if (cfg.stripeBurnBarCloudProAnnualPriceID && priceIDs.has(cfg.stripeBurnBarCloudProAnnualPriceID)) {
    return cfg.burnBarProMaxAnnualProductID;
  }
  if (cfg.stripeBurnBarUltraMonthlyPriceID && priceIDs.has(cfg.stripeBurnBarUltraMonthlyPriceID)) {
    return cfg.burnBarUltraProductID;
  }
  if (cfg.stripeBurnBarUltraAnnualPriceID && priceIDs.has(cfg.stripeBurnBarUltraAnnualPriceID)) {
    return cfg.burnBarUltraAnnualProductID;
  }
  if (entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID) return cfg.burnBarUltraProductID;
  return entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID ? cfg.burnBarProMaxProductID : cfg.burnBarProProductID;
}

export function stripeEntitlementProductID(entitlement: Record<string, unknown>, entitlementID: string): string {
  if (typeof entitlement.productID === "string" && entitlement.productID.length > 0) {
    return entitlement.productID;
  }
  const cfg = getConfig();
  if (entitlementID === BURNBAR_ULTRA_ENTITLEMENT_ID) return cfg.burnBarUltraProductID;
  if (entitlementID === BURNBAR_PRO_MAX_ENTITLEMENT_ID) return cfg.burnBarProMaxProductID;
  return cfg.burnBarProProductID;
}

export function stripeEntitlementExpiryMillis(entitlement: Record<string, unknown>): number {
  const expireAt = entitlement.expireAt;
  if (expireAt && typeof expireAt === "object" && "toMillis" in expireAt && typeof expireAt.toMillis === "function") {
    const millis = expireAt.toMillis();
    if (Number.isFinite(millis)) return millis;
  }
  if (typeof entitlement.expiresAt === "string") {
    const millis = Date.parse(entitlement.expiresAt);
    if (Number.isFinite(millis)) return millis;
  }
  return Date.now() - 1;
}
