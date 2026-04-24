import OpenBurnBarCore
import Foundation

// MARK: - Internal supporting types shared across extension files

struct BurnBarRunExecutionPlan: Sendable {
    let requiresApproval: Bool
    let failUntilAttempt: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let approvalTitle: String
    let approvalMessage: String

    init(request: BurnBarRunCreateRequest) {
        self.requiresApproval = request.metadata.boolValue(forKey: "requiresApproval") ?? false
        self.failUntilAttempt = request.metadata.intValue(forKey: "failUntilAttempt") ?? 0
        self.inputTokens = request.metadata.intValue(forKey: "inputTokens") ?? max(1, request.prompt.count / 4)
        self.outputTokens = request.metadata.intValue(forKey: "outputTokens") ?? 12
        self.cacheCreationTokens = request.metadata.intValue(forKey: "cacheCreationTokens") ?? 0
        self.cacheReadTokens = request.metadata.intValue(forKey: "cacheReadTokens") ?? 0
        self.approvalTitle = request.metadata.stringValue(forKey: "approvalTitle")
            ?? "Approve burnbar_action"
        self.approvalMessage = request.metadata.stringValue(forKey: "approvalMessage")
            ?? "OpenBurnBar needs approval before continuing this tool step."
    }
}

struct BurnBarManagedRun: Sendable {
    let runID: BurnBarRunID
    let originalPrompt: String
    let modelID: String
    let metadata: [String: BurnBarJSONValue]
    var intent: BurnBarAgentIntent
    var planOutline: BurnBarPlanOutline
    var attempt: Int
    var route: BurnBarProviderRoute
    var plan: BurnBarRunExecutionPlan
    var snapshot: BurnBarRunStateSnapshot
    var approvalRequest: BurnBarApprovalRequest?
    var approvalResolvedForAttempt: Bool
    var activeToolCallID: String?
    var pendingApprovalToolInvocation: BurnBarToolInvocation?
    var lastToolCall: BurnBarToolCallSnapshot?
    var workflowStep: Int
    var workflowReadContent: String?
    var lastReadFilePath: String?
    var searchResultPaths: [String]
    var companionToolCompleted: Bool
    var lastRecoveryDecision: BurnBarRecoveryDecision?
    var loopState: BurnBarAgentLoopState
}

extension Dictionary where Key == String, Value == BurnBarJSONValue {
    func boolValue(forKey key: String) -> Bool? {
        guard case .bool(let value)? = self[key] else { return nil }
        return value
    }

    func stringValue(forKey key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }

    func intValue(forKey key: String) -> Int? {
        guard case .number(let value)? = self[key] else { return nil }
        return Int(value)
    }
}

extension BurnBarJSONValue {
    func objectValue() -> [String: BurnBarJSONValue]? {
        guard case .object(let value) = self else {
            return nil
        }
        return value
    }

    func stringValue() -> String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }
}

// MARK: - BurnBarRunService actor (public API facade)

