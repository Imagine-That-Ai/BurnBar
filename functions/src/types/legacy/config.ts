/**
 * @fileoverview Shared TypeScript types for OpenBurnBar Cloud Functions v2.
 *
 * Extracted from src/types/legacy.ts (the strangler "leftovers" bucket) and
 * grouped by domain. Re-exported verbatim from src/types/legacy.ts so every
 * existing `import ... from "../types/legacy"` keeps resolving unchanged.
 */

import type { CredentialKind, Provider } from "./providers.js";
import type { QuotaSnapshotDoc } from "./quota-usage.js";

// ---------------------------------------------------------------------------
// Provider adapter contract
// ---------------------------------------------------------------------------

/** Result of testing a credential against a provider endpoint. */
export interface CredentialTestResult {
  /** Whether the credential is valid and active. */
  valid: boolean;

  /** Redacted label to store in Firestore (no secrets). */
  redactedLabel: string;

  /** Credential kind inferred from the raw value. */
  credentialKind: CredentialKind;

  /** Human-readable error code if invalid. */
  errorCode?: string;

  /** Human-readable message if invalid. */
  errorMessage?: string;

  /** Warning to surface to the user (e.g. short TTL). */
  warningMessage?: string;
}

/** Result of a quota refresh against a provider. */
export interface QuotaRefreshResult {
  /** Whether the refresh succeeded. */
  ok: boolean;

  /** Snapshot document to write (only when ok === true). */
  snapshot?: Omit<QuotaSnapshotDoc, "schemaVersion" | "updatedAt">;

  /** Error code on failure. */
  errorCode?: string;

  /** Error message on failure. */
  errorMessage?: string;
}

export type ProviderAccountConnectContext = import("../generated/provider-account.js").ProviderAccountConnectContext;

/** Every provider adapter must satisfy this interface. */
export interface ProviderAdapter {
  readonly provider: Provider;

  /** Test a raw credential without storing it. */
  testCredential(credential: string, accountContext?: ProviderAccountConnectContext): Promise<CredentialTestResult>;

  /** Fetch current quota using the decrypted credential. */
  fetchQuota(credential: string, sourceId: string, accountContext?: ProviderAccountConnectContext): Promise<QuotaRefreshResult>;
}

// ---------------------------------------------------------------------------
// Runtime configuration shapes
// ---------------------------------------------------------------------------

export interface EnvConfig {
  /** GCP project id. */
  projectId: string;

  /** KMS key name for envelope encryption (projects/…/locations/…/keyRings/…/cryptoKeys/…). */
  kmsKeyName: string;

  /** Firebase app check enforcement (default true). */
  enforceAppCheck: boolean;

  /** Require a single-use high-risk action nonce on high-risk callables (default false; staged rollout). */
  requireHighRiskNonce: boolean;

  /**
   * App Check app ids permitted to mint / carry a lower-trust desktop App Check token.
   * Always includes the Linux and Windows placeholder app ids; extra ids can be added via
   * `APP_CHECK_ALLOWED_APP_IDS` / `openburnbar.app_check_allowed_app_ids`. This
   * allowlist gates the greenfield desktop mint paths only — it deliberately does
   * NOT gate the existing Apple/Android/Web appId-equality binding (see appCheckAttestation.ts),
   * so Apple clients are unaffected.
   */
  allowedAppCheckAppIDs: string[];

  /**
   * Placeholder / non-prod Firebase App Check app id used by the Windows port
   * until the real Windows app id is provisioned (AC-012/AC-013). Never a prod id.
   */
  windowsAppCheckAppID: string;

  /**
   * Firebase App Check app id used by the Linux port. Non-production projects
   * may use the placeholder fixture; production requires a provisioned Web app
   * id and the config builder rejects the placeholder or malformed values.
   */
  linuxAppCheckAppID: string;

  /**
   * Whether the MOCK desktop attestation verifier may be registered. True only in
   * non-production (emulator/demo/test/dev) config; FORCED false in production so a
   * mock/unverified attestation claim can never mint a real App Check token. This is
   * the attestation gate — the mint endpoints themselves stay available for future
   * real platform verifiers (no blanket `if(prod) disable-endpoint`).
   */
  allowMockAppCheckAttestation: boolean;

  /** HTTPS endpoint for the Windows-hosted NCryptVerifyClaim service. */
  windowsTpmVerifierURL: string;

