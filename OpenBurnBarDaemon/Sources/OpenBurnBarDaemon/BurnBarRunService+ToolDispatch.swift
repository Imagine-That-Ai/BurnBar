import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
import Foundation

struct BurnBarBrowserExecutionOutcome {
    let succeeded: Bool
    let output: BurnBarJSONValue?
    let error: BurnBarToolExecutionError?
}

extension BurnBarRunService {

    func isRunManagedComputerUse(_ tool: BurnBarToolKind) -> Bool {
        tool.isBrowserComputerUse || tool.isSafariComputerUse
    }

    func makeComputerUseRequirement(
        for run: BurnBarManagedRun,
        invocation: BurnBarToolInvocation,
        generation: UInt64? = nil
    ) -> BurnBarComputerUseRunRequirement {
        BurnBarComputerUseRunRequirement(
            runID: run.runID,
            clientID: run.snapshot.clientID,
            sessionID: run.snapshot.sessionID,
            invocation: invocation,
            generation: generation ?? run.computerUseGeneration
        )
    }

    func validateComputerUseBinding(
        _ requirement: BurnBarComputerUseRunRequirement,
        matches invocation: BurnBarToolInvocation,
        for run: BurnBarManagedRun,
        message: String
    ) throws {
        guard requirement.runID == run.runID,
              requirement.clientID == run.snapshot.clientID,
              requirement.sessionID == run.snapshot.sessionID,
              requirement.invocation == invocation,
              requirement.generation == run.computerUseGeneration else {
            throw BurnBarRunServiceError.invalidToolResult(run.runID, message)
        }
    }

    func computerUseRequirementForRevocation(
        _ run: BurnBarManagedRun,
        generation: UInt64
    ) -> BurnBarComputerUseRunRequirement? {
        let invocation: BurnBarToolInvocation?
        if let pending = run.pendingComputerUseInvocation {
            invocation = pending
        } else if let lastToolCall = run.lastToolCall,
                  isRunManagedComputerUse(lastToolCall.tool) {
            invocation = BurnBarToolInvocation(
                callID: lastToolCall.callID,
                runID: lastToolCall.runID,
                tool: lastToolCall.tool,
                arguments: lastToolCall.arguments,
                requestedBy: lastToolCall.requestedBy,
                requestedAt: lastToolCall.requestedAt
            )
        } else {
            invocation = nil
        }
        guard let invocation,
              invocation.runID == run.runID,
              invocation.requestedBy == run.snapshot.clientID else {
            return nil
        }
        return makeComputerUseRequirement(
            for: run,
            invocation: invocation,
            generation: generation
        )
    }

    func computerUseBindingPermits(
        _ requirement: BurnBarComputerUseRunRequirement
    ) async -> Bool {
        if requirement.invocation.tool.isSafariComputerUse {
            guard let safariComputerUseRunBindingChecker else {
                // Safari can never fall through to the legacy Playwright path.
                // Without the dedicated binding authority, retain the requirement
                // and fail closed until the daemon composition root supplies it.
                return false
            }
            return await safariComputerUseRunBindingChecker(requirement)
        }
        if let computerUseRunBindingChecker {
            return await computerUseRunBindingChecker(
                requirement.runID,
                requirement.generation
            )
        }
        return true
    }

    func revokeComputerUseBinding(
        _ requirement: BurnBarComputerUseRunRequirement
    ) async {
        if requirement.invocation.tool.isSafariComputerUse {
            await safariComputerUseRunRevoker?(requirement)
        } else {
            await computerUseRunRevoker?(requirement.runID, requirement.generation)
        }
    }