public actor BurnBarRunService {
    public static let controllerRuntimeClientID = BurnBarClientID(rawValue: "openburnbar-controller-runtime")
    public static let controllerRuntimeSessionID = BurnBarSessionID(rawValue: "openburnbar-controller-runtime")

    let router: BurnBarProviderRouter
    let usageRecorder: BurnBarUsageRecorder
    let clientRegistry: BurnBarClientRegistry
    let providerExecutor: any BurnBarProviderExecuting
    let workspaceBridgeBroker: BurnBarWorkspaceBridgeBroker
    let plannerService: BurnBarPlannerService
    let contextSelector: BurnBarContextSelector
    let agentLoopService: BurnBarAgentLoopService
    let recoveryEngine: BurnBarRecoveryEngine
    let policyEngine: BurnBarPolicyEngine
    let runJournal: BurnBarRunJournal
    let connectorPlaneService: BurnBarConnectorPlaneService
    let browserToolService: BurnBarBrowserToolService
    let logger: BurnBarDaemonLogger

    var runs: [BurnBarRunID: BurnBarManagedRun] = [:]
    var runOrder: [BurnBarRunID] = []
    var restoredPersistedRuns = false
    let maxInMemoryRuns: Int
    let evictionPolicy: BurnBarRunRegistryEvictionPolicy

    public init(
        router: BurnBarProviderRouter,
        usageRecorder: BurnBarUsageRecorder,
        clientRegistry: BurnBarClientRegistry,
        providerExecutor: any BurnBarProviderExecuting = BurnBarOpenAICompatibleProviderExecutor(),
        workspaceBridgeBroker: BurnBarWorkspaceBridgeBroker = BurnBarWorkspaceBridgeBroker(),
        plannerService: BurnBarPlannerService = BurnBarPlannerService(),
        contextSelector: BurnBarContextSelector = BurnBarContextSelector(),
        agentLoopService: BurnBarAgentLoopService = BurnBarAgentLoopService(),
        recoveryEngine: BurnBarRecoveryEngine = BurnBarRecoveryEngine(),
        policyEngine: BurnBarPolicyEngine = BurnBarPolicyEngine(),
        runJournal: BurnBarRunJournal = BurnBarRunJournal(),
        connectorPlaneService: BurnBarConnectorPlaneService = BurnBarConnectorPlaneService(),
        browserToolService: BurnBarBrowserToolService = BurnBarBrowserToolService(),
        maxInMemoryRuns: Int = 200,
        evictionPolicy: BurnBarRunRegistryEvictionPolicy = .maxCount(200),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "run-service")
    ) {
        self.router = router
        self.usageRecorder = usageRecorder
        self.clientRegistry = clientRegistry
        self.providerExecutor = providerExecutor
        self.workspaceBridgeBroker = workspaceBridgeBroker
        self.plannerService = plannerService
        self.contextSelector = contextSelector
        self.agentLoopService = agentLoopService
        self.recoveryEngine = recoveryEngine
        self.policyEngine = policyEngine
        self.runJournal = runJournal
        self.connectorPlaneService = connectorPlaneService
        self.browserToolService = browserToolService
        self.maxInMemoryRuns = max(maxInMemoryRuns, 1)
        self.evictionPolicy = evictionPolicy
        self.logger = logger
    }

    // MARK: - Public API

    public func createRun(_ request: BurnBarRunCreateRequest) async throws -> BurnBarRunCreateResponse {
        try await createRun(request, enforceClientOwnership: true)
    }

    public func createControllerReviewRun(
        prompt: String,
        modelID: String,
        metadata: [String: BurnBarJSONValue] = [:]
    ) async throws -> BurnBarRunCreateResponse {
        try await createDaemonManagedRun(
            prompt: prompt,
            modelID: modelID,
            metadata: metadata.merging(["controllerReview": .bool(true)]) { _, new in new }
        )
    }

    public func createDaemonManagedRun(
        prompt: String,
        modelID: String,
        metadata: [String: BurnBarJSONValue] = [:]
    ) async throws -> BurnBarRunCreateResponse {
        let effectiveMetadata = metadata
        let request = BurnBarRunCreateRequest(
            clientID: Self.controllerRuntimeClientID,
            sessionID: Self.controllerRuntimeSessionID,
            prompt: prompt,
            modelID: modelID,
            metadata: effectiveMetadata
        )
        return try await createRun(request, enforceClientOwnership: false)
    }

    public func snapshot(for runID: BurnBarRunID) async -> BurnBarRunStateSnapshot? {
        do {
            try await restorePersistedRunsIfNeeded()
            try await restoreSingleRunIfNeeded(runID: runID)
        } catch {
            logger.warning(
                "restore_persisted_runs_failed",
                metadata: ["runID": "\(runID)", "error": "\(error)"]
            )
        }
        return runs[runID]?.snapshot
    }

    public func listRuns(_ request: BurnBarRunListRequest) async throws -> BurnBarRunListResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireAttached(request.clientID)
        let snapshots = runOrder
            .compactMap { runs[$0]?.snapshot }
            .sorted { $0.updatedAt > $1.updatedAt }
            .dropFirst(request.offset)
            .prefix(request.limit)
        return BurnBarRunListResponse(runs: Array(snapshots))
    }

    public func getRun(_ request: BurnBarRunGetRequest) async throws -> BurnBarRunDetailResponse {
        try await restorePersistedRunsIfNeeded()
        try await restoreSingleRunIfNeeded(runID: request.runID)
        try await clientRegistry.requireAttached(request.clientID)
        guard let run = runs[request.runID] else {
            throw BurnBarRunServiceError.runNotFound(request.runID)
        }

        return BurnBarRunDetailResponse(
            run: run.snapshot,
            approvalRequest: run.approvalRequest,
            pendingToolCall: await workspaceBridgeBroker.activeCall(for: request.runID),
            loopState: run.loopState,
            arbitration: await clientRegistry.arbitration()
        )
    }

    public func pollRuns(_ request: BurnBarRunPollRequest) async throws -> BurnBarRunEventBatch {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireAttached(request.clientID, sessionID: request.sessionID)

        let scopedRuns: [BurnBarManagedRun]
        if let runID = request.runID {
            try await restoreSingleRunIfNeeded(runID: runID)
            guard let run = runs[runID] else {
                throw BurnBarRunServiceError.runNotFound(runID)
            }
            scopedRuns = [run]
        } else {
            scopedRuns = Array(runOrder
                .compactMap { runs[$0] }
                .sorted { $0.snapshot.updatedAt > $1.snapshot.updatedAt }
                .prefix(request.limit))
        }

        let runIDs = Set(scopedRuns.map(\.runID))
        let approvals = scopedRuns.compactMap(\.approvalRequest)
        let pendingToolCalls = await workspaceBridgeBroker.activeCallsList(for: runIDs)

        return BurnBarRunEventBatch(
            runs: scopedRuns.map(\.snapshot),
            approvals: approvals,
            pendingToolCalls: pendingToolCalls,
            arbitration: await clientRegistry.arbitration(),
            emittedAt: Date()
        )
    }

    public func executeTool(_ request: BurnBarToolExecutionRequest) async throws -> BurnBarToolExecutionResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireAttached(request.clientID, sessionID: request.sessionID)
        try await clientRegistry.requireController(request.clientID)

        if let runID = request.runID, runs[runID] == nil {
            return BurnBarToolExecutionResponse(disposition: .runNotFound)
        }

        guard let toolCall = await workspaceBridgeBroker.claimToolCall(runID: request.runID, clientID: request.clientID) else {
            return BurnBarToolExecutionResponse(disposition: .noPendingToolCall)
        }

        if var run = runs[toolCall.runID], run.snapshot.phase == .waitingOnCompanion {
            try transition(&run, to: .executingTool)
            runs[toolCall.runID] = run
        }

        return BurnBarToolExecutionResponse(disposition: .dispatched, toolCall: toolCall)
    }

    public func submitToolResult(_ request: BurnBarToolResultSubmissionRequest) async throws -> BurnBarRunDetailResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireAttached(request.clientID, sessionID: request.sessionID)
        try await clientRegistry.requireController(request.clientID)
        try await restoreSingleRunIfNeeded(runID: request.runID)
        guard var run = runs[request.runID] else {
            throw BurnBarRunServiceError.runNotFound(request.runID)
        }

        if run.snapshot.phase == .waitingOnCompanion {
            try transition(&run, to: .executingTool)
        }

        let callSnapshot = try await workspaceBridgeBroker.applyToolResult(request)
        run.lastToolCall = callSnapshot
        run.activeToolCallID = nil
        _ = await workspaceBridgeBroker.clearActiveCall(runID: request.runID, callID: request.callID)
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .toolCompleted,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(callSnapshot),
                emittedAt: Date()
            )
        )

        if request.succeeded {
            try applySuccessfulToolResult(callSnapshot, to: &run)
            try transition(&run, to: .planning, activeApprovalID: nil)
            try await continueExecution(for: &run)
        } else {
            let error = request.error ?? BurnBarToolExecutionError(
                code: .unknown,
                message: request.error?.message ?? "Workspace companion reported a failed tool call."
            )
            try await handleToolFailure(error: error, callSnapshot: callSnapshot, run: &run)
        }

        try await writeCheckpoint(for: run)
        runs[request.runID] = run

        return BurnBarRunDetailResponse(
            run: run.snapshot,
            approvalRequest: run.approvalRequest,
            pendingToolCall: await workspaceBridgeBroker.activeCall(for: request.runID),
            loopState: run.loopState,
            arbitration: await clientRegistry.arbitration()
        )
    }

    public func cancelRun(_ request: BurnBarRunCancelRequest) async throws -> BurnBarRunDetailResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireController(request.clientID)
        try await restoreSingleRunIfNeeded(runID: request.runID)
        guard var run = runs[request.runID] else {
            throw BurnBarRunServiceError.runNotFound(request.runID)
        }

        let message = request.reason ?? "Cancelled by controller."
        try transition(&run, to: .cancelled, errorMessage: message, activeApprovalID: nil)
        run.approvalRequest = nil
        run.activeToolCallID = nil
        _ = await workspaceBridgeBroker.cancelActiveCall(for: request.runID)
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .runCancelled,
                phase: run.snapshot.phase,
                payload: .object(["message": .string(message)]),
                emittedAt: Date()
            )
        )
        try await writeCheckpoint(for: run)
        runs[request.runID] = run

        logger.notice(
            "run_cancelled",
            metadata: [
                "run_id": request.runID.rawValue,
                "client_id": request.clientID.rawValue
            ]
        )

        return try await getRun(BurnBarRunGetRequest(runID: request.runID, clientID: request.clientID))
    }

    public func retryRun(_ request: BurnBarRunRetryRequest) async throws -> BurnBarRunDetailResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireController(request.clientID)
        try await restoreSingleRunIfNeeded(runID: request.runID)
        guard var run = runs[request.runID] else {
            throw BurnBarRunServiceError.runNotFound(request.runID)
        }
        guard run.snapshot.phase == .failed else {
            throw BurnBarRunServiceError.retryRequiresFailedRun(request.runID)
        }

        let sessionID = await clientRegistry.sessionID(for: request.clientID) ?? run.snapshot.sessionID
        let retryRequest = BurnBarRunCreateRequest(
            clientID: request.clientID,
            sessionID: sessionID,
            prompt: run.originalPrompt,
            modelID: run.modelID,
            metadata: run.metadata
        )

        let route: BurnBarProviderRoute
        do {
            route = try await router.route(modelName: retryRequest.modelID)
        } catch {
            throw BurnBarRunServiceError.routeFailed(error.localizedDescription)
        }
        let plannedRun = try plannerService.plan(for: retryRequest)

        run.attempt += 1
        run.route = route
        run.intent = plannedRun.intent
        run.planOutline = plannedRun.outline
        run.plan = BurnBarRunExecutionPlan(request: retryRequest)
        run.approvalRequest = nil
        run.approvalResolvedForAttempt = false
        run.activeToolCallID = nil
        run.pendingApprovalToolInvocation = nil
        run.lastToolCall = nil
        run.workflowStep = 0
        run.workflowReadContent = nil
        run.lastReadFilePath = nil
        run.searchResultPaths = []
        run.companionToolCompleted = false
        run.lastRecoveryDecision = nil
        run.loopState = BurnBarAgentLoopState()
        _ = await workspaceBridgeBroker.cancelActiveCall(for: request.runID)
        run.snapshot = BurnBarRunStateSnapshot(
            runID: run.runID,
            clientID: retryRequest.clientID,
            sessionID: retryRequest.sessionID,
            phase: run.snapshot.phase,
            modelID: retryRequest.modelID,
            updatedAt: Date(),
            errorMessage: nil
        )

        try transition(&run, to: .planning)
        try await appendJournalBootstrap(for: run)
        try await continueExecution(for: &run)
        try await writeCheckpoint(for: run)
        runs[request.runID] = run

        logger.notice(
            "run_retried",
            metadata: [
                "run_id": request.runID.rawValue,
                "attempt": "\(run.attempt)"
            ]
        )

        return try await getRun(BurnBarRunGetRequest(runID: request.runID, clientID: request.clientID))
    }

    public func respondToApproval(_ request: BurnBarApprovalRespondRequest) async throws -> BurnBarRunDetailResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireController(request.response.clientID)
        guard let runID = try await findRunIDByApprovalID(request.response.approvalID),
              var run = runs[runID] else {
            throw BurnBarRunServiceError.approvalNotFound(request.response.approvalID)
        }
        guard run.snapshot.phase == .awaitingApproval, run.approvalRequest != nil else {
            throw BurnBarRunServiceError.approvalAlreadyResolved(request.response.approvalID)
        }

        switch request.response.decision {
        case .approve:
            let pendingInvocation = run.pendingApprovalToolInvocation
            run.approvalRequest = nil
            run.pendingApprovalToolInvocation = nil
            if pendingInvocation == nil {
                run.approvalResolvedForAttempt = true
            }
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .approvalResponded,
                    phase: run.snapshot.phase,
                    payload: try BurnBarJSONValue.fromEncodable(request.response),
                    emittedAt: Date()
                )
            )
            if let pendingInvocation {
                try transition(&run, to: .planning, activeApprovalID: nil)
                try await enqueueCompanionToolCall(pendingInvocation, for: &run)
            } else {
                try transition(&run, to: .planning, activeApprovalID: nil)
                try await continueExecution(for: &run)
            }
        case .reject, .cancel:
            run.approvalRequest = nil
            run.activeToolCallID = nil
            run.pendingApprovalToolInvocation = nil
            _ = await workspaceBridgeBroker.cancelActiveCall(for: runID)
            let decisionText = request.response.decision == .reject ? "rejected" : "cancelled"
            let message = request.response.note ?? "Approval \(decisionText) by controller."
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .approvalResponded,
                    phase: run.snapshot.phase,
                    payload: try BurnBarJSONValue.fromEncodable(request.response),
                    emittedAt: Date()
                )
            )
            try transition(&run, to: .cancelled, errorMessage: message, activeApprovalID: nil)
        }

        try await writeCheckpoint(for: run)
        runs[runID] = run

        logger.notice(
            "approval_responded",
            metadata: [
                "approval_id": request.response.approvalID.rawValue,
                "decision": request.response.decision.rawValue,
                "run_id": runID.rawValue
            ]
        )

        return try await getRun(BurnBarRunGetRequest(runID: runID, clientID: request.response.clientID))
    }

    // MARK: - Eviction & Lazy Restore

    func evictIfNeeded() {
        guard case .maxCount(let limit) = evictionPolicy else { return }
        guard runs.count > limit else { return }

        let terminalPhases: Set<BurnBarRunPhase> = [.completed, .failed, .cancelled]
        let candidates = runOrder.compactMap { runID -> (BurnBarRunID, Date)? in
            guard let run = runs[runID], terminalPhases.contains(run.snapshot.phase) else { return nil }
            // Never evict runs with pending approvals or active tool calls
            guard run.approvalRequest == nil, run.activeToolCallID == nil else { return nil }
            return (runID, run.snapshot.updatedAt)
        }

        let sortedCandidates = candidates.sorted { $0.1 < $1.1 }
        var evicted = 0
        for (runID, _) in sortedCandidates {
            if runs.count <= limit { break }
            runs.removeValue(forKey: runID)
            runOrder.removeAll { $0 == runID }
            evicted += 1
        }

        if evicted > 0 {
            logger.debug(
                "run_registry_evicted",
                metadata: [
                    "evicted_count": "\(evicted)",
                    "remaining_count": "\(runs.count)",
                    "limit": "\(limit)"
                ]
            )
        }

        if runs.count > limit {
            logger.warning(
                "run_registry_eviction_failed",
                metadata: [
                    "run_count": "\(runs.count)",
                    "limit": "\(limit)",
                    "reason": "insufficient_terminal_runs"
                ]
            )
        }
    }

    private func restoreSingleRunIfNeeded(runID: BurnBarRunID) async throws {
        guard runs[runID] == nil else { return }

        guard let checkpoint = try await runJournal.checkpoint(for: runID) else {
            return
        }

        let route: BurnBarProviderRoute
        do {
            route = try await router.route(modelName: checkpoint.modelID)
        } catch {
            logger.error(
                "run_restore_skipped_route_failed",
                metadata: [
                    "run_id": checkpoint.runID.rawValue,
                    "model_id": checkpoint.modelID,
                    "error": error.localizedDescription
                ]
            )
            return
        }

        let retryRequest = BurnBarRunCreateRequest(
            clientID: checkpoint.clientID,
            sessionID: checkpoint.sessionID,
            prompt: checkpoint.originalPrompt,
            modelID: checkpoint.modelID,
            metadata: checkpoint.metadata
        )
        let plan = BurnBarRunExecutionPlan(request: retryRequest)
        let approvalID = checkpoint.activeApprovalID ?? checkpoint.approvalRequest?.approvalID
        let restoredRun = BurnBarManagedRun(
            runID: checkpoint.runID,
            originalPrompt: checkpoint.originalPrompt,
            modelID: checkpoint.modelID,
            metadata: checkpoint.metadata,
            intent: checkpoint.intent,
            planOutline: checkpoint.planOutline,
            attempt: checkpoint.attempt,
            route: route,
            plan: plan,
            snapshot: BurnBarRunStateSnapshot(
                runID: checkpoint.runID,
                clientID: checkpoint.clientID,
                sessionID: checkpoint.sessionID,
                phase: checkpoint.phase,
                modelID: checkpoint.modelID,
                updatedAt: checkpoint.updatedAt,
                errorMessage: checkpoint.errorMessage,
                activeApprovalID: approvalID
            ),
            approvalRequest: checkpoint.approvalRequest,
            approvalResolvedForAttempt: checkpoint.approvalResolvedForAttempt,
            activeToolCallID: checkpoint.lastToolCallID,
            pendingApprovalToolInvocation: checkpoint.pendingApprovalToolInvocation,
            lastToolCall: checkpoint.lastToolCall,
            workflowStep: checkpoint.workflowStep,
            workflowReadContent: checkpoint.workflowReadContent,
            lastReadFilePath: checkpoint.loopState.lastContextSnapshot?.lastReadFilePath,
            searchResultPaths: checkpoint.loopState.lastContextSnapshot?.searchResultPaths ?? [],
            companionToolCompleted: checkpoint.companionToolCompleted,
            lastRecoveryDecision: checkpoint.lastRecoveryDecision,
            loopState: checkpoint.loopState
        )
        runs[checkpoint.runID] = restoredRun
        if !runOrder.contains(checkpoint.runID) {
            runOrder.append(checkpoint.runID)
        }

        if let lastToolCall = checkpoint.lastToolCall {
            await workspaceBridgeBroker.restoreActiveCall(lastToolCall)
        }

        logger.debug(
            "run_restored_lazily",
            metadata: [
                "run_id": checkpoint.runID.rawValue,
                "phase": checkpoint.phase.rawValue
            ]
        )
    }

    private func findRunIDByApprovalID(_ approvalID: BurnBarApprovalID) async throws -> BurnBarRunID? {
        // First check in-memory runs
        if let runID = runs.first(where: { $0.value.approvalRequest?.approvalID == approvalID })?.key {
            return runID
        }

        // Fallback: scan checkpoints for the approval
        let checkpoints = try await runJournal.allCheckpoints()
        return checkpoints.first(where: { $0.approvalRequest?.approvalID == approvalID || $0.activeApprovalID == approvalID })?.runID
    }
}
