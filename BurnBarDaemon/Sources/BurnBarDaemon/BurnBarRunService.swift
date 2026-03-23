import BurnBarCore
import Foundation

public enum BurnBarRunServiceError: Error, LocalizedError {
    case runNotFound(BurnBarRunID)
    case retryRequiresFailedRun(BurnBarRunID)
    case approvalNotFound(BurnBarApprovalID)
    case approvalAlreadyResolved(BurnBarApprovalID)
    case routeFailed(String)
    case invalidToolResult(BurnBarRunID, String)
    case missingWorkflowInput(BurnBarRunID, String)

    public var errorDescription: String? {
        switch self {
        case .runNotFound(let runID):
            return "Run '\(runID.rawValue)' was not found."
        case .retryRequiresFailedRun(let runID):
            return "Run '\(runID.rawValue)' is not in a failed state and cannot be retried."
        case .approvalNotFound(let approvalID):
            return "Approval '\(approvalID.rawValue)' was not found."
        case .approvalAlreadyResolved(let approvalID):
            return "Approval '\(approvalID.rawValue)' has already been resolved."
        case .routeFailed(let message):
            return "BurnBar could not route the requested run: \(message)"
        case .invalidToolResult(let runID, let message):
            return "BurnBar received an invalid tool result for run '\(runID.rawValue)': \(message)"
        case .missingWorkflowInput(let runID, let message):
            return "BurnBar could not continue workflow for run '\(runID.rawValue)': \(message)"
        }
    }
}

private struct BurnBarReplaceStringWorkflow: Sendable {
    let path: String
    let from: String
    let to: String
}

private struct BurnBarRunExecutionPlan: Sendable {
    let requiresApproval: Bool
    let toolKind: BurnBarToolKind?
    let waitOnCompanion: Bool
    let toolArguments: BurnBarJSONValue
    let workflow: BurnBarReplaceStringWorkflow?
    let failUntilAttempt: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let approvalTitle: String
    let approvalMessage: String

    init(request: BurnBarRunCreateRequest) {
        let workflow = request.metadata.replaceStringWorkflow()
        let toolKind = request.metadata.toolKindValue(forKey: "toolKind")

        self.requiresApproval = request.metadata.boolValue(forKey: "requiresApproval") ?? false
        self.toolKind = toolKind
        self.waitOnCompanion = request.metadata.boolValue(forKey: "waitOnCompanion") ?? false
        self.toolArguments = request.metadata.jsonValue(forKey: "toolArguments") ?? .object([:])
        self.workflow = workflow
        self.failUntilAttempt = request.metadata.intValue(forKey: "failUntilAttempt") ?? 0
        self.inputTokens = request.metadata.intValue(forKey: "inputTokens") ?? max(1, request.prompt.count / 4)
        self.outputTokens = request.metadata.intValue(forKey: "outputTokens") ?? (toolKind == nil ? 48 : 12)
        self.cacheReadTokens = request.metadata.intValue(forKey: "cacheReadTokens") ?? 0
        self.approvalTitle = request.metadata.stringValue(forKey: "approvalTitle")
            ?? "Approve \(toolKind?.rawValue ?? "burnbar_action")"
        self.approvalMessage = request.metadata.stringValue(forKey: "approvalMessage")
            ?? "BurnBar needs approval before continuing this tool step."
    }
}

private struct BurnBarManagedRun: Sendable {
    let runID: BurnBarRunID
    let originalPrompt: String
    let modelID: String
    let metadata: [String: BurnBarJSONValue]
    var attempt: Int
    var route: BurnBarProviderRoute
    var plan: BurnBarRunExecutionPlan
    var snapshot: BurnBarRunStateSnapshot
    var approvalRequest: BurnBarApprovalRequest?
    var approvalResolvedForAttempt: Bool
    var activeToolCallID: String?
    var lastToolCall: BurnBarToolCallSnapshot?
    var workflowStep: Int
    var workflowReadContent: String?
    var companionToolCompleted: Bool
}

