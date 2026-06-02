import { Timestamp } from "firebase-admin/firestore";

import { getConfig } from "./config.js";
import { isTimestampWithToMillis } from "./guards.js";

const BURNBAR_CLOUD_PRO_PRODUCT_ALIASES = new Set([
  "com.openburnbar.proMax.v2.monthly",
  "com.openburnbar.proMax.annual",
  "com.openburnbar.promax.v2.monthly",
  "com.openburnbar.promax.annual",
  "com.openburnbar.proMax.bundle.monthly",
]);

export function isProductionEntitlementEnvironment(raw: Record<string, unknown>): boolean {
  return raw.environment === "Production";
}

export function isActiveHostedQuotaEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  if (!isProductionEntitlementEnvironment(raw)) return false;
  if (raw.productID !== getConfig().hostedQuotaProductID) return false;
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

export function isActivePremiumEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  if (!isProductionEntitlementEnvironment(raw)) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  const cfg = getConfig();
  if (
    productID !== cfg.hostedQuotaProductID &&
    productID !== cfg.burnBarProProductID &&
    productID !== cfg.burnBarProAnnualProductID &&
    productID !== cfg.burnBarProMaxProductID &&
    productID !== cfg.burnBarProMaxAnnualProductID &&
    productID !== cfg.googlePlaySubscriptionProductID &&
    productID !== cfg.googlePlayCloudMonthlyProductID &&
    productID !== cfg.googlePlayCloudAnnualProductID &&
    productID !== cfg.googlePlayCloudProMonthlyProductID &&
    productID !== cfg.googlePlayCloudProAnnualProductID &&
    !BURNBAR_CLOUD_PRO_PRODUCT_ALIASES.has(productID)
  ) {
    return false;
  }
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

export function isActiveBurnBarCloudProEntitlement(raw: Record<string, unknown> | undefined): boolean {
  if (!raw || raw.active !== true) return false;
  if (!isProductionEntitlementEnvironment(raw)) return false;
  const productID = typeof raw.productID === "string" ? raw.productID : "";
  const cfg = getConfig();
  if (
    productID !== cfg.burnBarProMaxProductID &&
    productID !== cfg.burnBarProMaxAnnualProductID &&
    productID !== cfg.googlePlayCloudProMonthlyProductID &&
    productID !== cfg.googlePlayCloudProAnnualProductID &&
    !BURNBAR_CLOUD_PRO_PRODUCT_ALIASES.has(productID)
  ) {
    return false;
  }
  const expiry = entitlementExpiryMillis(raw);
  return Number.isFinite(expiry) && expiry > Date.now();
}

export function entitlementExpiryMillis(raw: Record<string, unknown>): number {
  const expireAt = raw.expireAt;
  if (expireAt instanceof Timestamp) {
    return expireAt.toMillis();
  }
  if (isTimestampWithToMillis(expireAt)) {
    return expireAt.toMillis();
  }
  if (raw.expiresAt) {
    const parsed = Date.parse(String(raw.expiresAt));
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}
