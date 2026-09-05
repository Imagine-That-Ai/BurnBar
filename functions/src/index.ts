/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — main entry point.
 *
 * Initializes Firebase Admin and re-exports all callable, scheduled, and trigger
 * functions from domain modules so `lib/index.js` remains the deployment entry.
 */

import "./adminRuntime.js";

export { healthCheck, healthLive, healthReady } from "./health.js";
export { insightsHostedAnswer } from "./insightsHostedAnswer.js";
export { benchAssistant } from "./benchAssistant.js";
export { arenaMatchup, arenaVote } from "./arenaVote.js";
export { markIrohAuditEventRollupEligible, rollupIrohTransportDaily } from "./irohMonitoring.js";
export { recomputeMediaQuotaUsage } from "./mediaQuota.js";
export { rollupMediaSessionDaily } from "./mediaMonitoring.js";
export { grantMediaGrandfather, validateMediaPurchase } from "./callables/mediaSku.js";
export { triggerVoIPCall } from "./callables/voipPush.js";
export { evaluateMediaBudget } from "./mediaBudget.js";
export { evaluateComputerUseBudget } from "./computerUseBudget.js";
export { computeTierCogsDaily } from "./tierCogs.js";
export { reserveAgentControlActionBudget, reserveFlooRelayBudget } from "./cloudProAllowance.js";
export { performElderWandHostedSearch } from "./elderWandHostedSearch.js";
export { recomputeComputerUseQuotaUsage } from "./computerUseQuota.js";
export {
  meterComputerUseAction,
  meterComputerUseSessionStart,
  meterComputerUseSessionCompletion,
} from "./computerUseMetering.js";
export { reconcileAccountErasures } from "./accountDeletionReconciler.js";
export { rollupComputerUseDaily } from "./computerUseMonitoring.js";
export { validateOpenTimestampsProof } from "./computerUseOpenTimestamps.js";
export { sendVoIPOutbound, retryStuckVoIPPushes } from "./apnsSender.js";
export { retryStuckFcmPushes, sendFcmOutbound } from "./fcmAndroidSender.js";
export {
  onCliSessionAgentReplyNotification,
  onMobileAssistantAgentReplyNotification,
  retryStuckAgentReplyEvents,
} from "./agentNotifications.js";
export { onAIInboxItemNotification } from "./aiInboxNotifications.js";
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
  getHermesGatewayAttachmentDownloadUrl,
  approveHermesGatewayDeviceGrant,
  listHermesGatewayClients,
  revokeHermesGatewayClient,
  rotateHermesGatewayClientToken,
  enqueueHermesGatewayEvent,
  setHermesGatewayOversightMode,
  respondHermesGatewayApproval,
  reapHermesGatewayApprovals,
} from "./callables/hermesGateway.js";
export { writeSignalAtRestDocument } from "./callables/writeSignalAtRestDocument.js";
export {
  createCliAgentMission,
  claimCliAgentMission,
  updateCliAgentMissionStatus,
  cancelCliAgentMission,
  appendCliAgentMissionEvent,
} from "./callables/cliAgentMissions.js";
export { reapBurnbarAttachments } from "./scheduled/reapBurnbarAttachments.js";
export {
  beginBurnbarAttachment,
  mintBurnbarAttachmentPartURL,
  composeBurnbarAttachment,
  finalizeBurnbarAttachment,
  ticketBurnbarAttachmentDownload,
  deleteBurnbarAttachment,
} from "./callables/burnbarAttachments.js";
export { publishMissionApprovalCeiling, redeemMissionApprovalAnswer } from "./callables/missionApprovalAnswers.js";
export { submitBugReport } from "./callables/bugReporting.js";

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
export { googlePlayDeveloperNotifications } from "./googlePlayRtdn.js";
export { reconcileGooglePlayVoidedPurchasesDaily } from "./googlePlayVoidedPurchaseReconciler.js";

