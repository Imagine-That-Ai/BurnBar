import BurnBarCore
@testable import BurnBarDaemon
import Foundation
import XCTest

final class BurnBarAgentStackTests: XCTestCase {
    func testPlannerNormalizesReplaceStringWorkflowIntoTypedIntentAndPlan() throws {
        let planner = BurnBarPlannerService()
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "Change a string in one file",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("Sources/App.swift"),
                        "from": .string("old"),
                        "to": .string("new")
                    ])
                ]
            )
        )

        XCTAssertEqual(planned.intent.kind, .replaceStringInFile)
        XCTAssertEqual(planned.intent.targetPath, "Sources/App.swift")
        XCTAssertEqual(planned.intent.replacement?.from, "old")
        XCTAssertEqual(planned.intent.replacement?.to, "new")
        XCTAssertEqual(planned.outline.steps.count, 3)
        XCTAssertEqual(planned.outline.steps.last?.title, "Verify result")
    }

    func testPlannerNormalizesTerminalIntentFromToolMetadata() throws {
        let planner = BurnBarPlannerService()
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "Run tests",
                modelID: "glm-5",
                metadata: [
                    "toolKind": .string(BurnBarToolKind.runTerminal.rawValue),
                    "toolArguments": .object([
                        "command": .string("npm test"),
                        "cwd": .string("app")
                    ])
                ]
            )
        )

        XCTAssertEqual(planned.intent.kind, .runTerminal)
        XCTAssertEqual(planned.intent.terminalCommand?.command, "npm test")
        XCTAssertEqual(planned.intent.terminalCommand?.cwd, "app")
        XCTAssertEqual(planned.intent.requestedTools, [.runTerminal])
    }

    func testPlannerInfersReplaceIntentFromPromptAndActiveFile() throws {
        let planner = BurnBarPlannerService()
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "replace \"old title\" with \"new title\"",
                modelID: "glm-5",
                metadata: [
                    "activeFilePath": .string("src/example.ts")
                ]
            )
        )

        XCTAssertEqual(planned.intent.kind, .replaceStringInFile)
        XCTAssertEqual(planned.intent.targetPath, "src/example.ts")
        XCTAssertEqual(planned.intent.replacement?.from, "old title")
        XCTAssertEqual(planned.intent.replacement?.to, "new title")
    }

    func testPlannerInfersReplaceIntentFromSelectionPrompt() throws {
        let planner = BurnBarPlannerService()
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "change this selection to \"updated text\"",
                modelID: "glm-5",
                metadata: [
                    "activeFilePath": .string("src/example.ts"),
                    "activeSelectionText": .string("selected text")
                ]
            )
        )

        XCTAssertEqual(planned.intent.kind, .replaceStringInFile)
        XCTAssertEqual(planned.intent.replacement?.from, "selected text")
        XCTAssertEqual(planned.intent.replacement?.to, "updated text")
    }

    func testPlannerInfersTerminalIntentFromPrompt() throws {
        let planner = BurnBarPlannerService()
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "run npm test",
                modelID: "glm-5",
                metadata: [
                    "activeFilePath": .string("app/src/example.ts")
                ]
            )
        )

        XCTAssertEqual(planned.intent.kind, .runTerminal)
        XCTAssertEqual(planned.intent.terminalCommand?.command, "npm test")
        XCTAssertEqual(planned.intent.terminalCommand?.cwd, "app/src")
    }

    func testPlannerInfersSearchIntentFromPrompt() throws {
        let planner = BurnBarPlannerService()
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "search for BurnBarRunService",
                modelID: "glm-5"
            )
        )

        XCTAssertEqual(planned.intent.kind, .inspectWorkspace)
        XCTAssertEqual(planned.intent.searchQuery, "BurnBarRunService")
        XCTAssertEqual(planned.intent.requestedTools, [.searchWorkspace])
    }

    func testPlannerInfersReadIntentFromPromptAndActiveFile() throws {
        let planner = BurnBarPlannerService()
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "inspect this file",
                modelID: "glm-5",
                metadata: [
                    "activeFilePath": .string("README.md")
                ]
            )
        )

        XCTAssertEqual(planned.intent.kind, .generic)
        XCTAssertEqual(planned.intent.targetPath, "README.md")
        XCTAssertEqual(planned.intent.requestedTools, [.readFile])
    }

    func testContextSelectorProducesReadThenPatchSequence() throws {
        let selector = BurnBarContextSelector()
        let intent = BurnBarAgentIntent(
            kind: .replaceStringInFile,
            objective: "Change a string in one file",
            summary: "Inspect, replace, verify",
            targetPath: "src/example.ts",
            replacement: BurnBarTextReplacement(from: "value = 1", to: "value = 2"),
            requestedTools: [.readFile, .applyPatch]
        )

        let readAction = try selector.nextAction(
            for: intent,
            state: BurnBarContextSelectionState(workflowStep: 0, lastReadContent: nil, toolAlreadyCompleted: false)
        )
        XCTAssertEqual(readAction?.tool, .readFile)

        let patchAction = try selector.nextAction(
            for: intent,
            state: BurnBarContextSelectionState(
                workflowStep: 1,
                lastReadContent: "export const value = 1;\n",
                toolAlreadyCompleted: false
            )
        )
        XCTAssertEqual(patchAction?.tool, .applyPatch)
        guard case .object(let payload)? = patchAction?.arguments,
              case .array(let changes)? = payload["changes"],
              case .object(let firstChange)? = changes.first,
              case .string(let text)? = firstChange["text"] else {
            return XCTFail("Expected apply_patch arguments with updated text.")
        }
        XCTAssertEqual(text, "export const value = 2;\n")
    }

    func testPolicyEngineProvidesExplicitApprovalAndRiskClassification() {
        let policy = BurnBarPolicyEngine()
        let intent = BurnBarAgentIntent(
            kind: .runTerminal,
            objective: "Run tests",
            summary: "Execute terminal command",
            terminalCommand: BurnBarTerminalCommandIntent(command: "npm test"),
            requestedTools: [.runTerminal]
        )

        XCTAssertEqual(policy.risk(for: .readFile), .low)
        XCTAssertEqual(policy.risk(for: .applyPatch), .medium)
        XCTAssertEqual(policy.risk(for: .runTerminal), .high)

        let approval = policy.approvalDescriptor(
            explicitApprovalRequired: true,
            intent: intent,
            tool: .runTerminal,
            customTitle: nil,
            customMessage: nil
        )
        XCTAssertEqual(approval?.tool, .runTerminal)
        XCTAssertEqual(approval?.risk, .high)
        XCTAssertEqual(policy.indicatesProgress(for: BurnBarToolCallSnapshot(
            callID: "call-1",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .searchWorkspace,
            arguments: .object([:]),
            status: .completed,
            requestedBy: BurnBarClientID(rawValue: "client-a"),
            requestedAt: Date(),
            output: .object(["matches": .array([])])
        )), true)
        XCTAssertEqual(policy.indicatesProgress(for: BurnBarToolCallSnapshot(
            callID: "call-2",
            runID: BurnBarRunID(rawValue: "run-2"),
            tool: .readFile,
            arguments: .object([:]),
            status: .pending,
            requestedBy: BurnBarClientID(rawValue: "client-a"),
            requestedAt: Date(),
            output: nil
        )), false)
    }

    func testPolicyEngineRiskAndApprovalMatrix() {
        let policy = BurnBarPolicyEngine()
        let readIntent = BurnBarAgentIntent(
            kind: .generic,
            objective: "Read file",
            summary: "Read a file",
            targetPath: "README.md",
            requestedTools: [.readFile]
        )
        let patchIntent = BurnBarAgentIntent(
            kind: .replaceStringInFile,
            objective: "Patch file",
            summary: "Patch a file",
            targetPath: "src/example.ts",
            replacement: BurnBarTextReplacement(from: "a", to: "b"),
            requestedTools: [.readFile, .applyPatch]
        )

        XCTAssertEqual(policy.risk(for: .readFile), .low)
        XCTAssertEqual(policy.risk(for: .searchWorkspace), .low)
        XCTAssertEqual(policy.risk(for: .applyPatch), .medium)
        XCTAssertEqual(policy.risk(for: .runTerminal), .high)

        XCTAssertNil(policy.approvalDescriptor(
            explicitApprovalRequired: false,
            intent: readIntent,
            tool: .readFile,
            customTitle: nil,
            customMessage: nil
        ))

        let patchApproval = policy.approvalDescriptor(
            explicitApprovalRequired: true,
            intent: patchIntent,
            tool: .applyPatch,
            customTitle: nil,
            customMessage: nil
        )
        XCTAssertEqual(patchApproval?.tool, .applyPatch)
        XCTAssertEqual(patchApproval?.risk, .medium)
        XCTAssertEqual(patchApproval?.title, "Approve apply_patch")
    }

    func testRecoveryEngineMapsRefusalsAndFailuresDeterministically() {
        let engine = BurnBarRecoveryEngine()
        let toolCall = BurnBarToolCallSnapshot(
            callID: "call-1",
            runID: BurnBarRunID(rawValue: "run-1"),
            tool: .applyPatch,
            arguments: .object([:]),
            status: .failed,
            requestedBy: BurnBarClientID(rawValue: "client-a"),
            requestedAt: Date()
        )

        let approvalDecision = engine.decide(
            for: BurnBarToolExecutionError(code: .trustGated, message: "Trust required."),
            toolCall: toolCall,
            attempt: 1
        )
        XCTAssertEqual(approvalDecision.action, .requestApproval)

        let failureDecision = engine.decide(
            for: BurnBarToolExecutionError(code: .applyFailed, message: "Patch failed."),
            toolCall: toolCall,
            attempt: 1
        )
        XCTAssertEqual(failureDecision.action, .failRun)
    }

    func testContextSelectorCanSearchWorkspaceForInspectIntent() throws {
        let selector = BurnBarContextSelector()
        let intent = BurnBarAgentIntent(
            kind: .inspectWorkspace,
            objective: "Find references",
            summary: "Search for relevant files",
            searchQuery: "BurnBarRunService",
            requestedTools: [.searchWorkspace]
        )

        let action = try selector.nextAction(
            for: intent,
            state: BurnBarContextSelectionState(workflowStep: 0, lastReadContent: nil, toolAlreadyCompleted: false)
        )
        XCTAssertEqual(action?.tool, .searchWorkspace)
        guard case .object(let payload)? = action?.arguments,
              case .string(let query)? = payload["query"] else {
            return XCTFail("Expected search query payload.")
        }
        XCTAssertEqual(query, "BurnBarRunService")
    }

    func testRunJournalAppendsEventsAndLoadsCheckpoint() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar-journal-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let journal = BurnBarRunJournal(
            fileURL: rootURL.appendingPathComponent("run-journal.jsonl"),
            checkpointsDirectoryURL: rootURL.appendingPathComponent("checkpoints", isDirectory: true),
            logger: BurnBarDaemonLogger(category: "journal-tests")
        )
        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "Inspect repo",
            summary: "Read context and verify"
        )
        let outline = BurnBarPlanOutline(
            objective: intent.objective,
            steps: [BurnBarPlanStep(title: "Inspect", detail: "Read context")]
        )
        let runID = BurnBarRunID(rawValue: "run-journal")

        try await journal.append(
            BurnBarRunJournalEvent(
                runID: runID,
                kind: .runCreated,
                phase: .planning,
                payload: try BurnBarJSONValue.fromEncodable(intent),
                emittedAt: Date()
            )
        )
        try await journal.writeCheckpoint(
            BurnBarRunJournalCheckpoint(
                runID: runID,
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                phase: .planning,
                modelID: "glm-5",
                originalPrompt: intent.objective,
                intent: intent,
                planOutline: outline,
                updatedAt: Date()
            )
        )

        let events = try await journal.events(for: runID)
        XCTAssertEqual(events.count, 1)
        let checkpoint = try await journal.checkpoint(for: runID)
        XCTAssertEqual(checkpoint?.intent.kind, .generic)
        XCTAssertEqual(checkpoint?.planOutline.steps.count, 1)
    }

    func testAgentLoopServiceParsesStructuredSearchDecision() async throws {
        let service = BurnBarAgentLoopService()
        let route = BurnBarProviderRoute(
            providerID: "zai",
            providerDisplayName: "Z.ai",
            baseURL: "https://example.com",
            requestedModel: "glm-5",
            resolvedModelID: "glm-5",
            apiKey: "test",
            pricing: BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 1, cacheReadPerMToken: 0)
        )
        let executor = BurnBarQueuedLoopProviderExecutor(outputs: [
            #"{"action":"search_workspace","requestedTool":"search_workspace","arguments":{"query":"BurnBarRunService"},"rationale":"Need repo context first."}"#
        ])

        let decision = try await service.decideNextAction(
            request: BurnBarAgentLoopRequest(
                objective: "Find where the run service lives",
                intent: BurnBarAgentIntent(
                    kind: .generic,
                    objective: "Find where the run service lives",
                    summary: "Investigate and act"
                ),
                planOutline: BurnBarPlanOutline(
                    objective: "Find where the run service lives",
                    steps: [BurnBarPlanStep(title: "Inspect", detail: "Search the repo")]
                ),
                loopState: BurnBarAgentLoopState(),
                contextSnapshot: BurnBarAgentContextSnapshot(candidatePaths: [], searchHints: ["BurnBarRunService"]),
                journalTail: []
            ),
            route: route,
            providerExecutor: executor
        )

        XCTAssertEqual(decision.action, .searchWorkspace)
        XCTAssertEqual(decision.requestedTool, .searchWorkspace)
    }

    func testAgentLoopServiceRetriesMalformedDecisionOnce() async throws {
        let service = BurnBarAgentLoopService()
        let route = BurnBarProviderRoute(
            providerID: "zai",
            providerDisplayName: "Z.ai",
            baseURL: "https://example.com",
            requestedModel: "glm-5",
            resolvedModelID: "glm-5",
            apiKey: "test",
            pricing: BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 1, cacheReadPerMToken: 0)
        )
        let executor = BurnBarQueuedLoopProviderExecutor(outputs: [
            "not json",
            #"{"action":"complete","rationale":"Context is sufficient.","message":"Done."}"#
        ])

        let decision = try await service.decideNextAction(
            request: BurnBarAgentLoopRequest(
                objective: "Summarize the repo",
                intent: BurnBarAgentIntent(
                    kind: .generic,
                    objective: "Summarize the repo",
                    summary: "Investigate and complete"
                ),
                planOutline: BurnBarPlanOutline(
                    objective: "Summarize the repo",
                    steps: [BurnBarPlanStep(title: "Inspect", detail: "Search and summarize")]
                ),
                loopState: BurnBarAgentLoopState(),
                contextSnapshot: BurnBarAgentContextSnapshot(candidatePaths: [], searchHints: ["repo"]),
                journalTail: []
            ),
            route: route,
            providerExecutor: executor
        )

        XCTAssertEqual(decision.action, .complete)
        XCTAssertEqual(decision.message, "Done.")
    }
}

private actor BurnBarQueuedLoopProviderExecutor: BurnBarProviderExecuting {
    private var outputs: [String]

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func completeStructured(
        _ request: BurnBarStructuredPromptRequest,
        route: BurnBarProviderRoute
    ) async throws -> BurnBarProviderExecutionResult {
        let output = outputs.isEmpty ? #"{"action":"fail","rationale":"No queued output.","message":"No response available."}"# : outputs.removeFirst()

        let inputPrompt = [request.systemPrompt, request.userPrompt]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        return BurnBarProviderExecutionResult(
            outputText: output,
            inputTokens: max(1, inputPrompt.count / 4),
            outputTokens: max(1, output.count / 4),
            cacheReadTokens: 0
        )
    }
}
