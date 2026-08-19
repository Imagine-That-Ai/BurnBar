import OpenBurnBarEngine
import OpenBurnBarComputerUseCore
import Foundation

struct BurnBarBrowserExecutionOutcome {
    let succeeded: Bool
    let output: BurnBarJSONValue?
    let error: BurnBarToolExecutionError?
}

extension BurnBarRunService {

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
        // when the production Linux composition root installs this dispatcher.
        // Retain the legacy run-level approval only for callers that deliberately
        // construct a run service without that safety authority.
        if computerUseBrowserDispatcher == nil,
           try await requestMandatoryToolApprovalIfNeeded(for: &run, invocation: invocation) {
            return
        }
        if let computerUseRunBindingChecker,
           await computerUseRunBindingChecker(run.runID, run.computerUseGeneration) == false {
            try await waitForComputerUseSession(invocation, run: &run)
            return
        }
        try await executeBrowserToolInvocation(invocation, for: &run)
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
        alreadyClaimed: Bool = false
    ) async throws {
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
                    await computerUseRunRevoker?(run.runID, claimedGeneration)
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

        let outcome = await executeBrowserAction(invocation)
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
        _ invocation: BurnBarToolInvocation
    ) async -> BurnBarBrowserExecutionOutcome {
        do {
            if let computerUseBrowserDispatcher {
                let dispatchResult = try await computerUseBrowserDispatcher(invocation)
                let response = dispatchResult.response
                guard response.sessionId == dispatchResult.expectedSessionID.rawValue,
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
                                message: "Computer Use reported an executed browser action without a tool result."
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
                                message: "Computer Use returned a browser result for a different run or tool call."
                            )
                        )
                    }
                    return BurnBarBrowserExecutionOutcome(
                        succeeded: result.succeeded,
                        output: result.output,
                        error: result.succeeded ? nil : BurnBarToolExecutionError(
                            code: .unknown,
                            message: result.errorMessage ?? "Computer Use browser action failed."
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
                            message: response.denyReason ?? "Computer Use browser action was denied."
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
                            message: response.denyReason ?? "Computer Use browser action failed."
                        )
                    )
                }
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
