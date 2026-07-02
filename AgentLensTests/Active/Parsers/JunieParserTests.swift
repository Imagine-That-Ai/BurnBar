import XCTest
@testable import OpenBurnBar

final class JunieParserTests: XCTestCase {

    // MARK: - Helpers

    /// Builds `<root>/sessions/<sessionId>/…` mirroring Junie's documented
    /// on-disk layout (`~/.junie/sessions/index.jsonl` +
    /// `<sessionId>/events.jsonl` + `<sessionId>/state.json`).
    private func makeTempRoots() throws -> (tempRoot: URL, sessionsRoot: URL, supportRoot: URL) {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("openburnbar-junie-parser-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsRoot = tempRoot.appendingPathComponent("sessions", isDirectory: true)
        let supportRoot = tempRoot.appendingPathComponent("support", isDirectory: true)
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        return (tempRoot, sessionsRoot, supportRoot)
    }

    private func writeSession(
        sessionsRoot: URL,
        sessionId: String,
        events: String,
        state: String? = nil
    ) throws {
        let sessionDir = sessionsRoot.appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try events.write(
            to: sessionDir.appendingPathComponent("events.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        if let state {
            try state.write(
                to: sessionDir.appendingPathComponent("state.json"),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    // MARK: - Basics

    func testParseEmptyDirectory() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testParseMissingDirectoryReturnsEmpty() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-junie-missing-\(UUID().uuidString)", isDirectory: true)
        let parser = JunieParser(sessionsDirectoryOverride: missing)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testProviderReturnsCorrectValue() {
        let parser = JunieParser()
        XCTAssertEqual(parser.provider, .junie)
    }

    // MARK: - Explicit usage extraction

    func testExplicitUsageBucketsAndIndexProjectMapping() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-191559-1tv1"
        // Session index carries the projectPath field (Junie associates
        // sessions with projects by field, not directory nesting).
        try """
        {"sessionId":"\(sessionId)","projectPath":"/Users/alberto/Projects/demo","createdAt":1782951360319}
        """.write(
            to: sessionsRoot.appendingPathComponent("index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","timestamp":"2026-07-01T19:16:02.000Z","message":{"role":"user","content":"Fix the failing test"}}
            {"type":"message","timestamp":"2026-07-01T19:16:20.000Z","message":{"role":"assistant","content":"Done — the test passes now.","usage":{"input_tokens":1000,"output_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":2000}},"model":"claude-sonnet-4-5"}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .junie)
        XCTAssertEqual(usage.sessionId, sessionId)
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertEqual(usage.cacheCreationTokens, 50)
        XCTAssertEqual(usage.cacheReadTokens, 2000)
        XCTAssertEqual(usage.model, "claude-sonnet-4-5")
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        // Vendor-model pricing resolves through the global catalog even
        // though there is no "junie" provider block.
        XCTAssertGreaterThan(usage.costUSD, 0)
        // Project path from the index, abbreviated for display.
        XCTAssertTrue(usage.projectName.contains("Projects/demo"), "got \(usage.projectName)")
    }

    func testStateJSONUsageTotalsWin() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-201000-ab12"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","message":{"role":"user","content":"hello"}}
            """,
            state: """
            {"model":"gpt-5.5","projectPath":"/Users/alberto/Projects/other","usage":{"inputTokens":500,"outputTokens":250}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 500)
        XCTAssertEqual(usage.outputTokens, 250)
        XCTAssertEqual(usage.model, "gpt-5.5")
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        XCTAssertTrue(usage.projectName.contains("Projects/other"), "got \(usage.projectName)")
    }

    func testEnvelopeWrappedEventsAreUnwrapped() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-203000-cd34"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"event","event":{"message":{"role":"assistant","content":"wrapped reply"},"usage":{"input_tokens":300,"output_tokens":40},"model":"claude-haiku-4-5"}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.outputTokens, 40)
        XCTAssertEqual(usage.model, "claude-haiku-4-5")
        XCTAssertEqual(usage.provenanceConfidence, .exact)
    }

    // MARK: - Fallback estimation

    func testNoExplicitUsageFallsBackToCharacterEstimate() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-210000-ef56"
        let longAnswer = String(repeating: "The build is green and the tests pass. ", count: 40)
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","message":{"role":"user","content":"Summarize the repo state for me please."}}
            {"type":"message","message":{"role":"assistant","content":"\(longAnswer)"}}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertEqual(usage.provenanceConfidence, .lowConfidenceEstimate)
    }

    func testSessionWithNoContentProducesNoUsage() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: "session-260701-220000-gh78",
            events: """
            {"type":"lifecycle","phase":"onboarding"}
            """
        )

        let parser = JunieParser(
            appPaths: OpenBurnBarAppPaths(applicationSupportRoot: supportRoot),
            sessionsDirectoryOverride: sessionsRoot
        )
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
    }

    // MARK: - Conversations + caching

    func testConversationRecordAndDiskCacheRoundTrip() async throws {
        let (tempRoot, sessionsRoot, supportRoot) = try makeTempRoots()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let sessionId = "session-260701-230000-ij90"
        try writeSession(
            sessionsRoot: sessionsRoot,
            sessionId: sessionId,
            events: """
            {"type":"message","timestamp":"2026-07-01T23:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"Refactor the parser module"}]}}
            {"type":"message","timestamp":"2026-07-01T23:00:30.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Refactor complete."}],"usage":{"input_tokens":120,"output_tokens":30}}}
            """
        )

        let appPaths = OpenBurnBarAppPaths(applicationSupportRoot: supportRoot)
        let parser = JunieParser(
            appPaths: appPaths,
            sessionsDirectoryOverride: sessionsRoot
        )
        let first = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        let conversation = try XCTUnwrap(first.conversations.first)
        XCTAssertEqual(conversation.provider, .junie)
        XCTAssertEqual(conversation.sessionId, sessionId)
        XCTAssertTrue(conversation.inferredTaskTitle.contains("Refactor"))

        // Second parse must serve the identical usage from the disk cache.
        let second = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(second.usages.count, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 120)
        XCTAssertEqual(second.usages.first?.outputTokens, 30)
        XCTAssertEqual(second.conversations.count, 1)
    }
}
