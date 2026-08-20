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

    func test_archivedAgent_mapsXAIToGrokBuildArchiveOnly() {
        XCTAssertEqual(CLIAgentSessionMirror.archivedAgent(for: .xAI), .grok)
        XCTAssertFalse(CLIAgentSessionMirror.canResume(agent: .grok))
    }

    func testWriteResumeHintUsesEditorSpecificOwnerOnlyFiles() throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-resume-hint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let cursorURL = try OpenBurnBarChatWorkspaceConfigurator.writeResumeHint(
            in: workspaceURL,
            targetHarness: "Cursor",
            briefingMarkdown: "# BurnBar Resume\n"
        )
        XCTAssertEqual(
            cursorURL.path,
            workspaceURL.appendingPathComponent(".cursor/burnbar-resume.md").path
        )
        XCTAssertEqual(try String(contentsOf: cursorURL, encoding: .utf8), "# BurnBar Resume\n")
        XCTAssertEqual(try posixPermissions(at: cursorURL), 0o600)
        XCTAssertEqual(try posixPermissions(at: cursorURL.deletingLastPathComponent()), 0o700)

        let windsurfURL = try OpenBurnBarChatWorkspaceConfigurator.writeResumeHint(
            in: workspaceURL,
            targetHarness: "windsurf",
            briefingMarkdown: "handoff"
        )
        XCTAssertEqual(
            windsurfURL.path,
            workspaceURL.appendingPathComponent(".windsurf/burnbar-resume.md").path
        )
        XCTAssertEqual(try posixPermissions(at: windsurfURL), 0o600)

        let fallbackURL = try OpenBurnBarChatWorkspaceConfigurator.writeResumeHint(
            in: workspaceURL,
            targetHarness: "unknown-gui",
            briefingMarkdown: "fallback"
        )
        XCTAssertEqual(
            fallbackURL.path,
            workspaceURL.appendingPathComponent(".openburnbar/burnbar-resume.md").path
        )
        XCTAssertEqual(try posixPermissions(at: fallbackURL), 0o600)
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

    func test_buildArchivedLogRecord_includesMobileVisibleTranscriptPreview() throws {
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
            fullText: """
            ## You

            Fix startup.

            ## Assistant

            Done and verified.
            """,
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
        XCTAssertEqual(record.messages.count, 2)
        XCTAssertEqual(record.messages.first?.role, .user)
        XCTAssertEqual(record.messages.first?.text, "Fix startup.")
        XCTAssertEqual(record.messages.last?.role, .assistant)
        XCTAssertEqual(record.messages.last?.text, "Done and verified.")
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

    func test_missionEventFactory_sealsPrivateEventPayloadWithRequestBoundAAD() throws {
        let vaultKey = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: vaultKey)
        let event = CLIAgentMissionEventFactory.event(
            sequence: 7,
            phase: "tool_use",
            kind: "tool_call",
            title: "Shell",
            message: "ran swift tests",
            runtime: "codex",
            toolName: "exec_command",
            artifactPath: "docs/report.md",
            changedFilePath: "AgentLens/App.swift",
            isError: false
        )

        let sealed = try CLIAgentMissionEventFactory.sealedEvent(
            event,
            uid: "uid-1",
            requestID: "mission-1",
            eventID: "000007",
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID
        )

        XCTAssertEqual(sealed["contentSealed"] as? Bool, true)
        XCTAssertEqual(sealed["sealedSchemaVersion"] as? Int, 2)
        XCTAssertEqual(sealed["vaultKeyID"] as? String, vaultKeyID)
        XCTAssertNil(sealed["title"])
        XCTAssertNil(sealed["message"])
        XCTAssertNil(sealed["fullMessage"])
        XCTAssertNil(sealed["toolName"])
        XCTAssertNil(sealed["artifactPath"])
        XCTAssertNil(sealed["changedFilePath"])

        let envelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: sealed["sealedPayload"]))
        let expectedContext = try CloudVaultAADContext(
            uid: "uid-1",
            collection: "cli_agent_mission_requests/events",
            docID: "mission-1/000007",
            field: "sealedPayload"
        )
        XCTAssertEqual(envelope.aad, expectedContext.stringValue)
        let opened = try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: expectedContext)
        let decoded = try JSONDecoder().decode(DecodedMissionEventPayload.self, from: opened)
        XCTAssertEqual(decoded.title, "Shell")
        XCTAssertEqual(decoded.message, "ran swift tests")
        XCTAssertEqual(decoded.fullMessage, "ran swift tests")
        XCTAssertEqual(decoded.toolName, "exec_command")
        XCTAssertEqual(decoded.artifactPath, "docs/report.md")
        XCTAssertEqual(decoded.changedFilePath, "AgentLens/App.swift")

        let wrongContext = try CloudVaultAADContext(
            uid: "uid-1",
            collection: "cli_agent_mission_requests/events",
            docID: "mission-1/000008",
            field: "sealedPayload"
        )
        XCTAssertThrowsError(try CloudVaultCrypto.openPayload(envelope, keyData: vaultKey, aadContext: wrongContext))
    }

    func test_missionCloudSealer_bindsStatePayloadToMissionRequestAAD() throws {
        let vaultKey = try CloudVaultCrypto.generateVaultKey()
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: vaultKey)
        let privatePayload = CLIAgentMissionPrivatePayload(
            title: "Launch audit",
            prompt: "Find launch blockers.",
            targetProject: "/repo",
            liveSummary: "Running",
            resultPreview: "Two issues",
            errorMessage: nil,
            approvalTitle: "Allow shell?",
            approvalMessage: "Needs local tests",
            personaScopeJSON: #"{"mode":"strict"}"#,
            synthesisSummary: "Ready"
        )
        let expectedContext = try CLIAgentMissionCloudSealer.missionAADContext(
            uid: "uid-1",
            requestID: "mission-1",
            field: "sealedStatePayload"
        )

        let sealedPayload = try CLIAgentMissionCloudSealer.seal(
            privatePayload,
            vaultKey: vaultKey,
            vaultKeyID: vaultKeyID,
            aadContext: expectedContext
        )
        let envelope = try XCTUnwrap(CloudVaultCrypto.sealedPayload(from: sealedPayload))
        XCTAssertEqual(envelope.aad, expectedContext.stringValue)

        let opened = try XCTUnwrap(CLIAgentMissionCloudSealer.openPrivatePayload(
            ["sealedStatePayload": sealedPayload],
            field: "sealedStatePayload",
            uid: "uid-1",
            requestID: "mission-1",
            vaultKey: vaultKey
        ))
        XCTAssertEqual(opened.title, "Launch audit")
        XCTAssertEqual(opened.prompt, "Find launch blockers.")
        XCTAssertEqual(opened.targetProject, "/repo")
        XCTAssertEqual(opened.liveSummary, "Running")
        XCTAssertEqual(opened.resultPreview, "Two issues")
        XCTAssertEqual(opened.approvalTitle, "Allow shell?")
        XCTAssertEqual(opened.approvalMessage, "Needs local tests")
        XCTAssertEqual(opened.personaScopeJSON, #"{"mode":"strict"}"#)
        XCTAssertEqual(opened.synthesisSummary, "Ready")

        XCTAssertNil(CLIAgentMissionCloudSealer.openPrivatePayload(
            ["sealedStatePayload": sealedPayload],
            field: "sealedStatePayload",
            uid: "uid-1",
            requestID: "mission-2",
            vaultKey: vaultKey
        ))
    }

    func test_missionEventFactory_redactsSecretsBeforeMobileStreaming() {
        let providerToken = "sk-" + "1234567890abcdef"
        let jwtToken = ["eyJhbGciOiJIUzI1NiJ9", "eyJzdWIiOiJ1c2VyLWlkLTEyMzQ1Njc4OTAifQ", "signaturepayload0987654321"].joined(separator: ".")
        let redacted = CLIAgentMissionEventFactory.redactSecrets(
            "token=\(providerToken) bearer abcdefghijklmnopqrstuvwxyz012345 and \(jwtToken)"
        )

        XCTAssertFalse(redacted.contains(providerToken))
        XCTAssertFalse(redacted.lowercased().contains("bearer abcdef"))
        XCTAssertFalse(redacted.contains("eyJhbGci"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func test_missionEventFactory_redactsParentPreviewAndErrorTextForMobile() {
        let providerToken = "sk-" + "1234567890abcdef"
        let safeText = CLIAgentMissionEventFactory.mobileSafeText(
            "Final answer token=\(providerToken) bearer abcdefghijklmnopqrstuvwxyz012345",
            limit: 80
        )

        XCTAssertTrue(safeText.contains("[REDACTED]"))
        XCTAssertFalse(safeText.contains(providerToken))
        XCTAssertFalse(safeText.lowercased().contains("bearer abcdef"))
        XCTAssertLessThanOrEqual(safeText.count, 80)
    }

    func test_missionRuntimePlanner_honorsExplicitMobileRuntimeSelection() {
        let enabled: [ChatBackendID] = [.codex, .claude, .hermes, .piAgent, .openclaw, .droid, .forge, .antigravity]

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
                requestedRuntime: "pi-agent",
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
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "droid",
                missionKind: "provider_routing",
                enabledBackends: enabled
            ).chatBackend,
            .droid
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "factory-droid",
                missionKind: "provider_routing",
                enabledBackends: enabled
            ).chatBackend,
            .droid
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.resolve(
                requestedRuntime: "forge",
                missionKind: "custom",
                enabledBackends: enabled
            ).chatBackend,
            .forge
        )
        for alias in ["omp", "ohmypi", "oh-my-pi", "oh my pi"] {
            XCTAssertEqual(
                CLIAgentMissionRuntimePlanner.resolve(
                    requestedRuntime: alias,
                    missionKind: "custom",
                    enabledBackends: enabled
                ).chatBackend,
                .omp,
                "alias \(alias)"
            )
        }

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

    func test_cliAgentRelayExecutor_classifiesSupportedChatBackends() {
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "codex"), .codex)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "claude-code"), .claude)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "hermes"), .hermes)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "openclaw"), .openclaw)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "pi-agent"), .piAgent)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "droid"), .droid)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "factory-droid"), .droid)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "forge"), .forge)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "omp"), .omp)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "ohmypi"), .omp)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "oh-my-pi"), .omp)
        XCTAssertEqual(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "oh my pi"), .omp)
        XCTAssertNil(ChatSessionControllerCLIAgentRelayChatExecutor.backend(for: "unknown"))
    }

    func test_cursorAgentModelCatalog_usesPrimaryProbe() async throws {
        let (discovery, root) = try makeCursorAgentCatalogDiscovery(script: """
        #!/bin/sh
        if [ "$1" = "models" ]; then
          printf '%s\n' 'Available models' 'gpt-5.4-high - GPT-5.4 High' 'Tip: done'
          exit 0
        fi
        exit 9
        """)
        defer { removeCursorAgentCatalogFixture(at: root) }

        let response = try await discovery.modelCatalog(
            for: CLIRuntimeModelCatalogRequest(runtime: AssistantRuntimeID.cursorAgent.rawValue)
        )

        XCTAssertEqual(response.options.map(\.modelID), ["gpt-5.4-high"])
        XCTAssertEqual(response.options.map(\.source), [.cursorAgentModelCatalog])
    }

    func test_cursorAgentModelCatalog_usesFallbackAfterPrimaryProbeFails() async throws {
        let (discovery, root) = try makeCursorAgentCatalogDiscovery(script: """
        #!/bin/sh
        if [ "$1" = "models" ]; then
          echo 'primary failed' >&2
          exit 7
        fi
        if [ "$1" = "--list-models" ]; then
          printf '%s\n' 'Available models' 'claude-opus-4-8-high - Opus 4.8 High' 'Tip: done'
          exit 0
        fi
        exit 9
        """)
        defer { removeCursorAgentCatalogFixture(at: root) }

        let response = try await discovery.modelCatalog(
            for: CLIRuntimeModelCatalogRequest(runtime: AssistantRuntimeID.cursorAgent.rawValue)
        )

        XCTAssertEqual(response.options.map(\.modelID), ["claude-opus-4-8-high"])
        XCTAssertEqual(response.options.map(\.source), [.cursorAgentModelCatalog])
    }

    func test_cursorAgentModelCatalog_usesDefaultProfileAfterBothProbesFail() async throws {
        let (discovery, root) = try makeCursorAgentCatalogDiscovery(script: """
        #!/bin/sh
        echo "probe $1 failed" >&2
        exit 7
        """)
        defer { removeCursorAgentCatalogFixture(at: root) }

        let response = try await discovery.modelCatalog(
            for: CLIRuntimeModelCatalogRequest(runtime: AssistantRuntimeID.cursorAgent.rawValue)
        )

        XCTAssertEqual(response.options.count, 1)
        XCTAssertEqual(response.options.first?.modelID, "")
        XCTAssertEqual(response.options.first?.source, .cursorAgentProfile)
    }

    private func makeCursorAgentCatalogDiscovery(
        script: String
    ) throws -> (CLIRuntimeModelCatalogDiscovery, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cursor-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("cursor-agent")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        CLIExecutableResolver.clearCache()
        let rootPath = root.path
        let resolver = CLIExecutableResolver(
            environmentProvider: {
                ["PATH": rootPath, "SHELL": "/openburnbar-nonexistent-shell"]
            },
            homeDirectoryProvider: { rootPath }
        )
        return (
            CLIRuntimeModelCatalogDiscovery(
                resolver: resolver,
                gatewayProvider: {
                    RoutingClientGateway(host: "127.0.0.1", port: 8317, authToken: "")
                }
            ),
            root
        )
    }

    private func removeCursorAgentCatalogFixture(at root: URL) {
        CLIExecutableResolver.clearCache()
        try? FileManager.default.removeItem(at: root)
    }

    private func posixPermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
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

    func test_missionRuntimePlanner_buildsPlainPromptForMobileChat() {
        let backend = CLIAgentMissionBackend(chatBackend: .claude)
        let prompt = CLIAgentMissionRuntimePlanner.prompt(
            title: "New Claude Chat",
            prompt: "Hi how are you",
            backend: backend,
            data: [
                "source": "ios-chat",
                "missionKind": "chat",
                "commandsAllowed": false,
                "fileEditsAllowed": false
            ]
        )

        XCTAssertTrue(prompt.contains("continuing a normal chat"))
        XCTAssertTrue(prompt.contains("Source: ios-chat"))
        XCTAssertTrue(prompt.contains("Reply directly to the user's message"))
        XCTAssertTrue(prompt.contains("Hi how are you"))
        XCTAssertFalse(prompt.contains("Mission:"))
        XCTAssertFalse(prompt.contains("Produce actionable findings"))
    }

    func test_missionRuntimePlanner_acceptsSafeMobileClientThreadIDForChatContinuity() {
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.mobileChatClientThreadID(from: [
                "source": "ios-chat",
                "clientThreadID": "mobile-codex-ABC_123"
            ]),
            "mobile-codex-ABC_123"
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.mobileChatClientThreadID(from: [
                "source": "android-chat",
                "clientThreadID": "mobile-claude-xyz"
            ]),
            "mobile-claude-xyz"
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.mobileChatClientThreadID(from: [
                "missionKind": "chat",
                "clientThreadID": "mobile-openclaw-1"
            ]),
            "mobile-openclaw-1"
        )
    }

    func test_missionRuntimePlanner_rejectsUnsafeOrNonChatClientThreadID() {
        XCTAssertNil(CLIAgentMissionRuntimePlanner.mobileChatClientThreadID(from: [
            "source": "ios",
            "missionKind": "debt",
            "clientThreadID": "mobile-codex-ABC_123"
        ]))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.mobileChatClientThreadID(from: [
            "source": "ios-chat",
            "clientThreadID": "../escape"
        ]))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.mobileChatClientThreadID(from: [
            "source": "ios-chat",
            "clientThreadID": String(repeating: "a", count: 513)
        ]))
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
            XCTAssertEqual(plan.arguments.first, "-lc")
            XCTAssertFalse(
                plan.arguments.joined(separator: " ").contains(hostilePrompt),
                "\(backend.displayName) must not interpolate mobile prompt text into the shell command."
            )
            XCTAssertTrue(plan.arguments.joined(separator: " ").contains("OPENBURNBAR_MISSION_PROMPT"))
            XCTAssertEqual(plan.extraEnvironment["OPENBURNBAR_MISSION_PROMPT"]?.contains(hostilePrompt), true)
        }
    }

    func test_missionRuntimePlanner_usesDirectArgumentsForOpenClaudeWithoutShell() throws {
        let hostilePrompt = #"Read "$HOME"; rm -rf /tmp/should-not-run"#
        let backend = CLIAgentMissionBackend(chatBackend: .openClaude)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "OpenClaude direct mission",
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
        XCTAssertFalse(plan.arguments.contains("-lc"))
        XCTAssertTrue(plan.arguments.contains("-p"))
        XCTAssertTrue(plan.arguments.contains("--permission-mode"))
        XCTAssertTrue(plan.arguments.contains("plan"))
        XCTAssertTrue(plan.arguments.contains("--tools"))
        let toolsIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(plan.arguments[toolsIndex + 1], "")
        XCTAssertTrue(plan.arguments.joined(separator: "\n").contains(hostilePrompt))
    }

    func test_missionRuntimePlanner_usesDirectArgumentsForOMPWithHostPromptImmediatelyAfterDashP() throws {
        let hostilePrompt = #"Read "$HOME"; rm -rf /tmp/should-not-run"#
        let backend = CLIAgentMissionBackend(chatBackend: .omp)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "OMP direct mission",
            prompt: hostilePrompt,
            backend: backend,
            data: [
                "approvalMode": "read_only",
                "commandsAllowed": false,
                "fileEditsAllowed": false
            ]
        ))

        XCTAssertEqual(plan.executableName, "omp")
        XCTAssertEqual(plan.extraEnvironment, [:])
        XCTAssertFalse(plan.arguments.contains("-lc"))
        let promptIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "-p"))
        let hostPrompt = plan.arguments[promptIndex + 1]
        XCTAssertNotEqual(hostPrompt, "--mode")
        XCTAssertTrue(hostPrompt.contains("OpenBurnBar Mission Control"))
        XCTAssertTrue(hostPrompt.contains(hostilePrompt))
        XCTAssertEqual(Array(plan.arguments[promptIndex...promptIndex + 4]), ["-p", hostPrompt, "--mode", "json", "--no-session"])
        XCTAssertTrue(plan.arguments.contains("--no-tools"))
    }

    func test_missionRuntimePlanner_passesRequestedModelToOMPDirectCLI() throws {
        let backend = CLIAgentMissionBackend(chatBackend: .omp)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "OMP selected model mission",
            prompt: "Use the phone-selected model.",
            backend: backend,
            data: [
                "requestedModelID": "anthropic/claude-sonnet-4",
                "approvalMode": "read_only",
                "commandsAllowed": true,
                "fileEditsAllowed": false
            ]
        ))

        let promptIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "-p"))
        XCTAssertNotEqual(plan.arguments[promptIndex + 1], "--mode")
        let modelIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--model"))
        XCTAssertEqual(plan.arguments[modelIndex + 1], "anthropic/claude-sonnet-4")
        let toolsIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--tools"))
        XCTAssertTrue(plan.arguments[toolsIndex + 1].contains("bash"))
        XCTAssertFalse(plan.arguments[toolsIndex + 1].contains("edit"))
    }

    func test_missionRuntimePlanner_passesRequestedModelToPiDirectCLI() throws {
        let backend = CLIAgentMissionBackend(chatBackend: .piAgent)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Pi selected model mission",
            prompt: "Use the phone-selected model.",
            backend: backend,
            data: [
                "requestedModelID": "openai/gpt-5.5",
                "approvalMode": "read_only",
                "commandsAllowed": false,
                "fileEditsAllowed": false
            ]
        ))

        XCTAssertEqual(plan.executableName, "zsh")
        XCTAssertEqual(plan.extraEnvironment["OPENBURNBAR_MISSION_MODEL"], "openai/gpt-5.5")
        XCTAssertTrue(plan.arguments.joined(separator: "\n").contains("--model \"$OPENBURNBAR_MISSION_MODEL\""))
        XCTAssertFalse(plan.arguments.joined(separator: "\n").contains("openai/gpt-5.5"))
    }

    func test_missionRuntimePlanner_passesRequestedModelToOpenClaudeDirectCLI() throws {
        let backend = CLIAgentMissionBackend(chatBackend: .openClaude)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "OpenClaw selected model mission",
            prompt: "Use the phone-selected model.",
            backend: backend,
            data: [
                "requestedModelID": "claude-opus-4-7",
                "approvalMode": "read_only",
                "commandsAllowed": false,
                "fileEditsAllowed": false
            ]
        ))

        let modelIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--model"))
        XCTAssertEqual(plan.arguments[modelIndex + 1], "claude-opus-4-7")
    }

    func test_missionRuntimePlanner_launchesHermesVisibleCLIWithSelectedModel() throws {
        let backend = CLIAgentMissionBackend(chatBackend: .hermes)
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Hermes visible CLI chat",
            prompt: "Answer from a visible Terminal.",
            backend: backend,
            data: [
                "requestedModelID": "minimax/minimax-2.7-highspeed",
                "source": "ios-chat",
                "missionKind": "chat",
                "commandsAllowed": false,
                "fileEditsAllowed": false
            ]
        ))

        XCTAssertEqual(plan.executableName, "hermes")
        XCTAssertEqual(Array(plan.arguments.prefix(2)), ["chat", "--query"])
        let query = try XCTUnwrap(plan.arguments.dropFirst(2).first)
        XCTAssertTrue(query.contains("Source: ios-chat"))
        XCTAssertTrue(query.contains("Commands allowed: no"))
        XCTAssertTrue(query.contains("File edits allowed: no"))
        XCTAssertTrue(query.contains("Answer from a visible Terminal."))
        XCTAssertTrue(plan.arguments.contains("--accept-hooks"))
        XCTAssertTrue(plan.arguments.contains("--source"))
        XCTAssertTrue(plan.arguments.contains("openburnbar-mobile-cli"))
        let modelIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--model"))
        XCTAssertEqual(plan.arguments[modelIndex + 1], "minimax/minimax-2.7-highspeed")
    }

    func test_missionRuntimePlanner_constrainsOpenClaudeEditToolsWhenFileEditsAreDisabled() throws {
        let backend = CLIAgentMissionBackend(chatBackend: .openClaude)
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

        XCTAssertFalse(plan.arguments.contains("auto"))
        XCTAssertTrue(plan.arguments.contains("--allowedTools"))
        let allowedIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--allowedTools"))
        XCTAssertEqual(plan.arguments[allowedIndex + 1], "Bash")
        XCTAssertTrue(plan.arguments.contains("--disallowedTools"))
        let disallowedIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "--disallowedTools"))
        let disallowed = plan.arguments[disallowedIndex + 1]
        XCTAssertTrue(disallowed.contains("Edit"))
        XCTAssertTrue(disallowed.contains("MultiEdit"))
        XCTAssertTrue(disallowed.contains("Write"))
        XCTAssertTrue(disallowed.contains("NotebookEdit"))
        XCTAssertFalse(disallowed.contains("Bash"))
    }

    func test_missionRuntimePlanner_parsesPresentationModeWithNativeDefault() {
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.presentationMode(from: ["presentationMode": "mac_visible_cli"]),
            .macVisibleCLI
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.presentationMode(from: ["presentationMode": "  native_chat  "]),
            .nativeChat
        )
        XCTAssertEqual(
            CLIAgentMissionRuntimePlanner.presentationMode(from: ["presentationMode": "nonsense"]),
            .nativeChat
        )
        XCTAssertEqual(CLIAgentMissionRuntimePlanner.presentationMode(from: [:]), .nativeChat)
    }

    // The pre-dispatch approval DECISION (`requiresPreDispatchApproval`) moved to
    // the daemon in split-brain M4; its GUI↔daemon parity is now pinned by
    // OpenBurnBarDaemonTests/`MissionRemoteAuthorizationParityTests` and the
    // daemon's own `BurnBarRemoteMissionAuthorizationTests`. The EXECUTION-side
    // Mac CLI-assistant consent gate (`requiresMacCLIAssistantConsentForRemoteMission`)
    // survives M4 and stays pinned below.

    func test_missionRuntimePlanner_localAgentRuntimesHonorMacCLIAssistantConsentGate() {
        let localAgentBackends = [
            CLIAgentMissionBackend(chatBackend: .codex),
            CLIAgentMissionBackend(chatBackend: .claude),
            CLIAgentMissionBackend(chatBackend: .openclaw),
            CLIAgentMissionBackend(chatBackend: .piAgent),
            CLIAgentMissionBackend(chatBackend: .droid),
            CLIAgentMissionBackend(chatBackend: .forge),
            CLIAgentMissionBackend(chatBackend: .antigravity),
            CLIAgentMissionBackend(chatBackend: .cursorAgent),
            CLIAgentMissionBackend(rawValue: "opencode", displayName: "OpenCode"),
            CLIAgentMissionBackend(rawValue: "ollama", displayName: "Ollama")
        ]

        for backend in localAgentBackends {
            XCTAssertTrue(
                CLIAgentMissionRuntimePlanner.requiresMacCLIAssistantConsentForRemoteMission(backend: backend),
                "\(backend.rawValue) must honor the Mac CLI assistant consent switch before local launch"
            )
        }
    }

    func test_missionRuntimePlanner_hermesIsExemptFromTheMacCLIAssistantConsentGate() {
        XCTAssertFalse(CLIAgentMissionRuntimePlanner.requiresMacCLIAssistantConsentForRemoteMission(
            backend: CLIAgentMissionBackend(chatBackend: .hermes)
        ))
    }

    func test_missionRuntimePlanner_buildsDirectLaunchPlansForAdditionalAgentRuntimes() throws {
        let baseData: [String: Any] = [
            "source": "ios",
            "targetProject": "~/Developer/OpenBurnBar",
            "depth": "deep",
            "approvalMode": "risky_only",
            "commandsAllowed": true,
            "fileEditsAllowed": false,
            "requestedModelID": "sage"
        ]

        let droidCommandPlan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Droid mission",
            prompt: "Inspect the workspace.",
            backend: CLIAgentMissionBackend(chatBackend: .droid),
            data: baseData
        ))
        XCTAssertEqual(droidCommandPlan.executableName, "droid")
        XCTAssertTrue(droidCommandPlan.arguments.contains("exec"))
        XCTAssertTrue(droidCommandPlan.arguments.contains("--model"))
        XCTAssertTrue(droidCommandPlan.arguments.contains("sage"))
        XCTAssertTrue(droidCommandPlan.arguments.contains("--auto"))
        XCTAssertTrue(droidCommandPlan.arguments.contains("medium"))

        var editOnlyData = baseData
        editOnlyData["commandsAllowed"] = false
        editOnlyData["fileEditsAllowed"] = true
        let droidEditPlan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Droid edit mission",
            prompt: "Prepare edits without shell execution.",
            backend: CLIAgentMissionBackend(chatBackend: .droid),
            data: editOnlyData
        ))
        XCTAssertTrue(droidEditPlan.arguments.contains("low"))
        XCTAssertTrue(droidEditPlan.arguments.contains("--disabled-tools"))
        XCTAssertTrue(droidEditPlan.arguments.contains("execute-cli"))

        let forgePlan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Forge mission",
            prompt: "Use the selected Forge agent.",
            backend: CLIAgentMissionBackend(chatBackend: .forge),
            data: baseData
        ))
        XCTAssertEqual(forgePlan.executableName, "forge")
        XCTAssertEqual(Array(forgePlan.arguments.prefix(2)), ["--agent", "sage"])
        XCTAssertTrue(forgePlan.arguments.contains("--prompt"))

        let antigravityPlan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Antigravity mission",
            prompt: "Run with AGY.",
            backend: CLIAgentMissionBackend(chatBackend: .antigravity),
            data: baseData
        ))
        XCTAssertEqual(antigravityPlan.executableName, "agy")
        XCTAssertFalse(antigravityPlan.arguments.isEmpty)

        let cursorPlan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Cursor mission",
            prompt: "Run with Cursor Agent.",
            backend: CLIAgentMissionBackend(chatBackend: .cursorAgent),
            data: baseData
        ))
        XCTAssertEqual(cursorPlan.executableName, "cursor-agent")
        XCTAssertFalse(cursorPlan.arguments.isEmpty)
    }

    func test_missionRuntimePlanner_refusesRestrictedJunieVisibleTerminalPlan() {
        let readOnlyData: [String: Any] = [
            "source": "ios",
            "targetProject": "~/Documents/Windsurf/BurnBar",
            "clientThreadID": "visible-junie-read-only",
            "commandsAllowed": false,
            "fileEditsAllowed": false,
            "requestedModelID": "junie-default"
        ]
        XCTAssertFalse(CLIAgentJunieMissionPolicy.hasFullDesktopCapabilities(
            CLIAgentMissionRuntimePlanner.capabilityGrant(for: CLIAgentMissionBackend(chatBackend: .junie), data: readOnlyData)
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Restricted Junie mission",
            prompt: "Inspect without edits or commands.",
            backend: CLIAgentMissionBackend(chatBackend: .junie),
            data: readOnlyData
        ))

        var editOnlyData = readOnlyData
        editOnlyData["fileEditsAllowed"] = true
        XCTAssertFalse(CLIAgentJunieMissionPolicy.hasFullDesktopCapabilities(
            CLIAgentMissionRuntimePlanner.capabilityGrant(for: CLIAgentMissionBackend(chatBackend: .junie), data: editOnlyData)
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Edit-only Junie mission",
            prompt: "Edit without commands.",
            backend: CLIAgentMissionBackend(chatBackend: .junie),
            data: editOnlyData
        ))
    }

    func test_missionRuntimePlanner_allowsJunieVisibleTerminalPlanOnlyWithFullDesktopCapabilities() throws {
        let data: [String: Any] = [
            "source": "ios",
            "targetProject": "~/Documents/Windsurf/BurnBar",
            "clientThreadID": "visible-junie-full",
            "commandsAllowed": true,
            "fileEditsAllowed": true,
            "requestedModelID": "junie-default"
        ]

        XCTAssertTrue(CLIAgentJunieMissionPolicy.hasFullDesktopCapabilities(
            CLIAgentMissionRuntimePlanner.capabilityGrant(for: CLIAgentMissionBackend(chatBackend: .junie), data: data)
        ))
        let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Full Junie mission",
            prompt: "Run with explicit full desktop approval.",
            backend: CLIAgentMissionBackend(chatBackend: .junie),
            data: data
        ))
        XCTAssertEqual(plan.executableName, "junie")
        XCTAssertTrue(plan.arguments.contains("--task"))
        XCTAssertTrue(plan.arguments.contains("--model"))
        XCTAssertTrue(plan.arguments.contains("junie-default"))
    }

    func test_junieMissionPolicy_directExecutionRefusalFailsClosed() throws {
        let junie = CLIAgentMissionBackend(chatBackend: .junie)
        let restricted: [String: Any] = ["commandsAllowed": true, "fileEditsAllowed": false]
        let refusal = try XCTUnwrap(CLIAgentJunieMissionPolicy.directExecutionRefusal(
            backend: junie,
            grant: CLIAgentMissionRuntimePlanner.capabilityGrant(for: junie, data: restricted)
        ))
        XCTAssertEqual(refusal.status, "failed")
        XCTAssertTrue(refusal.sessionID.hasPrefix("policy-junie-"))
        XCTAssertEqual(refusal.errorMessage?.contains("command execution and file-edit approval"), true)

        let full: [String: Any] = ["commandsAllowed": true, "fileEditsAllowed": true]
        XCTAssertNil(CLIAgentJunieMissionPolicy.directExecutionRefusal(
            backend: junie,
            grant: CLIAgentMissionRuntimePlanner.capabilityGrant(for: junie, data: full)
        ))

        // Non-Junie backends are never refused by the Junie policy.
        let codex = CLIAgentMissionBackend(chatBackend: .codex)
        XCTAssertNil(CLIAgentJunieMissionPolicy.directExecutionRefusal(
            backend: codex,
            grant: CLIAgentMissionRuntimePlanner.capabilityGrant(for: codex, data: restricted)
        ))
    }

    func test_missionRuntimePlanner_buildsVisibleTerminalPlansForGrantBackedRuntimes() throws {
        let data: [String: Any] = [
            "source": "ios",
            "targetProject": "~/Documents/Windsurf/BurnBar",
            "clientThreadID": "visible-thread-1",
            "commandsAllowed": true,
            "fileEditsAllowed": true,
            "requestedModelID": "frontier-model"
        ]

        let expectedExecutables: [(ChatBackendID, String)] = [
            (.codex, "codex"),
            (.claude, "claude"),
            (.droid, "droid"),
            (.junie, "junie"),
            (.fx, "fx"),
            (.forge, "forge"),
            (.antigravity, "agy"),
            (.cursorAgent, "cursor-agent")
        ]

        for (backendID, executable) in expectedExecutables {
            let plan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
                title: "Visible terminal mission",
                prompt: "Run visibly with scoped permissions.",
                backend: CLIAgentMissionBackend(chatBackend: backendID),
                data: data
            ))
            XCTAssertEqual(plan.executableName, executable)
            XCTAssertFalse(plan.arguments.isEmpty, "\(backendID.rawValue) should receive launch arguments")
            XCTAssertEqual(plan.extraEnvironment, [:])
        }
    }

    func test_missionRuntimePlanner_blocksJunieVisibleTerminalWhenGrantIsNotFullyInteractive() {
        let backend = CLIAgentMissionBackend(chatBackend: .junie)
        let baseData: [String: Any] = [
            "source": "ios",
            "targetProject": "~/Documents/Windsurf/BurnBar",
            "clientThreadID": "visible-thread-read-only",
            "requestedModelID": "frontier-model"
        ]

        XCTAssertNil(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Read-only Junie mission",
            prompt: "Inspect the workspace without edits or commands.",
            backend: backend,
            data: baseData.merging([
                "commandsAllowed": false,
                "fileEditsAllowed": false
            ]) { _, new in new }
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Junie shell-only mission",
            prompt: "Run commands but do not edit files.",
            backend: backend,
            data: baseData.merging([
                "commandsAllowed": true,
                "fileEditsAllowed": false
            ]) { _, new in new }
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Junie write-only mission",
            prompt: "Edit files without commands.",
            backend: backend,
            data: baseData.merging([
                "commandsAllowed": false,
                "fileEditsAllowed": true
            ]) { _, new in new }
        ))
    }

    func test_missionRuntimePlanner_returnsNilForUnsupportedDirectAndVisibleRuntimes() {
        let custom = CLIAgentMissionBackend(rawValue: "unknown-runtime", displayName: "Unknown")
        XCTAssertNil(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Unsupported",
            prompt: "No launch plan",
            backend: custom,
            data: [:]
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.visibleTerminalLaunchPlan(
            title: "Unsupported",
            prompt: "No launch plan",
            backend: custom,
            data: [:]
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Codex native chat",
            prompt: "Continue the interactive mobile chat.",
            backend: CLIAgentMissionBackend(chatBackend: .codex),
            data: ["source": "ios-chat", "missionKind": "chat"]
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Claude native chat",
            prompt: "Continue the interactive mobile chat.",
            backend: CLIAgentMissionBackend(chatBackend: .claude),
            data: ["source": "ios-chat", "missionKind": "chat"]
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Codex Android native chat",
            prompt: "Continue the interactive mobile chat.",
            backend: CLIAgentMissionBackend(chatBackend: .codex),
            data: ["source": "android-chat"]
        ))
        XCTAssertNil(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Claude Android native chat",
            prompt: "Continue the interactive mobile chat.",
            backend: CLIAgentMissionBackend(chatBackend: .claude),
            data: ["source": "android-chat"]
        ))
    }

    func test_missionRuntimePlanner_routesApprovedWandClaudeAndCodexMissionsDirectly() throws {
        let expectedReply = "PARETO_READY_REGRESSION"
        let data: [String: Any] = [
            "source": "ios-insights",
            "missionKind": "diligence",
            "approvalMode": "existing_policy",
            "commandsAllowed": false,
            "fileEditsAllowed": false
        ]

        let codexPlan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Pareto regression · codex",
            prompt: "Reply with exactly \(expectedReply).",
            backend: CLIAgentMissionBackend(chatBackend: .codex),
            data: data
        ))
        XCTAssertEqual(codexPlan.executableName, "codex")
        XCTAssertTrue(codexPlan.arguments.contains("--json"))
        XCTAssertTrue(codexPlan.arguments.contains("read-only"))
        XCTAssertTrue(codexPlan.arguments.joined(separator: "\n").contains(expectedReply))
        XCTAssertFalse(codexPlan.arguments.joined(separator: "\n").contains("<UNTRUSTED_CONTENT"))

        let claudePlan = try XCTUnwrap(CLIAgentMissionRuntimePlanner.directLaunchPlan(
            title: "Pareto regression · claude",
            prompt: "Reply with exactly \(expectedReply).",
            backend: CLIAgentMissionBackend(chatBackend: .claude),
            data: data
        ))
        XCTAssertEqual(claudePlan.executableName, "claude")
        XCTAssertTrue(claudePlan.arguments.contains("stream-json"))
        XCTAssertTrue(claudePlan.arguments.joined(separator: "\n").contains(expectedReply))
        XCTAssertFalse(claudePlan.arguments.joined(separator: "\n").contains("<UNTRUSTED_CONTENT"))
    }

    func test_directCLIStreamMirror_extractsFinalCodexReplyFromRealJSONLShape() throws {
        let mirror = DirectCLIStreamMirror()
        let expectedReply = "PARETO_READY_REGRESSION"
        let event = try XCTUnwrap(mirror.parseJSONLine(#"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"PARETO_READY_REGRESSION"}}"#))

        XCTAssertEqual(event.kind, "llm_response")
        XCTAssertEqual(event.message, expectedReply)
        XCTAssertEqual(mirror.finalOutputSnapshot(fallback: "raw-json-fallback"), expectedReply)
    }

    func test_directCLIStreamMirror_mapsCodexLifecycleAndUsageEvents() throws {
        let mirror = DirectCLIStreamMirror()

        let session = try XCTUnwrap(mirror.parseJSONLine(#"{"type":"thread.started"}"#))
        XCTAssertEqual(session.title, "LLM call started")
        XCTAssertEqual(session.message, "Codex session initialized.")

        let turn = try XCTUnwrap(mirror.parseJSONLine(#"{"type":"turn.started"}"#))
        XCTAssertEqual(turn.title, "LLM call started")
        XCTAssertEqual(turn.message, "Codex turn started.")

        let usage = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"turn.completed","usage":{"output_tokens":5,"input_tokens":3}}"#
        ))
        XCTAssertEqual(usage.title, "LLM usage")
        XCTAssertEqual(usage.message, "input_tokens=3\noutput_tokens=5")
    }

    func test_directCLIStreamMirror_mapsCodexCommandEventsAndFallbacks() throws {
        let mirror = DirectCLIStreamMirror()

        let started = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.started","item":{"type":"command_execution","command":"swift test"}}"#
        ))
        XCTAssertEqual(started.kind, "tool_call")
        XCTAssertEqual(started.message, "swift test")
        XCTAssertEqual(started.toolName, "Bash")

        let output = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"command_execution","command":"swift test","output":"  42 tests passed  "}}"#
        ))
        XCTAssertEqual(output.kind, "tool_result")
        XCTAssertEqual(output.message, "42 tests passed")

        let stdout = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.finished","item":{"type":"command_execution","stdout":"stdout fallback"}}"#
        ))
        XCTAssertEqual(stdout.message, "stdout fallback")

        let stderr = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"command_execution","stderr":"stderr fallback"}}"#
        ))
        XCTAssertEqual(stderr.message, "stderr fallback")

        let result = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"command_execution","result":"result fallback"}}"#
        ))
        XCTAssertEqual(result.message, "result fallback")

        let commandOnly = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"command_execution","command":"make ci"}}"#
        ))
        XCTAssertEqual(commandOnly.message, "Completed: make ci")

        let defaulted = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"command_execution"}}"#
        ))
        XCTAssertEqual(defaulted.message, "Codex command completed.")
    }

    func test_directCLIStreamMirror_deduplicatesCumulativeCodexAssistantMessages() throws {
        let mirror = DirectCLIStreamMirror()

        let first = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Ready"}}"#
        ))
        XCTAssertEqual(first.message, "Ready")

        let delta = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Ready to merge"}}"#
        ))
        XCTAssertEqual(delta.message, " to merge")
        XCTAssertNil(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Ready to merge"}}"#
        ))

        let replacement = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Replacement answer"}}"#
        ))
        XCTAssertEqual(replacement.message, "Replacement answer")
        XCTAssertEqual(mirror.finalOutputSnapshot(fallback: nil), "Replacement answer")
    }

    func test_directCLIStreamMirror_mapsCodexErrorsAndRejectsMalformedEvents() throws {
        let mirror = DirectCLIStreamMirror()

        let itemError = try XCTUnwrap(mirror.parseJSONLine(
            #"{"type":"item.completed","item":{"type":"error","message":"tool failed"}}"#
        ))
        XCTAssertTrue(itemError.isError)
        XCTAssertEqual(itemError.message, "tool failed")

        let messageError = try XCTUnwrap(mirror.parseJSONLine(#"{"type":"error","message":"turn failed"}"#))
        XCTAssertEqual(messageError.message, "turn failed")

        let objectError = try XCTUnwrap(mirror.parseJSONLine(#"{"type":"error","error":"network unavailable"}"#))
        XCTAssertEqual(objectError.message, "network unavailable")

        let defaultError = try XCTUnwrap(mirror.parseJSONLine(#"{"type":"error"}"#))
        XCTAssertEqual(defaultError.message, "Codex reported an error.")

        XCTAssertNil(mirror.parseJSONLine(#"{"type":"item.completed","item":{}}"#))
        XCTAssertNil(mirror.parseJSONLine(#"{"type":"unknown"}"#))
        XCTAssertNil(mirror.parseJSONLine("not-json"))
    }
}

private struct DecodedMissionEventPayload: Decodable {
    let title: String?
    let message: String
    let fullMessage: String?
    let toolName: String?
    let artifactPath: String?
    let changedFilePath: String?
}