export {
  beginEncryptedSessionBlobUpload,
  getEncryptedSessionBlobDownloadUrl,
  commitEncryptedSearchIndexBatch,
  commitEncryptedProjectMemorySnapshot,
  deleteEncryptedProjectMemorySnapshot,
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
  purgeLegacyKnowledgeVectors,
  purgeLegacyKnowledgeVectorsScheduled,
} from "./callables/knowledgeMemory.js";
export {
  onKnowledgeRepoPush,
  connectKnowledgeRepo,
  disconnectKnowledgeRepo,
  listKnowledgeRepos,
  requestKnowledgeResync,
  reconcileKnowledgeMemoryDaily,
} from "./callables/knowledgeSync.js";
export { curateUsageMemoryBatch } from "./callables/usageCuration.js";
export {
  publishSignalPrekeyBundle,
  claimSignalPrekeyBundle,
  recordSignalSession,
  recordSignalRotation,
  signalPrekeyWatermark,
} from "./callables/signalPrekeyDirectory.js";
export { signalActivationReadiness } from "./callables/signalActivationReadiness.js";
export { rotateCloudVaultKey } from "./callables/cloudVaultRotation.js";
export {
  listPendingCloudVaultRotationRequirements,
  detectStalePendingCloudVaultRotations,
} from "./cloudVaultRotationResilience.js";
export { getDataDomainUsage } from "./callables/dataDomainUsage.js";
export { searchKnowledge, listKnowledgeChunks } from "./callables/knowledgeSearch.js";
export { exportUserData } from "./callables/dataExport.js";
export { deleteDomainData } from "./callables/dataDeletion.js";
export { setupRecovery, confirmRecovery, listRecovery } from "./callables/recovery.js";
export {
  createCredentialTransfer,
  consumeCredentialTransfer,
  completeCredentialTransfer,
  cancelCredentialTransfer,
} from "./callables/credentialTransfer.js";
export { revokeAllAccess } from "./callables/panic.js";
export { getAuditLog, verifyAuditLog } from "./callables/auditLog.js";
export { registerBrowserEscrowDevice } from "./callables/webAppCheck.js";
export { mintLinuxAppCheckToken } from "./callables/linuxAppCheck.js";
export { pullLinuxCloudReplicas, pushLinuxCloudReplicas } from "./callables/linuxCloudReplica.js";
export {
  approveLinuxAppCheckDevice,
  issueLinuxAppCheckChallenge,
  listLinuxAppCheckDevices,
  registerLinuxAppCheckDevice,
  revokeLinuxAppCheckDevice,
} from "./callables/linuxAppCheckDevices.js";
export { issueWindowsAppCheckChallenge, mintWindowsAppCheckToken } from "./callables/windowsAppCheck.js";
export { getWindowsRuntimeSafetyConfig } from "./callables/windowsRuntimeSafetyConfig.js";
export {
  registerPasskey,
  verifyPasskeyRegistration,
  beginPasskeyAssertion,
  verifyPasskeyAssertion,
} from "./callables/passkey.js";

export { issueRemoteMcpGrant, revokeRemoteMcpClient, searchStreams } from "./callables/remoteMcp.js";
export {
  bindAppCheckAttestation,
  issueHighRiskActionNonce,
  registerEscrowDevice,
  approveEscrowDeviceTrust,
  revokeEscrowDeviceTrust,
  issueTrustedSignalIdentityRepairChallenge,
  repairTrustedSignalIdentity,
  publishIrohPairingPublicKey,
  publishIrohPairingRecord,
  revokeIrohPairingRecord,
  issuePhoneControlEnrollmentGrant,
  publishPhoneControlAuthority,
  issueIrohControllerRouteChallenge,
  registerIrohControllerRoute,
  revokeIrohControllerRoute,
  resolveActiveIrohControllerRoutes,
  publishRelaySenderKey,
  publishAgentGrantAuthority,
  queueAgentCapabilityGrantRequest,
  respondMissionApproval,
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
  rollupUserRebuild,
  refreshAllProviderQuotas,
  refreshModelLandscapeBenchmarks,
  anchorAuditLogHeads,
  latestRouterRundown,
} from "./scheduledExports.js";

export {
  onSignalMigrationConversationWritten,
  onSignalMigrationChatThreadWritten,
  onSignalMigrationMobileAssistantChatWritten,
  onSignalMigrationCliSessionWritten,
  onSignalMigrationMissionRequestWritten,
  onSignalMigrationTextSnippetWritten,
  onSignalMigrationRollbackRequestWritten,
  onSignalMigrationApprovalPolicyWritten,
  onSignalMigrationAgentIdentityWritten,
  onSignalMigrationSubscriptionTopicWritten,
} from "./signalMigrationTelemetry.js";

export {
  beginEntitlementBinding,
  verifyHostedQuotaEntitlement,
  verifyCloudProTopUp,
  restoreHostedQuotaEntitlement,
  appStoreServerNotificationsV2,
  reconcileHostedEntitlementsDaily,
} from "./appstore/index.js";

export { startCliLink, pollCliLink, completeCliLink } from "./callables/cliLink.js";
export { getProfileAvatarDownloadUrl } from "./callables/profileAvatar.js";

// Privacy-leak remediation: idempotent backfill that strips legacy plaintext
// fields once a sealed copy exists + bumps a per-user reseal watermark.
export { backfillPrivacyPlaintext, backfillPrivacyPlaintextScheduled } from "./callables/privacyBackfill.js";

// Shared-artifact privacy remediation: read-only inventory of legacy plaintext
// documents so trusted clients can pull and locally re-seal them.
export { scanLegacyPlaintextArtifacts } from "./callables/sharedArtifactLegacyScan.js";

export { submitDomainCoreShadowSamples } from "./callables/domainCoreShadowEvidence.js";

export {
  createTeam,
  inviteTeamMember,
  acceptTeamInvite,
  removeTeamMember,
  rotateTeamKey,
  TeamRosterService,
} from "./teamRoster.js";
