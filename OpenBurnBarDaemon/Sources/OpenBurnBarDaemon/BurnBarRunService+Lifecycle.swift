import OpenBurnBarCore
import Foundation

extension BurnBarRunService {

    func createRun(
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
        evictIfNeeded()

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

    func transition(
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

    func restorePersistedRunsIfNeeded() async throws {
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
        evictIfNeeded()
    }

    func writeCheckpoint(for run: BurnBarManagedRun) async throws {
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

    func appendJournalBootstrap(for run: BurnBarManagedRun) async throws {
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

    func appendJournalEvent(_ event: BurnBarRunJournalEvent) async throws {
        try await runJournal.append(event)
    }

    func makeUsageEvent(for run: BurnBarManagedRun, plan: BurnBarRunExecutionPlan) -> BurnBarUsageEvent {
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
}
