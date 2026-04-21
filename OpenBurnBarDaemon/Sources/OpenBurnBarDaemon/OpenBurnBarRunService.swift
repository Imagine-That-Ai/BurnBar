import OpenBurnBarCore
import Foundation

private struct BurnBarRunExecutionPlan: Sendable {
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

private struct BurnBarManagedRun: Sendable {
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

public actor BurnBarRunService {
    public static let controllerRuntimeClientID = BurnBarClientID(rawValue: "openburnbar-controller-runtime")
    public static let controllerRuntimeSessionID = BurnBarSessionID(rawValue: "openburnbar-controller-runtime")

    private let router: BurnBarProviderRouter
    private let usageRecorder: BurnBarUsageRecorder
    private let clientRegistry: BurnBarClientRegistry
    private let providerExecutor: any BurnBarProviderExecuting
    private let workspaceBridgeBroker: BurnBarWorkspaceBridgeBroker
    private let plannerService: BurnBarPlannerService
    private let contextSelector: BurnBarContextSelector
    private let agentLoopService: BurnBarAgentLoopService
    private let recoveryEngine: BurnBarRecoveryEngine
    private let policyEngine: BurnBarPolicyEngine
    private let runJournal: BurnBarRunJournal
    private let connectorPlaneService: BurnBarConnectorPlaneService
    private let browserToolService: BurnBarBrowserToolService
    private let logger: BurnBarDaemonLogger

    private var runs: [BurnBarRunID: BurnBarManagedRun] = [:]
    private var runOrder: [BurnBarRunID] = []
    private var restoredPersistedRuns = false

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
        self.logger = logger
    }

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
        } catch {
            logger.warning(
                "restore_persisted_runs_failed",
                metadata: ["runID": "\(runID)", "error": "\(error)"]
            )
        }
        return runs[runID]?.snapshot
    }

    public func connectorPlaneSnapshot() async throws -> BurnBarConnectorPlaneSnapshot {
        try await connectorPlaneService.snapshot()
    }

    public func updateConnectorPlane(
        _ request: BurnBarConnectorConfigUpdateRequest
    ) async throws -> BurnBarConnectorPlaneSnapshot {
        try await connectorPlaneService.updateConfig(request)
    }

    public func performConnectorAction(
        _ request: BurnBarConnectorActionRequest
    ) async throws -> BurnBarConnectorActionResponse {
        try await connectorPlaneService.performAction(request)
    }

    public func browserToolingSnapshot() async throws -> BurnBarBrowserToolingSnapshot {
        try await browserToolService.snapshot()
    }

    public func updateBrowserTooling(
        _ request: BurnBarBrowserToolingUpdateRequest
    ) async throws -> BurnBarBrowserToolingSnapshot {
        try await browserToolService.update(request)
    }

    public func performBrowserAction(
        _ request: BurnBarBrowserActionRequest
    ) async throws -> BurnBarBrowserActionResponse {
        try await browserToolService.performAction(request)
    }

    public func listRuns(_ request: BurnBarRunListRequest) async throws -> BurnBarRunListResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireAttached(request.clientID)
        let snapshots = runOrder.compactMap { runs[$0]?.snapshot }.sorted { $0.updatedAt > $1.updatedAt }
        return BurnBarRunListResponse(runs: snapshots)
    }

    public func getRun(_ request: BurnBarRunGetRequest) async throws -> BurnBarRunDetailResponse {
        try await restorePersistedRunsIfNeeded()
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
            guard let run = runs[runID] else {
                throw BurnBarRunServiceError.runNotFound(runID)
            }
            scopedRuns = [run]
        } else {
            scopedRuns = runOrder.compactMap { runs[$0] }.sorted { $0.snapshot.updatedAt > $1.snapshot.updatedAt }
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
        guard let runID = runs.first(where: { $0.value.approvalRequest?.approvalID == request.response.approvalID })?.key,
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

    private func continueExecution(for run: inout BurnBarManagedRun) async throws {
        if let approval = policyEngine.approvalDescriptor(
            explicitApprovalRequired: run.plan.requiresApproval && !run.approvalResolvedForAttempt && run.approvalRequest == nil,
            intent: run.intent,
            tool: run.intent.requestedToolsOrEmpty.last,
            customTitle: run.plan.approvalTitle,
            customMessage: run.plan.approvalMessage
        ) {
            let approvalID = BurnBarApprovalID()
            run.approvalRequest = BurnBarApprovalRequest(
                approvalID: approvalID,
                runID: run.runID,
                tool: approval.tool,
                title: approval.title,
                message: approval.message,
                requestedAt: Date()
            )
            try transition(&run, to: .awaitingApproval, activeApprovalID: approvalID)
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .approvalRequested,
                    phase: run.snapshot.phase,
                    payload: try BurnBarJSONValue.fromEncodable(run.approvalRequest),
                    emittedAt: Date()
                )
            )
            return
        }

        if run.metadata.boolValue(forKey: "controllerReview") ?? false
            || run.metadata.boolValue(forKey: "missionExecution") ?? false
            || run.metadata.boolValue(forKey: "autoTakeover") ?? false {
            try await executeProviderOnlyRun(for: &run)
            return
        }

        if run.attempt <= run.plan.failUntilAttempt {
            try transition(
                &run,
                to: .failed,
                errorMessage: "Simulated failure on attempt \(run.attempt).",
                activeApprovalID: nil
            )
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .runFailed,
                    phase: run.snapshot.phase,
                    payload: .object(["message": .string("Simulated failure on attempt \(run.attempt).")]),
                    emittedAt: Date()
                )
            )
            try await writeCheckpoint(for: run)
            return
        }

        if run.intent.requiresWorkspaceToolExecution || run.intent.kind == .generic || run.intent.kind == .inspectWorkspace {
            try transition(&run, to: .executingTool)

            if run.intent.kind != .generic && run.intent.kind != .inspectWorkspace && run.companionToolCompleted {
                try await completeRunAndRecordUsage(for: &run)
                return
            }

            if let deterministicAction = try deterministicContextAction(for: run) {
                try await dispatchCompanionToolCall(
                    for: &run,
                    toolKind: deterministicAction.tool,
                    arguments: deterministicAction.arguments
                )
                return
            }

            if run.intent.kind == .replaceStringInFile && run.workflowStep >= 2 {
                try await completeRunAndRecordUsage(for: &run)
                return
            }

            if run.intent.kind == .generic && run.intent.requestedToolsOrEmpty.count == 1 && run.intent.toolArguments == nil {
                try await completeRunAndRecordUsage(for: &run)
                return
            }

            try await runAgentLoop(for: &run)
            return
        }

        try await executeProviderOnlyRun(for: &run)
    }

    private func continueIntentExecution(for run: inout BurnBarManagedRun) async throws {
        let selectionState = BurnBarContextSelectionState(
            workflowStep: run.workflowStep,
            lastReadContent: run.workflowReadContent,
            toolAlreadyCompleted: run.companionToolCompleted
        )

        do {
            if let action = try contextSelector.nextAction(for: run.intent, state: selectionState) {
                if run.snapshot.phase != .executingTool {
                    try transition(&run, to: .executingTool)
                }
                try await dispatchCompanionToolCall(
                    for: &run,
                    toolKind: action.tool,
                    arguments: action.arguments
                )
            } else {
                try await completeRunAndRecordUsage(for: &run)
            }
        } catch let error as BurnBarContextSelectorError {
            try transition(
                &run,
                to: .failed,
                errorMessage: error.localizedDescription,
                activeApprovalID: nil
            )
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .runFailed,
                    phase: run.snapshot.phase,
                    payload: .object(["message": .string(error.localizedDescription)]),
                    emittedAt: Date()
                )
            )
        }
    }

    private func deterministicContextAction(for run: BurnBarManagedRun) throws -> BurnBarContextAction? {
        let selectionState = BurnBarContextSelectionState(
            workflowStep: run.workflowStep,
            lastReadContent: run.workflowReadContent,
            toolAlreadyCompleted: run.companionToolCompleted
        )

        switch run.intent.kind {
        case .replaceStringInFile, .runTerminal:
            return try contextSelector.nextAction(for: run.intent, state: selectionState)
        case .inspectWorkspace:
            if run.loopState.iterationCount == 0, run.searchResultPaths.isEmpty, run.workflowReadContent == nil {
                return try contextSelector.nextAction(for: run.intent, state: selectionState)
            }
            return nil
        case .generic:
            if run.intent.requestedToolsOrEmpty.count == 1 {
                return try contextSelector.nextAction(for: run.intent, state: selectionState)
            }
            return nil
        }
    }

    private func currentContextSnapshot(for run: BurnBarManagedRun) -> BurnBarAgentContextSnapshot {
        let selectionState = BurnBarContextSelectionState(
            workflowStep: run.workflowStep,
            lastReadContent: run.workflowReadContent,
            toolAlreadyCompleted: run.companionToolCompleted
        )
        return contextSelector.makeContextSnapshot(
            for: run.intent,
            state: selectionState,
            lastReadFilePath: run.lastReadFilePath,
            searchResultPaths: run.searchResultPaths
        )
    }

    private func runAgentLoop(for run: inout BurnBarManagedRun) async throws {
        do {
            let contextSnapshot = currentContextSnapshot(for: run)
            let journalTail = try await runJournal.events(for: run.runID)
            let decision = try await agentLoopService.decideNextAction(
                request: BurnBarAgentLoopRequest(
                    objective: run.originalPrompt,
                    intent: run.intent,
                    planOutline: run.planOutline,
                    loopState: run.loopState,
                    contextSnapshot: contextSnapshot,
                    journalTail: journalTail
                ),
                route: run.route,
                providerExecutor: providerExecutor
            )

            run.loopState = BurnBarAgentLoopState(
                iterationCount: run.loopState.iterationCount + 1,
                lastDecision: decision,
                lastContextSnapshot: contextSnapshot,
                lastExecutedTool: run.loopState.lastExecutedTool,
                terminalPending: decision.action == .runTerminal
            )

            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .loopDecided,
                    phase: run.snapshot.phase,
                    payload: try BurnBarJSONValue.fromEncodable(decision),
                    emittedAt: Date()
                )
            )

            switch decision.action {
            case .searchWorkspace, .readFile, .applyPatch, .runTerminal:
                guard let tool = decision.requestedTool ?? BurnBarToolKind(rawValue: decision.action.rawValue),
                      let arguments = decision.arguments else {
                    throw BurnBarAgentLoopServiceError.invalidDecision("Tool action '\(decision.action.rawValue)' is missing tool arguments.")
                }
                run.loopState = BurnBarAgentLoopState(
                    iterationCount: run.loopState.iterationCount,
                    lastDecision: run.loopState.lastDecision,
                    lastContextSnapshot: run.loopState.lastContextSnapshot,
                    lastExecutedTool: tool,
                    terminalPending: tool == .runTerminal
                )
                try await dispatchCompanionToolCall(
                    for: &run,
                    toolKind: tool,
                    arguments: arguments
                )
            case .requestApproval:
                guard policyEngine.shouldHonorModelRequestedApproval(for: decision.requestedTool),
                      let requestedTool = decision.requestedTool else {
                    throw BurnBarAgentLoopServiceError.unsupportedAction("Model requested approval for an unsupported or low-risk action.")
                }
                let approvalID = BurnBarApprovalID()
                run.approvalRequest = BurnBarApprovalRequest(
                    approvalID: approvalID,
                    runID: run.runID,
                    tool: requestedTool,
                    title: "Approve \(requestedTool.rawValue)",
                    message: decision.message ?? "OpenBurnBar paused because the model requested approval before continuing.",
                    requestedAt: Date()
                )
                try transition(&run, to: .awaitingApproval, activeApprovalID: approvalID)
                try await appendJournalEvent(
                    BurnBarRunJournalEvent(
                        runID: run.runID,
                        kind: .approvalRequested,
                        phase: run.snapshot.phase,
                        payload: try BurnBarJSONValue.fromEncodable(run.approvalRequest),
                        emittedAt: Date()
                    )
                )
            case .complete:
                try await completeRunAndRecordUsage(for: &run)
            case .fail:
                let message = decision.message ?? "OpenBurnBar agent loop reported an unrecoverable failure."
                try transition(&run, to: .failed, errorMessage: message, activeApprovalID: nil)
                try await appendJournalEvent(
                    BurnBarRunJournalEvent(
                        runID: run.runID,
                        kind: .runFailed,
                        phase: run.snapshot.phase,
                        payload: .object(["message": .string(message)]),
                        emittedAt: Date()
                    )
                )
                try await writeCheckpoint(for: run)
            }
        } catch {
            if shouldFailOverProviderError(error) {
                let currentRoute = run.route
                let excludedRouteKey = router.routeKey(
                    providerID: currentRoute.providerID,
                    slotID: currentRoute.credentialSlotID
                )
                if let fallbackRoute = try? await router.route(
                    modelName: run.modelID,
                    excludedRouteKeys: [excludedRouteKey]
                ) {
                    await router.markRouteFailure(currentRoute, error: error)
                    run.route = fallbackRoute
                    try await appendJournalEvent(
                        BurnBarRunJournalEvent(
                            runID: run.runID,
                            kind: .recoveryDecided,
                            phase: run.snapshot.phase,
                            payload: .object([
                                "strategy": .string("provider_failover"),
                                "from_route": .string(excludedRouteKey),
                                "to_route": .string(router.routeKey(providerID: fallbackRoute.providerID, slotID: fallbackRoute.credentialSlotID))
                            ]),
                            emittedAt: Date()
                        )
                    )
                    try await runAgentLoop(for: &run)
                    return
                }
            }

            let recoveryDecision = recoveryEngine.decideLoopFailure(error)
            run.lastRecoveryDecision = recoveryDecision
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .recoveryDecided,
                    phase: run.snapshot.phase,
                    payload: try BurnBarJSONValue.fromEncodable(recoveryDecision),
                    emittedAt: Date()
                )
            )
            try transition(&run, to: .failed, errorMessage: recoveryDecision.userMessage, activeApprovalID: nil)
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .runFailed,
                    phase: run.snapshot.phase,
                    payload: .object(["message": .string(recoveryDecision.userMessage)]),
                    emittedAt: Date()
                )
            )
            try await writeCheckpoint(for: run)
        }
    }

    private func dispatchCompanionToolCall(
        for run: inout BurnBarManagedRun,
        toolKind: BurnBarToolKind,
        arguments: BurnBarJSONValue
    ) async throws {
        let invocation = BurnBarToolInvocation(
            callID: UUID().uuidString,
            runID: run.runID,
            tool: toolKind,
            arguments: arguments,
            requestedBy: run.snapshot.clientID,
            requestedAt: Date()
        )
        if try await requestMandatoryToolApprovalIfNeeded(for: &run, invocation: invocation) {
            return
        }
        try await enqueueCompanionToolCall(invocation, for: &run)
    }

    private func enqueueCompanionToolCall(
        _ invocation: BurnBarToolInvocation,
        for run: inout BurnBarManagedRun
    ) async throws {
        let snapshot = try await workspaceBridgeBroker.enqueueToolCall(invocation)
        run.activeToolCallID = snapshot.callID
        run.pendingApprovalToolInvocation = nil
        run.lastToolCall = snapshot
        try transition(&run, to: .waitingOnCompanion)
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .toolDispatched,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(snapshot),
                emittedAt: Date()
            )
        )
    }

    private func requestMandatoryToolApprovalIfNeeded(
        for run: inout BurnBarManagedRun,
        invocation: BurnBarToolInvocation
    ) async throws -> Bool {
        guard run.approvalRequest == nil,
              invocation.tool == .applyPatch || invocation.tool == .runTerminal,
              let approval = policyEngine.approvalDescriptor(
                  explicitApprovalRequired: true,
                  intent: run.intent,
                  tool: invocation.tool,
                  customTitle: nil,
                  customMessage: nil
              ) else {
            return false
        }

        if run.approvalResolvedForAttempt {
            // A run-level approval from metadata should only bypass the next risky tool call.
            run.approvalResolvedForAttempt = false
            return false
        }

        let approvalID = BurnBarApprovalID()
        run.approvalRequest = BurnBarApprovalRequest(
            approvalID: approvalID,
            runID: run.runID,
            tool: approval.tool,
            title: approval.title,
            message: approval.message,
            requestedAt: Date()
        )
        run.pendingApprovalToolInvocation = invocation
        try transition(&run, to: .awaitingApproval, activeApprovalID: approvalID)
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .approvalRequested,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(run.approvalRequest),
                emittedAt: Date()
            )
        )
        return true
    }

    private func applySuccessfulToolResult(
        _ callSnapshot: BurnBarToolCallSnapshot,
        to run: inout BurnBarManagedRun
    ) throws {
        if run.intent.kind == .replaceStringInFile {
            switch run.workflowStep {
            case 0:
                guard callSnapshot.tool == .readFile else {
                    throw BurnBarRunServiceError.invalidToolResult(
                        run.runID,
                        "Expected read_file result, received \(callSnapshot.tool.rawValue)."
                    )
                }
                guard case .object(let object)? = callSnapshot.output,
                      let content = object.stringValue(forKey: "content") else {
                    throw BurnBarRunServiceError.invalidToolResult(
                        run.runID,
                        "read_file output must include a 'content' string."
                    )
                }
                run.workflowReadContent = content
                run.workflowStep = 1
            case 1:
                guard callSnapshot.tool == .applyPatch else {
                    throw BurnBarRunServiceError.invalidToolResult(
                        run.runID,
                        "Expected apply_patch result, received \(callSnapshot.tool.rawValue)."
                    )
                }
                run.workflowStep = 2
                run.companionToolCompleted = true
            default:
                break
            }
            return
        }

        switch callSnapshot.tool {
        case .readFile:
            if let output = callSnapshot.output?.objectValue() {
                run.lastReadFilePath = output["path"]?.stringValue()
                run.workflowReadContent = output["content"]?.stringValue()
            }
        case .searchWorkspace:
            if let output = callSnapshot.output?.objectValue(),
               case .array(let matches)? = output["matches"] {
                run.searchResultPaths = matches.compactMap { match in
                    match.objectValue()?["path"]?.stringValue()
                }
            }
        case .applyPatch, .runTerminal:
            break
        }

        if run.intent.kind == .runTerminal || (run.intent.kind == .generic && run.intent.requestedToolsOrEmpty.count == 1) {
            run.companionToolCompleted = true
        }

        run.loopState = BurnBarAgentLoopState(
            iterationCount: run.loopState.iterationCount,
            lastDecision: run.loopState.lastDecision,
            lastContextSnapshot: currentContextSnapshot(for: run),
            lastExecutedTool: callSnapshot.tool,
            terminalPending: false
        )
    }

    private func handleToolFailure(
        error: BurnBarToolExecutionError,
        callSnapshot: BurnBarToolCallSnapshot,
        run: inout BurnBarManagedRun
    ) async throws {
        let decision = recoveryEngine.decide(for: error, toolCall: callSnapshot, attempt: run.attempt)
        run.lastRecoveryDecision = decision
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .recoveryDecided,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(decision),
                emittedAt: Date()
            )
        )

        switch decision.action {
        case .requestApproval:
            let approvalID = BurnBarApprovalID()
            run.approvalRequest = BurnBarApprovalRequest(
                approvalID: approvalID,
                runID: run.runID,
                tool: callSnapshot.tool,
                title: "Workspace action required for \(callSnapshot.tool.rawValue)",
                message: decision.userMessage,
                requestedAt: Date()
            )
            try transition(&run, to: .awaitingApproval, activeApprovalID: approvalID)
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .approvalRequested,
                    phase: run.snapshot.phase,
                    payload: try BurnBarJSONValue.fromEncodable(run.approvalRequest),
                    emittedAt: Date()
                )
            )
        case .retryTool:
            run.attempt += 1
            try transition(&run, to: .planning, activeApprovalID: nil)
            try await continueExecution(for: &run)
        case .failRun:
            try transition(
                &run,
                to: .failed,
                errorMessage: decision.userMessage,
                activeApprovalID: nil
            )
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .runFailed,
                    phase: run.snapshot.phase,
                    payload: .object(["message": .string(decision.userMessage)]),
                    emittedAt: Date()
                )
            )
        }
    }

    private func completeRunAndRecordUsage(for run: inout BurnBarManagedRun) async throws {
        let usageEvent = makeUsageEvent(for: run, plan: run.plan)
        try transition(&run, to: .completed, activeApprovalID: nil)
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .runCompleted,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(usageEvent),
                emittedAt: Date()
            )
        )
        try await writeCheckpoint(for: run)
        _ = try await usageRecorder.record(
            usageEvent,
            idempotencyKey: "run:\(run.runID.rawValue):attempt:\(run.attempt)"
        )
    }

    private func appendJournalBootstrap(for run: BurnBarManagedRun) async throws {
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .runCreated,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(run.intent),
                emittedAt: Date()
            )
        )
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .planGenerated,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(run.planOutline),
                emittedAt: Date()
            )
        )
    }

    private func appendJournalEvent(_ event: BurnBarRunJournalEvent) async throws {
        try await runJournal.append(event)
    }

    private func writeCheckpoint(for run: BurnBarManagedRun) async throws {
        try await runJournal.writeCheckpoint(
            BurnBarRunJournalCheckpoint(
                runID: run.runID,
                clientID: run.snapshot.clientID,
                sessionID: run.snapshot.sessionID,
                phase: run.snapshot.phase,
                modelID: run.snapshot.modelID,
                originalPrompt: run.originalPrompt,
                metadata: run.metadata,
                intent: run.intent,
                planOutline: run.planOutline,
                attempt: run.attempt,
                errorMessage: run.snapshot.errorMessage,
                approvalRequest: run.approvalRequest,
                approvalResolvedForAttempt: run.approvalResolvedForAttempt,
                activeApprovalID: run.snapshot.activeApprovalID,
                pendingApprovalToolInvocation: run.pendingApprovalToolInvocation,
                lastToolCall: run.lastToolCall,
                lastToolCallID: run.lastToolCall?.callID,
                workflowStep: run.workflowStep,
                workflowReadContent: run.workflowReadContent,
                companionToolCompleted: run.companionToolCompleted,
                lastRecoveryDecision: run.lastRecoveryDecision,
                loopState: run.loopState,
                updatedAt: run.snapshot.updatedAt
            )
        )
    }

    private func restorePersistedRunsIfNeeded() async throws {
        guard !restoredPersistedRuns else {
            return
        }

        let checkpoints = try await runJournal.allCheckpoints()
        guard !checkpoints.isEmpty else {
            restoredPersistedRuns = true
            return
        }

        for checkpoint in checkpoints {
            guard runs[checkpoint.runID] == nil else {
                continue
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
                continue
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
            runOrder.append(checkpoint.runID)

            if let lastToolCall = checkpoint.lastToolCall {
                await workspaceBridgeBroker.restoreActiveCall(lastToolCall)
            }
        }

        var dedupedOrder: [BurnBarRunID] = []
        var seen = Set<BurnBarRunID>()
        for runID in runOrder where !seen.contains(runID) {
            seen.insert(runID)
            dedupedOrder.append(runID)
        }
        runOrder = dedupedOrder
        restoredPersistedRuns = true
    }

    private func makeUsageEvent(for run: BurnBarManagedRun, plan: BurnBarRunExecutionPlan) -> BurnBarUsageEvent {
        BurnBarUsageEvent(
            runID: run.runID,
            providerID: run.route.providerID,
            modelID: run.route.resolvedModelID,
            inputTokens: plan.inputTokens,
            outputTokens: plan.outputTokens,
            cacheCreationTokens: plan.cacheCreationTokens,
            cacheReadTokens: plan.cacheReadTokens,
            cost: run.route.pricing.cost(
                inputTokens: plan.inputTokens,
                outputTokens: plan.outputTokens,
                cacheCreationTokens: plan.cacheCreationTokens,
                cacheReadTokens: plan.cacheReadTokens
            ),
            recordedAt: Date()
        )
    }

    private func transition(
        _ run: inout BurnBarManagedRun,
        to phase: BurnBarRunPhase,
        errorMessage: String? = nil,
        activeApprovalID: BurnBarApprovalID? = nil
    ) throws {
        try BurnBarRunStateMachine.validatedTransition(from: run.snapshot.phase, to: phase)
        run.snapshot = BurnBarRunStateSnapshot(
            runID: run.snapshot.runID,
            clientID: run.snapshot.clientID,
            sessionID: run.snapshot.sessionID,
            phase: phase,
            modelID: run.snapshot.modelID,
            updatedAt: Date(),
            errorMessage: errorMessage,
            activeApprovalID: activeApprovalID
        )
    }

    private func createRun(
        _ request: BurnBarRunCreateRequest,
        enforceClientOwnership: Bool
    ) async throws -> BurnBarRunCreateResponse {
        try await restorePersistedRunsIfNeeded()
        if enforceClientOwnership {
            try await clientRegistry.requireController(request.clientID)
            try await clientRegistry.requireAttached(request.clientID, sessionID: request.sessionID)
        }

        let route: BurnBarProviderRoute
        do {
            route = try await router.route(modelName: request.modelID)
        } catch {
            throw BurnBarRunServiceError.routeFailed(error.localizedDescription)
        }
        let plannedRun = try plannerService.plan(for: request)

        let runID = BurnBarRunID()
        let plan = BurnBarRunExecutionPlan(request: request)
        var run = BurnBarManagedRun(
            runID: runID,
            originalPrompt: request.prompt,
            modelID: request.modelID,
            metadata: request.metadata,
            intent: plannedRun.intent,
            planOutline: plannedRun.outline,
            attempt: 1,
            route: route,
            plan: plan,
            snapshot: BurnBarRunStateSnapshot(
                runID: runID,
                clientID: request.clientID,
                sessionID: request.sessionID,
                phase: .idle,
                modelID: request.modelID,
                updatedAt: Date()
            ),
            approvalRequest: nil,
            approvalResolvedForAttempt: false,
            activeToolCallID: nil,
            pendingApprovalToolInvocation: nil,
            lastToolCall: nil,
            workflowStep: 0,
            workflowReadContent: nil,
            lastReadFilePath: nil,
            searchResultPaths: [],
            companionToolCompleted: false,
            lastRecoveryDecision: nil,
            loopState: BurnBarAgentLoopState()
        )

        try transition(&run, to: .planning)
        try await appendJournalBootstrap(for: run)
        try await continueExecution(for: &run)
        try await writeCheckpoint(for: run)
        runs[runID] = run
        runOrder.append(runID)

        logger.notice(
            "run_created",
            metadata: [
                "run_id": runID.rawValue,
                "client_id": request.clientID.rawValue,
                "phase": run.snapshot.phase.rawValue
            ]
        )

        return BurnBarRunCreateResponse(runID: runID, phase: run.snapshot.phase)
    }

    private func executeProviderOnlyRun(for run: inout BurnBarManagedRun) async throws {
        try transition(&run, to: .modelStreaming)
        var attemptedRouteKeys: Set<String> = [router.routeKey(providerID: run.route.providerID, slotID: run.route.credentialSlotID)]
        var candidateRoutes: [BurnBarProviderRoute] = [run.route]
        // Use scoreAndRankRoutes() instead of candidateRoutes() to ensure failover alternates
        // are ordered by scorecard composite score (capability, cost, latency, trust, policy-fit)
        // with deterministic tie-break, matching the primary route selection logic.
        let ranking = (try? await router.scoreAndRankRoutes(
            modelName: run.modelID,
            excludedRouteKeys: attemptedRouteKeys
        ))
        let additionalRoutes = ranking?.rankedRoutes.map { $0.route } ?? []
        candidateRoutes.append(contentsOf: additionalRoutes)

        for (index, route) in candidateRoutes.enumerated() {
            run.route = route
            do {
                let providerResult = try await providerExecutor.complete(
                    prompt: run.originalPrompt,
                    route: route
                )
                await router.markRouteSuccess(route)
                let usageEvent = BurnBarUsageEvent(
                    runID: run.runID,
                    providerID: route.providerID,
                    modelID: route.resolvedModelID,
                    inputTokens: providerResult.inputTokens,
                    outputTokens: providerResult.outputTokens,
                    cacheCreationTokens: providerResult.cacheCreationTokens,
                    cacheReadTokens: providerResult.cacheReadTokens,
                    cost: route.pricing.cost(
                        inputTokens: providerResult.inputTokens,
                        outputTokens: providerResult.outputTokens,
                        cacheCreationTokens: providerResult.cacheCreationTokens,
                        cacheReadTokens: providerResult.cacheReadTokens
                    ),
                    recordedAt: Date()
                )
                try transition(&run, to: .completed, activeApprovalID: nil)
                _ = try await usageRecorder.record(
                    usageEvent,
                    idempotencyKey: "run:\(run.runID.rawValue):attempt:\(run.attempt)"
                )
                return
            } catch {
                await router.markRouteFailure(route, error: error)
                let routeKey = router.routeKey(providerID: route.providerID, slotID: route.credentialSlotID)
                attemptedRouteKeys.insert(routeKey)
                let canFailOver = shouldFailOverProviderError(error)
                let hasMoreCandidates = index < candidateRoutes.count - 1
                if canFailOver && hasMoreCandidates {
                    continue
                }

                try transition(
                    &run,
                    to: .failed,
                    errorMessage: error.localizedDescription,
                    activeApprovalID: nil
                )
                try await appendJournalEvent(
                    BurnBarRunJournalEvent(
                        runID: run.runID,
                        kind: .runFailed,
                        phase: run.snapshot.phase,
                        payload: .object(["message": .string(error.localizedDescription)]),
                        emittedAt: Date()
                    )
                )
                try await writeCheckpoint(for: run)
                return
            }
        }
        throw BurnBarRunServiceError.routeFailed("No provider route was available for execution.")
    }

    private func shouldFailOverProviderError(_ error: Error) -> Bool {
        if let providerError = error as? BurnBarProviderExecutorError {
            switch providerError {
            case .upstreamError(let statusCode, let body):
                if statusCode == 429 || statusCode == 401 || statusCode == 403 || statusCode == 402 {
                    return true
                }
                let normalizedBody = body.lowercased()
                return normalizedBody.contains("quota")
                    || normalizedBody.contains("rate")
                    || normalizedBody.contains("insufficient")
                    || normalizedBody.contains("exhaust")
            case .invalidBaseURL, .invalidResponse:
                return false
            }
        }

        let description = error.localizedDescription.lowercased()
        return description.contains("quota")
            || description.contains("rate limit")
            || description.contains("429")
    }
}

private extension Dictionary where Key == String, Value == BurnBarJSONValue {
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

private extension BurnBarJSONValue {
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
