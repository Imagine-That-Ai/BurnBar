import OpenBurnBarEngine
import Foundation

/// Canonical mapping of socket RPC methods to daemon handler domains.
/// Used by `BurnBarDaemonServer.responseData` routing and contract tests.
enum BurnBarDaemonSocketRPCCoverage {
    static let auth: Set<BurnBarRPCMethod> = [
        .linuxAuthStatus,
        .linuxAuthBegin,
        .linuxAuthCancel,
        .linuxAuthRotateIdentity,
        .linuxAuthSignOut,
        .linuxAccountCloudDataExport,
        .linuxAccountCloudDataDelete,
        .linuxTrustedDeviceList,
        .linuxTrustedDeviceApprove,
        .linuxTrustedDeviceRevoke,
        .linuxCloudSyncStatus,
        .linuxCloudSyncPolicyUpdate,
        .linuxCloudSyncRun
    ]

    static let lifecycle: Set<BurnBarRPCMethod> = [
        .health,
        .catalog,
        .authBootstrap,
        .linuxOnboardingSnapshot
    ]

    static let config: Set<BurnBarRPCMethod> = [
        .configGet,
        .configUpdate,
        .textExpansionGet,
        .textExpansionUpsert,
        .textExpansionDelete,
        .textExpansionConsentUpdate,
        .textExpansionEngineStatus,
        .textExpansionEngineStart,
        .textExpansionEngineStop,
        .textExpansionEngineExpand,
        .linuxPrivacyInventory,
        .linuxPrivacyDeletionPreview,
        .linuxPrivacyDeletionExecute,
        .linuxPrivacyExport,
        .linuxPrivacyRetentionStatus,
        .linuxPrivacyRetentionApply,
        .linuxOnboardingAction,
        .linuxOnboardingReset,
        .providerCredentialSlotUpsert,
        .providerCredentialSlotRemove,
        .providerModelVariantUpsert,
        .providerModelVariantRemove,
        .providerModelAliasUpsert,
        .providerModelAliasRemove,
        .providerCustomModelUpsert,
        .providerCustomModelRemove,
        .providerModelDisplayNameSet,
        .providerModelDisplayNameClear
    ]

    static let usage: Set<BurnBarRPCMethod> = [
        .usageRecord,
        .usageRecent,
        .usageProjection,
        .usageRecount,
        .usageHistory,
        .usageInsights
    ]

    static let chat: Set<BurnBarRPCMethod> = [
        .chatThreadList,
        .chatThreadGet,
        .chatMessageAppend
    ]

    static let observability: Set<BurnBarRPCMethod> = [
        .proxyRouteLogRecent,
        .proxyRouteLogClear,
        .quotaSignalsRecent,
        .quotaSignalsClear,
        .perfMeasure
    ]

    static let membership: Set<BurnBarRPCMethod> = [
        .membershipStatus,
        .membershipCheckoutURL,
        .membershipPortalURL,
        .membershipRestore
    ]

    static let tooling: Set<BurnBarRPCMethod> = [
        .connectorPlaneGet,
        .connectorConfigUpdate,
        .connectorAction,
        .browserToolingGet,
        .browserToolingUpdate,
        .browserAction
    ]

    static let computerUse: Set<BurnBarRPCMethod> = [
        .computerUseCapabilityStateUpdate,
        .computerUseSessionGrantReadiness,
        .computerUseSessionGrantAcquire,
        .computerUseSessionGrantStatus,
        .computerUseSessionStart,
        .computerUseInvoke,
        .computerUseApprovalPending,
        .computerUseApprovalRespond,
        .computerUsePanicHalt,
        .computerUseAuditExport,
        .phoneControlPinProvision
    ]

    static let media: Set<BurnBarRPCMethod> = [
        .daemonMediaSessionState,
        .daemonMediaCallAccept,
        .daemonMediaCallDecline,
        .daemonMediaCallEnd,
        .daemonMediaCapabilityGet,
        .daemonMediaStatus,
        .daemonMediaFileOfferList,
        .daemonMediaFileAccept,
        .daemonMediaFileDecline,
        .daemonMediaFileSend
    ]

    static let missionControl: Set<BurnBarRPCMethod> = [
        .controllerSummary,
        .controllerRuntimeSnapshot,
        .controllerProjectsList,
        .controllerProjectGet,
        .controllerProjectUpsert,
        .controllerProjectDelete,
        .controllerProjectReassign,
        .reviewRunRecord,
        .questionCreate,
        .questionGet,
        .questionsList,
        .questionAnswer,
        .followupCreate,
        .followupsList,
        .followupDone,
        .followupSnooze,
        .followupCalendar,
        .missionCreate,
        .missionsList,
        .missionGet,
        .missionHealth,
        .missionApprove,
        .missionCancel,
        .missionDispatchPacket,
        .missionRecordResult,
        .missionAuthorizeRemote,
        .notificationConfigGet,
        .notificationConfigUpdate,
        .notificationHealth,
        .notificationCommand,
        .simulatorRun,
        .simulatorList,
        .simulatorReplay,
        .projectionRebuild
    ]