  /** Maximum credential string length (default 8192). */
  maxCredentialLength: number;

  /** Rate-limit window in seconds for refreshProviderQuota (default 60). */
  refreshRateLimitSeconds: number;

  /** Max dirty rollup jobs the scheduler enqueues per tick (default 1000). */
  rollupBatchSize: number;

  /** Page size for raw-usage counter repair rebuilds (default 500). */
  rollupRepairPageSize: number;

  /** Consecutive full-rebuild failures before pausing repair attempts (default 3). */
  rollupMaxConsecutiveFullRebuildFailures: number;

  /** Minutes to pause a user's full-rebuild repair after the breaker opens (default 60). */
  rollupFullRebuildCircuitBreakerMinutes: number;

  /** Minimum minutes between client `force` full rebuilds per user (default 10). */
  rollupForceRebuildMinIntervalMinutes: number;

  /** Max pending-delta queue pages drained per invocation (default 20 = 2,000 docs). */
  rollupPendingDeltaDrainMaxPages: number;

  /** Max batch size for scheduled quota refresh (default 20). */
  quotaRefreshBatchSize: number;

  /** StoreKit product ID that unlocks hosted quota sync. */
  hostedQuotaProductID: string;

  /** Canonical premium bundle entitlement doc id/product id. */
  burnBarProProductID: string;

  /** Annual BurnBar Cloud product id. */
  burnBarProAnnualProductID: string;

  /** Canonical Cloud Pro product id. */
  burnBarProMaxProductID: string;

  /** Annual Cloud Pro product id. */
  burnBarProMaxAnnualProductID: string;

  /** Monthly Ultra product id (Pensieve 10x limits; mirrors Cloud Pro). */
  burnBarUltraProductID: string;

  /** Annual Ultra product id. */
  burnBarUltraAnnualProductID: string;

  /** Agent Control hosted-action top-up product id. */
  agentControl100ActionsProductID: string;

  /** Floo relay-accounting top-up product id. */
  flooRelay50GBProductID: string;

  /** Elder Wand Fusion 100 hosted-search top-up product id. */
  elderWandSearches100ProductID: string;

  /** Elder Wand Fusion 500 hosted-search top-up product id. */
  elderWandSearches500ProductID: string;

  /** Compatibility Stripe price id for macOS/web BurnBar Cloud monthly checkout. */
  stripeBurnBarProPriceID: string;

  /** Stripe price id for BurnBar Cloud monthly checkout. */
  stripeBurnBarCloudMonthlyPriceID: string;

  /** Stripe price id for BurnBar Cloud annual checkout. */
  stripeBurnBarCloudAnnualPriceID: string;

  /** Stripe price id for BurnBar Cloud Pro monthly checkout. */
  stripeBurnBarCloudProMonthlyPriceID: string;

  /** Stripe price id for BurnBar Cloud Pro annual checkout. */
  stripeBurnBarCloudProAnnualPriceID: string;

  /** Stripe price id for BurnBar Ultra monthly checkout. */
  stripeBurnBarUltraMonthlyPriceID: string;

  /** Stripe price id for BurnBar Ultra annual checkout. */
  stripeBurnBarUltraAnnualPriceID: string;

  /** Stripe price id for 100 hosted Agent Control action top-up. */
  stripeAgentControl100ActionsPriceID: string;

  /** Stripe price id for 50 GB Floo relay top-up. */
  stripeFlooRelay50GBPriceID: string;

  /** Stripe price id for 100 hosted Elder Wand Fusion searches. */
  stripeElderWandSearches100PriceID: string;

  /** Stripe price id for 500 hosted Elder Wand Fusion searches. */
  stripeElderWandSearches500PriceID: string;

  /** Exact non-loopback hostname[:port] values allowed for Stripe browser redirects. */
  stripeRedirectURLAllowlist: string[];

  /** Stripe secret key for macOS/web BurnBar Pro checkout and webhook reads. */
  stripeSecretKey: string;

  /** Stripe webhook signing secret for subscription entitlement updates. */
  stripeWebhookSecret: string;

  /** Google Play package name used for Android subscription verification. */
  googlePlayPackageName: string;

  /** Google Play subscription product id for BurnBar Pro. */
  googlePlaySubscriptionProductID: string;

