/**
 * Single source of truth for OpenBurnBar entitlement product IDs.
 *
 * Historically this catalog was implemented 4–9 independent ways (firestore.rules
 * x3, two same-named functions in the functions package, the hosted-MCP service,
 * the realtime relay, and Swift/Kotlin clients), held coherent only by a dual-write
 * convention. This module is the FIRST consolidation seam: the product-ID constants
 * and the Firestore-doc active-state predicate now live in exactly one place and are
 * imported by the Node consumers (functions/relay/hosted-mcp).
 *
 * These string literals are the SHIPPED App Store / Google Play product IDs and the
 * compiled-in defaults of `functions/src/config.ts`. The backend allows overriding
 * each ID via env / remote config at runtime, so the predicate accepts an injected
 * {@link EntitlementCatalog}; callers that have resolved their runtime config pass
 * their resolved IDs, and the predicate still matches. Callers without overrides use
 * {@link DEFAULT_ENTITLEMENT_CATALOG}.
 */

/** Canonical App Store (Apple) product IDs. Defaults of `functions/src/config.ts`. */
export const APPLE_PRODUCT_IDS = {
  hostedQuota: "com.openburnbar.hostedQuotaSync.cloud.monthly",
  proMonthly: "com.openburnbar.pro.monthly",
  proAnnual: "com.openburnbar.pro.annual",
  proMaxMonthly: "com.openburnbar.proMax.v2.monthly",
  proMaxAnnual: "com.openburnbar.proMax.annual",
  ultraMonthly: "com.openburnbar.ultra.monthly",
  ultraAnnual: "com.openburnbar.ultra.annual.v2",
} as const;

/** Canonical Google Play product IDs. Defaults of `functions/src/config.ts`. */
export const GOOGLE_PLAY_PRODUCT_IDS = {
  proMonthly: "com.openburnbar.pro.monthly",
  proAnnual: "com.openburnbar.pro.annual",
  cloudProMonthly: "com.openburnbar.promax.v2.monthly",
  cloudProAnnual: "com.openburnbar.promax.annual",
  ultraMonthly: "com.openburnbar.ultra.monthly",
  ultraAnnual: "com.openburnbar.ultra.annual",
} as const;

/**
 * Cloud-Pro (proMax) product-ID aliases. The proMax SKU shipped under several
 * historical bundle identifiers; receipts minted under any of these still grant
 * Cloud Pro. Kept verbatim from `functions/src/callables/shared.ts`.
 */
export const BURNBAR_CLOUD_PRO_PRODUCT_ALIASES = [
  "com.openburnbar.proMax.v2.monthly",
  "com.openburnbar.proMax.annual",
  "com.openburnbar.promax.v2.monthly",
  "com.openburnbar.promax.annual",
  "com.openburnbar.proMax.bundle.monthly",
] as const;

/** Firestore entitlement document IDs (the doc id under `users/{uid}/entitlements/`). */
export const ENTITLEMENT_DOC_IDS = {
  pro: "burnbar_pro",
  proMax: "burnbar_pro_max",
  ultra: "burnbar_ultra",
  hostedQuotaSync: "hosted_quota_sync",
} as const;

/**
 * The entitlement features a consumer can gate on. Each maps to the set of product
 * IDs whose active receipt grants the feature.
 *
 * - `hostedQuota`  — Hosted Quota Sync only.
 * - `premium`      — "BurnBar Pro" floor: any paid SKU (Pro, Cloud Pro/proMax, Ultra,
 *                    Hosted Quota Sync) grants it. Matches `isActivePremiumEntitlement`.
 * - `cloudPro`     — Cloud Pro / proMax tier (Floo + hosted Agent Control).
 * - `ultra`        — Ultra tier (10x Pensieve limits).
 */
export type EntitlementFeature = "hostedQuota" | "premium" | "cloudPro" | "ultra";

/**
 * A resolved catalog of product IDs. {@link DEFAULT_ENTITLEMENT_CATALOG} is the
 * compiled-in default; backends with env/remote-config overrides build one from
 * their resolved config and pass it to {@link isActiveEntitlement}.
 */
