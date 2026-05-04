/**
 * @fileoverview App Store JWS verification public exports.
 *
 * Stable surface used by `functions/src/index.ts` to register callables
 * and webhooks; everything else is internal to this directory.
 */

export {
  beginEntitlementBinding,
  verifyHostedQuotaEntitlement,
  restoreHostedQuotaEntitlement,
} from "./callable.js";

export { appStoreServerNotificationsV2 } from "./notifications.js";

export { reconcileHostedEntitlementsDaily } from "./scheduled.js";

export {
  AppleJWSVerifier,
  getAppleJWSVerifier,
  JWSVerificationFailure,
  loadAppleRootCertificates,
  ROOT_CERT_FILES,
} from "./verifier.js";

export {
  reconcileEntitlement,
  beginBinding,
  EntitlementReconcileError,
} from "./reconciler.js";

export {
  fetchLiveSubscriptionStatus,
  fetchLatestTransactionInfo,
} from "./client.js";

export { appendEntitlementEvent } from "./audit.js";
