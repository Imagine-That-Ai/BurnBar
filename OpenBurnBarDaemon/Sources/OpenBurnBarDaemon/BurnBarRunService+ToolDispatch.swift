import OpenBurnBarCore
import Foundation

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
             .macInputClick, .macInputType, .macInputKey,
             .macInputShortcut, .macInputDragDrop, .macInspectAccessibility:
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
