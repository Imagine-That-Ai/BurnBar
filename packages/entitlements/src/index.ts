export {
  APPLE_PRODUCT_IDS,
  GOOGLE_PLAY_PRODUCT_IDS,
  BURNBAR_CLOUD_PRO_PRODUCT_ALIASES,
  ENTITLEMENT_DOC_IDS,
  DEFAULT_ENTITLEMENT_CATALOG,
  productIDsForFeature,
  type EntitlementCatalog,
  type EntitlementFeature,
} from "./catalog.js";

export {
  entitlementExpiryMillis,
  evaluateEntitlement,
  isActiveEntitlement,
  type EntitlementEvaluation,
} from "./predicate.js";

export { EntitlementCache, type EntitlementCacheOptions } from "./cache.js";
