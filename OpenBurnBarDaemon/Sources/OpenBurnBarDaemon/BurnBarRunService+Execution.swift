import OpenBurnBarCore
import Foundation

extension BurnBarRunService {

    func continueExecution(for run: inout BurnBarManagedRun) async throws {
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

    func continueIntentExecution(for run: inout BurnBarManagedRun) async throws {
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

    func deterministicContextAction(for run: BurnBarManagedRun) throws -> BurnBarContextAction? {
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

    func currentContextSnapshot(for run: BurnBarManagedRun) -> BurnBarAgentContextSnapshot {
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

    func runAgentLoop(for run: inout BurnBarManagedRun) async throws {
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
                let fallbackRoute: BurnBarProviderRoute?
                do {
                    fallbackRoute = try await router.route(
                        modelName: run.modelID,
                        excludedRouteKeys: [excludedRouteKey]
                    )
                } catch {
                    logger.silentFailure("provider_failover_route", error: error)
                    fallbackRoute = nil
                }
                if let fallbackRoute {
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

    func executeProviderOnlyRun(for run: inout BurnBarManagedRun) async throws {
        try transition(&run, to: .modelStreaming)
        var attemptedRouteKeys: Set<String> = [router.routeKey(providerID: run.route.providerID, slotID: run.route.credentialSlotID)]
        var candidateRoutes: [BurnBarProviderRoute] = [run.route]
        // Use scoreAndRankRoutes() instead of candidateRoutes() to ensure failover alternates
        // are ordered by scorecard composite score (capability, cost, latency, trust, policy-fit)
        // with deterministic tie-break, matching the primary route selection logic.
        let ranking: BurnBarRouteRankingResult?
        do {
            ranking = try await router.scoreAndRankRoutes(
                modelName: run.modelID,
                excludedRouteKeys: attemptedRouteKeys
            )
        } catch {
            logger.silentFailure("score_and_rank_routes", error: error)
            ranking = nil
        }
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

    func shouldFailOverProviderError(_ error: Error) -> Bool {
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

    func completeRunAndRecordUsage(for run: inout BurnBarManagedRun) async throws {
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
}
