import OpenBurnBarCore
import Foundation

/// Canonical mapping of socket RPC methods to daemon handler domains.
/// Used by `BurnBarDaemonServer.responseData` routing and contract tests.
enum BurnBarDaemonSocketRPCCoverage {
    static let lifecycle: Set<BurnBarRPCMethod> = [
        .health,
        .catalog,
        .authBootstrap
    ]

    static let config: Set<BurnBarRPCMethod> = [
        .configGet,
        .configUpdate,
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
        .usageRecent
    ]

    static let observability: Set<BurnBarRPCMethod> = [
        .proxyRouteLogRecent,
        .proxyRouteLogClear
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
        .computerUseSessionStart,
        .computerUseInvoke,
        .computerUseApprovalPending,
        .computerUseApprovalRespond,
        .computerUsePanicHalt,
        .computerUseAuditExport
    ]

    static let missionControl: Set<BurnBarRPCMethod> = [
        .controllerSummary,
        .controllerRuntimeSnapshot,
        .controllerProjectsList,
        .controllerProjectGet,
        .controllerProjectUpsert,
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
        .missionApprove,
        .missionCancel,
        .missionDispatchPacket,
        .missionRecordResult,
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
        .workspaceExecuteTool,
        .workspaceToolResult,
        .approvalRespond
    ]

    static let search: Set<BurnBarRPCMethod> = [
        .searchQuery
    ]

    static var allHandled: Set<BurnBarRPCMethod> {
        lifecycle
            .union(config)
            .union(usage)
            .union(observability)
            .union(tooling)
            .union(computerUse)
            .union(missionControl)
            .union(client)
            .union(runWorkspaceApproval)
            .union(search)
    }

    static func domain(for method: BurnBarRPCMethod) -> String? {
        if lifecycle.contains(method) { return "lifecycle" }
        if config.contains(method) { return "config" }
        if usage.contains(method) { return "usage" }
        if observability.contains(method) { return "observability" }
        if tooling.contains(method) { return "tooling" }
        if computerUse.contains(method) { return "computer_use" }
        if missionControl.contains(method) { return "mission_control" }
        if client.contains(method) { return "client" }
        if runWorkspaceApproval.contains(method) { return "run_workspace_approval" }
        if search.contains(method) { return "search" }
        return nil
    }
}
