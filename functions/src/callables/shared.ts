/**
 * @fileoverview Shared helpers, constants, and provider registry for Cloud Function callables.
 *
 * The implementation has been split into cohesive sibling modules under `./shared/`.
 * This file remains the canonical import surface and re-exports every symbol so existing
 * `import { X } from "../shared"` / "./shared" call sites keep resolving unchanged.
 */

import { defineSecret } from "firebase-functions/params";

import { HOSTED_QUOTA_PROVIDERS } from "./shared/accounts.js";

export const REMOTE_MCP_TOKEN_HMAC_SECRET = defineSecret("REMOTE_MCP_TOKEN_HMAC_SECRET");
export const REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64 = defineSecret("REMOTE_MCP_TOKEN_ED25519_PRIVATE_KEY_BASE64");

export { commitBatchedWrites } from "./shared/firestoreWrites.js";

// ---------------------------------------------------------------------------
// Re-exports — preserve the historical `../shared` / `./shared` import surface.
// ---------------------------------------------------------------------------

export {
  assertProvider,
  nowISO,
  safeIdentifier,
  requiredIdentifier,
  boundedTrimmedString,
  sha256Hex,
  safeCloudDocumentID,
  requireHexDigest,
  requireBoundedNumber,
  requireRecordArray,
  requireTokenHashes,
  requireOptionalSearchHashes,
  cloudVaultAADContext,
  requireSealedText,
  optionalISODateString,
  requireBoundedStringArray,
  parseProjectMemoryFreshness,
  requireCloudVaultBlobEnvelope,
  boundedHttpsURL,
} from "./shared/validators.js";

export {
  assertUserStoragePath,
  encryptedSessionBlobDocumentIDFromStoragePath,
  assertEncryptedSessionBlobObject,
  resolveEncryptedSessionBlobByteCount,
} from "./shared/storage.js";

export {
  ACCOUNT_SCHEMA_VERSION,
  HERMES_SCHEMA_VERSION,
  HERMES_PAIRING_TTL_MS,
  HERMES_MAX_FAILED_PAIRING_ATTEMPTS,
  PI_AGENT_SCHEMA_VERSION,
  PI_AGENT_PAIRING_TTL_MS,
  PI_AGENT_MAX_FAILED_PAIRING_ATTEMPTS,
  writeHermesAuditEvent,
  writePiAgentAuditEvent,
  accountIDFor,
  connectionDocFromAccount,
  assertHostedProvider,
  hostedProviderLabel,
  hostedCredentialKind,
  assertSelfHostedProvider,
} from "./shared/accounts.js";

export {
  BURNBAR_PRO_ENTITLEMENT_ID,
  BURNBAR_PRO_MAX_ENTITLEMENT_ID,
  BURNBAR_ULTRA_ENTITLEMENT_ID,
  assertActiveHostedQuotaEntitlement,
  assertActiveBurnBarProEntitlement,
  assertActiveBurnBarCloudProEntitlement,
  isActiveHostedQuotaEntitlement,
  isActivePremiumEntitlement,
  isActiveBurnBarCloudProEntitlement,
  isActiveBurnBarUltraEntitlement,
  entitlementExpiryMillis,
  writeBurnBarProEntitlement,
  paidEntitlementWriteWouldDowngrade,
  creditCloudProTopUp,
  reconcileCloudProTopUpReversal,
} from "./shared/entitlements.js";

export {
  STRIPE_API_SECRETS,
  STRIPE_WEBHOOK_SECRETS,
  requireConfiguredStripe,
  requireConfiguredStripeWebhookSecret,
  getOrCreateStripeCustomer,
  applyStripeCheckoutSession,
  applyStripeSubscription,
  reconcileStripeInvoice,
  reconcileStripeCharge,
  reconcileStripeRefund,
  reconcileStripeDispute,
  reconcileStripeCreditNote,
  deactivateStripeCustomerEntitlements,
  assertStripeCustomerCanStartSubscriptionCheckout,
  findReusableStripeSubscriptionCheckoutSession,
  expireOpenStripeSubscriptionCheckoutSessions,
} from "./shared/stripe.js";

export { GOOGLE_PLAY_ACTIVE_STATES, selectGooglePlaySubscriptionLineItem } from "./shared/googlePlay.js";

export {
  normalizeCloudConnectAuthMethodID,
  normalizeHostedCredential,
  sanitizeUploadedQuotaSnapshot,
  writePrivateSecretRef,
  connectProviderAccountInternal,
  checkRefreshRateLimit,
  checkHermesRateLimit,
  checkPiAgentRateLimit,
} from "./shared/providerConnect.js";

// Side effect preserved from the original module: claude-code becomes a hosted
// quota provider at import time.
HOSTED_QUOTA_PROVIDERS.add("claude-code");
