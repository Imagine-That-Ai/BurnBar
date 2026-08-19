import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
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
        self.requiresApproval = request.metadata.boolValue(forKey: .requiresApproval) ?? false
        self.failUntilAttempt = request.metadata.intValue(forKey: .failUntilAttempt) ?? 0
        self.inputTokens = request.metadata.intValue(forKey: .inputTokens) ?? max(1, request.prompt.count / 4)
        self.outputTokens = request.metadata.intValue(forKey: .outputTokens) ?? 12
        self.cacheCreationTokens = request.metadata.intValue(forKey: .cacheCreationTokens) ?? 0
        self.cacheReadTokens = request.metadata.intValue(forKey: .cacheReadTokens) ?? 0
        self.approvalTitle = request.metadata.stringValue(forKey: .approvalTitle)
            ?? "Approve burnbar_action"
        self.approvalMessage = request.metadata.stringValue(forKey: .approvalMessage)
            ?? "OpenBurnBar needs approval before continuing this tool step."
    }
}

struct BurnBarManagedRun: Sendable {
    let runID: BurnBarRunID
    let originalPrompt: String
    let modelID: String
    let metadata: BurnBarRunCreateMetadata
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
    var pendingComputerUseInvocation: BurnBarToolInvocation?
    var computerUseGeneration: UInt64
    var lastToolCall: BurnBarToolCallSnapshot?
    var workflowStep: Int
    var workflowReadContent: String?
    var lastReadFilePath: String?
    var searchResultPaths: [String]
    var companionToolCompleted: Bool
    var lastRecoveryDecision: BurnBarRecoveryDecision?
    var loopState: BurnBarAgentLoopState
}

struct BurnBarInterruptedComputerUseNormalization: Sendable {
    let interruptedGeneration: UInt64
    var revocationCompleted = false
    var journalEventPersisted = false
}

enum BurnBarRunRestoreError: Error {
    case interruptedComputerUseNormalizationInProgress(BurnBarRunID)
    case interruptedComputerUseNormalizationEventConflict(BurnBarRunID)
    case interruptedComputerUseNormalizedRunMissing(BurnBarRunID)
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

    func intValue() -> Int? {
        guard case .number(let value) = self else {
            return nil
        }
        return Int(value)
    }
}

// MARK: - BurnBarRunService actor (public API facade)

public struct BurnBarComputerUseBrowserDispatchResult: Sendable {
    public let expectedSessionID: ComputerUseSessionID
    public let response: ComputerUseInvokeResponse

    public init(expectedSessionID: ComputerUseSessionID, response: ComputerUseInvokeResponse) {
        self.expectedSessionID = expectedSessionID
        self.response = response
    }
}

public struct BurnBarComputerUseRunRequirement: Sendable, Equatable {
    public let runID: BurnBarRunID
    public let clientID: BurnBarClientID
    public let sessionID: BurnBarSessionID
    public let invocation: BurnBarToolInvocation
    public let generation: UInt64
}