    func dispatchCompanionToolCall(
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

    func dispatchBrowserToolCall(
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
        // The Computer Use coordinator owns approval, scope, panic, and audit
        // when the relevant production composition root installs its dispatcher.
        // Safari always waits for its dedicated binding and never falls back to
        // either the Linux browser dispatcher or the legacy Playwright service.
        if invocation.tool.isSafariComputerUse == false,
           computerUseBrowserDispatcher == nil,
           try await requestMandatoryToolApprovalIfNeeded(for: &run, invocation: invocation) {
            return
        }
        let requirement = makeComputerUseRequirement(for: run, invocation: invocation)
        if await computerUseBindingPermits(requirement) == false {
            try await waitForComputerUseSession(invocation, run: &run)
            return
        }
        try await executeBrowserToolInvocation(
            invocation,
            for: &run,
            bindingRequirement: requirement
        )
    }

    func waitForComputerUseSession(
        _ invocation: BurnBarToolInvocation,
        run: inout BurnBarManagedRun
    ) async throws {
        let pendingSnapshot = BurnBarToolCallSnapshot(
            callID: invocation.callID,
            runID: invocation.runID,
            tool: invocation.tool,
            arguments: invocation.arguments,
            status: .pending,
            requestedBy: invocation.requestedBy,
            requestedAt: invocation.requestedAt
        )
        run.activeToolCallID = nil
        run.computerUseGeneration &+= 1
        run.pendingComputerUseInvocation = invocation
        run.lastToolCall = pendingSnapshot
        try transition(&run, to: .awaitingComputerUseSession)
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .computerUseSessionRequired,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(pendingSnapshot),
                emittedAt: Date()
            )
        )
    }

    func claimBrowserToolInvocation(
        _ invocation: BurnBarToolInvocation,
        for run: inout BurnBarManagedRun
    ) throws -> BurnBarToolCallSnapshot {
        let started = Date()
        let pendingSnapshot = BurnBarToolCallSnapshot(
            callID: invocation.callID,
            runID: invocation.runID,
            tool: invocation.tool,
            arguments: invocation.arguments,
            status: .inProgress,
            requestedBy: invocation.requestedBy,
            requestedAt: invocation.requestedAt,
            claimedBy: BurnBarRunService.controllerRuntimeClientID,
            claimedAt: started
        )
        run.activeToolCallID = invocation.callID
        run.pendingComputerUseInvocation = nil
        run.lastToolCall = pendingSnapshot
        try transition(&run, to: .executingTool)
        return pendingSnapshot
    }

    func executeBrowserToolInvocation(
        _ invocation: BurnBarToolInvocation,
        for run: inout BurnBarManagedRun,
        alreadyClaimed: Bool = false,
        bindingRequirement suppliedRequirement: BurnBarComputerUseRunRequirement? = nil
    ) async throws {
        let bindingRequirement = suppliedRequirement
            ?? makeComputerUseRequirement(for: run, invocation: invocation)
        try validateComputerUseBinding(
            bindingRequirement,
            matches: invocation,
            for: run,
            message: "Computer Use invocation no longer matches its exact run binding."
        )

        let pendingSnapshot: BurnBarToolCallSnapshot
        if alreadyClaimed {
            guard run.snapshot.phase == .executingTool,
                  run.activeToolCallID == invocation.callID,
                  let claimed = run.lastToolCall,
                  claimed.callID == invocation.callID,
                  claimed.status == .inProgress else {
                throw BurnBarRunServiceError.invalidToolResult(
                    run.runID,
                    "Computer Use invocation was not claimed by this run."
                )
            }
            pendingSnapshot = claimed
        } else {
            pendingSnapshot = try claimBrowserToolInvocation(invocation, for: &run)
            let claimedGeneration = run.computerUseGeneration
            runs[run.runID] = run
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
            } catch {
                if let current = runs[run.runID],
                   current.snapshot.phase == .executingTool,
                   current.activeToolCallID == invocation.callID,
                   current.computerUseGeneration == claimedGeneration {
                    run = current
                    run.activeToolCallID = nil
                    run.pendingComputerUseInvocation = nil
                    try? transition(
                        &run,
                        to: .failed,
                        errorMessage: "Computer Use execution could not be durably claimed.",
                        activeApprovalID: nil
                    )
                    runs[run.runID] = run
                    try? await appendJournalEvent(
                        BurnBarRunJournalEvent(
                            runID: run.runID,
                            kind: .runFailed,
                            phase: run.snapshot.phase,
                            payload: .object([
                                "message": .string("Computer Use execution could not be durably claimed.")
                            ]),
                            emittedAt: Date()
                        )
                    )
                    try? await writeCheckpoint(for: run)
                    await revokeComputerUseBinding(bindingRequirement)
                } else if let current = runs[run.runID] {
                    run = current
                }
                throw error
            }

            guard let claimed = runs[run.runID],
                  claimed.snapshot.phase == .executingTool,
                  claimed.activeToolCallID == invocation.callID,
                  claimed.computerUseGeneration == claimedGeneration else {
                if let current = runs[run.runID] {
                    run = current
                }
                return
            }
            run = claimed
        }

        try validateComputerUseBinding(
            bindingRequirement,
            matches: invocation,
            for: run,
            message: "Computer Use invocation lost its exact run binding before dispatch."
        )

        let outcome = await executeBrowserAction(
            invocation,
            bindingRequirement: bindingRequirement
        )
        let completedAt = Date()
        let completedSnapshot = BurnBarToolCallSnapshot(
            callID: invocation.callID,
            runID: invocation.runID,
            tool: invocation.tool,
            arguments: invocation.arguments,
            status: outcome.succeeded ? .completed : .failed,
            requestedBy: invocation.requestedBy,
            requestedAt: invocation.requestedAt,
            claimedBy: BurnBarRunService.controllerRuntimeClientID,
            claimedAt: pendingSnapshot.claimedAt,
            completedAt: completedAt,
            output: outcome.output,
            error: outcome.error
        )
        run.lastToolCall = completedSnapshot
        run.activeToolCallID = nil
        try await appendJournalEvent(
            BurnBarRunJournalEvent(
                runID: run.runID,
                kind: .toolCompleted,
                phase: run.snapshot.phase,
                payload: try BurnBarJSONValue.fromEncodable(completedSnapshot),
                emittedAt: completedAt
            )
        )

        if outcome.succeeded {
            try applySuccessfulToolResult(completedSnapshot, to: &run)
            try transition(&run, to: .planning, activeApprovalID: nil)
            try await continueExecution(for: &run)
        } else {
            try await handleToolFailure(
                error: outcome.error ?? BurnBarToolExecutionError(
                    code: .unknown,
                    message: "Browser Computer Use failed without an error detail."
                ),
                callSnapshot: completedSnapshot,
                run: &run
            )
        }
    }

    func executeBrowserAction(
        _ invocation: BurnBarToolInvocation,
        bindingRequirement: BurnBarComputerUseRunRequirement? = nil
    ) async -> BurnBarBrowserExecutionOutcome {
        do {
            if invocation.tool.isSafariComputerUse {
                guard let bindingRequirement,
                      bindingRequirement.runID == invocation.runID,
                      bindingRequirement.clientID == invocation.requestedBy,
                      bindingRequirement.invocation == invocation else {
                    return BurnBarBrowserExecutionOutcome(
                        succeeded: false,
                        output: nil,
                        error: BurnBarToolExecutionError(
                            code: .unknown,
                            message: "Safari Computer Use requires an exact run, call, client, session, and generation binding."
                        )
                    )
                }
                guard let safariComputerUseRunDispatcher else {
                    return BurnBarBrowserExecutionOutcome(
                        succeeded: false,
                        output: nil,
                        error: BurnBarToolExecutionError(
                            code: .unknown,
                            message: "Safari Computer Use is unavailable because its dedicated dispatcher is not installed."
                        )
                    )
                }
                let dispatchResult = try await safariComputerUseRunDispatcher(bindingRequirement)
                return computerUseOutcome(
                    from: dispatchResult,
                    invocation: invocation,
                    surfaceName: "Safari"
                )
            }

            if let computerUseBrowserDispatcher {
                let dispatchResult = try await computerUseBrowserDispatcher(invocation)
                return computerUseOutcome(
                    from: dispatchResult,
                    invocation: invocation,
                    surfaceName: "browser"
                )
            }

            let response = try await browserToolService.performAction(
                browserActionRequest(for: invocation)
            )
            return BurnBarBrowserExecutionOutcome(
                succeeded: response.ok,
                output: try BurnBarJSONValue.fromEncodable(response),
                error: response.ok ? nil : BurnBarToolExecutionError(
                    code: .unknown,
                    message: response.detail ?? response.summary
                )
            )
        } catch {
            return BurnBarBrowserExecutionOutcome(
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .unknown,
                    message: error.localizedDescription
                )
            )
        }
    }

    private func computerUseOutcome(
        from dispatchResult: BurnBarComputerUseBrowserDispatchResult,
        invocation: BurnBarToolInvocation,
        surfaceName: String
    ) -> BurnBarBrowserExecutionOutcome {
        let response = dispatchResult.response
        guard dispatchResult.expectedSessionID.rawValue.isEmpty == false,
              response.sessionId == dispatchResult.expectedSessionID.rawValue,
              response.callID == invocation.callID else {
            return BurnBarBrowserExecutionOutcome(
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .unknown,
                    message: "Computer Use returned a response for a different session or tool call."
                )
            )
        }
        switch response.status {
        case .executed:
            guard let result = response.result else {
                return BurnBarBrowserExecutionOutcome(
                    succeeded: false,
                    output: nil,
                    error: BurnBarToolExecutionError(
                        code: .unknown,
                        message: "Computer Use reported an executed \(surfaceName) action without a tool result."
                    )
                )
            }
            guard result.callID == invocation.callID,
                  result.runID == invocation.runID else {
                return BurnBarBrowserExecutionOutcome(
                    succeeded: false,
                    output: nil,
                    error: BurnBarToolExecutionError(
                        code: .unknown,
                        message: "Computer Use returned a \(surfaceName) result for a different run or tool call."
                    )
                )
            }
            return BurnBarBrowserExecutionOutcome(
                succeeded: result.succeeded,
                output: result.output,
                error: result.succeeded ? nil : BurnBarToolExecutionError(
                    code: .unknown,
                    message: result.errorMessage ?? "Computer Use \(surfaceName) action failed."
                )
            )
        case .denied:
            let code: BurnBarToolExecutionErrorCode = response.denyReason
                == ComputerUseDenyReason.userRejected.rawValue
                ? .operatorDenied
                : .computerUseDenied
            return BurnBarBrowserExecutionOutcome(
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: code,
                    message: response.denyReason ?? "Computer Use \(surfaceName) action was denied."
                )
            )
        case .awaitingApproval:
            return BurnBarBrowserExecutionOutcome(
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .unknown,
                    message: "Computer Use returned before its approval was resolved."
                )
            )
        case .error:
            return BurnBarBrowserExecutionOutcome(
                succeeded: false,
                output: nil,
                error: BurnBarToolExecutionError(
                    code: .unknown,
                    message: response.denyReason ?? "Computer Use \(surfaceName) action failed."
                )
            )
        }
    }

    func enqueueCompanionToolCall(
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

    func requestMandatoryToolApprovalIfNeeded(
        for run: inout BurnBarManagedRun,
        invocation: BurnBarToolInvocation
    ) async throws -> Bool {
        guard run.approvalRequest == nil,
              invocation.tool == .applyPatch || invocation.tool == .runTerminal || invocation.tool.isBrowserComputerUse,
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

    private func browserActionRequest(for invocation: BurnBarToolInvocation) throws -> BurnBarBrowserActionRequest {
        let encoded = try JSONEncoder().encode(invocation.arguments)
        let arguments = try JSONDecoder().decode(BurnBarBrowserActionArguments.self, from: encoded)
        let action: BurnBarBrowserActionKind
        switch invocation.tool {
        case .browserClick:
            action = .click
        case .browserFill:
            action = .fill
        case .browserGoto:
            action = .goto
        case .browserKey:
            action = .key
        case .browserSelect:
            action = .select
        case .browserScreenshot:
            action = .screenshot
        case .browserExtract:
            action = .extract
        default:
            throw BurnBarAgentLoopServiceError.unsupportedAction("Tool \(invocation.tool.rawValue) is not a browser Computer Use tool.")
        }
        return BurnBarBrowserActionRequest(
            action: action,
            url: arguments.url ?? "about:blank",
            preferredEngine: .playwright,
            arguments: arguments
        )
    }

    func applySuccessfulToolResult(
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
        case .applyPatch, .runTerminal,
             .browserClick, .browserFill, .browserGoto, .browserKey,
             .browserSelect, .browserScreenshot, .browserExtract,
             .safariPageContext, .safariScreenshot, .safariFullPageScreenshot,
             .safariClick, .safariType, .safariPressKey, .safariScroll,
             .safariHover, .safariFocus, .safariSelectOption, .safariNavigate,
             .safariOpenTab, .safariCloseTab, .safariListTabs, .safariWaitFor,
             .safariRunJavaScript, .safariExtract, .safariAbort,
             .macInputClick, .macInputType, .macInputKey,
             .macInputShortcut, .macInputDragDrop, .macInputScroll,
             .macInputPointerMove, .macInspectAccessibility:
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

    func handleToolFailure(
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
            run.approvalResolvedForAttempt = false
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
}
