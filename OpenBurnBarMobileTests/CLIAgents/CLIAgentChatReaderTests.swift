import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class CLIAgentChatReaderTests: XCTestCase {

    func test_refresh_populatesSessions() async {
        let stub = StubCLISource()
        stub.allSessions = [
            makeSession(id: "a", agent: .codex, updated: Date(timeIntervalSince1970: 100)),
            makeSession(id: "b", agent: .claude, updated: Date(timeIntervalSince1970: 200))
        ]
        let reader = CLIAgentChatReader(remote: stub)

        XCTAssertTrue(reader.sessions.isEmpty)
        await reader.refresh()

        XCTAssertEqual(reader.sessions.count, 2)
        XCTAssertNil(reader.lastError)
        XCTAssertNotNil(reader.lastRefreshedAt)
    }

    func test_filteringByAgent_returnsSubset() async {
        let stub = StubCLISource()
        stub.allSessions = [
            makeSession(id: "codex-1", agent: .codex, updated: Date(timeIntervalSince1970: 100)),
            makeSession(id: "claude-1", agent: .claude, updated: Date(timeIntervalSince1970: 200)),
            makeSession(id: "claude-2", agent: .claude, updated: Date(timeIntervalSince1970: 300))
        ]
        let reader = CLIAgentChatReader(remote: stub)
        await reader.refresh()

        let claudes = reader.sessions(for: .claude)
        XCTAssertEqual(claudes.count, 2)
        XCTAssertEqual(claudes.first?.id, "claude-2", "Newest first")
        XCTAssertEqual(reader.sessions(for: .codex).map(\.id), ["codex-1"])
        XCTAssertEqual(reader.sessions(for: .openClaw).count, 0)
    }

    func test_refresh_recordsError() async {
        let stub = StubCLISource()
        stub.failure = NSError(domain: "CLITest", code: 7, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let reader = CLIAgentChatReader(remote: stub)

        await reader.refresh()

        XCTAssertTrue(reader.sessions.isEmpty)
        XCTAssertEqual(reader.lastError, "boom")
    }

    func test_concurrentRefreshes_coalesce() async {
        let stub = StubCLISource()
        stub.allSessions = [makeSession(id: "a", agent: .codex, updated: Date())]
        let reader = CLIAgentChatReader(remote: stub)

        // Fire two refreshes back-to-back. Both should resolve but only
        // one underlying fetch should land.
        async let one: Void = reader.refresh()
        async let two: Void = reader.refresh()
        _ = await (one, two)

        XCTAssertEqual(reader.sessions.count, 1)
    }

    func test_session_lookupByID_returnsNilForUnknown() async {
        let stub = StubCLISource()
        let known = makeSession(id: "known", agent: .codex, updated: Date())
        stub.allSessions = [known]
        let reader = CLIAgentChatReader(remote: stub)
        await reader.refresh()

        XCTAssertEqual(reader.session(id: "known")?.id, "known")
        XCTAssertNil(reader.session(id: "missing"))
    }

    func test_mobileChatReducer_hidesUnclaimedQueuedState() throws {
        let snapshot = try makeMissionSnapshot(
            status: "pending",
            liveSummary: "Queued on your Mac.",
            events: [
                makeMissionEvent(sequence: 1, phase: "queued", kind: "status", message: "Chat queued.", source: "ios-chat", runtime: nil)
            ]
        )

        XCTAssertNil(CLIAgentMobileChatSnapshotReducer.visibleAssistantText(for: snapshot))
        XCTAssertFalse(CLIAgentMobileChatSnapshotReducer.isError(snapshot))
    }

    func test_mobileChatReducer_streamsLatestAssistantEvent() throws {
        let snapshot = try makeMissionSnapshot(
            status: "running",
            liveSummary: "Codex is composing.",
            events: [
                makeMissionEvent(sequence: 1, phase: "accepted", kind: "status", message: "Accepted."),
                makeMissionEvent(
                    sequence: 2,
                    phase: "assistant_response",
                    kind: "llm_response",
                    message: "Short assistant text",
                    fullMessage: "Full assistant text"
                )
            ]
        )

        XCTAssertEqual(
            CLIAgentMobileChatSnapshotReducer.visibleAssistantText(for: snapshot),
            "Full assistant text"
        )
    }

    func test_mobileChatReducer_completedPrefersFullFinalAnswerOverPreview() throws {
        let snapshot = try makeMissionSnapshot(
            status: "completed",
            resultPreview: "Preview only",
            events: [
                makeMissionEvent(
                    sequence: 3,
                    phase: "completed",
                    kind: "final_answer",
                    message: "Preview only",
                    fullMessage: "This is the full final answer from the Mac transcript."
                )
            ]
        )

        XCTAssertEqual(
            CLIAgentMobileChatSnapshotReducer.visibleAssistantText(for: snapshot),
            "This is the full final answer from the Mac transcript."
        )
    }

    func test_mobileChatReducer_failedUsesTerminalErrorMessage() throws {
        let snapshot = try makeMissionSnapshot(
            status: "failed",
            liveSummary: "Claude failed.",
            errorMessage: "Claude Code is not signed in."
        )

        XCTAssertEqual(
            CLIAgentMobileChatSnapshotReducer.visibleAssistantText(for: snapshot),
            "Error: Claude Code is not signed in."
        )
        XCTAssertTrue(CLIAgentMobileChatSnapshotReducer.isError(snapshot))
    }

    func test_mobileChatReducer_mapsToolEventsToToolCallPills() throws {
        let snapshot = try makeMissionSnapshot(
            status: "running",
            events: [
                makeMissionEvent(
                    sequence: 2,
                    phase: "tool_use",
                    kind: "tool_call",
                    title: "Shell",
                    message: "Running tests",
                    toolName: "exec_command"
                ),
                makeMissionEvent(
                    sequence: 3,
                    phase: "tool_result",
                    kind: "tool_result",
                    title: "Shell",
                    message: "Tests passed",
                    toolName: "exec_command"
                )
            ]
        )

        let tools = CLIAgentMobileChatSnapshotReducer.toolCalls(for: snapshot)
        XCTAssertEqual(tools.map(\.name), ["exec_command", "exec_command"])
        XCTAssertEqual(tools.map(\.status), ["running", "done"])
        XCTAssertEqual(tools.last?.detail, "Tests passed")
    }

    func test_mobileChatService_streamsRelayEventsIntoNativeThread() async throws {
        let local = CLITestMobileChatLocalStore()
        let history = MobileChatHistoryStore(local: local, cloud: nil)
        let relay = StubCLIRelayTransport(events: [
            CLIAgentRelayChatEvent(
                kind: .assistantSnapshot,
                text: "Working",
                modelID: "gpt-test",
                transcriptPieces: [
                    CLIAgentRelayTranscriptPiece(id: "tool-1", kind: .toolUse, value: "Read", detail: "File.swift")
                ]
            ),
            CLIAgentRelayChatEvent(
                kind: .completed,
                text: "Done from the Mac.",
                modelID: "gpt-test",
                transcriptPieces: [
                    CLIAgentRelayTranscriptPiece(id: "tool-1", kind: .toolUse, value: "Read", detail: "File.swift"),
                    CLIAgentRelayTranscriptPiece(id: "tool-2", kind: .toolResult, value: "Read", detail: "Read 20 lines.")
                ]
            )
        ])
        let service = CLIAgentMobileChatService(
            runtime: .codex,
            route: .new(runtime: .codex),
            historyStore: history,
            relayChatTransport: relay
        )

        await service.send(message: "Hi Codex")

        XCTAssertFalse(service.isSending)
        XCTAssertEqual(relay.requests.map(\.runtime), [.codex])
        let thread = try XCTUnwrap(history.thread(id: service.threadID))
        XCTAssertEqual(thread.runtime, AssistantRuntimeID.codex.rawValue)
        XCTAssertEqual(thread.messages.map(\.role), ["user", "assistant"])
        XCTAssertEqual(thread.messages.last?.text, "Done from the Mac.")
        XCTAssertEqual(thread.messages.last?.modelName, "gpt-test")
        XCTAssertEqual(thread.messages.last?.toolCalls.map(\.status), ["running", "done"])
    }

    // MARK: - Helpers

    private func makeSession(id: String, agent: CLIAgentRuntime, updated: Date) -> CLIAgentSessionRecord {
        CLIAgentSessionRecord(
            id: id,
            agent: agent,
            title: "title-\(id)",
            preview: "preview-\(id)",
            createdAt: updated,
            updatedAt: updated
        )
    }

    private func makeMissionSnapshot(
        status: String,
        liveSummary: String? = nil,
        resultPreview: String? = nil,
        errorMessage: String? = nil,
        events: [CLIAgentMissionEvent] = []
    ) throws -> CLIAgentMissionSnapshot {
        var data: [String: Any] = [
            "title": "Mobile chat",
            "status": status,
            "requestedRuntime": "codex"
        ]
        if let liveSummary { data["liveSummary"] = liveSummary }
        if let resultPreview { data["resultPreview"] = resultPreview }
        if let errorMessage { data["errorMessage"] = errorMessage }
        return try XCTUnwrap(CLIAgentMissionSnapshot(
            documentID: "request-1",
            data: data,
            eventOverride: events
        ))
    }

    private func makeMissionEvent(
        sequence: Int,
        phase: String,
        kind: String,
        title: String? = nil,
        message: String,
        fullMessage: String? = nil,
        source: String? = "mac",
        runtime: String? = "codex",
        toolName: String? = nil,
        isError: Bool = false
    ) -> CLIAgentMissionEvent {
        var data: [String: Any] = [
            "sequence": sequence,
            "timestamp": "2026-05-17T12:00:\(String(format: "%02d", sequence))Z",
            "phase": phase,
            "kind": kind,
            "message": message,
            "isError": isError
        ]
        if let title { data["title"] = title }
        if let fullMessage { data["fullMessage"] = fullMessage }
        if let source { data["source"] = source }
        if let runtime { data["runtime"] = runtime }
        if let toolName { data["toolName"] = toolName }
        return CLIAgentMissionEvent(data: data)!
    }
}

// MARK: - Stubs

@MainActor
final class StubCLISource: CLIAgentChatRemoteSource {
    var allSessions: [CLIAgentSessionRecord] = []
    var failure: Error?
    var isAvailable: Bool = true

    func fetchAll() async throws -> [CLIAgentSessionRecord] {
        if let failure { throw failure }
        return allSessions
    }

    func fetch(agent: CLIAgentRuntime) async throws -> [CLIAgentSessionRecord] {
        if let failure { throw failure }
        return allSessions.filter { $0.agent == agent }
    }
}

@MainActor
private final class StubCLIRelayTransport: CLIAgentRelayChatTransporting {
    struct Request: Equatable {
        let runtime: CLIAgentRuntime
        let threadID: String
        let prompt: String
        let title: String
        let parentSessionID: String?
        let resumeAction: String?
    }

    var events: [CLIAgentRelayChatEvent]
    var requests: [Request] = []

    init(events: [CLIAgentRelayChatEvent]) {
        self.events = events
    }

    func stream(
        runtime: CLIAgentRuntime,
        threadID: String,
        prompt: String,
        title: String,
        parentSessionID: String?,
        resumeAction: String?,
        onEvent: @escaping @MainActor (CLIAgentRelayChatEvent) -> Void
    ) async throws {
        requests.append(Request(
            runtime: runtime,
            threadID: threadID,
            prompt: prompt,
            title: title,
            parentSessionID: parentSessionID,
            resumeAction: resumeAction
        ))
        for event in events {
            onEvent(event)
        }
    }
}

private final class CLITestMobileChatLocalStore: MobileChatLocalStoring {
    private var snapshot = MobileChatHistorySnapshot()

    func setActivePartition(_ key: String) {}

    func load() throws -> MobileChatHistorySnapshot {
        snapshot
    }

    func save(_ snapshot: MobileChatHistorySnapshot) throws {
        self.snapshot = snapshot
    }
}
