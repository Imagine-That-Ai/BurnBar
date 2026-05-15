import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class CLIAgentSessionMirrorTests: XCTestCase {

    func test_cliAgent_mapsBackendsToCLIRuntime() {
        XCTAssertEqual(CLIAgentSessionMirror.cliAgent(for: .codex), .codex)
        XCTAssertEqual(CLIAgentSessionMirror.cliAgent(for: .claude), .claude)
        XCTAssertEqual(CLIAgentSessionMirror.cliAgent(for: .openclaw), .openClaw)
        XCTAssertNil(CLIAgentSessionMirror.cliAgent(for: .hermes))
        XCTAssertNil(CLIAgentSessionMirror.cliAgent(for: .piAgent))
    }

    func test_build_convertsMessagesAndDerivesMetadata() throws {
        let started = Date(timeIntervalSince1970: 1_730_000_000)
        let user = ChatMessageRecord(
            id: "u1",
            role: .user,
            content: "Please refactor the login flow.",
            timestamp: started
        )
        let assistant = ChatMessageRecord(
            id: "a1",
            role: .assistant,
            content: "On it.",
            timestamp: started.addingTimeInterval(30),
            cliUsed: "claude",
            transcriptPieces: [
                ChatTranscriptPiece(id: "p1", kind: .text, value: "On it. "),
                ChatTranscriptPiece(id: "p2", kind: .toolUse, value: "Read", detail: "Auth.swift"),
                ChatTranscriptPiece(id: "p3", kind: .toolResult, value: "Read", detail: "Read 80 lines."),
                ChatTranscriptPiece(id: "p4", kind: .text, value: "Now editing.")
            ]
        )

        let record = CLIAgentSessionMirror.build(
            threadID: "thread-x",
            agent: .claude,
            modelName: "claude-sonnet-4.7",
            workspaceLabel: "BurnBar",
            messages: [user, assistant],
            usage: CLIUsageSnapshot(
                inputTokens: 100,
                outputTokens: 200,
                cacheCreationTokens: 0,
                cacheReadTokens: 0,
                reasoningTokens: 0
            ),
            endedAt: nil
        )

        XCTAssertEqual(record.id, "thread-x")
        XCTAssertEqual(record.agent, .claude)
        XCTAssertEqual(record.modelName, "claude-sonnet-4.7")
        XCTAssertEqual(record.workspaceLabel, "BurnBar")
        XCTAssertEqual(record.title, "Please refactor the login flow.")
        XCTAssertFalse(record.isCompleted)
        XCTAssertEqual(record.messages.count, 2)
        let convertedAssistant = try XCTUnwrap(record.messages.last)
        XCTAssertEqual(convertedAssistant.role, .assistant)
        XCTAssertEqual(convertedAssistant.text, "On it. Now editing.")
        XCTAssertEqual(convertedAssistant.toolUses.count, 2)
        XCTAssertEqual(convertedAssistant.toolUses.first?.name, "Read")
        XCTAssertEqual(convertedAssistant.toolUses.first?.detail, "Auth.swift")
        XCTAssertEqual(convertedAssistant.toolUses.last?.status, "completed")
        XCTAssertEqual(convertedAssistant.toolUses.last?.detail, "Read 80 lines.")
        XCTAssertEqual(record.tokenUsage?.inputTokens, 100)
        XCTAssertEqual(record.tokenUsage?.outputTokens, 200)
    }

    func test_build_legacyMessageWithEmptyTranscript_usesContentAsBody() throws {
        let legacy = ChatMessageRecord(
            id: "legacy",
            role: .assistant,
            content: "Plain answer.",
            timestamp: Date()
        )
        let record = CLIAgentSessionMirror.build(
            threadID: "t",
            agent: .codex,
            modelName: nil,
            workspaceLabel: nil,
            messages: [legacy],
            usage: nil,
            endedAt: nil
        )
        XCTAssertEqual(record.messages.first?.text, "Plain answer.")
        XCTAssertTrue(record.messages.first?.toolUses.isEmpty ?? false)
    }

    func test_buildArchivedLogRecord_indexesProviderLogWithoutPlaintextTranscript() throws {
        let start = Date(timeIntervalSince1970: 1_730_000_000)
        let conversation = ConversationRecord(
            id: ConversationRecord.stableId(provider: .codex, sessionId: "thread-123"),
            provider: .codex,
            sessionId: "thread-123",
            projectName: "BurnBar",
            startTime: start,
            endTime: start.addingTimeInterval(60),
            messageCount: 4,
            userWordCount: 8,
            assistantWordCount: 80,
            keyFiles: ["AgentLens/App.swift"],
            keyCommands: ["swift test"],
            keyTools: ["exec_command"],
            inferredTaskTitle: "Fix startup",
            lastAssistantMessage: "Done and verified.",
            fullText: "very private transcript body",
            indexedAt: start,
            fileModifiedAt: start,
            summary: nil
        )

        let record = try XCTUnwrap(
            CLIAgentSessionMirror.buildArchivedLogRecord(
                conversation: conversation,
                cloudLogDocumentID: "mac_codex_thread_123"
            )
        )

        XCTAssertEqual(record.agent, .codex)
        XCTAssertEqual(record.sourceKind, .archivedLog)
        XCTAssertEqual(record.title, "Fix startup")
        XCTAssertEqual(record.preview, "Done and verified.")
        XCTAssertEqual(record.workspaceLabel, "BurnBar")
        XCTAssertTrue(record.messages.isEmpty, "Archive index rows must not duplicate the encrypted transcript in plaintext")
        XCTAssertTrue(record.encryptedTranscriptAvailable)
        XCTAssertEqual(record.resumeHandle?.providerSessionID, "thread-123")
        XCTAssertEqual(record.resumeHandle?.commandHint, "codex resume \"thread-123\"")
        XCTAssertTrue(record.resumeHandle?.canResume ?? false)
        XCTAssertTrue(record.resumeHandle?.canFork ?? false)
    }

    func test_build_titleFallsBackToDefault_whenNoUserMessage() {
        let assistantOnly = ChatMessageRecord(
            id: "a1",
            role: .assistant,
            content: "Hi",
            timestamp: Date()
        )
        let record = CLIAgentSessionMirror.build(
            threadID: "t",
            agent: .codex,
            modelName: nil,
            workspaceLabel: nil,
            messages: [assistantOnly],
            usage: nil,
            endedAt: nil
        )
        XCTAssertEqual(record.title, "CLI session")
    }

    func test_missionEventFactory_buildsDurableOrderedMacEventPayload() throws {
        let event = CLIAgentMissionEventFactory.event(
            sequence: 42,
            phase: "tool_use",
            kind: "tool_call",
            title: "Shell",
            message: "Running unit tests",
            runtime: "codex",
            toolName: "exec_command",
            artifactPath: "docs/INSIGHTS.md",
            changedFilePath: "OpenBurnBarMobile/Views/Insights/InsightsRootView.swift",
            isError: false
        )

        XCTAssertEqual(CLIAgentMissionEventFactory.eventID(for: 42), "000042")
        XCTAssertEqual(event["sequence"] as? Int, 42)
        XCTAssertEqual(event["phase"] as? String, "tool_use")
        XCTAssertEqual(event["kind"] as? String, "tool_call")
        XCTAssertEqual(event["title"] as? String, "Shell")
        XCTAssertEqual(event["message"] as? String, "Running unit tests")
        XCTAssertEqual(event["source"] as? String, "mac")
        XCTAssertEqual(event["runtime"] as? String, "codex")
        XCTAssertEqual(event["toolName"] as? String, "exec_command")
        XCTAssertEqual(event["artifactPath"] as? String, "docs/INSIGHTS.md")
        XCTAssertEqual(event["changedFilePath"] as? String, "OpenBurnBarMobile/Views/Insights/InsightsRootView.swift")
        XCTAssertEqual(event["isError"] as? Bool, false)
        XCTAssertNotNil(event["timestamp"] as? String)
    }

    func test_missionEventFactory_redactsSecretsBeforeMobileStreaming() {
        let redacted = CLIAgentMissionEventFactory.redactSecrets(
            "token=sk-1234567890abcdef bearer abcdefghijklmnopqrstuvwxyz012345 and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLWlkLTEyMzQ1Njc4OTAifQ.signaturepayload0987654321"
        )

        XCTAssertFalse(redacted.contains("sk-1234567890abcdef"))
        XCTAssertFalse(redacted.lowercased().contains("bearer abcdef"))
        XCTAssertFalse(redacted.contains("eyJhbGci"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func test_missionEventFactory_redactsParentPreviewAndErrorTextForMobile() {
        let safeText = CLIAgentMissionEventFactory.mobileSafeText(
            "Final answer token=sk-1234567890abcdef bearer abcdefghijklmnopqrstuvwxyz012345",
            limit: 80
        )

        XCTAssertTrue(safeText.contains("[REDACTED]"))
        XCTAssertFalse(safeText.contains("sk-1234567890abcdef"))
        XCTAssertFalse(safeText.lowercased().contains("bearer abcdef"))
        XCTAssertLessThanOrEqual(safeText.count, 80)
    }

    func test_missionRuntimePlanner_honorsExplicitMobileRuntimeSelection() {
        let enabled: [ChatBackendID] = [.codex, .claude, .hermes, .piAgent, .openclaw]

        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "codex",
                missionKind: "debt",
                enabledBackends: enabled
            ).chatBackend,
            .codex
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "claude",
                missionKind: "diligence",
                enabledBackends: enabled
            ).chatBackend,
            .claude
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "hermes",
                missionKind: "custom",
                enabledBackends: enabled
            ).chatBackend,
            .hermes
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "pi",
                missionKind: "creative",
                enabledBackends: enabled
            ).chatBackend,
            .piAgent
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "piAgent",
                missionKind: "creative",
                enabledBackends: enabled
            ).chatBackend,
            .piAgent
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "openclaw",
                missionKind: "ui_improvement",
                enabledBackends: enabled
            ).chatBackend,
            .openclaw
        )

        let opencode = CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: "opencode",
            missionKind: "provider_routing",
            enabledBackends: enabled
        )
        XCTAssertEqual(opencode.rawValue, "opencode")
        XCTAssertEqual(opencode.displayName, "OpenCode")
        XCTAssertTrue(opencode.usesDirectCLI)

        let ollama = CLIAgentMissionRuntimePlanner.resolve(
            requestedRuntime: "ollama",
            missionKind: "cost_efficiency",
            enabledBackends: enabled
        )
        XCTAssertEqual(ollama.rawValue, "ollama")
        XCTAssertEqual(ollama.displayName, "Ollama")
        XCTAssertTrue(ollama.usesDirectCLI)
    }

    func test_missionRuntimePlanner_selectsMissionKindFallbacksFromEnabledBackends() {
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "auto",
                missionKind: "diligence",
                enabledBackends: [.codex, .claude]
            ).chatBackend,
            .claude
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: nil,
                missionKind: "security",
                enabledBackends: [.codex]
            ).chatBackend,
            .codex
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: nil,
                missionKind: "creative",
                enabledBackends: [.codex, .openclaw]
            ).chatBackend,
            .openclaw
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: nil,
                missionKind: "ui_improvement",
                enabledBackends: [.hermes]
            ).chatBackend,
            .hermes
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: nil,
                missionKind: "provider_routing",
                enabledBackends: [.claude, .codex]
            ).chatBackend,
            .codex
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: nil,
                missionKind: "unknown",
                enabledBackends: [.piAgent]
            ).chatBackend,
            .piAgent
        )
    }

    func test_missionRuntimePlanner_buildsMacHostPromptWithApprovalAndSafetyContext() {
        let backend = CLIAgentMissionBackend(chatBackend: .codex)
        let prompt = CLIAgentMissionRuntimePlanner.prompt(
            title: "Audit Launch State",
            prompt: "Find the blocking issue.",
            backend: backend,
            data: [
                "source": "ios",
                "targetProject": "/Users/albertonunez/Documents/Windsurf/BurnBar",
                "depth": "deep",
                "approvalMode": "ask_for_risky_actions",
                "commandsAllowed": true,
                "fileEditsAllowed": false
            ]
        )

        XCTAssertTrue(prompt.contains("running from \(backend.displayName) on the user's Mac"))
        XCTAssertTrue(prompt.contains("Mission: Audit Launch State"))
        XCTAssertTrue(prompt.contains("Source: ios"))
        XCTAssertTrue(prompt.contains("Target project: /Users/albertonunez/Documents/Windsurf/BurnBar"))
        XCTAssertTrue(prompt.contains("Depth: deep"))
        XCTAssertTrue(prompt.contains("Approval mode: ask_for_risky_actions"))
        XCTAssertTrue(prompt.contains("Commands allowed: yes"))
        XCTAssertTrue(prompt.contains("File edits allowed: no"))
        XCTAssertTrue(prompt.contains("If file edits are not allowed, do not modify files"))
        XCTAssertTrue(prompt.contains("Find the blocking issue."))
    }

    func test_missionRuntimePlanner_keepsShellBackedPromptsOutOfCommandStrings() throws {
        let hostilePrompt = #"Inspect repo"; touch /tmp/openburnbar-owned; echo "$OPENROUTER_API_KEY" #"#
        let data: [String: Any] = [
            "source": "android-insights",
            "targetProject": "/tmp",
            "depth": "max",
            "approvalMode": "read_only",
            "commandsAllowed": false,
            "fileEditsAllowed": false
        ]
        let shellBackedBackends = [
            CLIAgentMissionBackend(chatBackend: .piAgent),
            CLIAgentMissionBackend(rawValue: "opencode", displayName: "OpenCode"),
            CLIAgentMissionBackend(rawValue: "ollama", displayName: "Ollama")
        ]

        for backend in shellBackedBackends {
            let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
                title: "Hostile prompt mission",
                prompt: hostilePrompt,
                backend: backend,
                data: data
            ))
            XCTAssertEqual(plan.executableName, "zsh")
            XCTAssertEqual(plan.arguments.first, "-lic")
            XCTAssertFalse(
                plan.arguments.joined(separator: " ").contains(hostilePrompt),
                "\(backend.displayName) must not interpolate mobile prompt text into the shell command."
            )
            XCTAssertTrue(plan.arguments.joined(separator: " ").contains("OPENBURNBAR_MISSION_PROMPT"))
            XCTAssertTrue(plan.extraEnvironment["OPENBURNBAR_MISSION_PROMPT"]?.contains(hostilePrompt) == true)
        }
    }

    func test_missionRuntimePlanner_usesDirectArgumentsForOpenClawWithoutShell() throws {
        let hostilePrompt = #"Read "$HOME"; rm -rf /tmp/should-not-run"#
        let backend = CLIAgentMissionBackend(chatBackend: .openclaw)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "OpenClaw direct mission",
            prompt: hostilePrompt,
            backend: backend,
            data: [
                "approvalMode": "read_only",
                "commandsAllowed": false,
                "fileEditsAllowed": false
            ]
        ))

        XCTAssertEqual(plan.executableName, "openclaude")
        XCTAssertEqual(plan.extraEnvironment, [:])
        XCTAssertFalse(plan.arguments.contains("-lic"))
        XCTAssertTrue(plan.arguments.contains("-p"))
        XCTAssertTrue(plan.arguments.contains("--permission-mode"))
        XCTAssertTrue(plan.arguments.contains("plan"))
        XCTAssertTrue(plan.arguments.contains("--tools"))
        let toolsIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(plan.arguments[toolsIndex + 1], "")
        XCTAssertTrue(plan.arguments.joined(separator: "\n").contains(hostilePrompt))
    }

    func test_missionRuntimePlanner_constrainsOpenClawEditToolsWhenFileEditsAreDisabled() throws {
        let backend = CLIAgentMissionBackend(chatBackend: .openclaw)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "OpenClaw command-only mission",
            prompt: "Inspect the repository with commands, but do not edit files.",
            backend: backend,
            data: [
                "approvalMode": "risky_only",
                "commandsAllowed": true,
                "fileEditsAllowed": false
            ]
        ))

        XCTAssertTrue(plan.arguments.contains("--permission-mode"))
        XCTAssertTrue(plan.arguments.contains("auto"))
        XCTAssertTrue(plan.arguments.contains("--disallowedTools"))
        let disallowed = try XCTUnwrap(plan.arguments.last)
        XCTAssertTrue(disallowed.contains("Edit"))
        XCTAssertTrue(disallowed.contains("MultiEdit"))
        XCTAssertTrue(disallowed.contains("Write"))
        XCTAssertTrue(disallowed.contains("NotebookEdit"))
        XCTAssertFalse(disallowed.contains("Bash"))
    }
}
