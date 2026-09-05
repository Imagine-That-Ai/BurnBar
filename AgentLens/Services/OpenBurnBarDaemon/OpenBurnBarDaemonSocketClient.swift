import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import Foundation

enum OpenBurnBarDaemonSocketClient {
    private static let controllerRuntimeSecrets = KeychainStore(
        service: OpenBurnBarCore.OpenBurnBarIdentity.controllerRuntimeKeychainService,
        legacyServices: OpenBurnBarCore.OpenBurnBarIdentity.legacyControllerRuntimeKeychainServices
    )
    private static let daemonSocketAuthTokenLock = NSLock()
    // AUDIT(nonisolated): all reads/writes go through
    // `daemonSocketAuthTokenLock`; the raw storage is never accessed directly.
    nonisolated(unsafe) private static var cachedDaemonSocketAuthToken: String?

    private static let aggregatedSnapshotSupportLock = NSLock()
    // AUDIT(nonisolated): all reads/writes go through
    // `aggregatedSnapshotSupportLock`. Process-lifetime memo: once an older
    // daemon rejects `daemon.controller.runtime_snapshot`, refreshes stop
    // paying a failed probe and go straight to the legacy six-RPC path.
    nonisolated(unsafe) private static var aggregatedSnapshotUnsupported = false

    static var isAggregatedSnapshotMarkedUnsupported: Bool {
        aggregatedSnapshotSupportLock.withLock { aggregatedSnapshotUnsupported }
    }

    static func markAggregatedSnapshotUnsupported(_ unsupported: Bool) {
        aggregatedSnapshotSupportLock.withLock { aggregatedSnapshotUnsupported = unsupported }
    }

    static func cacheDaemonSocketAuthToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        daemonSocketAuthTokenLock.withLock {
            cachedDaemonSocketAuthToken = trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    static func health(at socketURL: URL) throws -> BurnBarHealthResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarHealthResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .health),
            socketURL: socketURL
        )

        if let error = envelope.error {
            let managerError = OpenBurnBarDaemonManagerError.rpcError(error.message)
            logDaemonFailure(OpenBurnBarError.fromDaemonManager(managerError))
            throw managerError
        }

        guard let result = envelope.result else {
            let managerError = OpenBurnBarDaemonManagerError.emptyResponse
            logDaemonFailure(OpenBurnBarError.fromDaemonManager(managerError))
            throw managerError
        }

        return result
    }

    static func fleetSnapshot(at socketURL: URL) throws -> BurnBarFleetSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarFleetSnapshotResponse>
        do {
            envelope = try send(
                BurnBarRPCRequestEnvelope(method: .fleetSnapshot),
                socketURL: socketURL
            )
        } catch let error as OpenBurnBarDaemonManagerError {
            if case .emptyResponse = error {
                throw BurnBarFleetClientError.emptyResponse
            }
            throw BurnBarFleetClientError.daemonUnavailable(error.localizedDescription)
        }
        if let error = envelope.error {
            throw classifyFleetError(error)
        }
        guard let result = envelope.result else {
            throw BurnBarFleetClientError.emptyResponse
        }
        return result.snapshot
    }

    static func fleetOrchestratorGet(at socketURL: URL) throws -> BurnBarOrchestratorState {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorGetResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .fleetOrchestratorGet),
            socketURL: socketURL
        )
        if let error = envelope.error {
            throw classifyFleetError(error)
        }
        guard let result = envelope.result else {
            throw BurnBarFleetClientError.emptyResponse
        }
        return result.state
    }

    static func fleetOrchestratorSet(
        _ designation: BurnBarOrchestratorDesignation,
        at socketURL: URL
    ) throws -> BurnBarOrchestratorState {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarFleetOrchestratorSetResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .fleetOrchestratorSet,
                params: BurnBarFleetOrchestratorSetRequest(
                    state: BurnBarOrchestratorState(designation: designation)
                )
            ),
            socketURL: socketURL
        )
        if let error = envelope.error {
            throw classifyFleetError(error)
        }
        guard let result = envelope.result else {
            throw BurnBarFleetClientError.emptyResponse
        }
        return result.state
    }

    static func fleetDirectiveRecord(
        _ directive: BurnBarFleetDirective,
        at socketURL: URL
    ) throws -> BurnBarFleetDirective {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarFleetDirectiveRecordResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .fleetDirectiveRecord,
                params: BurnBarFleetDirectiveRecordRequest(directive: directive)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error {
            throw classifyFleetError(error)
        }
        guard let result = envelope.result else {
            throw BurnBarFleetClientError.emptyResponse
        }
        return result.directive
    }

    private static func classifyFleetError(_ error: BurnBarRPCError) -> BurnBarFleetClientError {
        if error.code == -32603, error.message.contains("not ready") {
            return .notReady
        }
        if error.code == -32601 || error.code == -32001 {
            return .protocolMismatch(reason: error.message)
        }
        return .rpcError(code: error.code, message: error.message)
    }

    private static func logDaemonFailure(_ error: OpenBurnBarError) {
        AppLogger.daemon.error("daemon_rpc_failed", metadata: error.logMetadata)
    }

    static func membershipRestore(at socketURL: URL) throws -> BurnBarMembershipRestoreResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarMembershipRestoreResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .membershipRestore),
            socketURL: socketURL
        )
        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }
        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }
        return result
    }

    static func config(at socketURL: URL) throws -> BurnBarProviderConfigurationSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConfigResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .configGet),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.snapshot
    }

    static func updateConfig(
        _ snapshot: BurnBarProviderConfigurationSnapshot,
        at socketURL: URL
    ) throws -> BurnBarProviderConfigurationSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConfigResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .configUpdate,
                params: BurnBarConfigUpdateRequest(snapshot: snapshot)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.snapshot
    }

    static func upsertProviderCredentialSlot(
        _ request: BurnBarProviderCredentialSlotUpsertRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderCredentialSlotMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerCredentialSlotUpsert,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func removeProviderCredentialSlot(
        _ request: BurnBarProviderCredentialSlotRemoveRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderCredentialSlotMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerCredentialSlotRemove,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func upsertProviderModelVariant(
        _ request: BurnBarProviderModelVariantUpsertRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderModelVariantMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerModelVariantUpsert,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func removeProviderModelVariant(
        _ request: BurnBarProviderModelVariantRemoveRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderModelVariantMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerModelVariantRemove,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func upsertProviderModelAlias(
        _ request: BurnBarProviderModelAliasUpsertRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderModelAliasMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerModelAliasUpsert,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func removeProviderModelAlias(
        _ request: BurnBarProviderModelAliasRemoveRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderModelAliasMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerModelAliasRemove,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func upsertProviderCustomModel(
        _ request: BurnBarProviderCustomModelUpsertRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderCustomModelMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerCustomModelUpsert,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func removeProviderCustomModel(
        _ request: BurnBarProviderCustomModelRemoveRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderCustomModelMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerCustomModelRemove,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func setProviderModelDisplayName(
        _ request: BurnBarProviderModelDisplayNameSetRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderModelDisplayNameMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerModelDisplayNameSet,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func clearProviderModelDisplayName(
        _ request: BurnBarProviderModelDisplayNameClearRequest,
        at socketURL: URL
    ) throws -> BurnBarProviderModelDisplayNameMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .providerModelDisplayNameClear,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func recentUsage(
        at socketURL: URL,
        limit: Int = 20
    ) throws -> [BurnBarUsageEvent] {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarRecentUsageResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .usageRecent,
                params: BurnBarRecentUsageRequest(limit: limit)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.usage
    }

    /// Per-project memory counters from the daemon's own store — which is this
    /// app's database, indexed by the daemon at
    /// `OpenBurnBarAppPaths.live(...).databaseURL`.
    ///
    /// `daemon.memory.analytics` already exists, already maps to the
    /// `memory_read` capability, and is already `.full` for the `.app` peer, so
    /// this is a client method and nothing more: no new RPC id, no new contract,
    /// no new capability. `projectPath` is resolved to a project identity
    /// DAEMON-side — the app never guesses one — and nil asks about the daemon's
    /// own default project.
    ///
    /// A refusing or unreachable daemon THROWS. It must never degrade to a
    /// zeroed response: "we could not ask" and "this project has no memories"
    /// are different statements, and only one of them is ever observed here.
    static func memoryAnalytics(
        projectPath: String?,
        at socketURL: URL
    ) throws -> BurnBarProjectMemoryAnalyticsResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarProjectMemoryAnalyticsResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .memoryAnalytics,
                params: BurnBarProjectMemoryAnalyticsRequest(projectPath: projectPath)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result
    }

    static func proxyRouteLog(
        at socketURL: URL,
        limit: Int = 50
    ) throws -> [BurnBarProxyRouteLogEntry] {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarProxyRouteLogRecentResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .proxyRouteLogRecent,
                params: BurnBarProxyRouteLogRecentRequest(limit: limit)
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.entries
    }

    @discardableResult
    static func clearProxyRouteLog(at socketURL: URL) throws -> Bool {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarProxyRouteLogClearResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .proxyRouteLogClear,
                params: BurnBarProxyRouteLogClearRequest()
            ),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }

        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        return result.cleared
    }

    static func runResume(
        _ request: BurnBarRunResumeRequest,
        at socketURL: URL
    ) throws -> BurnBarRunResumeResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .runResume,
                params: request
            ),
            socketURL: socketURL
        )
    }

    static func connectorPlane(at socketURL: URL) throws -> BurnBarConnectorPlaneSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarConnectorPlaneResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .connectorPlaneGet),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }
        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }
        return result.snapshot
    }

    static func updateConnectorConfig(
        _ request: BurnBarConnectorConfigUpdateRequest,
        at socketURL: URL
    ) throws -> BurnBarConnectorPlaneSnapshot {
        let response: BurnBarConnectorPlaneResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .connectorConfigUpdate,
                params: request
            ),
            socketURL: socketURL
        )
        return response.snapshot
    }

    static func performConnectorAction(
        _ request: BurnBarConnectorActionRequest,
        at socketURL: URL
    ) throws -> BurnBarConnectorActionResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .connectorAction,
                params: request
            ),
            socketURL: socketURL
        ) as BurnBarConnectorActionResponse
    }

    static func browserTooling(at socketURL: URL) throws -> BurnBarBrowserToolingSnapshot {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarBrowserToolingResponse> = try send(
            BurnBarRPCRequestEnvelope(method: .browserToolingGet),
            socketURL: socketURL
        )

        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }
        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }
        return result.snapshot
    }

    static func updateBrowserTooling(
        _ request: BurnBarBrowserToolingUpdateRequest,
        at socketURL: URL
    ) throws -> BurnBarBrowserToolingSnapshot {
        let response: BurnBarBrowserToolingResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .browserToolingUpdate,
                params: request
            ),
            socketURL: socketURL
        )
        return response.snapshot
    }

    static func performBrowserAction(
        _ request: BurnBarBrowserActionRequest,
        at socketURL: URL
    ) throws -> BurnBarBrowserActionResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .browserAction,
                params: request
            ),
            socketURL: socketURL
        ) as BurnBarBrowserActionResponse
    }

    static func startComputerUseSession(
        _ request: ComputerUseSessionStartRequest,
        at socketURL: URL
    ) throws -> ComputerUseSessionStartResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUseSessionStart,
                params: request
            ),
            socketURL: socketURL
        ) as ComputerUseSessionStartResponse
    }

    static func updateComputerUseCapabilityState(
        _ request: ComputerUseCapabilityStateUpdateRequest,
        at socketURL: URL
    ) throws -> ComputerUseCapabilityStateUpdateResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUseCapabilityStateUpdate,
                params: request
            ),
            socketURL: socketURL
        ) as ComputerUseCapabilityStateUpdateResponse
    }

    static func invokeComputerUse(
        _ request: ComputerUseInvokeRequest,
        at socketURL: URL
    ) throws -> ComputerUseInvokeResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUseInvoke,
                params: request
            ),
            socketURL: socketURL
        ) as ComputerUseInvokeResponse
    }

    static func provisionPhoneControlPin(
        _ request: DaemonPhoneControlPinProvisionRequest,
        at socketURL: URL
    ) throws -> DaemonPhoneControlPinProvisionResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .phoneControlPinProvision,
                params: request
            ),
            socketURL: socketURL
        ) as DaemonPhoneControlPinProvisionResponse
    }

    static func pendingComputerUseApprovals(
        _ request: ComputerUseApprovalPendingRequest,
        at socketURL: URL
    ) throws -> ComputerUseApprovalPendingResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUseApprovalPending,
                params: request
            ),
            socketURL: socketURL
        ) as ComputerUseApprovalPendingResponse
    }

    static func respondToComputerUseApproval(
        _ request: ComputerUseApprovalRespondRequest,
        at socketURL: URL
    ) throws -> ComputerUseApprovalRespondResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUseApprovalRespond,
                params: request
            ),
            socketURL: socketURL
        ) as ComputerUseApprovalRespondResponse
    }

    static func panicHaltComputerUse(
        _ request: ComputerUsePanicHaltRequest,
        at socketURL: URL
    ) throws -> ComputerUsePanicHaltResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUsePanicHalt,
                params: request
            ),
            socketURL: socketURL
        ) as ComputerUsePanicHaltResponse
    }

    static func exportComputerUseAudit(
        _ request: ComputerUseAuditExportRequest,
        at socketURL: URL
    ) throws -> ComputerUseAuditExportResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .computerUseAuditExport,
                params: request
            ),
            socketURL: socketURL
        ) as ComputerUseAuditExportResponse
    }

    static func updateNotificationConfig(
        _ config: BurnBarNotificationConfig,
        at socketURL: URL
    ) throws -> BurnBarNotificationConfig {
        let response: BurnBarNotificationConfigResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .notificationConfigUpdate,
                params: BurnBarNotificationConfigUpdateRequest(config: config)
            ),
            socketURL: socketURL
        )
        return response.config
    }

    static func controllerProjects(at socketURL: URL) throws -> [BurnBarReviewProjectSnapshot] {
        let response: BurnBarControllerProjectsListResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .controllerProjectsList,
                params: BurnBarControllerProjectsListRequest(includePaused: true, limit: 200)
            ),
            socketURL: socketURL
        )
        return response.projects
    }

    static func upsertControllerProject(
        _ project: BurnBarReviewProjectSnapshot,
        at socketURL: URL
    ) throws -> BurnBarReviewProjectSnapshot? {
        let response: BurnBarControllerProjectResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .controllerProjectUpsert,
                params: BurnBarControllerProjectUpsertRequest(project: project)
            ),
            socketURL: socketURL
        )
        return response.project
    }

    static func missionCreate(
        _ request: BurnBarMissionCreateRequest,
        at socketURL: URL
    ) throws -> BurnBarMissionMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .missionCreate,
                params: request
            ),
            socketURL: socketURL
        ) as BurnBarMissionMutationResponse
    }

    /// daemon.mission.authorizeRemote — the daemon's authoritative verdict over
    /// a remote (mobile/Wand) mission. Called in SHADOW mode by the GUI mission
    /// listener (split-brain Phase M3): the GUI compares this verdict against
    /// its own decision and telemeters divergence without yet changing runtime
    /// behavior.
    static func authorizeRemoteMission(
        _ request: BurnBarRemoteMissionAuthorizeRequest,
        at socketURL: URL
    ) throws -> BurnBarRemoteMissionAuthorizeResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .missionAuthorizeRemote,
                params: request
            ),
            socketURL: socketURL
        ) as BurnBarRemoteMissionAuthorizeResponse
    }

    static func recordControllerReviewRun(
        _ run: BurnBarReviewRunSnapshot,
        at socketURL: URL
    ) throws -> BurnBarControllerReviewRunRecordResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .reviewRunRecord,
                params: BurnBarControllerReviewRunRecordRequest(run: run)
            ),
            socketURL: socketURL
        ) as BurnBarControllerReviewRunRecordResponse
    }

    static func controllerRuntimeSnapshot(at socketURL: URL) throws -> OpenBurnBarControllerRuntimeSnapshot {
        // Preferred path: ONE aggregated RPC instead of six sequential
        // socket round trips (docs/architecture/macos-performance.md §16).
        // The daemon is a separate long-running process that may be older
        // than this app, so a failure falls back to the legacy per-list
        // path — and a successful fallback memoizes the downgrade for the
        // process lifetime.
        if !isAggregatedSnapshotMarkedUnsupported {
            do {
                let response = try requestResult(
                    BurnBarRPCRequestEnvelopeWithParams(
                        method: .controllerRuntimeSnapshot,
                        params: BurnBarControllerRuntimeSnapshotRequest()
                    ),
                    socketURL: socketURL
                ) as BurnBarControllerRuntimeSnapshotResponse
                return makeControllerRuntimeSnapshot(payload: response.snapshot)
            } catch {
                let legacy = try legacyControllerRuntimeSnapshot(at: socketURL)
                markAggregatedSnapshotUnsupported(true)
                return legacy
            }
        }
        return try legacyControllerRuntimeSnapshot(at: socketURL)
    }

    private static func legacyControllerRuntimeSnapshot(at socketURL: URL) throws -> OpenBurnBarControllerRuntimeSnapshot {
        let summary = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .controllerSummary,
                params: BurnBarControllerSummaryRequest()
            ),
            socketURL: socketURL
        ) as OpenBurnBarCore.BurnBarControllerSummaryResponse
        let questions = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .questionsList,
                params: BurnBarQuestionsListRequest(projectSlug: nil, statuses: BurnBarPendingQuestionStatus.allCases)
            ),
            socketURL: socketURL
        ) as BurnBarQuestionsListResponse
        let followups = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupsList,
                params: BurnBarFollowupsListRequest(projectSlug: nil, statuses: BurnBarFollowupStatus.allCases)
            ),
            socketURL: socketURL
        ) as BurnBarFollowupsListResponse
        let missions = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .missionsList,
                params: BurnBarMissionListRequest()
            ),
            socketURL: socketURL
        ) as BurnBarMissionListResponse
        let notificationHealth = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .notificationHealth,
                params: BurnBarNotificationHealthRequest()
            ),
            socketURL: socketURL
        ) as BurnBarNotificationHealthResponse
        let simulatorRuns = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .simulatorList,
                params: BurnBarSimulatorListRequest()
            ),
            socketURL: socketURL
        ) as BurnBarSimulatorListResponse

        return makeControllerRuntimeSnapshot(
            summary: summary.summary,
            questions: questions.questions,
            followups: followups.followups,
            missions: missions.missions,
            notificationHealth: notificationHealth.health,
            simulatorRuns: simulatorRuns.runs
        )
    }

    static func answerControllerQuestion(
        questionID: String,
        answer: String,
        selectedOptionID: String? = nil,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let response: BurnBarQuestionAnswerResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .questionAnswer,
                params: BurnBarQuestionAnswerRequest(
                    questionID: BurnBarQuestionID(rawValue: questionID),
                    answeredBy: "operator",
                    answer: answer,
                    selectedOptionID: selectedOptionID
                )
            ),
            socketURL: socketURL
        )
        // Newer daemons embed the post-mutation runtime; older ones don't —
        // fall back to the follow-up snapshot call.
        if let payload = response.runtimeSnapshot {
            return makeControllerRuntimeSnapshot(payload: payload)
        }
        return try controllerRuntimeSnapshot(at: socketURL)
    }

    private static func runtimeSnapshot(
        from response: BurnBarFollowupMutationResponse,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        if let payload = response.runtimeSnapshot {
            return makeControllerRuntimeSnapshot(payload: payload)
        }
        return try controllerRuntimeSnapshot(at: socketURL)
    }

    static func completeControllerFollowup(
        followupID: String,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let response: BurnBarFollowupMutationResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupDone,
                params: BurnBarFollowupDoneRequest(
                    followupID: BurnBarFollowupID(rawValue: followupID),
                    actor: "operator"
                )
            ),
            socketURL: socketURL
        )
        return try runtimeSnapshot(from: response, at: socketURL)
    }

    static func snoozeControllerFollowup(
        followupID: String,
        until: Date,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let response: BurnBarFollowupMutationResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupSnooze,
                params: BurnBarFollowupSnoozeRequest(
                    followupID: BurnBarFollowupID(rawValue: followupID),
                    actor: "operator",
                    snoozeUntil: until
                )
            ),
            socketURL: socketURL
        )
        return try runtimeSnapshot(from: response, at: socketURL)
    }

    static func scheduleControllerFollowupCalendar(
        followupID: String,
        title: String?,
        start: Date,
        durationMinutes: Int,
        at socketURL: URL
    ) throws -> OpenBurnBarControllerRuntimeSnapshot? {
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? title!
            : "OpenBurnBar followup"
        let end = start.addingTimeInterval(Double(max(durationMinutes, 15)) * 60)
        let response: BurnBarFollowupMutationResponse = try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupCalendar,
                params: BurnBarFollowupCalendarRequest(
                    followupID: BurnBarFollowupID(rawValue: followupID),
                    actor: "operator",
                    action: .create,
                    entry: BurnBarCalendarEntrySnapshot(
                        externalID: nil,
                        title: resolvedTitle,
                        startAt: start,
                        endAt: end,
                        notes: "Scheduled from AgentLens."
                    )
                )
            ),
            socketURL: socketURL
        )
        return try runtimeSnapshot(from: response, at: socketURL)
    }

    private static func send<Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelope,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let signedRequest = BurnBarRPCRequestEnvelope(
            id: request.id,
            method: request.method,
            authToken: request.authToken ?? daemonSocketAuthToken()
        )
        return try sendEncoded(signedRequest, socketURL: socketURL)
    }

    private static func send<Params: Codable & Sendable, Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelopeWithParams<Params>,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let signedRequest = BurnBarRPCRequestEnvelopeWithParams(
            id: request.id,
            method: request.method,
            authToken: request.authToken ?? daemonSocketAuthToken(),
            params: request.params
        )
        return try sendEncoded(signedRequest, socketURL: socketURL)
    }

    private static func requestResult<Params: Codable & Sendable, Response: Codable & Sendable>(
        _ request: BurnBarRPCRequestEnvelopeWithParams<Params>,
        socketURL: URL
    ) throws -> Response {
        let envelope: BurnBarRPCResponseEnvelope<Response> = try send(request, socketURL: socketURL)
        if let error = envelope.error {
            throw OpenBurnBarDaemonManagerError.rpcError(error.message)
        }
        guard let result = envelope.result else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }
        return result
    }

    static func makeControllerRuntimeSnapshot(
        payload: BurnBarControllerRuntimeSnapshotPayload
    ) -> OpenBurnBarControllerRuntimeSnapshot {
        makeControllerRuntimeSnapshot(
            summary: payload.summary,
            questions: payload.questions,
            followups: payload.followups,
            missions: payload.missions,
            notificationHealth: payload.notificationHealth,
            simulatorRuns: payload.simulatorRuns
        )
    }

    static func makeControllerRuntimeSnapshot(
        summary: OpenBurnBarCore.BurnBarControllerSummary,
        questions: [BurnBarPendingQuestionSnapshot],
        followups: [BurnBarFollowupSnapshot],
        missions: [BurnBarMissionSnapshot],
        notificationHealth: BurnBarNotificationHealthSnapshot,
        simulatorRuns: [BurnBarSimulatorRunSnapshot]
    ) -> OpenBurnBarControllerRuntimeSnapshot {
        let visibleQuestions = questions.filter { shouldIncludeInOperatorInbox($0) }
        let visibleQuestionIDs = Set(visibleQuestions.map(\.id.rawValue))
        let visibleFollowups = followups.filter {
            shouldIncludeInOperatorInbox($0, visibleQuestionIDs: visibleQuestionIDs)
        }

        let mappedQuestions = visibleQuestions.map { question in
            OpenBurnBarControllerQuestion(
                id: question.id.rawValue,
                projectName: displayName(for: question.projectSlug),
                sessionID: question.sessionID?.rawValue,
                title: question.title,
                prompt: question.prompt,
                stageLabel: question.stageLabel,
                evidenceHint: question.contextSummary,
                state: questionState(for: question.status),
                priority: questionPriority(for: question.priority),
                sourceLabel: question.sessionID == nil ? "Daemon controller runtime" : "Daemon session runtime",
                createdAt: question.askedAt,
                answeredAt: question.latestAnswer?.answeredAt,
                answer: question.latestAnswer?.answer,
                selectedOptionID: question.latestAnswer?.selectedOptionID,
                answerPlaceholder: question.answerPlaceholder,
                suggestedOptions: question.suggestedOptions.map { option in
                    OpenBurnBarControllerQuestionOption(
                        id: option.id,
                        title: option.title,
                        detail: option.detail,
                        answer: option.answer
                    )
                },
                deepLink: question.deepLink.map { link in
                    OpenBurnBarControllerQuestionDeepLink(
                        kind: questionDeepLinkKind(for: link.kind),
                        targetID: link.targetID,
                        title: link.title,
                        subtitle: link.subtitle
                    )
                },
                isUnread: question.tracker?.isUnread ?? false,
                notificationCount: question.tracker?.notificationCount ?? 0
            )
        }

        let mappedFollowups = visibleFollowups.map { followup in
            OpenBurnBarControllerFollowup(
                id: followup.id.rawValue,
                projectName: displayName(for: followup.projectSlug),
                title: followup.title,
                summary: followup.summary,
                stageLabel: followup.stageLabel,
                detail: followup.calendarEntry?.notes,
                state: followupState(for: followup.status),
                kind: followupKind(for: followup.kind),
                linkedQuestionID: followup.questionID?.rawValue,
                deepLink: followup.deepLink.map { link in
                    OpenBurnBarControllerQuestionDeepLink(
                        kind: questionDeepLinkKind(for: link.kind),
                        targetID: link.targetID,
                        title: link.title,
                        subtitle: link.subtitle
                    )
                },
                createdAt: followup.createdAt,
                updatedAt: followup.nextNudgeAt ?? followup.snoozeUntil ?? followup.createdAt,
                dueAt: followup.nextNudgeAt,
                snoozedUntil: followup.snoozeUntil,
                calendarTitle: followup.calendarEntry?.title,
                calendarStart: followup.calendarEntry?.startAt,
                calendarEnd: followup.calendarEntry?.endAt
            )
        }

        let mappedMissions = missions.map { mission in
            let latestPacket = mission.packets.min {
                ($0.dispatchedAt ?? .distantPast) > ($1.dispatchedAt ?? .distantPast)
            }
            let activePacket = mission.packets.first(where: { [.queued, .dispatched, .running].contains($0.status) }) ?? latestPacket
            let latestResult = mission.results.min(by: { $0.createdAt > $1.createdAt })
            let missionPRLinkage = mission.prLinkage ?? latestResult?.prLinkage
            let packetSummary = latestPacket.map { packet in
                "\(packet.workerName): \(packet.objective)"
            }
            let burnTokens = mission.results.reduce(0) { partial, result in
                partial
                    + intValue(in: result.metadata["input_tokens"])
                    + intValue(in: result.metadata["output_tokens"])
                    + intValue(in: result.metadata["cache_read_tokens"])
            }
            let mappedPRLinkage = missionPRLinkage.map {
                OpenBurnBarControllerMissionPRLinkage(
                    repository: $0.repository,
                    prNumberOrID: $0.prNumberOrID,
                    url: $0.url,
                    state: missionPRState(for: $0.state),
                    isMerged: $0.isMerged,
                    mergeCommitSHA: $0.mergeCommitSHA,
                    mergedAt: $0.mergedAt,
                    closedAt: $0.closedAt
                )
            }
            let latestTakeover = mission.takeoverHistory?
                .min(by: { $0.updatedAt > $1.updatedAt })
            let ownerPrincipalID = stringValue(in: mission.metadata["team_owner_id"])
                ?? stringValue(in: mission.metadata["owner_principal_id"])
                ?? mission.approval.approvedBy
            let assigneePrincipalID = stringValue(in: mission.metadata["team_assignee_id"])
                ?? stringValue(in: mission.metadata["assignee_principal_id"])
                ?? activePacket?.workerName
            let roleEligibility = OpenBurnBarControllerMissionRoleEligibility(
                canApprove: boolValue(in: mission.metadata["role_can_approve"])
                    ?? (!mission.approval.approved && mission.status == .awaitingApproval),
                canTransferOwnership: boolValue(in: mission.metadata["role_can_transfer"])
                    ?? ![BurnBarMissionStatus.completed, .failed, .cancelled].contains(mission.status),
                canAnswerClosureQuestion: boolValue(in: mission.metadata["role_can_answer_closure"])
                    ?? (mission.status == .awaitingApproval)
            )
            let latestAuditEventID = stringValue(in: mission.metadata["audit_event_id"])
                ?? stringValue(in: mission.metadata["last_audit_event_id"])
            let latestAuditSummary = stringValue(in: mission.metadata["audit_summary"])
                ?? stringValue(in: mission.metadata["last_audit_summary"])
            return OpenBurnBarControllerMissionRecord(
                id: mission.id.rawValue,
                projectName: displayName(for: mission.projectSlug),
                title: mission.title,
                summary: mission.summary,
                state: missionLifecycle(for: mission.status),
                approval: mission.approval.approved ? .approved : .pending,
                ownerPrincipalID: ownerPrincipalID,
                assigneePrincipalID: assigneePrincipalID,
                roleEligibility: roleEligibility,
                latestAuditEventID: latestAuditEventID,
                latestAuditSummary: latestAuditSummary,
                packetSummary: packetSummary,
                latestResultSummary: latestResult?.summary,
                latestResultDetail: latestResult?.detail,
                latestResultRunID: latestResult?.runID?.rawValue,
                activeWorkerName: activePacket?.workerName,
                activeRunID: activePacket?.runID?.rawValue,
                packetRunCount: mission.packets.compactMap(\.runID).count,
                latestTakeoverState: latestTakeover.map { takeoverState(for: $0.status) },
                latestTakeoverReason: latestTakeover?.reason,
                latestTakeoverRunID: latestTakeover?.takeoverRunID?.rawValue,
                takeoverCount: mission.takeoverHistory?.count ?? 0,
                burnCostUSD: mission.burnRecords.reduce(0) { $0 + $1.amount },
                burnTokens: burnTokens,
                updatedAt: mission.updatedAt,
                prLinkage: mappedPRLinkage
            )
        }

        let mappedEvents = summary.recentEvents.map { event in
            OpenBurnBarControllerEvent(
                id: event.id.rawValue,
                projectName: displayName(for: event.projectSlug),
                category: eventCategory(for: event.family),
                title: readableEventTitle(for: event.eventType),
                summary: event.summary,
                detail: event.detail,
                createdAt: event.recordedAt
            )
        }

        let pendingQuestionCount = mappedQuestions.filter { $0.state == .pending }.count
        let unresolvedFollowupCount = mappedFollowups.filter { $0.state == .open }.count
        let openMissionCount = mappedMissions.filter { $0.state != OpenBurnBarMissionLifecycle.completed }.count

        return OpenBurnBarControllerRuntimeSnapshot(
            source: .daemon,
            updatedAt: summary.updatedAt,
            summary: OpenBurnBarControllerSummary(
                headline: controllerHeadline(
                    questionCount: pendingQuestionCount,
                    followupCount: unresolvedFollowupCount
                ),
                detail: "Daemon-backed controller summary. \(freshnessLabel(for: summary.freshness)).",
                pendingQuestions: pendingQuestionCount,
                unresolvedFollowups: unresolvedFollowupCount,
                openMissions: openMissionCount,
                replayLabel: replayLabel(from: simulatorRuns),
                notificationLabel: notificationLabel(from: notificationHealth)
            ),
            questions: mappedQuestions,
            followups: mappedFollowups,
            missions: mappedMissions,
            recentEvents: mappedEvents
        )
    }

    private static func shouldIncludeInOperatorInbox(_ question: BurnBarPendingQuestionSnapshot) -> Bool {
        stringValue(in: question.metadata["ingestion_source"]) != BurnBarControllerProjectIngestionSource.appActivity.rawValue
    }

    private static func shouldIncludeInOperatorInbox(
        _ followup: BurnBarFollowupSnapshot,
        visibleQuestionIDs: Set<String>
    ) -> Bool {
        guard let questionID = followup.questionID?.rawValue else {
            return true
        }
        return visibleQuestionIDs.contains(questionID)
    }

    private static func controllerHeadline(questionCount: Int, followupCount: Int) -> String {
        if questionCount > 0 && followupCount > 0 {
            return "\(questionCount) pending question\(questionCount == 1 ? "" : "s") and \(followupCount) followup\(followupCount == 1 ? "" : "s") need attention."
        }
        if questionCount > 0 {
            return "\(questionCount) pending question\(questionCount == 1 ? "" : "s") need an answer."
        }
        if followupCount > 0 {
            return "\(followupCount) followup\(followupCount == 1 ? "" : "s") are still open."
        }
        return "Controller runtime is quiet."
    }

    private static func freshnessLabel(for freshness: BurnBarControllerFreshnessState) -> String {
        switch freshness {
        case .fresh: return "Fresh local signal."
        case .aging: return "Aging review signal."
        case .stale: return "Review signal is stale."
        case .provisional: return "Controller view is provisional."
        case .missing: return "Controller view is awaiting its first review."
        }
    }

    private static func notificationLabel(from health: BurnBarNotificationHealthSnapshot) -> String {
        let localHealthy = health.channels.contains { $0.channel == .local && $0.status == .healthy }
        let telegramHealthy = health.channels.contains { $0.channel == .telegram && $0.status == .healthy }
        let needsSetup = health.channels.contains { [.degraded, .unauthorized].contains($0.status) }
        if localHealthy && telegramHealthy {
            return "Telegram and local notifications armed"
        }
        if telegramHealthy {
            return "Telegram armed"
        }
        if localHealthy {
            return "Local notifications armed"
        }
        if needsSetup {
            return "Notifications need setup"
        }
        return "Notifications optional"
    }

    private static func replayLabel(from runs: [BurnBarSimulatorRunSnapshot]) -> String {
        guard let latest = runs.min(by: { $0.startedAt > $1.startedAt }) else {
            return "Replay idle"
        }
        let status: String
        switch latest.status {
        case .idle: status = "Replay idle"
        case .queued: status = "Replay queued"
        case .running: status = "Replay running"
        case .completed: status = "Replay complete"
        case .failed: status = "Replay failed"
        }
        return "\(status): \(latest.scenarioName)"
    }

    private static func questionState(for status: BurnBarPendingQuestionStatus) -> OpenBurnBarControllerQuestionState {
        switch status {
        case .pending: return .pending
        case .answered: return .answered
        case .dismissed, .expired: return .dismissed
        }
    }

    private static func questionPriority(for priority: BurnBarPendingQuestionPriority) -> OpenBurnBarControllerQuestionPriority {
        switch priority {
        case .critical, .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }

    private static func questionDeepLinkKind(
        for kind: BurnBarQuestionDeepLinkKind
    ) -> OpenBurnBarControllerQuestionDeepLinkKind {
        switch kind {
        case .sessionLog: return .sessionLog
        case .dashboard: return .dashboard
        case .project: return .project
        case .settings: return .settings
        }
    }

    private static func followupState(for status: BurnBarFollowupStatus) -> OpenBurnBarControllerFollowupState {
        switch status {
        case .open: return .open
        case .done: return .done
        case .snoozed: return .snoozed
        }
    }

    private static func followupKind(for kind: BurnBarFollowupKind) -> OpenBurnBarControllerFollowupKind {
        switch kind {
        case .pendingQuestion: return .pendingQuestion
        case .completedAction: return .completedAction
        case .missionReview: return .missionWork
        case .controllerNudge: return .setup
        }
    }

    private static func missionLifecycle(for status: BurnBarMissionStatus) -> OpenBurnBarMissionLifecycle {
        switch status {
        case .draft, .awaitingApproval, .approved:
            return .planned
        case .dispatching, .inProgress:
            return .running
        case .partiallyCompleted:
            return .partial
        case .failed, .cancelled:
            return .blocked
        case .completed:
            return .completed
        }
    }

    private static func missionPRState(for state: BurnBarPRLinkageState) -> OpenBurnBarControllerMissionPRState {
        switch state {
        case .opened:
            return .opened
        case .merged:
            return .merged
        case .closed:
            return .closed
        }
    }

    private static func takeoverState(for status: BurnBarAutoTakeoverStatus) -> OpenBurnBarControllerTakeoverState {
        switch status {
        case .monitoring:
            return .monitoring
        case .launched:
            return .launched
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .skipped:
            return .skipped
        }
    }

    private static func eventCategory(for family: BurnBarControllerEventFamily) -> OpenBurnBarControllerEventCategory {
        switch family {
        case .controller: return .controller
        case .question: return .question
        case .followup: return .followup
        case .mission: return .mission
        case .notification: return .notification
        case .simulator, .projection: return .replay
        case .governance: return .governance
        }
    }

    private static func readableEventTitle(for eventType: String) -> String {
        eventType
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private static func displayName(for slug: String) -> String {
        let title = slug
            .split(separator: "-", omittingEmptySubsequences: true)
            .map { $0.capitalized }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? slug : title
    }

    private static func intValue(in value: BurnBarJSONValue?) -> Int {
        switch value {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value) ?? 0
        default: return 0
        }
    }

    private static func boolValue(in value: BurnBarJSONValue?) -> Bool? {
        guard case .bool(let value) = value else { return nil }
        return value
    }

    private static func stringValue(in value: BurnBarJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func daemonSocketAuthToken() -> String? {
        let cached = daemonSocketAuthTokenLock.withLock { cachedDaemonSocketAuthToken }
        if let cached {
            return cached
        }
        let nonEmptyToken = readDaemonSocketAuthToken(
            from: controllerRuntimeSecrets,
            tokenFileURL: OpenBurnBarDaemonRuntimePaths.live().socketAuthTokenFileURL
        )
        cacheDaemonSocketAuthToken(nonEmptyToken)
        return nonEmptyToken
    }

    /// Resolves the daemon socket auth token from a `KeychainStore`, trimming
    /// whitespace and collapsing an empty value to `nil`.
    ///
    /// The read goes through `credentialIfPresent`, not `try?`: a genuinely
    /// absent token still yields `nil` (the daemon simply has no socket token
    /// provisioned yet), but a real Keychain fault — a locked keychain, an ACL
    /// denial, an unhandled `OSStatus`, or corrupt data — is logged via
    /// `AppLogger` instead of silently collapsing into the same `nil` as
    /// "no token configured", which would let a broken keychain masquerade as
    /// an unauthenticated daemon and mint unsigned RPCs without a diagnostic.
    ///
    /// Exposed at file-internal visibility so the fault path is exercisable
    /// with an injected `KeychainStore` backend in tests.
    static func readDaemonSocketAuthToken(from secrets: KeychainStore, tokenFileURL: URL? = nil) -> String? {
        if let tokenFileURL,
           let fileToken = readDaemonSocketAuthTokenFile(at: tokenFileURL) {
            return fileToken
        }
        if let storedToken = secrets.credentialIfPresent(
            for: OpenBurnBarCore.OpenBurnBarIdentity.daemonSocketAuthTokenAccount,
            allowUserInteraction: false,
            event: "daemon_socket_token_read_failed"
        ) {
            let token = storedToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return token
            }
        }
        return nil
    }

    static func readDaemonSocketAuthTokenFile(at url: URL) -> String? {
        do {
            let token = try String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError {
                return nil
            }
            AppLogger.daemon.error(
                "daemon_socket_token_file_read_failed",
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return nil
        }
    }

    private static func mapConnectFailure() -> OpenBurnBarDaemonManagerError {
        let code = errno
        if code == ETIMEDOUT || code == EAGAIN {
            return .rpcTimedOut(seconds: 30)
        }
        return .rpcError("Daemon socket connect failed: \(POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription)")
    }

    private static func sendEncoded<Request: Encodable, Response: Codable & Sendable>(
        _ request: Request,
        socketURL: URL
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor != -1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var noSigPipe: Int32 = 1
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        configureIOTimeouts(for: fileDescriptor)

        var address = try socketAddress(for: socketURL.path)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let managerError = mapConnectFailure()
            logDaemonFailure(OpenBurnBarError.fromDaemonManager(managerError))
            throw managerError
        }

        let encoder = JSONEncoder()
        let payload = try encoder.encode(request) + Data([0x0A])
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                guard bytesWritten > 0 else {
                    let code = errno
                    if code == ETIMEDOUT || code == EAGAIN {
                        throw OpenBurnBarDaemonManagerError.rpcTimedOut(seconds: 30)
                    }
                    throw POSIXError(.init(rawValue: code) ?? .EIO)
                }
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        response.reserveCapacity(65_536)
        // 64KB chunks: large responses (controller snapshots, mission
        // lists) used to cost one read() syscall per KB
        // (docs/architecture/macos-performance.md §16).
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 {
                break
            }
            guard bytesRead > 0 else {
                let code = errno
                if code == ETIMEDOUT || code == EAGAIN {
                    throw OpenBurnBarDaemonManagerError.rpcTimedOut(seconds: 30)
                }
                throw POSIXError(.init(rawValue: code) ?? .EIO)
            }
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A {
                break
            }
        }

        while response.last == 0x0A || response.last == 0x0D {
            response.removeLast()
        }

        guard response.isEmpty == false else {
            throw OpenBurnBarDaemonManagerError.emptyResponse
        }

        do {
            return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
        } catch is DecodingError {
            throw OpenBurnBarDaemonManagerError.rpcError(
                "The daemon response did not match the expected OpenBurnBar RPC envelope."
            )
        }
    }

    private static func configureIOTimeouts(for fileDescriptor: Int32, seconds: Int = 30) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    private static func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                rawBuffer[index] = byte
            }
        }

        return address
    }

    // MARK: - AI Inbox control plane
    //
    // Inbox *reads* go straight to the shared SQLite database (see
    // `ControlPlaneStore+AIInbox`) because the rows are already local and the
    // surface should render even while the daemon restarts. These calls are the
    // exception: configuration and "analyze now" are daemon-owned state, and the
    // daemon must stay the single writer of both — it owns the loop, the
    // credentials, and the egress policy.
    //
    // They live in this file rather than an extension because `send` is
    // deliberately private; reaching them from outside would mean widening the
    // socket client's encapsulation for no benefit.

    static func inboxConfiguration(at socketURL: URL) throws -> BurnBarInboxConfig {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try send(
            BurnBarRPCRequestEnvelope(method: .inboxConfigGet),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    /// Returns the config the daemon actually stored, which can differ from the
    /// request: every value is re-clamped on write. Callers should render the
    /// response rather than assume their request was accepted verbatim.
    @discardableResult
    static func updateInboxConfiguration(
        _ config: BurnBarInboxConfig,
        at socketURL: URL
    ) throws -> BurnBarInboxConfig {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxConfig> = try send(
            BurnBarRPCRequestEnvelopeWithParams(method: .inboxConfigUpdate, params: config),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    static func runInboxNow(force: Bool, at socketURL: URL) throws -> BurnBarInboxRunNowResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxRunNowResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxRunNow,
                params: BurnBarInboxRunNowRequest(force: force)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    /// Tick telemetry plus today's spend. Read over RPC rather than from SQLite
    /// because the authoritative spend figure lives in the daemon's usage ledger,
    /// which the app's mirror lags behind.
    static func inboxRuns(limit: Int = 20, at socketURL: URL) throws -> BurnBarInboxRunsResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxRunsResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxRunsRecent,
                params: BurnBarInboxRunsRequest(limit: limit)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    // MARK: Founder Lens — threads, plans, memory export

    static func inboxThread(fingerprint: String, at socketURL: URL) throws -> BurnBarInboxThread? {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxThreadGetResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxThreadGet,
                params: BurnBarInboxThreadGetRequest(fingerprint: fingerprint)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.thread
    }

    /// A refusal (budget, egress, disabled) arrives as a result with
    /// `refusalReason` set — render it; it is the answer.
    static func inboxReply(
        fingerprint: String,
        bodyMarkdown: String,
        at socketURL: URL
    ) throws -> BurnBarInboxReplyResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxReplyResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxReply,
                params: BurnBarInboxReplyRequest(fingerprint: fingerprint, bodyMarkdown: bodyMarkdown)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    static func inboxPlans(
        statuses: [BurnBarInboxPlanStatus] = [],
        at socketURL: URL
    ) throws -> [BurnBarInboxPlan] {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlansListResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansList,
                params: BurnBarInboxPlansListRequest(statuses: statuses)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.plans
    }

    static func inboxPlanAccept(
        candidate: BurnBarInboxPlanCandidate,
        pack: String,
        at socketURL: URL
    ) throws -> BurnBarInboxPlanAcceptResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlanAcceptResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansAccept,
                params: BurnBarInboxPlanAcceptRequest(candidate: candidate, pack: pack)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    @discardableResult
    static func inboxPlanUpdateStep(
        stepID: String,
        status: BurnBarInboxPlanStepStatus? = nil,
        missionID: String? = nil,
        followupID: String? = nil,
        at socketURL: URL
    ) throws -> BurnBarInboxPlanStep {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlanUpdateStepResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansUpdateStep,
                params: BurnBarInboxPlanUpdateStepRequest(
                    stepID: stepID,
                    status: status,
                    missionID: missionID,
                    followupID: followupID
                )
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.step
    }

    @discardableResult
    static func inboxPlanGrade(
        stepID: String,
        grade: Int,
        noteMarkdown: String? = nil,
        at socketURL: URL
    ) throws -> BurnBarInboxPlanGradeResponse {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxPlanGradeResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxPlansGrade,
                params: BurnBarInboxPlanGradeRequest(stepID: stepID, grade: grade, noteMarkdown: noteMarkdown)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result
    }

    /// Full-set push of approved inbox-scoped snippets (revocation by omission).
    @discardableResult
    static func inboxMemoryExport(
        entries: [BurnBarInboxMemoryExportEntry],
        at socketURL: URL
    ) throws -> Int {
        let envelope: BurnBarRPCResponseEnvelope<BurnBarInboxMemoryExportResponse> = try send(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .inboxMemoryExport,
                params: BurnBarInboxMemoryExportRequest(entries: entries)
            ),
            socketURL: socketURL
        )
        if let error = envelope.error { throw OpenBurnBarDaemonManagerError.rpcError(error.message) }
        guard let result = envelope.result else { throw OpenBurnBarDaemonManagerError.emptyResponse }
        return result.stored
    }

    /// Create a Mission Control follow-up (capability `mission_control`).
    /// Used by the Founder Plan promote flow; the daemon evaluates and owns
    /// the nudge schedule from here.
    @discardableResult
    static func followupCreate(
        _ request: BurnBarFollowupCreateRequest,
        at socketURL: URL
    ) throws -> BurnBarFollowupMutationResponse {
        try requestResult(
            BurnBarRPCRequestEnvelopeWithParams(
                method: .followupCreate,
                params: request
            ),
            socketURL: socketURL
        )
    }

}
