import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBar

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
                ChatTranscriptPiece(id: "p3", kind: .text, value: "Now editing.")
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
        XCTAssertEqual(convertedAssistant.toolUses.count, 1)
        XCTAssertEqual(convertedAssistant.toolUses.first?.name, "Read")
        XCTAssertEqual(convertedAssistant.toolUses.first?.detail, "Auth.swift")
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
}
