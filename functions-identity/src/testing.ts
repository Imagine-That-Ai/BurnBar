/**
 * @fileoverview Cross-codebase test seam for knip (identity codebase).
 *
 * The admin vitest suite imports sibling `src/` modules and the .mjs
 * harnesses import compiled `lib/` output. Per-package knip analyzes only
 * this package's `src/`, so it cannot see those edges; this knip entry
 * re-exports each test-consumed module as a namespace to mark it live.
 * Every entry must stay live: `scripts/ci/verify-functions-test-seams.mjs`
 * fails on a seam with no knip-invisible importer. Production code must
 * never import from this module.
 */

export * as analyticsBucketsTesting from "./analytics/buckets.js";
export * as analyticsIndexTesting from "./analytics/index.js";
export * as callablesLinuxAppCheckDeviceCryptoTesting from "./callables/linuxAppCheckDeviceCrypto.js";
export * as domainsAppCheckLinuxAppCheckTesting from "./domains/app-check/linuxAppCheck.js";
export * as domainsAppCheckLinuxAppCheckDevicesTesting from "./domains/app-check/linuxAppCheckDevices.js";
export * as domainsAppCheckWebAppCheckTesting from "./domains/app-check/webAppCheck.js";
export * as domainsAppCheckWindowsAppCheckTesting from "./domains/app-check/windowsAppCheck.js";
export * as domainsAppCheckWindowsRuntimeSafetyConfigTesting from "./domains/app-check/windowsRuntimeSafetyConfig.js";
export * as domainsBillingAppstoreAuditTesting from "./domains/billing/appstore/audit.js";
export * as domainsBillingAppstoreNotificationsTesting from "./domains/billing/appstore/notifications.js";
export * as domainsBillingAppstoreReconcilerTesting from "./domains/billing/appstore/reconciler.js";
export * as domainsBillingAppstoreVerifierTesting from "./domains/billing/appstore/verifier.js";
export * as domainsBillingStripeTesting from "./domains/billing/stripe.js";
export * as domainsBillingTierCogsTesting from "./domains/billing/tierCogs.js";
export * as domainsDevicesCliLinkTesting from "./domains/devices/cliLink.js";
export * as domainsDevicesCloudVaultRotationResilienceTesting from "./domains/devices/cloudVaultRotationResilience.js";
export * as domainsDevicesSignalActivationReadinessTesting from "./domains/devices/signalActivationReadiness.js";
export * as domainsDevicesSignalPrekeyDirectoryTesting from "./domains/devices/signalPrekeyDirectory.js";
export * as domainsIdentityCredentialTransferTesting from "./domains/identity/credentialTransfer.js";
export * as remoteMcpOAuthTesting from "./remoteMcpOAuth.js";
export * as sharedGooglePlayTesting from "./shared/googlePlay.js";
export * as teamKeyEnvelopesTesting from "./teamKeyEnvelopes.js";
export * as teamRosterTesting from "./teamRoster.js";