export interface EntitlementCatalog {
  hostedQuotaProductID: string;
  burnBarProProductID: string;
  burnBarProAnnualProductID: string;
  burnBarProMaxProductID: string;
  burnBarProMaxAnnualProductID: string;
  burnBarUltraProductID: string;
  burnBarUltraAnnualProductID: string;
  googlePlaySubscriptionProductID: string;
  googlePlayCloudMonthlyProductID: string;
  googlePlayCloudAnnualProductID: string;
  googlePlayCloudProMonthlyProductID: string;
  googlePlayCloudProAnnualProductID: string;
  googlePlayUltraMonthlyProductID: string;
  googlePlayUltraAnnualProductID: string;
}

/** Compiled-in default catalog — identical to `functions/src/config.ts` fallbacks. */
export const DEFAULT_ENTITLEMENT_CATALOG: EntitlementCatalog = {
  hostedQuotaProductID: APPLE_PRODUCT_IDS.hostedQuota,
  burnBarProProductID: APPLE_PRODUCT_IDS.proMonthly,
  burnBarProAnnualProductID: APPLE_PRODUCT_IDS.proAnnual,
  burnBarProMaxProductID: APPLE_PRODUCT_IDS.proMaxMonthly,
  burnBarProMaxAnnualProductID: APPLE_PRODUCT_IDS.proMaxAnnual,
  burnBarUltraProductID: APPLE_PRODUCT_IDS.ultraMonthly,
  burnBarUltraAnnualProductID: APPLE_PRODUCT_IDS.ultraAnnual,
  googlePlaySubscriptionProductID: GOOGLE_PLAY_PRODUCT_IDS.proMonthly,
  googlePlayCloudMonthlyProductID: GOOGLE_PLAY_PRODUCT_IDS.proMonthly,
  googlePlayCloudAnnualProductID: GOOGLE_PLAY_PRODUCT_IDS.proAnnual,
  googlePlayCloudProMonthlyProductID: GOOGLE_PLAY_PRODUCT_IDS.cloudProMonthly,
  googlePlayCloudProAnnualProductID: GOOGLE_PLAY_PRODUCT_IDS.cloudProAnnual,
  googlePlayUltraMonthlyProductID: GOOGLE_PLAY_PRODUCT_IDS.ultraMonthly,
  googlePlayUltraAnnualProductID: GOOGLE_PLAY_PRODUCT_IDS.ultraAnnual,
};

/**
 * Returns the set of product IDs that grant `feature` under `catalog`. The aliases
 * are always merged in for the `premium` and `cloudPro` features (Cloud Pro receipts
 * grant both the Cloud-Pro tier and the broader premium floor).
 */
export function productIDsForFeature(
  feature: EntitlementFeature,
  catalog: EntitlementCatalog = DEFAULT_ENTITLEMENT_CATALOG,
): Set<string> {
  switch (feature) {
    case "hostedQuota":
      return new Set([catalog.hostedQuotaProductID]);
    case "premium":
      return new Set([
        catalog.hostedQuotaProductID,
        catalog.burnBarProProductID,
        catalog.burnBarProAnnualProductID,
        catalog.burnBarProMaxProductID,
        catalog.burnBarProMaxAnnualProductID,
        catalog.googlePlaySubscriptionProductID,
        catalog.googlePlayCloudMonthlyProductID,
        catalog.googlePlayCloudAnnualProductID,
        catalog.googlePlayCloudProMonthlyProductID,
        catalog.googlePlayCloudProAnnualProductID,
        ...BURNBAR_CLOUD_PRO_PRODUCT_ALIASES,
      ]);
    case "cloudPro":
      return new Set([
        catalog.burnBarProMaxProductID,
        catalog.burnBarProMaxAnnualProductID,
        catalog.googlePlayCloudProMonthlyProductID,
        catalog.googlePlayCloudProAnnualProductID,
        ...BURNBAR_CLOUD_PRO_PRODUCT_ALIASES,
      ]);
    case "ultra":
      return new Set([
        catalog.burnBarUltraProductID,
        catalog.burnBarUltraAnnualProductID,
        catalog.googlePlayUltraMonthlyProductID,
        catalog.googlePlayUltraAnnualProductID,
      ]);
  }
}