  /** Google Play BurnBar Cloud monthly product id. */
  googlePlayCloudMonthlyProductID: string;

  /** Google Play BurnBar Cloud annual product id. */
  googlePlayCloudAnnualProductID: string;

  /** Google Play BurnBar Cloud Pro monthly product id. */
  googlePlayCloudProMonthlyProductID: string;

  /** Google Play BurnBar Cloud Pro annual product id. */
  googlePlayCloudProAnnualProductID: string;

  /** Google Play Ultra monthly product id. */
  googlePlayUltraMonthlyProductID: string;

  /** Google Play Ultra annual product id. */
  googlePlayUltraAnnualProductID: string;

  /** Google Play Agent Control hosted-action top-up product id. */
  googlePlayAgentControl100ActionsProductID: string;

  /** Google Play Floo relay-accounting top-up product id. */
  googlePlayFlooRelay50GBProductID: string;

  /** Google Play Elder Wand Fusion 100 hosted-search top-up product id. */
  googlePlayElderWandSearches100ProductID: string;

  /** Google Play Elder Wand Fusion 500 hosted-search top-up product id. */
  googlePlayElderWandSearches500ProductID: string;

  /** Max encrypted session blob upload size in bytes. */
  encryptedSessionBlobMaxBytes: number;

  /** HTTPS endpoint for the paid hosted quota runner. */
  hostedQuotaRunnerURL: string;

  hostedQuotaRunnerAllowedHosts: string[];

  /** Shared bearer token used between Functions and the hosted quota runner. */
  hostedQuotaRunnerToken: string;

  /** Daily hosted-runner attempt ceiling per account. */
  hostedQuotaDailyRefreshLimit: number;

  /** Monthly hosted-runner attempt ceiling per account. */
  hostedQuotaMonthlyRefreshLimit: number;

  /** App Store verification config. */
  appStore: AppStoreConfig;
}

// ---------------------------------------------------------------------------
// App Store hosted quota entitlement docs
// ---------------------------------------------------------------------------

export type AppStoreEnvironment = "Production" | "Sandbox" | "Xcode" | "LocalTesting";

export interface AppStoreConfig {
  bundleId: string;
  appAppleId?: number;
  environment: AppStoreEnvironment;
  enableOnlineChecks: boolean;
  autoFallbackEnvironment: boolean;
  asc: {
    issuerId: string;
    keyId: string;
    privateKeyP8: string;
  };
}

export type EntitlementOwnershipType = "PURCHASED" | "FAMILY_SHARED";

export type HostedQuotaEntitlementSource = "apple_jws_verified" | "apple_s2s" | "scheduled_reconcile";

export interface HostedQuotaEntitlementDoc {
  id: string;
  active: boolean;
  productID: string;
  transactionID: string;
  originalTransactionID: string;
  expiresAt?: string;
  expireAt?: import("firebase-admin/firestore").Timestamp;
  revokedAt?: string;
  revocationReason?: number;
  environment: AppStoreEnvironment;
  ownershipType?: EntitlementOwnershipType;
  appAccountToken?: string;
  signedTransactionHash: string;
  signedDateMs?: number;
  lastNotificationUUID?: string;
  lastVerifiedAt: string;
  source: HostedQuotaEntitlementSource;
  verificationVersion: number;
  schemaVersion: number;
  updatedAt: string;
}

export type EntitlementBindingDoc = import("../generated/hosted-quota.js").EntitlementBindingDoc & {
  id: string;
  productID: string;
  clientPlatform?: "ios" | "ipados" | "macos";
  consumedAt?: string;
  schemaVersion: number;
};

export interface EntitlementEventDoc {
  id: string;
  uid: string;
  source: "client_callable" | "apple_s2s" | "scheduled_reconcile";
  notificationType?: string;
  notificationSubtype?: string;
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  environment: AppStoreEnvironment;
  expiresAt?: string;
  revokedAt?: string;
  revocationReason?: number;
  rawJWSHash: string;
  observedAt: string;
  /**
   * Firestore TTL deletion target. Configure the TTL policy on this
   * field via Console / `firebase firestore:ttls:create` to have stale
   * audit rows reaped automatically.
   */
  expireAt?: import("firebase-admin/firestore").Timestamp;
  decoded: Record<string, unknown>;
  schemaVersion: number;
}
