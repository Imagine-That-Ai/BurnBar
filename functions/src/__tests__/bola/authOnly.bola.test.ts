/**
 * Shared auth-only and platform metadata BOLA coverage.
 */
import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix } from "../../security/endpointAuthorizationMatrix.js";

export const AUTH_ONLY_CALLABLES = [
  "insightsHostedAnswer",
  "grantMediaGrandfather",
  "validateMediaPurchase",
  "reserveAgentControlActionBudget",
  "reserveFlooRelayBudget",
  "connectProviderCredential",
  "refreshProviderQuota",
  "listHermesConnections",
  "listPiAgentConnections",
  "listHermesGatewayClients",
  "createStripeBurnBarProCheckoutSession",
  "createStripeBurnBarProPortalSession",
  "verifyGooglePlayBurnBarProSubscription",
  "verifyGooglePlayCloudProTopUp",
  "beginEntitlementBinding",
  "verifyHostedQuotaEntitlement",
  "verifyCloudProTopUp",
  "restoreHostedQuotaEntitlement",
  "listEncryptedProjectMemorySnapshots",
  "purgeKnowledgeMemory",
  "purgeLegacyKnowledgeVectors",
  "curateUsageMemoryBatch",
  "listKnowledgeRepos",
  "requestKnowledgeResync",
  "signalActivationReadiness",
  "listPendingCloudVaultRotationRequirements",
  "getDataDomainUsage",
  "searchKnowledge",
  "exportUserData",
  "deleteUserCloudData",
  "revokeAllAccess",
  "deleteDomainData",
  "listRecovery",
  "getAuditLog",
  "verifyAuditLog",
  "registerBrowserEscrowDevice",
  "registerPasskey",
  "verifyPasskeyRegistration",
  "beginPasskeyAssertion",
  "verifyPasskeyAssertion",
  "bindAppCheckAttestation",
  "mintWindowsAppCheckToken",
  "issueWindowsAppCheckChallenge",
  "getWindowsRuntimeSafetyConfig",
  "issueHighRiskActionNonce",
  "searchStreams",
  "issueRemoteMcpGrant",
  "setupRecovery",
  "rebuildUsageRollups",
  "seedAndroidDemoAccount",
  "backfillProviderAccountDeviceLinks",
  "backfillPrivacyPlaintext",
  "scanLegacyPlaintextArtifacts",
  "getProfileAvatarDownloadUrl",
  "pushLinuxCloudReplicas",
  "pullLinuxCloudReplicas",
  "writeSignalAtRestDocument",
] as const;

export const PLATFORM_TRIGGER_ENDPOINTS = [
  "rollupIrohTransportDaily",
  "recomputeMediaQuotaUsage",
  "rollupMediaSessionDaily",
  "evaluateMediaBudget",
  "evaluateComputerUseBudget",
  "computeTierCogsDaily",
  "recomputeComputerUseQuotaUsage",
  "rollupComputerUseDaily",
  "meterComputerUseAction",
  "meterComputerUseSessionStart",
  "meterComputerUseSessionCompletion",
  "retryStuckVoIPPushes",
  "retryStuckFcmPushes",
  "retryStuckAgentReplyEvents",
  "purgeLegacyKnowledgeVectorsScheduled",
  "reconcileKnowledgeMemoryDaily",
  "detectStalePendingCloudVaultRotations",
  "backfillProviderAccountDeviceLinksScheduled",
  "markIrohAuditEventRollupEligible",
  "onUsageWritten",
  "rebuildRollups",
  "rollupUserRebuild",
  "refreshAllProviderQuotas",
  "refreshModelLandscapeBenchmarks",
  "anchorAuditLogHeads",
  "latestRouterRundown",
  "reconcileAccountErasures",
  "reconcileHostedEntitlementsDaily",
  "reconcileGooglePlayVoidedPurchasesDaily",
  "backfillPrivacyPlaintextScheduled",
  "reapHermesGatewayApprovals",
  "reapBurnbarAttachments",
  "onCliSessionAgentReplyNotification",
  "onMobileAssistantAgentReplyNotification",
  "onAIInboxItemNotification",
  "onKnowledgeRepoPush",
  "sendFcmOutbound",
  "sendVoIPOutbound",
  "googlePlayDeveloperNotifications",
  "stripeBurnBarProWebhook",
  "appStoreServerNotificationsV2",
  "onSignalMigrationAgentIdentityWritten",
  "onSignalMigrationApprovalPolicyWritten",
  "onSignalMigrationChatThreadWritten",
  "onSignalMigrationCliSessionWritten",
  "onSignalMigrationConversationWritten",
  "onSignalMigrationMissionRequestWritten",
  "onSignalMigrationMobileAssistantChatWritten",
  "onSignalMigrationRollbackRequestWritten",
  "onSignalMigrationSubscriptionTopicWritten",
  "onSignalMigrationTextSnippetWritten",
] as const;

export const PUBLIC_HEALTH_ENDPOINTS = ["healthCheck", "healthLive", "healthReady", "startCliLink"] as const;

describe("auth-only BOLA coverage", () => {
  it("rejects unauthenticated callable access", () => {
    for (const exportedName of AUTH_ONLY_CALLABLES) {
      const entry = endpointAuthorizationMatrix.find((row) => row.exportedName === exportedName);
      expect(entry, exportedName).toBeTruthy();
      expect(entry?.objectIdsFromClient ?? []).toEqual([]);
      expect(entry?.bolaCoverage.some((ref) => ref.kind === "auth-only")).toBe(true);
    }
  });

  it("platform triggers are not client-callable", () => {
    for (const exportedName of PLATFORM_TRIGGER_ENDPOINTS) {
      const entry = endpointAuthorizationMatrix.find((row) => row.exportedName === exportedName);
      expect(entry?.trigger, exportedName).not.toBe("callable");
    }
  });

  it("public health endpoints do not expose tenant objects", () => {
    for (const exportedName of PUBLIC_HEALTH_ENDPOINTS) {
      const entry = endpointAuthorizationMatrix.find((row) => row.exportedName === exportedName);
      expect(entry?.objectIdsFromClient ?? []).toEqual([]);
      expect(entry?.appCheck === "not-required" || entry?.appCheck === "not-applicable").toBe(true);
    }
  });
});
