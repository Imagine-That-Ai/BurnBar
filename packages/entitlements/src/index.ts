export {
  APPLE_PRODUCT_IDS,
  GOOGLE_PLAY_PRODUCT_IDS,
  MEDIA_PRODUCT_IDS,
  COMPUTER_USE_PRODUCT_IDS,
  LEGACY_PRODUCT_IDS,
  PRO_MAX_BUNDLE_MONTHLY_PRODUCT_ID,
  BURNBAR_CLOUD_PRO_PRODUCT_ALIASES,
  FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS,
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
