import OpenBurnBarEngine
import OpenBurnBarKernel
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
        let runMetadata = await metadataIncludingSafariLearningContext(
            for: request
        )

        let runID = BurnBarRunID()
        let plan = BurnBarRunExecutionPlan(request: request)
        var run = BurnBarManagedRun(
            runID: runID,
            originalPrompt: request.prompt,
            modelID: request.modelID,
            metadata: runMetadata,
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
            pendingComputerUseInvocation: nil,
            computerUseGeneration: 0,
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

    func metadataIncludingSafariLearningContext(
        for request: BurnBarRunCreateRequest
    ) async -> BurnBarRunCreateMetadata {
        var metadata = request.metadata
        guard request.metadata.stringValue(forKey: .surface)
                == "safari_extension",
              request.metadata.boolValue(forKey: .learningOptedIn) == true,
              let safariLearningRecallProvider else {
            return metadata
        }

        do {
            guard let rawContext = try await safariLearningRecallProvider(
                request.prompt,
                8
            ) else {
                return metadata
            }
            let context = rawContext.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard context.isEmpty == false,
                  context.utf8.count <= 16 * 1024 else {
                logger.warning(
                    "safari_learning_recall_discarded",
                    metadata: [
                        "client_id": request.clientID.rawValue,
                        "reason": "empty_or_oversized"
                    ]
                )
                return metadata
            }
            metadata[.safariLearnedContext] = .string(context)
        } catch {
            // Personalization is supplemental. A recall outage, tier change,
            // or concurrent opt-out must never prevent the user's Safari task.
            logger.warning(
                "safari_learning_recall_unavailable",
                metadata: [
                    "client_id": request.clientID.rawValue,
                    "error": error.localizedDescription
                ]
            )
        }
        return metadata
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
        try await finalizePendingInterruptedComputerUseNormalizations()

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
            let interruptedNormalization = try normalizeInterruptedBrowserComputerUse(&restoredRun)
            runs[checkpoint.runID] = restoredRun
            if let interruptedNormalization {
                pendingInterruptedComputerUseNormalizations[checkpoint.runID] =
                    interruptedNormalization
            }
            runOrder.append(checkpoint.runID)

            if let lastToolCall = legacyWorkspaceToolCall(from: checkpoint) {
                await workspaceBridgeBroker.restoreActiveCall(lastToolCall)
            }
            try await finalizeInterruptedComputerUseNormalizationIfNeeded(for: checkpoint.runID)
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

    func finalizePendingInterruptedComputerUseNormalizations() async throws {
        for runID in Array(pendingInterruptedComputerUseNormalizations.keys) {
            try await finalizeInterruptedComputerUseNormalizationIfNeeded(for: runID)
        }
    }

    func finalizeInterruptedComputerUseNormalizationIfNeeded(
        for runID: BurnBarRunID
    ) async throws {
        guard var pending = pendingInterruptedComputerUseNormalizations[runID] else {
            return
        }
        guard interruptedComputerUseNormalizationClaims.insert(runID).inserted else {
            throw BurnBarRunRestoreError.interruptedComputerUseNormalizationInProgress(runID)
        }
        defer { interruptedComputerUseNormalizationClaims.remove(runID) }

        guard let run = runs[runID] else {
            throw BurnBarRunRestoreError.interruptedComputerUseNormalizedRunMissing(runID)
        }

        if pending.revocationCompleted == false {
            if let requirement = pending.revocationRequirement {
                await revokeComputerUseBinding(requirement)
            } else if pending.interruptedTool.isSafariComputerUse == false,
                      let computerUseRunRevoker {
                await computerUseRunRevoker(runID, pending.interruptedGeneration)
            }
            pending.revocationCompleted = true
            pendingInterruptedComputerUseNormalizations[runID] = pending
        }

        if pending.journalEventPersisted == false {
            let eventID = interruptedComputerUseNormalizationEventID(
                runID: runID,
                generation: pending.interruptedGeneration
            )
            let existingEvents = try await runJournal.events(for: runID)
            if let existing = existingEvents.first(where: { $0.eventID == eventID }) {
                guard existing.kind == .runFailed,
                      existing.phase == .failed,
                      existing.payload == .object([
                          "reason": .string(Self.interruptedComputerUseMessage)
                      ]) else {
                    throw BurnBarRunRestoreError.interruptedComputerUseNormalizationEventConflict(runID)
                }
            } else {
                try await appendJournalEvent(
                    BurnBarRunJournalEvent(
                        eventID: eventID,
                        runID: runID,
                        kind: .runFailed,
                        phase: .failed,
                        payload: .object(["reason": .string(Self.interruptedComputerUseMessage)]),
                        emittedAt: Date()
                    )
                )
            }
            pending.journalEventPersisted = true
            pendingInterruptedComputerUseNormalizations[runID] = pending
        }

        try await writeCheckpoint(for: run)
        pendingInterruptedComputerUseNormalizations.removeValue(forKey: runID)
    }

    func interruptedComputerUseNormalizationEventID(
        runID: BurnBarRunID,
        generation: UInt64
    ) -> String {
        "computer-use-interrupted-\(runID.rawValue)-\(generation)"
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
                pendingComputerUseInvocation: run.pendingComputerUseInvocation,
                computerUseGeneration: run.computerUseGeneration,
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
        let executionSource = executionSource(for: run)
        return BurnBarUsageEvent(
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
            recordedAt: Date(),
            executionSourceID: executionSource.id == "unknown" ? nil : executionSource.id,
            executionSourceName: executionSource.id == "unknown" ? nil : executionSource.name,
            executionSourceKind: executionSource.kind == .unknown ? nil : executionSource.kind,
            executionSourceConfidence: executionSource.id == "unknown" ? nil : .exact,
            providerAccountID: run.route.credentialSlotID,
            providerAccountLabel: run.route.credentialSlotLabel
        )
    }

    func executionSource(for run: BurnBarManagedRun) -> UsageExecutionSource {
        UsageExecutionSourceResolver.fromClientMarker(
            run.snapshot.clientID.rawValue,
            allowCustom: true
        ) ?? .unknown
    }
}
