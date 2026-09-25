/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — identity codebase entry point.
 *
 * Initializes Firebase Admin and re-exports this codebase's callable,
 * scheduled, and trigger functions from domains/ modules. (3.5 split:
 * functions/ (admin), functions-identity, functions-sync, functions-media.)
 */

import "@openburnbar/functions-shared/adminRuntime.js";

export { computeTierCogsDaily } from "./domains/billing/tierCogs.js";
export { reserveAgentControlActionBudget, reserveFlooRelayBudget } from "./domains/billing/cloudProAllowance.js";
export {
  connectProviderAccount,
  connectProviderCredential,
  connectHostedQuotaAccount,
  connectSelfHostedQuotaAccount,
  uploadProviderQuotaSnapshot,
  deleteHostedQuotaCredentials,
  updateProviderAccount,
  deleteProviderAccount,
  deleteUserCloudData,
  deleteProviderCredential,
  refreshProviderAccountQuota,
  refreshProviderQuota,
} from "./domains/identity/providerAccounts.js";
export { writeSignalAtRestDocument } from "./domains/devices/writeSignalAtRestDocument.js";
export {
  createPiAgentPairing,
  completePiAgentPairing,
  listPiAgentConnections,
  revokePiAgentConnection,
  updatePiAgentConnectionStatus,
} from "./domains/identity/piAgent.js";
export {
  createStripeBurnBarProCheckoutSession,
  createStripeBurnBarProPortalSession,
  verifyGooglePlayBurnBarProSubscription,
  verifyGooglePlayCloudProTopUp,
  stripeBurnBarProWebhook,
} from "./domains/billing/stripe.js";
export { googlePlayDeveloperNotifications } from "./domains/billing/googlePlayRtdn.js";
export { reconcileGooglePlayVoidedPurchasesDaily } from "./domains/billing/googlePlayVoidedPurchaseReconciler.js";
export {
  publishSignalPrekeyBundle,
  claimSignalPrekeyBundle,
  recordSignalSession,
  recordSignalRotation,
  signalPrekeyWatermark,
} from "./domains/devices/signalPrekeyDirectory.js";
export { signalActivationReadiness } from "./domains/devices/signalActivationReadiness.js";
export { rotateCloudVaultKey } from "./domains/devices/cloudVaultRotation.js";
export {
  listPendingCloudVaultRotationRequirements,
  detectStalePendingCloudVaultRotations,
} from "./domains/devices/cloudVaultRotationResilience.js";
export {
  createCredentialTransfer,
  consumeCredentialTransfer,
  completeCredentialTransfer,
  cancelCredentialTransfer,
} from "./domains/identity/credentialTransfer.js";
export { registerBrowserEscrowDevice } from "./domains/app-check/webAppCheck.js";
export { mintLinuxAppCheckToken } from "./domains/app-check/linuxAppCheck.js";
export {
  approveLinuxAppCheckDevice,
  issueLinuxAppCheckChallenge,
  listLinuxAppCheckDevices,
  registerLinuxAppCheckDevice,
  revokeLinuxAppCheckDevice,
} from "./domains/app-check/linuxAppCheckDevices.js";
export { issueWindowsAppCheckChallenge, mintWindowsAppCheckToken } from "./domains/app-check/windowsAppCheck.js";
export { getWindowsRuntimeSafetyConfig } from "./domains/app-check/windowsRuntimeSafetyConfig.js";
export {
  registerPasskey,
  verifyPasskeyRegistration,
  beginPasskeyAssertion,
  verifyPasskeyAssertion,
} from "./domains/identity/passkey.js";
export { issueRemoteMcpGrant, revokeRemoteMcpClient, searchStreams } from "./domains/identity/remoteMcp.js";
export {
  adoptProviderAccountForDevice,
  revokeProviderAccountDeviceLink,
  backfillProviderAccountDeviceLinks,
  backfillProviderAccountDeviceLinksScheduled,
} from "./domains/devices/deviceLinks.js";
export {
  beginEntitlementBinding,
  verifyHostedQuotaEntitlement,
  verifyCloudProTopUp,
  restoreHostedQuotaEntitlement,
  appStoreServerNotificationsV2,
  reconcileHostedEntitlementsDaily,
} from "./domains/billing/appstore/index.js";
export { startCliLink, pollCliLink, completeCliLink } from "./domains/devices/cliLink.js";
export {
  createTeam,
  inviteTeamMember,
  acceptTeamInvite,
  promoteTeamMember,
  removeTeamMember,
  rotateTeamKey,
  abandonTeamKeyGeneration,
  recordTeamRewrapComplete,
  recordTeamSlugKeyId,
} from "./domains/identity/teamRosterCallables.js";