    static let client: Set<BurnBarRPCMethod> = [
        .clientAttach,
        .clientClaimControl,
        .clientDetach
    ]

    static let runWorkspaceApproval: Set<BurnBarRPCMethod> = [
        .runCreate,
        .runList,
        .runGet,
        .runPoll,
        .runCancel,
        .runRetry,
        .runResume,
        .subscriptionStart,
        .subscriptionResume,
        .subscriptionStop,
        .workspaceExecuteTool,
        .workspaceToolResult,
        .approvalRespond
    ]

    static let search: Set<BurnBarRPCMethod> = [
        .searchQuery,
        .searchSQL
    ]

    static let memory: Set<BurnBarRPCMethod> = [
        .memoryRemember,
        .memoryRecall,
        .memoryReviewStatus,
        .memoryForget,
        .memoryAuditTrail,
        .memoryAnalytics,
        .memoryModelPolicy
    ]

    static let code: Set<BurnBarRPCMethod> = [
        .codeIndexProject,
        .codeWatchProject,
        .codeSearch,
        .codeContextPack,
        .codeGetSymbol,
        .codeFindReferences,
        .codeCallGraph,
        .codeDiagnostics,
        .codeIndexStatus,
        .codeExplore,
        .codeOpsDiagnostics,
        .codeDatabaseSnapshot,
        .codeDatabaseRestore
    ]

    static let databaseRecovery: Set<BurnBarRPCMethod> = [
        .databaseRecoveryStatus,
        .databaseRecoveryBundleExport,
        .databaseRecoveryBundleImport
    ]

    static let fleet: Set<BurnBarRPCMethod> = [
        .fleetSnapshot,
        .fleetOrchestratorGet,
        .fleetOrchestratorSet,
        .fleetDirectiveRecord
    ]

    /// War Room, the Flame. Kept separate from `fleet` because the two answer
    /// different questions: `fleet` reports what the agents on this machine are
    /// doing, `warRoom` decides which machine should do a thing next.
    static let warRoom: Set<BurnBarRPCMethod> = [
        .warFlameRoute,
        .warFlameDistillList,
        .warFlameDistillSettle
    ]

    static let inbox: Set<BurnBarRPCMethod> = [
        .inboxList,
        .inboxGet,
        .inboxRunsRecent,
        .inboxConfigGet,
        .inboxConfigUpdate,
        .inboxRunNow,
        .inboxThreadGet,
        .inboxReply,
        .inboxPlansList,
        .inboxPlansGet,
        .inboxPlansAccept,
        .inboxPlansUpdateStep,
        .inboxPlansGrade,
        .inboxMemoryExport
    ]

    static var allHandled: Set<BurnBarRPCMethod> {
        auth
            .union(lifecycle)
            .union(config)
            .union(usage)
            .union(chat)
            .union(observability)
            .union(membership)
            .union(tooling)
            .union(computerUse)
            .union(media)
            .union(missionControl)
            .union(client)
            .union(runWorkspaceApproval)
            .union(search)
            .union(memory)
            .union(code)
            .union(databaseRecovery)
            .union(inbox)
            .union(fleet)
            .union(warRoom)
    }

    static func domain(for method: BurnBarRPCMethod) -> String? {
        if auth.contains(method) { return "auth" }
        if lifecycle.contains(method) { return "lifecycle" }
        if config.contains(method) { return "config" }
        if usage.contains(method) { return "usage" }
        if chat.contains(method) { return "chat" }
        if observability.contains(method) { return "observability" }
        if membership.contains(method) { return "membership" }
        if tooling.contains(method) { return "tooling" }
        if computerUse.contains(method) { return "computer_use" }
        if media.contains(method) { return "media" }
        if missionControl.contains(method) { return "mission_control" }
        if client.contains(method) { return "client" }
        if runWorkspaceApproval.contains(method) { return "run_workspace_approval" }
        if search.contains(method) { return "search" }
        if memory.contains(method) { return "memory" }
        if code.contains(method) { return "code" }
        if databaseRecovery.contains(method) { return "database_recovery" }
        if inbox.contains(method) { return "inbox" }
        if fleet.contains(method) { return "fleet" }
        if warRoom.contains(method) { return "war_room" }
        return nil
    }
}