public typealias BurnBarComputerUseBrowserDispatcher = @Sendable (
    _ invocation: BurnBarToolInvocation
) async throws -> BurnBarComputerUseBrowserDispatchResult
public typealias BurnBarComputerUseRunBindingChecker = @Sendable (
    _ runID: BurnBarRunID,
    _ expectedGeneration: UInt64
) async -> Bool
public typealias BurnBarComputerUseRunRevoker = @Sendable (
    _ runID: BurnBarRunID,
    _ expectedGeneration: UInt64
) async -> Void

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
    let computerUseBrowserDispatcher: BurnBarComputerUseBrowserDispatcher?
    let computerUseRunBindingChecker: BurnBarComputerUseRunBindingChecker?
    let computerUseRunRevoker: BurnBarComputerUseRunRevoker?
    let logger: BurnBarDaemonLogger

    var runs: [BurnBarRunID: BurnBarManagedRun] = [:]
    var runOrder: [BurnBarRunID] = []
    var computerUseResumeClaims: [BurnBarRunID: UUID] = [:]
    var pendingInterruptedComputerUseNormalizations:
        [BurnBarRunID: BurnBarInterruptedComputerUseNormalization] = [:]
    var interruptedComputerUseNormalizationClaims = Set<BurnBarRunID>()
    var restoredPersistedRuns = false
    let maxInMemoryRuns: Int
    let evictionPolicy: BurnBarRunRegistryEvictionPolicy

    public init(
        router: BurnBarProviderRouter,
        usageRecorder: BurnBarUsageRecorder,
        clientRegistry: BurnBarClientRegistry,
        providerExecutor: any BurnBarProviderExecuting = BurnBarCompositeProviderExecutor(),
        workspaceBridgeBroker: BurnBarWorkspaceBridgeBroker = BurnBarWorkspaceBridgeBroker(),
        plannerService: BurnBarPlannerService = BurnBarPlannerService(),
        contextSelector: BurnBarContextSelector = BurnBarContextSelector(),
        agentLoopService: BurnBarAgentLoopService = BurnBarAgentLoopService(),
        recoveryEngine: BurnBarRecoveryEngine = BurnBarRecoveryEngine(),
        policyEngine: BurnBarPolicyEngine = BurnBarPolicyEngine(),
        runJournal: BurnBarRunJournal = BurnBarRunJournal(),
        connectorPlaneService: BurnBarConnectorPlaneService = BurnBarConnectorPlaneService(),
        browserToolService: BurnBarBrowserToolService = BurnBarBrowserToolService(),
        computerUseBrowserDispatcher: BurnBarComputerUseBrowserDispatcher? = nil,
        computerUseRunBindingChecker: BurnBarComputerUseRunBindingChecker? = nil,
        computerUseRunRevoker: BurnBarComputerUseRunRevoker? = nil,
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
        self.computerUseBrowserDispatcher = computerUseBrowserDispatcher
        self.computerUseRunBindingChecker = computerUseRunBindingChecker
        self.computerUseRunRevoker = computerUseRunRevoker
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
        metadata: BurnBarRunCreateMetadata = BurnBarRunCreateMetadata()
    ) async throws -> BurnBarRunCreateResponse {
        var combined = metadata
        combined[.controllerReview] = .bool(true)
        return try await createDaemonManagedRun(
            prompt: prompt,
            modelID: modelID,
            metadata: combined
        )
    }

    public func createDaemonManagedRun(
        prompt: String,
        modelID: String,
        metadata: BurnBarRunCreateMetadata = BurnBarRunCreateMetadata()
    ) async throws -> BurnBarRunCreateResponse {
        let request = BurnBarRunCreateRequest(
            clientID: Self.controllerRuntimeClientID,
            sessionID: Self.controllerRuntimeSessionID,
            prompt: prompt,
            modelID: modelID,
            metadata: metadata
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

    public func computerUseRequirement(
        for runID: BurnBarRunID
    ) async -> BurnBarComputerUseRunRequirement? {
        try? await restorePersistedRunsIfNeeded()
        try? await restoreSingleRunIfNeeded(runID: runID)
        guard let run = runs[runID],
              run.snapshot.phase == .awaitingComputerUseSession,
              let invocation = run.pendingComputerUseInvocation,
              invocation.runID == runID,
              invocation.tool.isBrowserComputerUse else {
            return nil
        }
        return BurnBarComputerUseRunRequirement(
            runID: runID,
            clientID: run.snapshot.clientID,
            sessionID: run.snapshot.sessionID,
            invocation: invocation,
            generation: run.computerUseGeneration
        )
    }

    public func listComputerUseRequirements() async -> [ComputerUseRunRequirementSummary] {
        try? await restorePersistedRunsIfNeeded()
        return runOrder.compactMap { runID in
            guard let run = runs[runID],
                  run.snapshot.phase == .awaitingComputerUseSession,
                  let invocation = run.pendingComputerUseInvocation,
                  invocation.runID == runID,
                  invocation.tool.isBrowserComputerUse else {
                return nil
            }
            return ComputerUseRunRequirementSummary(
                runID: runID,
                callID: invocation.callID,
                clientID: run.snapshot.clientID,
                toolKind: invocation.tool,
                generation: run.computerUseGeneration,
                requestedAt: invocation.requestedAt
            )
        }
        .sorted { $0.requestedAt < $1.requestedAt }
    }

    /// Resumes the exact browser invocation that placed a run into the
    /// Computer Use binding wait. No planning step is repeated and no new call
    /// identifier is allocated.
    @discardableResult
    public func resumeComputerUseRun(
        _ runID: BurnBarRunID,
        expectedCallID: String,
        expectedGeneration: UInt64
    ) async throws -> Bool {
        try await restorePersistedRunsIfNeeded()
        try await restoreSingleRunIfNeeded(runID: runID)
        guard var run = runs[runID],
              run.snapshot.phase == .awaitingComputerUseSession,
              let invocation = run.pendingComputerUseInvocation,
              invocation.runID == runID,
              invocation.callID == expectedCallID,
              run.computerUseGeneration == expectedGeneration,
              invocation.tool.isBrowserComputerUse else {
            return false
        }
        guard computerUseResumeClaims[runID] == nil else { return false }
        let claimID = UUID()
        computerUseResumeClaims[runID] = claimID
        defer {
            if computerUseResumeClaims[runID] == claimID {
                computerUseResumeClaims.removeValue(forKey: runID)
            }
        }
        if let computerUseRunBindingChecker,
           await computerUseRunBindingChecker(runID, expectedGeneration) == false {
            return false
        }

        guard let current = runs[runID],
              current.snapshot.phase == .awaitingComputerUseSession,
              current.pendingComputerUseInvocation?.callID == expectedCallID,
              current.computerUseGeneration == expectedGeneration,
              computerUseResumeClaims[runID] == claimID else {
            return false
        }
        run = current
        let pendingSnapshot = try claimBrowserToolInvocation(invocation, for: &run)
        // Publish the exact execution claim before journaling or dispatching.
        // Actor reentrancy can no longer admit a duplicate resume.
        runs[runID] = run
        do {
            try await appendJournalEvent(
                BurnBarRunJournalEvent(
                    runID: run.runID,
                    kind: .toolDispatched,
                    phase: run.snapshot.phase,
                    payload: try BurnBarJSONValue.fromEncodable(pendingSnapshot),
                    emittedAt: Date()
                )
            )
            try await writeCheckpoint(for: run)

            guard let claimed = runs[runID],
                  claimed.snapshot.phase == .executingTool,
                  claimed.activeToolCallID == expectedCallID,
                  claimed.computerUseGeneration == expectedGeneration,
                  computerUseResumeClaims[runID] == claimID else {
                return false
            }
            run = claimed
            try await executeBrowserToolInvocation(invocation, for: &run, alreadyClaimed: true)
            guard let stillClaimed = runs[runID],
                  stillClaimed.snapshot.phase == .executingTool,
                  stillClaimed.activeToolCallID == expectedCallID,
                  stillClaimed.computerUseGeneration == expectedGeneration,
                  computerUseResumeClaims[runID] == claimID else {
                return false
            }
            try await writeCheckpoint(for: run)
        } catch {
            if var failed = runs[runID],
               failed.snapshot.phase == .executingTool,
               failed.activeToolCallID == expectedCallID,
               failed.computerUseGeneration == expectedGeneration,
               computerUseResumeClaims[runID] == claimID {
                failed.activeToolCallID = nil
                failed.pendingComputerUseInvocation = nil
                try? transition(
                    &failed,
                    to: .failed,
                    errorMessage: "Computer Use execution could not be durably finalized.",
                    activeApprovalID: nil
                )
                runs[runID] = failed
                try? await appendJournalEvent(
                    BurnBarRunJournalEvent(
                        runID: runID,
                        kind: .runFailed,
                        phase: failed.snapshot.phase,
                        payload: .object(["message": .string("computer_use_durability_failure")]),
                        emittedAt: Date()
                    )
                )
                try? await writeCheckpoint(for: failed)
                computerUseResumeClaims.removeValue(forKey: runID)
                await computerUseRunRevoker?(runID, expectedGeneration)
            }
            throw error
        }
        guard runs[runID]?.computerUseGeneration == expectedGeneration,
              computerUseResumeClaims[runID] == claimID else {
            return false
        }
        runs[runID] = run
        if [.completed, .failed, .cancelled].contains(run.snapshot.phase) {
            // The terminal state is authoritative before cleanup. Release this
            // generation's claim so a retry can bind and resume independently;
            // the exact-generation revoker cannot touch that replacement.
            if computerUseResumeClaims[runID] == claimID {
                computerUseResumeClaims.removeValue(forKey: runID)
            }
            await computerUseRunRevoker?(runID, expectedGeneration)
        }
        return true
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
        if [.completed, .failed, .cancelled].contains(run.snapshot.phase) {
            await computerUseRunRevoker?(run.runID, run.computerUseGeneration)
        }

        return BurnBarRunDetailResponse(
            run: run.snapshot,
            approvalRequest: run.approvalRequest,
            pendingToolCall: await workspaceBridgeBroker.activeCall(for: request.runID),
            loopState: run.loopState,
            arbitration: await clientRegistry.arbitration()
        )
    }

    /// Shared cancellation sequence for every authority that may stop a run.
    ///
    /// Callers are responsible for proving authority BEFORE calling this —
    /// `cancelRun` requires controller status, `cancelSafariRun` requires the
    /// exact attached Safari client/session pair. Everything after that proof is
    /// identical, so it lives here once: terminal transition, computer-use
    /// revocation, workspace-call teardown, journal event, and checkpoint.
    private func applyRunCancellation(
        _ run: inout BurnBarManagedRun,
        runID: BurnBarRunID,
        message: String
    ) async throws {
        try transition(&run, to: .cancelled, errorMessage: message, activeApprovalID: nil)
        run.approvalRequest = nil
        run.activeToolCallID = nil
        run.pendingComputerUseInvocation = nil
        let revokedComputerUseGeneration = run.computerUseGeneration
        run.computerUseGeneration &+= 1
        let cancellationGeneration = run.computerUseGeneration
        // Publish revocation state before the first await. A concurrent resume
        // must observe cancellation even while external session cleanup blocks.
        runs[runID] = run
        await computerUseRunRevoker?(runID, revokedComputerUseGeneration)
        _ = await workspaceBridgeBroker.cancelActiveCall(for: runID)
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .runCancelled,
                phase: run.snapshot.phase,
                payload: .object(["message": .string(message)]),
                emittedAt: Date()
            )
        )
        if let current = runs[runID],
           current.snapshot.phase == .cancelled,
           current.computerUseGeneration == cancellationGeneration {
            try await writeCheckpoint(for: current)
        }
    }

    /// Cancels a run only when it is still owned by the exact attached Safari
    /// client/session pair.
    ///
    /// This is the non-interactive Stop path for the embedded Safari extension.
    /// It deliberately does NOT go through `cancelRun`, because that requires
    /// controller authority the appex must never hold. Ownership is proved by
    /// the attached client/session pair instead, so one Safari session can never
    /// cancel another client's run.
    ///
    /// The CLI hand-off lane is intentionally absent: Safari hand-off is not part
    /// of this bridge slice, so a Safari stop only ever cancels a managed run.
    @discardableResult
    public func cancelSafariRun(
        _ runID: BurnBarRunID,
        clientID: BurnBarClientID,
        sessionID: BurnBarSessionID,
        reason: String
    ) async throws -> Bool {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireAttached(clientID, sessionID: sessionID)
        try await restoreSingleRunIfNeeded(runID: runID)
        guard var run = runs[runID],
              run.snapshot.clientID == clientID,
              run.snapshot.sessionID == sessionID else {
            return false
        }
        if [.completed, .failed, .cancelled].contains(run.snapshot.phase) {
            return true
        }
        try await applyRunCancellation(&run, runID: runID, message: reason)
        logger.notice(
            "safari_run_cancelled",
            metadata: [
                "run_id": runID.rawValue,
                "client_id": clientID.rawValue
            ]
        )
        return true
    }

    public func cancelRun(_ request: BurnBarRunCancelRequest) async throws -> BurnBarRunDetailResponse {
        try await restorePersistedRunsIfNeeded()
        try await clientRegistry.requireController(request.clientID)
        try await restoreSingleRunIfNeeded(runID: request.runID)
        guard var run = runs[request.runID] else {
            throw BurnBarRunServiceError.runNotFound(request.runID)
        }

        let message = request.reason ?? "Cancelled by controller."
        try await applyRunCancellation(&run, runID: request.runID, message: message)

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
        run.pendingComputerUseInvocation = nil
        run.computerUseGeneration &+= 1
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
        if [.completed, .failed, .cancelled].contains(run.snapshot.phase) {
            await computerUseRunRevoker?(run.runID, run.computerUseGeneration)
        }

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
                if pendingInvocation.tool.isBrowserComputerUse {
                    try await executeBrowserToolInvocation(pendingInvocation, for: &run)
                } else {
                    try await enqueueCompanionToolCall(pendingInvocation, for: &run)
                }
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
        if [.completed, .failed, .cancelled].contains(run.snapshot.phase) {
            await computerUseRunRevoker?(run.runID, run.computerUseGeneration)
        }

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
        if runs[runID] != nil {
            try await finalizeInterruptedComputerUseNormalizationIfNeeded(for: runID)
            return
        }

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
        var restoredRun = BurnBarManagedRun(
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
            activeToolCallID: legacyWorkspaceToolCall(from: checkpoint)?.callID,
            pendingApprovalToolInvocation: checkpoint.pendingApprovalToolInvocation,
            pendingComputerUseInvocation: checkpoint.pendingComputerUseInvocation,
            computerUseGeneration: checkpoint.computerUseGeneration ?? 0,
            lastToolCall: checkpoint.lastToolCall,
            workflowStep: checkpoint.workflowStep,
            workflowReadContent: checkpoint.workflowReadContent,
            lastReadFilePath: checkpoint.loopState.lastContextSnapshot?.lastReadFilePath,
            searchResultPaths: checkpoint.loopState.lastContextSnapshot?.searchResultPaths ?? [],
            companionToolCompleted: checkpoint.companionToolCompleted,
            lastRecoveryDecision: checkpoint.lastRecoveryDecision,
            loopState: checkpoint.loopState
        )
        let interruptedGeneration = try normalizeInterruptedBrowserComputerUse(&restoredRun)
        runs[checkpoint.runID] = restoredRun
        if let interruptedGeneration {
            restoredPersistedRuns = false
            pendingInterruptedComputerUseNormalizations[checkpoint.runID] =
                BurnBarInterruptedComputerUseNormalization(
                    interruptedGeneration: interruptedGeneration
                )
        }
        if !runOrder.contains(checkpoint.runID) {
            runOrder.append(checkpoint.runID)
        }

        if let lastToolCall = legacyWorkspaceToolCall(from: checkpoint) {
            await workspaceBridgeBroker.restoreActiveCall(lastToolCall)
        }
        try await finalizeInterruptedComputerUseNormalizationIfNeeded(for: checkpoint.runID)

        logger.debug(
            "run_restored_lazily",
            metadata: [
                "run_id": checkpoint.runID.rawValue,
                "phase": checkpoint.phase.rawValue
            ]
        )
    }

    /// Only legacy companion-owned calls belong in the workspace broker after
    /// restart. Browser Computer Use calls are resumed exclusively through the
    /// exact run/call/generation handshake and must never be claimable by the
    /// extension bridge.
    func legacyWorkspaceToolCall(
        from checkpoint: BurnBarRunJournalCheckpoint
    ) -> BurnBarToolCallSnapshot? {
        guard checkpoint.pendingComputerUseInvocation == nil,
              checkpoint.phase == .waitingOnCompanion || checkpoint.phase == .executingTool,
              let lastToolCall = checkpoint.lastToolCall,
              lastToolCall.tool.isBrowserComputerUse == false else {
            return nil
        }
        return lastToolCall
    }

    static let interruptedComputerUseMessage =
        "Computer Use was interrupted while an action was in progress; the outcome is unknown. Retry explicitly to continue."

    /// A browser action checkpointed as executing cannot be replayed after a
    /// daemon restart because the external action may already have occurred.
    /// Convert it to a durable terminal failure and advance the generation so
    /// no stale session or resume token can reattach.
    func normalizeInterruptedBrowserComputerUse(
        _ run: inout BurnBarManagedRun
    ) throws -> UInt64? {
        guard run.snapshot.phase == .executingTool,
              run.pendingComputerUseInvocation == nil,
              let lastToolCall = run.lastToolCall,
              lastToolCall.tool.isBrowserComputerUse else {
            return nil
        }
        let interruptedGeneration = run.computerUseGeneration
        run.computerUseGeneration &+= 1
        run.activeToolCallID = nil
        run.lastToolCall = BurnBarToolCallSnapshot(
            callID: lastToolCall.callID,
            runID: lastToolCall.runID,
            tool: lastToolCall.tool,
            arguments: lastToolCall.arguments,
            status: .failed,
            requestedBy: lastToolCall.requestedBy,
            requestedAt: lastToolCall.requestedAt,
            claimedBy: lastToolCall.claimedBy,
            claimedAt: lastToolCall.claimedAt,
            completedAt: Date(),
            error: BurnBarToolExecutionError(
                code: .unknown,
                message: Self.interruptedComputerUseMessage
            )
        )
        try transition(&run, to: .failed, errorMessage: Self.interruptedComputerUseMessage)
        return interruptedGeneration
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
