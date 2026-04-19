import OpenBurnBarCore
@testable import OpenBurnBarDaemon
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
            .appendingPathComponent("openburnbar-journal-tests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - VAL-DAEMON-007: Intent normalization precedence is deterministic

    func testPlannerIntentNormalizationPrecedenceIsDeterministic_explicitIntentWinsOverWorkflow() throws {
        let planner = BurnBarPlannerService()
        // When both explicit agentIntent AND workspaceWorkflow are provided,
        // explicit intent metadata must win (precedence: explicit > workflow > tool > prompt > generic)
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "replace old with new",
                modelID: "glm-5",
                metadata: [
                    // Explicit intent (highest precedence)
                    "agentIntent": .object([
                        "kind": .string("inspect_workspace"),
                        "objective": .string("explicit objective"),
                        "summary": .string("explicit summary"),
                        "searchQuery": .string("explicit query")
                    ]),
                    // Workflow metadata (should be ignored because explicit intent wins)
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("ShouldBeIgnored.swift"),
                        "from": .string("old"),
                        "to": .string("new")
                    ])
                ]
            )
        )

        // Precedence: explicit intent > workflow metadata
        XCTAssertEqual(planned.intent.kind, .inspectWorkspace)
        XCTAssertEqual(planned.intent.searchQuery, "explicit query")
        XCTAssertEqual(planned.intent.requestedTools, [.searchWorkspace])
        // Workflow fields should NOT be present
        XCTAssertNil(planned.intent.targetPath)
        XCTAssertNil(planned.intent.replacement)
    }

    func testPlannerIntentNormalizationPrecedenceIsDeterministic_workflowWinsOverTool() throws {
        let planner = BurnBarPlannerService()
        // When both workspaceWorkflow AND toolKind are provided, workflow wins
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "run tests",
                modelID: "glm-5",
                metadata: [
                    // Workflow metadata (second highest precedence)
                    "workspaceWorkflow": .object([
                        "type": .string("replace_string_in_file"),
                        "path": .string("File.swift"),
                        "from": .string("a"),
                        "to": .string("b")
                    ]),
                    // Tool metadata (should be ignored because workflow wins)
                    "toolKind": .string("run_terminal"),
                    "toolArguments": .object([
                        "command": .string("npm test")
                    ])
                ]
            )
        )

        // Precedence: workflow > tool
        XCTAssertEqual(planned.intent.kind, .replaceStringInFile)
        XCTAssertEqual(planned.intent.targetPath, "File.swift")
        XCTAssertEqual(planned.intent.requestedTools, [.readFile, .applyPatch])
    }

    func testPlannerIntentNormalizationPrecedenceIsDeterministic_toolWinsOverPrompt() throws {
        let planner = BurnBarPlannerService()
        // When both toolKind and prompt heuristics are provided, tool wins
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "replace \"from\" with \"to\"", // This would trigger replace heuristic
                modelID: "glm-5",
                metadata: [
                    // Tool metadata (second lowest precedence)
                    "toolKind": .string("search_workspace"),
                    "toolArguments": .object([
                        "query": .string("specific query")
                    ])
                ]
            )
        )

        // Precedence: tool > prompt
        XCTAssertEqual(planned.intent.kind, .inspectWorkspace)
        XCTAssertEqual(planned.intent.searchQuery, "specific query")
        XCTAssertEqual(planned.intent.requestedTools, [.searchWorkspace])
    }

    func testPlannerIntentNormalizationPrecedenceIsDeterministic_promptWinsOverGenericFallback() throws {
        let planner = BurnBarPlannerService()
        // When prompt can be parsed, it wins over generic fallback
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "search for BurnBarRunService", // Matches search heuristic
                modelID: "glm-5",
                metadata: [:] // No explicit intent, workflow, or tool metadata
            )
        )

        // Precedence: prompt > generic fallback
        XCTAssertEqual(planned.intent.kind, .inspectWorkspace)
        XCTAssertEqual(planned.intent.searchQuery, "BurnBarRunService")
        XCTAssertEqual(planned.intent.requestedTools, [.searchWorkspace])
    }

    func testPlannerIntentNormalizationPrecedenceMatrix_fullOrderingIsStable() throws {
        // VAL-DAEMON-007: Intent resolution precedence is deterministic:
        // explicit intent metadata > workflow metadata > tool metadata > prompt heuristics > generic fallback
        let planner = BurnBarPlannerService()

        // Case 1: All sources present - explicit wins
        let allSources = try planner.plan(for: BurnBarRunCreateRequest(
            clientID: BurnBarClientID(rawValue: "client-a"),
            sessionID: BurnBarSessionID(rawValue: "session-a"),
            prompt: "search directive",
            modelID: "glm-5",
            metadata: [
                "agentIntent": .object([
                    "kind": .string("generic"),
                    "objective": .string("from explicit"),
                    "summary": .string("explicit wins")
                ]),
                "workspaceWorkflow": .object([
                    "type": .string("replace_string_in_file"),
                    "path": .string("workflow.swift"),
                    "from": .string("a"),
                    "to": .string("b")
                ]),
                "toolKind": .string("run_terminal"),
                "activeFilePath": .string("prompt.swift")
            ]
        ))
        XCTAssertEqual(allSources.intent.summary, "explicit wins")

        // Case 2: No explicit, but workflow and tool - workflow wins
        let workflowAndTool = try planner.plan(for: BurnBarRunCreateRequest(
            clientID: BurnBarClientID(rawValue: "client-a"),
            sessionID: BurnBarSessionID(rawValue: "session-a"),
            prompt: "some prompt",
            modelID: "glm-5",
            metadata: [
                "workspaceWorkflow": .object([
                    "type": .string("replace_string_in_file"),
                    "path": .string("workflow.swift"),
                    "from": .string("a"),
                    "to": .string("b")
                ]),
                "toolKind": .string("run_terminal")
            ]
        ))
        XCTAssertEqual(workflowAndTool.intent.kind, .replaceStringInFile)

        // Case 3: No explicit, no workflow, but tool - tool wins
        let toolOnly = try planner.plan(for: BurnBarRunCreateRequest(
            clientID: BurnBarClientID(rawValue: "client-a"),
            sessionID: BurnBarSessionID(rawValue: "session-a"),
            prompt: "some prompt",
            modelID: "glm-5",
            metadata: [
                "toolKind": .string("run_terminal"),
                "toolArguments": .object(["command": .string("echo test")])
            ]
        ))
        XCTAssertEqual(toolOnly.intent.kind, .runTerminal)

        // Case 4: No explicit, no workflow, no tool, but prompt parses - prompt wins
        let promptOnly = try planner.plan(for: BurnBarRunCreateRequest(
            clientID: BurnBarClientID(rawValue: "client-a"),
            sessionID: BurnBarSessionID(rawValue: "session-a"),
            prompt: "run echo hello",
            modelID: "glm-5",
            metadata: [:]
        ))
        XCTAssertEqual(promptOnly.intent.kind, .runTerminal)

        // Case 5: Nothing parses - generic fallback
        let genericFallback = try planner.plan(for: BurnBarRunCreateRequest(
            clientID: BurnBarClientID(rawValue: "client-a"),
            sessionID: BurnBarSessionID(rawValue: "session-a"),
            prompt: "do something vague",
            modelID: "glm-5",
            metadata: [:]
        ))
        XCTAssertEqual(genericFallback.intent.kind, .generic)
    }

    // MARK: - VAL-DAEMON-008: Unsupported workflow intent fails pre-execution

    func testPlannerUnsupportedWorkflowIntentFallsBackGracefully() throws {
        let planner = BurnBarPlannerService()

        // Unsupported workflow type should be skipped (returns nil) so fallback to generic
        // Note: workflow payload still requires path/from/to fields for decoding, but type check fails
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "do something",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("unsupported_workflow_type"),
                        "path": .string("some/path.swift"),
                        "from": .string("old"),
                        "to": .string("new")
                    ])
                ]
            )
        )
        // Should fall back to generic since unsupported workflow is skipped
        XCTAssertEqual(planned.intent.kind, .generic)
        XCTAssertEqual(planned.intent.objective, "do something")
    }

    func testPlannerUnsupportedWorkflowWithValidFallbackDoesNotThrow() throws {
        // Even if one workflow type is unsupported, if another parsing path succeeds, it should work
        let planner = BurnBarPlannerService()

        // This has an unsupported workflow but tool metadata will be used instead
        let planned = try planner.plan(
            for: BurnBarRunCreateRequest(
                clientID: BurnBarClientID(rawValue: "client-a"),
                sessionID: BurnBarSessionID(rawValue: "session-a"),
                prompt: "run tests",
                modelID: "glm-5",
                metadata: [
                    "workspaceWorkflow": .object([
                        "type": .string("unsupported_type"),
                        "path": .string("some/path.swift"),
                        "from": .string("old"),
                        "to": .string("new")
                    ]),
                    "toolKind": .string("run_terminal"),
                    "toolArguments": .object([
                        "command": .string("npm test")
                    ])
                ]
            )
        )

        // Tool metadata wins because workflow was unsupported
        XCTAssertEqual(planned.intent.kind, .runTerminal)
        XCTAssertEqual(planned.intent.terminalCommand?.command, "npm test")
    }

    // MARK: - VAL-DAEMON-014: Typed planner input requires constraints, risk level, and desired outputs

    func testTypedPlannerInputRejectsMissingConstraints() throws {
        let planner = BurnBarPlannerService()
        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "test",
            summary: "test summary"
        )
        let input = BurnBarPlannerInput(
            missionID: BurnBarMissionID(rawValue: "mission-1"),
            normalizedIntent: intent,
            constraints: [], // Empty constraints - should fail
            riskLevel: .low,
            desiredOutputs: ["output1"]
        )

        do {
            _ = try planner.plan(for: input)
            XCTFail("Expected planner to reject empty constraints")
        } catch let error as BurnBarPlannerServiceError {
            switch error {
            case .invalidPlannerInput(let message):
                XCTAssertTrue(message.contains("constraints"))
                XCTAssertTrue(message.contains("cannot be empty"))
            default:
                XCTFail("Expected invalidPlannerInput error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarPlannerServiceError, got \(error)")
        }
    }

    func testTypedPlannerInputRejectsMissingDesiredOutputs() throws {
        let planner = BurnBarPlannerService()
        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "test",
            summary: "test summary"
        )
        let input = BurnBarPlannerInput(
            missionID: BurnBarMissionID(rawValue: "mission-1"),
            normalizedIntent: intent,
            constraints: ["constraint1"],
            riskLevel: .low,
            desiredOutputs: [] // Empty desired outputs - should fail
        )

        do {
            _ = try planner.plan(for: input)
            XCTFail("Expected planner to reject empty desiredOutputs")
        } catch let error as BurnBarPlannerServiceError {
            switch error {
            case .invalidPlannerInput(let message):
                XCTAssertTrue(message.contains("desiredOutputs"))
                XCTAssertTrue(message.contains("cannot be empty"))
            default:
                XCTFail("Expected invalidPlannerInput error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarPlannerServiceError, got \(error)")
        }
    }

    func testTypedPlannerInputAcceptsValidInputWithAllRequiredFields() throws {
        let planner = BurnBarPlannerService()
        let intent = BurnBarAgentIntent(
            kind: .replaceStringInFile,
            objective: "replace old with new",
            summary: "replace operation",
            targetPath: "test.swift",
            replacement: BurnBarTextReplacement(from: "old", to: "new"),
            requestedTools: [.readFile, .applyPatch]
        )
        let input = BurnBarPlannerInput(
            missionID: BurnBarMissionID(rawValue: "mission-1"),
            normalizedIntent: intent,
            constraints: ["do not modify tests", "preserve imports"],
            riskLevel: .medium,
            desiredOutputs: ["file updated", "compilation succeeds"]
        )

        let planned = try planner.plan(for: input)

        XCTAssertEqual(planned.intent.kind, .replaceStringInFile)
        XCTAssertEqual(planned.constraints, ["do not modify tests", "preserve imports"])
        XCTAssertEqual(planned.riskLevel, .medium)
        XCTAssertEqual(planned.desiredOutputs, ["file updated", "compilation succeeds"])
        XCTAssertEqual(planned.outline.steps.count, 3)
    }

    func testTypedPlannerInputPreservesFieldsThroughPlanAndOutline() throws {
        let planner = BurnBarPlannerService()
        let intent = BurnBarAgentIntent(
            kind: .inspectWorkspace,
            objective: "find relevant files",
            summary: "workspace inspection",
            searchQuery: "BurnBarRunService",
            requestedTools: [.searchWorkspace]
        )
        let input = BurnBarPlannerInput(
            missionID: BurnBarMissionID(rawValue: "mission-2"),
            normalizedIntent: intent,
            constraints: ["only search src/"],
            riskLevel: .low,
            desiredOutputs: ["files identified"],
            workflowHints: ["scope": .string("src")]
        )

        let planned = try planner.plan(for: input)

        // Fields preserved through planning
        XCTAssertEqual(planned.intent.kind, .inspectWorkspace)
        XCTAssertEqual(planned.intent.searchQuery, "BurnBarRunService")
        XCTAssertEqual(planned.constraints, ["only search src/"])
        XCTAssertEqual(planned.riskLevel, .low)
        XCTAssertEqual(planned.desiredOutputs, ["files identified"])
        // Outline generated correctly
        XCTAssertEqual(planned.outline.objective, "find relevant files")
        XCTAssertEqual(planned.outline.steps.count, 3) // search, inspect, summarize
    }

    func testTypedPlannerInputRejectsUnsupportedSchemaVersion() throws {
        let planner = BurnBarPlannerService()
        let intent = BurnBarAgentIntent(
            kind: .generic,
            objective: "test",
            summary: "test"
        )
        let input = BurnBarPlannerInput(
            schemaVersion: 99, // Unsupported version
            missionID: BurnBarMissionID(rawValue: "mission-1"),
            normalizedIntent: intent,
            constraints: ["constraint"],
            riskLevel: .low,
            desiredOutputs: ["output"]
        )

        do {
            _ = try planner.plan(for: input)
            XCTFail("Expected planner to reject unsupported schema version")
        } catch let error as BurnBarPlannerInputError {
            switch error {
            case .unsupportedSchemaVersion(let version):
                XCTAssertEqual(version, 99)
            default:
                XCTFail("Expected unsupportedSchemaVersion error, got \(error)")
            }
        } catch {
            XCTFail("Expected BurnBarPlannerInputError, got \(error)")
        }
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
            cacheCreationTokens: 0,
            cacheReadTokens: 0
        )
    }
}
