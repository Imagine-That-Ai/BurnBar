/**
 * @fileoverview Cross-codebase test seam for knip (sync codebase).
 *
 * The admin vitest suite imports sibling `src/` modules and the .mjs
 * harnesses import compiled `lib/` output. Per-package knip analyzes only
 * this package's `src/`, so it cannot see those edges; this knip entry
 * re-exports each test-consumed module as a namespace to mark it live.
 * Every entry must stay live: `scripts/ci/verify-functions-test-seams.mjs`
 * fails on a seam with no knip-invisible importer. Production code must
 * never import from this module.
 */

export * as callablesAgentGrantCallablesTesting from "./callables/agentGrantCallables.js";
export * as callablesConversationQueryTesting from "./callables/conversationQuery.js";
export * as callablesEncryptedSearchIndexTesting from "./callables/encryptedSearchIndex.js";
export * as computerUseRemoteConfigTesting from "./computerUseRemoteConfig.js";
export * as domainsComputerUseComputerUseBudgetTesting from "./domains/computer-use/computerUseBudget.js";
export * as domainsComputerUseComputerUseMeteringTesting from "./domains/computer-use/computerUseMetering.js";
export * as domainsComputerUseComputerUseMonitoringTesting from "./domains/computer-use/computerUseMonitoring.js";
export * as domainsComputerUseComputerUseOpenTimestampsTesting from "./domains/computer-use/computerUseOpenTimestamps.js";
export * as domainsComputerUseComputerUseQuotaTesting from "./domains/computer-use/computerUseQuota.js";
export * as domainsComputerUseComputerUseSecurityTesting from "./domains/computer-use/computerUseSecurity.js";
export * as domainsKnowledgeKnowledgeMemoryTesting from "./domains/knowledge/knowledgeMemory.js";
export * as domainsKnowledgeKnowledgeSearchTesting from "./domains/knowledge/knowledgeSearch.js";
export * as domainsKnowledgeKnowledgeSyncTesting from "./domains/knowledge/knowledgeSync.js";
export * as domainsMissionsCliAgentMissionsTesting from "./domains/missions/cliAgentMissions.js";
export * as domainsMissionsMissionApprovalAnswersTesting from "./domains/missions/missionApprovalAnswers.js";
export * as domainsNotifyAgentNotificationTriggersTesting from "./domains/notify/agentNotificationTriggers.js";
export * as domainsNotifyAiInboxNotificationsTesting from "./domains/notify/aiInboxNotifications.js";
export * as domainsSupportLinuxCloudReplicaTesting from "./domains/support/linuxCloudReplica.js";
export * as domainsSupportProfileAvatarTesting from "./domains/support/profileAvatar.js";
export * as domainsTelemetryBenchAssistantTesting from "./domains/telemetry/benchAssistant.js";
export * as domainsTelemetrySignalMigrationTelemetryTesting from "./domains/telemetry/signalMigrationTelemetry.js";
export * as domainsUsageDataDomainUsageTesting from "./domains/usage/dataDomainUsage.js";
export * as domainsUsageMediaBudgetTesting from "./domains/usage/mediaBudget.js";
export * as domainsUsageMediaMonitoringTesting from "./domains/usage/mediaMonitoring.js";
export * as domainsUsageMediaQuotaTesting from "./domains/usage/mediaQuota.js";
export * as domainsUsageUsageCurationTesting from "./domains/usage/usageCuration.js";
export * as sharedStorageTesting from "./shared/storage.js";
export * as signalAtRestWriteTesting from "./signalAtRestWrite.js";
export * as usageCurationAllowanceTesting from "./usageCuration/allowance.js";
export * as usageCurationLimitsTesting from "./usageCuration/limits.js";
export * as usageCurationOpenrouterClientTesting from "./usageCuration/openrouterClient.js";
export * as usageCurationPromptTesting from "./usageCuration/prompt.js";
