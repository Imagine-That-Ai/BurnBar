/**
 * @fileoverview OpenBurnBar Cloud Functions v2 — sync codebase entry point.
 *
 * Initializes Firebase Admin and re-exports this codebase's callable,
 * scheduled, and trigger functions from domains/ modules. (3.5 split:
 * functions/ (admin), functions-identity, functions-sync, functions-media.)
 */

import "@openburnbar/functions-shared/adminRuntime.js";

export { insightsHostedAnswer } from "./domains/search/insightsHostedAnswer.js";
export { benchAssistant } from "./domains/telemetry/benchAssistant.js";
export { arenaMatchup, arenaVote } from "./domains/telemetry/arenaVote.js";
export { recomputeMediaQuotaUsage } from "./domains/usage/mediaQuota.js";
export { rollupMediaSessionDaily } from "./domains/usage/mediaMonitoring.js";
export { grantMediaGrandfather, validateMediaPurchase } from "./domains/usage/mediaSku.js";
export { evaluateMediaBudget } from "./domains/usage/mediaBudget.js";
export { evaluateComputerUseBudget } from "./domains/computer-use/computerUseBudget.js";
export { performElderWandHostedSearch } from "./domains/search/elderWandHostedSearch.js";
export { recomputeComputerUseQuotaUsage } from "./domains/computer-use/computerUseQuota.js";
export {
  meterComputerUseAction,
  meterComputerUseSessionStart,
  meterComputerUseSessionCompletion,
} from "./domains/computer-use/computerUseMetering.js";
export { rollupComputerUseDaily } from "./domains/computer-use/computerUseMonitoring.js";
export { validateOpenTimestampsProof } from "./domains/computer-use/computerUseOpenTimestamps.js";
export {
  onCliSessionAgentReplyNotification,
  onMobileAssistantAgentReplyNotification,
  retryStuckAgentReplyEvents,
} from "./domains/notify/agentNotificationTriggers.js";
export { onAIInboxItemNotification } from "./domains/notify/aiInboxNotifications.js";
export { submitAgentNotificationReply } from "./domains/notify/agentNotifications.js";
export {
  createCliAgentMission,
  createCliAgentMissionGroup,
  claimCliAgentMission,
  updateCliAgentMissionStatus,
  cancelCliAgentMission,
  appendCliAgentMissionEvent,
} from "./domains/missions/cliAgentMissions.js";
export {
  publishMissionApprovalCeiling,
  redeemMissionApprovalAnswer,
} from "./domains/missions/missionApprovalAnswers.js";
export { submitBugReport } from "./domains/support/bugReporting.js";
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
} from "./domains/search/encryptedSearch.js";
export {
  commitKnowledgeBatch,
  configureKnowledgeSource,
  deleteKnowledgeSource,
  purgeKnowledgeMemory,
  purgeLegacyKnowledgeVectors,
  purgeLegacyKnowledgeVectorsScheduled,
} from "./domains/knowledge/knowledgeMemory.js";
export {
  onKnowledgeRepoPush,
  connectKnowledgeRepo,
  disconnectKnowledgeRepo,
  listKnowledgeRepos,
  requestKnowledgeResync,
  reconcileKnowledgeMemoryDaily,
} from "./domains/knowledge/knowledgeSync.js";
export { curateUsageMemoryBatch } from "./domains/usage/usageCuration.js";
export { getDataDomainUsage } from "./domains/usage/dataDomainUsage.js";
export { searchKnowledge, listKnowledgeChunks } from "./domains/knowledge/knowledgeSearch.js";
export { pullLinuxCloudReplicas, pushLinuxCloudReplicas } from "./domains/support/linuxCloudReplica.js";
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
} from "./domains/computer-use/computerUseSecurity.js";
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
} from "./domains/telemetry/signalMigrationTelemetry.js";
export { getProfileAvatarDownloadUrl } from "./domains/support/profileAvatar.js";
export { submitDomainCoreShadowSamples } from "./domains/support/domainCoreShadowEvidence.js";
