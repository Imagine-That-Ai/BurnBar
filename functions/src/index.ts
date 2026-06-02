/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — main entry point.
 *
 * Initializes Firebase Admin and re-exports all callable, scheduled, and trigger
 * functions from domain modules so `lib/index.js` remains the deployment entry.
 */

import "./adminRuntime.js";

export { healthCheck, healthLive, healthReady } from "./health.js";
export { insightsHostedAnswer } from "./insightsHostedAnswer.js";
export { rollupIrohTransportDaily } from "./irohMonitoring.js";
export { recomputeMediaQuotaUsage } from "./mediaQuota.js";
export { rollupMediaSessionDaily } from "./mediaMonitoring.js";
export { grantMediaGrandfather, validateMediaPurchase } from "./callables/mediaSku.js";
export { triggerVoIPCall } from "./callables/voipPush.js";
export { evaluateMediaBudget } from "./mediaBudget.js";
export { evaluateComputerUseBudget } from "./computerUseBudget.js";
export { computeTierCogsDaily } from "./tierCogs.js";
export { reserveAgentControlActionBudget, reserveFlooRelayBudget } from "./cloudProAllowance.js";
export { recomputeComputerUseQuotaUsage } from "./computerUseQuota.js";
export { rollupComputerUseDaily } from "./computerUseMonitoring.js";
export { validateOpenTimestampsProof } from "./computerUseOpenTimestamps.js";
export { sendVoIPOutbound } from "./apnsSender.js";
export { sendFcmOutbound } from "./fcmAndroidSender.js";
export { onCliSessionAgentReplyNotification, onMobileAssistantAgentReplyNotification } from "./agentNotifications.js";
export { submitAgentNotificationReply } from "./callables/agentNotifications.js";

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
} from "./callables/providerAccounts.js";

export {
  createHermesPairing,
  completeHermesPairing,
  listHermesConnections,
  revokeHermesConnection,
  updateHermesConnectionStatus,
} from "./callables/hermes.js";

export {
  burnBarHermesGateway,
  approveHermesGatewayDeviceGrant,
  listHermesGatewayClients,
  revokeHermesGatewayClient,
  enqueueHermesGatewayEvent,
} from "./callables/hermesGateway.js";

export {
  createPiAgentPairing,
  completePiAgentPairing,
  listPiAgentConnections,
  revokePiAgentConnection,
  updatePiAgentConnectionStatus,
} from "./callables/piAgent.js";

export {
  createStripeBurnBarProCheckoutSession,
  createStripeBurnBarProPortalSession,
  verifyGooglePlayBurnBarProSubscription,
  verifyGooglePlayCloudProTopUp,
  stripeBurnBarProWebhook,
} from "./callables/stripe.js";

export {
  beginEncryptedSessionBlobUpload,
  getEncryptedSessionBlobDownloadUrl,
  commitEncryptedSearchIndexBatch,
  commitEncryptedProjectMemorySnapshot,
  getEncryptedProjectMemorySnapshot,
  listEncryptedProjectMemorySnapshots,
  searchEncryptedConversationIndex,
  queryConversations,
} from "./callables/encryptedSearch.js";

export {
  commitKnowledgeBatch,
  configureKnowledgeSource,
  deleteKnowledgeSource,
  purgeKnowledgeMemory,
} from "./callables/knowledgeMemory.js";
export {
  onKnowledgeRepoPush,
  connectKnowledgeRepo,
  disconnectKnowledgeRepo,
  reconcileKnowledgeMemoryDaily,
} from "./callables/knowledgeSync.js";

export { issueRemoteMcpGrant, revokeRemoteMcpClient, searchStreams } from "./callables/remoteMcp.js";
export {
  bindAppCheckAttestation,
  registerEscrowDevice,
  approveEscrowDeviceTrust,
  revokeEscrowDeviceTrust,
} from "./callables/computerUseSecurity.js";

export { rebuildUsageRollups, seedAndroidDemoAccount } from "./callables/misc.js";

export {
  adoptProviderAccountForDevice,
  revokeProviderAccountDeviceLink,
  backfillProviderAccountDeviceLinks,
  backfillProviderAccountDeviceLinksScheduled,
} from "./callables/deviceLinks.js";

export {
  onUsageWritten,
  rebuildRollups,
  refreshAllProviderQuotas,
  refreshModelLandscapeBenchmarks,
  latestRouterRundown,
} from "./scheduledExports.js";

export {
  beginEntitlementBinding,
  verifyHostedQuotaEntitlement,
  verifyCloudProTopUp,
  restoreHostedQuotaEntitlement,
  appStoreServerNotificationsV2,
  reconcileHostedEntitlementsDaily,
} from "./appstore/index.js";

export { startCliLink, pollCliLink, completeCliLink } from "./callables/cliLink.js";