public actor BurnBarRunService {
    private let router: BurnBarProviderRouter
    private let usageRecorder: BurnBarUsageRecorder
    private let clientRegistry: BurnBarClientRegistry
    private let providerExecutor: any BurnBarProviderExecuting
    private let workspaceBridgeBroker: BurnBarWorkspaceBridgeBroker
    private let logger: BurnBarDaemonLogger

    private var runs: [BurnBarRunID: BurnBarManagedRun] = [:]
    private var runOrder: [BurnBarRunID] = []

    public init(
        router: BurnBarProviderRouter,
        usageRecorder: BurnBarUsageRecorder,
        clientRegistry: BurnBarClientRegistry,
        providerExecutor: any BurnBarProviderExecuting = BurnBarOpenAICompatibleProviderExecutor(),
        workspaceBridgeBroker: BurnBarWorkspaceBridgeBroker = BurnBarWorkspaceBridgeBroker(),
        logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "run-service")
    ) {
        self.router = router
        self.usageRecorder = usageRecorder
        self.clientRegistry = clientRegistry
        self.providerExecutor = providerExecutor
        self.workspaceBridgeBroker = workspaceBridgeBroker
        self.logger = logger
    }

    public func createRun(_ request: BurnBarRunCreateRequest) async throws -> BurnBarRunCreateResponse {
        try await clientRegistry.requireController(request.clientID)
        try await clientRegistry.requireAttached(request.clientID, sessionID: request.sessionID)

        let route: BurnBarProviderRoute
        do {
            route = try await router.route(modelName: request.modelID)
        } catch {
            throw BurnBarRunServiceError.routeFailed(error.localizedDescription)
        }

        let runID = BurnBarRunID()
        let plan = BurnBarRunExecutionPlan(request: request)
        var run = BurnBarManagedRun(
            runID: runID,
            originalPrompt: request.prompt,
            modelID: request.modelID,
            metadata: request.metadata,
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
            lastToolCall: nil,
            workflowStep: 0,
            workflowReadContent: nil,
            companionToolCompleted: false
        )

        try transition(&run, to: .planning)
        try await continueExecution(for: &run)
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

    public func listRuns(_ request: BurnBarRunListRequest) async throws -> BurnBarRunListResponse {
        try await clientRegistry.requireAttached(request.clientID)
        let snapshots = runOrder.compactMap { runs[$0]?.snapshot }.sorted { $0.updatedAt > $1.updatedAt }
        return BurnBarRunListResponse(runs: snapshots)
    }

    public func getRun(_ request: BurnBarRunGetRequest) async throws -> BurnBarRunDetailResponse {
        try await clientRegistry.requireAttached(request.clientID)
        guard let run = runs[request.runID] else {
            throw BurnBarRunServiceError.runNotFound(request.runID)
        }

        return BurnBarRunDetailResponse(
            run: run.snapshot,
            approvalRequest: run.approvalRequest,
            pendingToolCall: await workspaceBridgeBroker.activeCall(for: request.runID),
            arbitration: await clientRegistry.arbitration()
        )
    }

    public func pollRuns(_ request: BurnBarRunPollRequest) async throws -> BurnBarRunEventBatch {
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

        if request.succeeded {
            try applySuccessfulToolResult(callSnapshot, to: &run)
            try transition(&run, to: .planning, activeApprovalID: nil)
            try await continueExecution(for: &run)
        } else {
            let error = request.error ?? BurnBarToolExecutionError(
                code: .unknown,
                message: request.error?.message ?? "Workspace companion reported a failed tool call."
            )
            try handleToolFailure(error: error, callSnapshot: callSnapshot, run: &run)
        }

        runs[request.runID] = run

        return BurnBarRunDetailResponse(
            run: run.snapshot,
            approvalRequest: run.approvalRequest,
            pendingToolCall: await workspaceBridgeBroker.activeCall(for: request.runID),
            arbitration: await clientRegistry.arbitration()
        )
    }

    public func cancelRun(_ request: BurnBarRunCancelRequest) async throws -> BurnBarRunDetailResponse {
        try await clientRegistry.requireController(request.clientID)
        guard var run = runs[request.runID] else {
            throw BurnBarRunServiceError.runNotFound(request.runID)
        }

        let message = request.reason ?? "Cancelled by controller."
        try transition(&run, to: .cancelled, errorMessage: message, activeApprovalID: nil)
        run.approvalRequest = nil
        run.activeToolCallID = nil
        _ = await workspaceBridgeBroker.cancelActiveCall(for: request.runID)
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

        run.attempt += 1
        run.route = route
        run.plan = BurnBarRunExecutionPlan(request: retryRequest)
        run.approvalRequest = nil
        run.approvalResolvedForAttempt = false
        run.activeToolCallID = nil
        run.lastToolCall = nil
        run.workflowStep = 0
        run.workflowReadContent = nil
        run.companionToolCompleted = false
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
        try await continueExecution(for: &run)
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
            run.approvalRequest = nil
            run.approvalResolvedForAttempt = true
            try transition(&run, to: .planning, activeApprovalID: nil)
            try await continueExecution(for: &run)
        case .reject, .cancel:
            run.approvalRequest = nil
            run.activeToolCallID = nil
            _ = await workspaceBridgeBroker.cancelActiveCall(for: runID)
            let decisionText = request.response.decision == .reject ? "rejected" : "cancelled"
            let message = request.response.note ?? "Approval \(decisionText) by controller."
            try transition(&run, to: .cancelled, errorMessage: message, activeApprovalID: nil)
        }

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
        if run.plan.requiresApproval && !run.approvalResolvedForAttempt && run.approvalRequest == nil {
            let approvalID = BurnBarApprovalID()
            run.approvalRequest = BurnBarApprovalRequest(
                approvalID: approvalID,
                runID: run.runID,
                tool: run.plan.toolKind ?? .applyPatch,
                title: run.plan.approvalTitle,
                message: run.plan.approvalMessage,
                requestedAt: Date()
            )
            try transition(&run, to: .awaitingApproval, activeApprovalID: approvalID)
            return
        }

        if run.attempt <= run.plan.failUntilAttempt {
            try transition(
                &run,
                to: .failed,
                errorMessage: "Simulated failure on attempt \(run.attempt).",
                activeApprovalID: nil
            )
            return
        }

        if run.plan.workflow != nil {
            try await continueReplaceStringWorkflow(for: &run)
            return
        }

        if let toolKind = run.plan.toolKind {
            try transition(&run, to: .executingTool)

            if run.plan.waitOnCompanion {
                if run.companionToolCompleted {
                    try await completeRunAndRecordUsage(for: &run)
                    return
                }

                try await dispatchCompanionToolCall(
                    for: &run,
                    toolKind: toolKind,
                    arguments: run.plan.toolArguments
                )
                return
            }

            try await completeRunAndRecordUsage(for: &run)
            return
        }

        try transition(&run, to: .modelStreaming)
        let usageEvent: BurnBarUsageEvent
        do {
            let providerResult = try await providerExecutor.complete(
                prompt: run.originalPrompt,
                route: run.route
            )
            usageEvent = BurnBarUsageEvent(
                runID: run.runID,
                providerID: run.route.providerID,
                modelID: run.route.resolvedModelID,
                inputTokens: providerResult.inputTokens,
                outputTokens: providerResult.outputTokens,
                cacheReadTokens: providerResult.cacheReadTokens,
                cost: run.route.pricing.cost(
                    inputTokens: providerResult.inputTokens,
                    outputTokens: providerResult.outputTokens,
                    cacheReadTokens: providerResult.cacheReadTokens
                ),
                recordedAt: Date()
            )
        } catch {
            try transition(
                &run,
                to: .failed,
                errorMessage: error.localizedDescription,
                activeApprovalID: nil
            )
            return
        }

        try transition(&run, to: .completed, activeApprovalID: nil)
        _ = try await usageRecorder.record(
            usageEvent,
            idempotencyKey: "run:\(run.runID.rawValue):attempt:\(run.attempt)"
        )
    }

    private func continueReplaceStringWorkflow(for run: inout BurnBarManagedRun) async throws {
        guard let workflow = run.plan.workflow else {
            throw BurnBarRunServiceError.missingWorkflowInput(run.runID, "Workflow metadata is unavailable.")
        }

        switch run.workflowStep {
        case 0:
            try transition(&run, to: .executingTool)
            try await dispatchCompanionToolCall(
                for: &run,
                toolKind: .readFile,
                arguments: .object(["path": .string(workflow.path)])
            )
        case 1:
            guard let readContent = run.workflowReadContent else {
                throw BurnBarRunServiceError.missingWorkflowInput(
                    run.runID,
                    "Read-file output is required before applying a patch."
                )
            }
            let updatedContent = readContent.replacingOccurrences(of: workflow.from, with: workflow.to)
            guard updatedContent != readContent else {
                try transition(
                    &run,
                    to: .failed,
                    errorMessage: "BurnBar could not find '\(workflow.from)' in \(workflow.path).",
                    activeApprovalID: nil
                )
                return
            }

            try transition(&run, to: .executingTool)
            try await dispatchCompanionToolCall(
                for: &run,
                toolKind: .applyPatch,
                arguments: .object([
                    "changes": .array([
                        .object([
                            "path": .string(workflow.path),
                            "text": .string(updatedContent)
                        ])
                    ])
                ])
            )
        default:
            try await completeRunAndRecordUsage(for: &run)
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
        let snapshot = try await workspaceBridgeBroker.enqueueToolCall(invocation)
        run.activeToolCallID = snapshot.callID
        run.lastToolCall = snapshot
        try transition(&run, to: .waitingOnCompanion)
    }

    private func applySuccessfulToolResult(
        _ callSnapshot: BurnBarToolCallSnapshot,
        to run: inout BurnBarManagedRun
    ) throws {
        if run.plan.workflow != nil {
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
            default:
                break
            }
            return
        }

        if run.plan.toolKind != nil && run.plan.waitOnCompanion {
            run.companionToolCompleted = true
        }
    }

    private func handleToolFailure(
        error: BurnBarToolExecutionError,
        callSnapshot: BurnBarToolCallSnapshot,
        run: inout BurnBarManagedRun
    ) throws {
        switch error.code {
        case .trustGated, .noWorkspace, .remoteUnsupported:
            let approvalID = BurnBarApprovalID()
            run.approvalRequest = BurnBarApprovalRequest(
                approvalID: approvalID,
                runID: run.runID,
                tool: callSnapshot.tool,
                title: "Workspace action required for \(callSnapshot.tool.rawValue)",
                message: error.message,
                requestedAt: Date()
            )
            try transition(&run, to: .awaitingApproval, activeApprovalID: approvalID)
        case .applyFailed, .terminalFailed, .unknown:
            try transition(
                &run,
                to: .failed,
                errorMessage: error.message,
                activeApprovalID: nil
            )
        }
    }

    private func completeRunAndRecordUsage(for run: inout BurnBarManagedRun) async throws {
        let usageEvent = makeUsageEvent(for: run, plan: run.plan)
        try transition(&run, to: .completed, activeApprovalID: nil)
        _ = try await usageRecorder.record(
            usageEvent,
            idempotencyKey: "run:\(run.runID.rawValue):attempt:\(run.attempt)"
        )
    }

    private func makeUsageEvent(for run: BurnBarManagedRun, plan: BurnBarRunExecutionPlan) -> BurnBarUsageEvent {
        BurnBarUsageEvent(
            runID: run.runID,
            providerID: run.route.providerID,
            modelID: run.route.resolvedModelID,
            inputTokens: plan.inputTokens,
            outputTokens: plan.outputTokens,
            cacheReadTokens: plan.cacheReadTokens,
            cost: run.route.pricing.cost(
                inputTokens: plan.inputTokens,
                outputTokens: plan.outputTokens,
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

    func jsonValue(forKey key: String) -> BurnBarJSONValue? {
        self[key]
    }

    func objectValue(forKey key: String) -> [String: BurnBarJSONValue]? {
        guard case .object(let value)? = self[key] else { return nil }
        return value
    }

    func toolKindValue(forKey key: String) -> BurnBarToolKind? {
        guard let rawValue = stringValue(forKey: key) else {
            return nil
        }
        return BurnBarToolKind(rawValue: rawValue)
    }

    func replaceStringWorkflow() -> BurnBarReplaceStringWorkflow? {
        if let workflowObject = objectValue(forKey: "workspaceWorkflow") ?? objectValue(forKey: "workflow"),
           let workflow = workflowObject.toReplaceStringWorkflow() {
            return workflow
        }

        if let path = stringValue(forKey: "filePath") ?? stringValue(forKey: "path"),
           let from = stringValue(forKey: "from") ?? stringValue(forKey: "fromText"),
           let to = stringValue(forKey: "to") ?? stringValue(forKey: "toText") {
            return BurnBarReplaceStringWorkflow(path: path, from: from, to: to)
        }

        return nil
    }
}

private extension Dictionary where Key == String, Value == BurnBarJSONValue {
    func toReplaceStringWorkflow() -> BurnBarReplaceStringWorkflow? {
        let type = stringValue(forKey: "type") ?? stringValue(forKey: "kind") ?? "replace_string_in_file"
        guard type == "replace_string_in_file" else {
            return nil
        }
        guard let path = stringValue(forKey: "path"),
              let from = stringValue(forKey: "from"),
              let to = stringValue(forKey: "to") else {
            return nil
        }
        return BurnBarReplaceStringWorkflow(path: path, from: from, to: to)
    }
}
