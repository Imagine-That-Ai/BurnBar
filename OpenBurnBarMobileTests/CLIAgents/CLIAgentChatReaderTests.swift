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
