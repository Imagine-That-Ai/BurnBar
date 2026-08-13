import Foundation
import XCTest
@testable import OpenBurnBarLogParsers

/// Idle usage ticks do not share indexing watermarks, so `ParserFileReadGate`
/// admits every session file every 60s. These parsers now resume unchanged
/// transcripts from a mtime+size disk cache (token totals only).
final class IdleUsageParserCacheTests: XCTestCase {
    private let fileManager = FileManager.default
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? fileManager.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    // MARK: - Cursor Agent

    func test_cursorAgent_skipsUnchangedNestedSessionOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("cursor-agent-cache")
        let session = root.appendingPathComponent("nested-session", isDirectory: true)
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        let transcript = session.appendingPathComponent("transcript.jsonl")
        try write(
            """
            {"role":"user","content":"Inspect the nested session.","timestamp":"2026-03-01T00:00:00Z"}
            {"role":"assistant","content":"The nested parser path is sound.","timestamp":"2026-03-01T00:00:10Z"}
            """,
            to: transcript
        )
        try write(
            #"{"current_model_id":"cursor-summary-model","project":"SummaryProject"}"#,
            to: session.appendingPathComponent("summary.json")
        )

        let parser = CursorAgentParser(logDirectoryOverride: root.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.model, "cursor-summary-model")
        XCTAssertEqual(firstUsage.projectName, "SummaryProject")
        XCTAssertGreaterThan(firstUsage.inputTokens, 0)
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, firstUsage.inputTokens)
        XCTAssertEqual(second.usages.first?.outputTokens, firstUsage.outputTokens)
        XCTAssertEqual(second.usages.first?.startTime, firstUsage.startTime)
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)
        XCTAssertEqual(second.usages.first?.model, firstUsage.model)

        let existing = try String(contentsOf: transcript, encoding: .utf8)
        try (existing + "\n{\"role\":\"assistant\",\"content\":\"More.\",\"timestamp\":\"2026-03-01T00:00:20Z\"}\n")
            .write(to: transcript, atomically: true, encoding: .utf8)

        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(third.usages.first?.outputTokens), firstUsage.outputTokens)
    }

    func test_cursorAgent_watermarkSkipDoesNotDropUsageCache() async throws {
        try await assertWatermarkKeepsCache(
            parser: CursorAgentParser(logDirectoryOverride: try writeCursorFlatSession().path),
            expectedInput: nil
        )
    }

    // MARK: - Cline

    func test_cline_skipsUnchangedTaskOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("cline-cache")
        let task = root.appendingPathComponent("cline-task-cache", isDirectory: true)
        try fileManager.createDirectory(at: task, withIntermediateDirectories: true)
        let history = task.appendingPathComponent("api_conversation_history.json")
        try write(
            """
            [
              {"role":"user","content":"Inspect the parser.","ts":1772323200000,"model":"claude-3-5-sonnet"},
              {"role":"assistant","content":[{"type":"text","text":"Covered."}],"ts":1772323260000,"model":"claude-3-5-sonnet","usage":{"input_tokens":321,"output_tokens":87,"cache_creation_input_tokens":43,"cache_read_input_tokens":29}}
            ]
            """,
            to: history
        )

        let parser = ClineFormatParser(provider: .cline, storagePaths: [root.path])
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.inputTokens, 321)
        XCTAssertEqual(firstUsage.outputTokens, 87)
        XCTAssertEqual(firstUsage.cacheCreationTokens, 43)
        XCTAssertEqual(firstUsage.cacheReadTokens, 29)
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 321)
        XCTAssertEqual(second.usages.first?.outputTokens, 87)
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)

        try write(
            """
            [
              {"role":"user","content":"Inspect the parser.","ts":1772323200000,"model":"claude-3-5-sonnet"},
              {"role":"assistant","content":[{"type":"text","text":"Covered."}],"ts":1772323260000,"model":"claude-3-5-sonnet","usage":{"input_tokens":400,"output_tokens":90}}
            ]
            """,
            to: history
        )

        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(third.usages.first?.inputTokens, 400)
        XCTAssertEqual(third.usages.first?.outputTokens, 90)
    }

    func test_cline_watermarkSkipDoesNotDropUsageCache() async throws {
        let root = try makeTemporaryDirectory("cline-watermark")
        let task = root.appendingPathComponent("task-w", isDirectory: true)
        try fileManager.createDirectory(at: task, withIntermediateDirectories: true)
        try write(
            """
            [{"role":"assistant","content":"Hi","ts":1772323200000,"model":"claude-3-5-sonnet","usage":{"input_tokens":8,"output_tokens":3}}]
            """,
            to: task.appendingPathComponent("api_conversation_history.json")
        )
        try await assertWatermarkKeepsCache(
            parser: ClineFormatParser(provider: .cline, storagePaths: [root.path]),
            expectedInput: 8
        )
    }

    // MARK: - Copilot

    func test_copilot_skipsUnchangedEventsOnUsageOnlySecondPass() async throws {
        let fixture = try CopilotCacheFixture()
        defer { fixture.remove() }
        let session = try fixture.session("session-cache")
        try write(
            """
            {"id":"u1","type":"assistant.usage","model":"gpt-5","usage":{"input_tokens":10,"output_tokens":4},"timestamp":"2026-07-20T10:00:01Z"}
            {"id":"u2","type":"assistant.usage","model":"gpt-5","usage":{"input_tokens":20,"output_tokens":6},"timestamp":"2026-07-20T10:00:02Z"}
            """,
            to: session.appendingPathComponent("events.jsonl")
        )

        let parser = fixture.parser()
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.inputTokens, 30)
        XCTAssertEqual(firstUsage.outputTokens, 10)
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 30)
        XCTAssertEqual(second.usages.first?.outputTokens, 10)
        XCTAssertEqual(second.usages.first?.startTime, firstUsage.startTime)
    }

    func test_copilot_processLogFallbackChangeMissesCache() async throws {
        let fixture = try CopilotCacheFixture()
        defer { fixture.remove() }
        let session = try fixture.session("legacy-session")
        try write(
            #"{"type":"user_message","role":"user","content":"legacy","timestamp":"2026-07-20T10:00:00Z"}"#,
            to: session.appendingPathComponent("events.jsonl")
        )
        let processLog = fixture.logs.appendingPathComponent("process-1.log")
        try "CompactionProcessor session=legacy-session context_tokens=100\nCompactionProcessor session=legacy-session context_tokens=160\n"
            .write(to: processLog, atomically: true, encoding: .utf8)

        let parser = fixture.parser()
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(first.usages.first?.inputTokens, 100)
        XCTAssertEqual(first.usages.first?.outputTokens, 60)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 100)

        try "CompactionProcessor session=legacy-session context_tokens=100\nCompactionProcessor session=legacy-session context_tokens=160\nCompactionProcessor session=legacy-session context_tokens=220\n"
            .write(to: processLog, atomically: true, encoding: .utf8)

        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(third.usages.first?.inputTokens, 160)
        XCTAssertEqual(third.usages.first?.outputTokens, 60)
    }

    func test_copilot_watermarkSkipDoesNotDropUsageCache() async throws {
        let fixture = try CopilotCacheFixture()
        defer { fixture.remove() }
        let session = try fixture.session("watermark")
        try write(
            #"{"id":"u1","type":"assistant.usage","model":"gpt-5","usage":{"input_tokens":8,"output_tokens":3},"timestamp":"2026-07-20T10:00:01Z"}"#,
            to: session.appendingPathComponent("events.jsonl")
        )
        try await assertWatermarkKeepsCache(parser: fixture.parser(), expectedInput: 8)
    }

    // MARK: - Antigravity

    func test_antigravity_skipsUnchangedTranscriptOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("antigravity-cache")
        try write(#"{"model":"Configured Cache Model"}"#, to: root.appendingPathComponent("settings.json"))
        let transcript = try writeAntigravityTranscript(
            root: root,
            sessionId: "session-cache",
            extraAssistant: nil
        )

        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.model, "Configured Cache Model")
        XCTAssertGreaterThan(firstUsage.inputTokens, 0)
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, firstUsage.inputTokens)
        XCTAssertEqual(second.usages.first?.outputTokens, firstUsage.outputTokens)
        XCTAssertEqual(second.usages.first?.model, firstUsage.model)
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)

        try write(
            """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Please inspect this project."}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Inspection complete."}
            {"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:02Z","content":"More."}
            """,
            to: transcript
        )

        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(third.usages.first?.outputTokens), firstUsage.outputTokens)
    }

    func test_antigravity_fallbackModelChangeMissesCache() async throws {
        let root = try makeTemporaryDirectory("antigravity-fallback")
        let settings = root.appendingPathComponent("settings.json")
        try write(#"{"model":"Model A"}"#, to: settings)
        _ = try writeAntigravityTranscript(root: root, sessionId: "session-fallback", extraAssistant: nil)

        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(first.usages.first?.model, "Model A")
        XCTAssertEqual(parser.lastSessionScanCount, 1)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.model, "Model A")

        try write(#"{"model":"Model B"}"#, to: settings)
        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(third.usages.first?.model, "Model B")
    }

    func test_antigravity_watermarkSkipDoesNotDropUsageCache() async throws {
        let root = try makeTemporaryDirectory("antigravity-watermark")
        _ = try writeAntigravityTranscript(root: root, sessionId: "session-w", extraAssistant: nil)
        try await assertWatermarkKeepsCache(
            parser: AntigravityParser(logDirectoryOverride: root.path),
            expectedInput: nil
        )
    }

    func test_antigravity_usageOnlyMatchesIndexedTotalsWithoutBodies() async throws {
        let root = try makeTemporaryDirectory("antigravity-bodies")
        _ = try writeAntigravityTranscript(root: root, sessionId: "session-bodies", extraAssistant: nil)
        let parser = AntigravityParser(logDirectoryOverride: root.path)
        let indexed = try await parser.parse()
        let usageOnly = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))

        XCTAssertEqual(indexed.usages.count, 1)
        XCTAssertEqual(indexed.conversations.count, 1)
        XCTAssertEqual(usageOnly.usages.count, 1)
        XCTAssertTrue(usageOnly.conversations.isEmpty)
        XCTAssertEqual(indexed.usages.first?.inputTokens, usageOnly.usages.first?.inputTokens)
        XCTAssertEqual(indexed.usages.first?.outputTokens, usageOnly.usages.first?.outputTokens)
        XCTAssertTrue(indexed.conversations.first?.fullText.contains("Please inspect this project.") == true)
    }

    // MARK: - Goose

    func test_goose_skipsUnchangedJSONLOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("goose-cache")
        let sessionURL = root.appendingPathComponent("goose-legacy-session.jsonl")
        try write(
            """
            {"timestamp":"2026-06-01T10:00:00Z","model":"anthropic/claude-sonnet-4","message":{"role":"user","content":"Review the legacy Goose session."}}
            {"timestamp":"2026-06-01T10:01:30Z","model":"anthropic/claude-sonnet-4","message":{"role":"assistant","content":"The legacy Goose session is valid.","usage":{"input_tokens":210,"output_tokens":55,"cache_creation_input_tokens":34,"cache_read_input_tokens":13}}}
            """,
            to: sessionURL
        )

        let parser = GooseParser(sessionDirectoryOverride: root.path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.inputTokens, 210)
        XCTAssertEqual(firstUsage.outputTokens, 55)
        XCTAssertEqual(firstUsage.cacheCreationTokens, 34)
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 210)
        XCTAssertEqual(second.usages.first?.outputTokens, 55)
        XCTAssertEqual(second.usages.first?.startTime, firstUsage.startTime)
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)

        let existing = try String(contentsOf: sessionURL, encoding: .utf8)
        try (existing + "\n{\"timestamp\":\"2026-06-01T10:02:00Z\",\"model\":\"anthropic/claude-sonnet-4\",\"message\":{\"role\":\"assistant\",\"content\":\"More.\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}\n")
            .write(to: sessionURL, atomically: true, encoding: .utf8)

        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(third.usages.first?.inputTokens, 220)
        XCTAssertEqual(third.usages.first?.outputTokens, 60)
    }

    func test_goose_watermarkSkipDoesNotDropUsageCache() async throws {
        let root = try makeTemporaryDirectory("goose-watermark")
        try write(
            """
            {"timestamp":"2026-06-01T10:00:00Z","model":"anthropic/claude-sonnet-4","message":{"role":"assistant","content":"Hi","usage":{"input_tokens":8,"output_tokens":3}}}
            """,
            to: root.appendingPathComponent("goose-w.jsonl")
        )
        try await assertWatermarkKeepsCache(
            parser: GooseParser(sessionDirectoryOverride: root.path),
            expectedInput: 8
        )
    }

    // MARK: - Helpers

    private func assertWatermarkKeepsCache(
        parser: some LogParser,
        expectedInput: Int?
    ) async throws {
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        let firstInput = try XCTUnwrap(first.usages.first?.inputTokens)
        if let expectedInput {
            XCTAssertEqual(firstInput, expectedInput)
        }

        let deferred = try await parser.parse(options: LogParseOptions(
            includeConversationBodies: false,
            minimumFileModificationDate: Date.distantFuture
        ))
        XCTAssertTrue(deferred.usages.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(second.usages.first?.inputTokens, firstInput)
        XCTAssertEqual(second.usages.first?.outputTokens, first.usages.first?.outputTokens)

        if let cursor = parser as? CursorAgentParser {
            XCTAssertEqual(cursor.lastSessionScanCount, 0)
            XCTAssertEqual(cursor.lastSessionCacheHitCount, 1)
        } else if let cline = parser as? ClineFormatParser {
            XCTAssertEqual(cline.lastSessionScanCount, 0)
            XCTAssertEqual(cline.lastSessionCacheHitCount, 1)
        } else if let copilot = parser as? CopilotParser {
            XCTAssertEqual(copilot.lastSessionScanCount, 0)
            XCTAssertEqual(copilot.lastSessionCacheHitCount, 1)
        } else if let antigravity = parser as? AntigravityParser {
            XCTAssertEqual(antigravity.lastSessionScanCount, 0)
            XCTAssertEqual(antigravity.lastSessionCacheHitCount, 1)
        } else if let goose = parser as? GooseParser {
            XCTAssertEqual(goose.lastSessionScanCount, 0)
            XCTAssertEqual(goose.lastSessionCacheHitCount, 1)
        } else {
            XCTFail("unexpected parser type")
        }
    }

    private func writeCursorFlatSession() throws -> URL {
        let root = try makeTemporaryDirectory("cursor-agent-flat-cache")
        try write(
            """
            {"role":"user","content":"Hi","timestamp":"2026-03-01T00:00:00Z"}
            {"role":"assistant","content":"Hello","timestamp":"2026-03-01T00:00:05Z"}
            """,
            to: root.appendingPathComponent("flat-session.jsonl")
        )
        return root
    }

    @discardableResult
    private func writeAntigravityTranscript(
        root: URL,
        sessionId: String,
        extraAssistant: String?
    ) throws -> URL {
        let transcript = root
            .appendingPathComponent("brain/\(sessionId)/.system_generated/logs", isDirectory: true)
            .appendingPathComponent("transcript_full.jsonl")
        var body = """
        {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-05-27T06:00:00Z","content":"Please inspect this project."}
        {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-05-27T06:00:01Z","content":"Inspection complete."}
        """
        if let extraAssistant {
            body += "\n\(extraAssistant)"
        }
        try write(body, to: transcript)
        return transcript
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ string: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url, options: .atomic)
    }
}

private final class CopilotCacheFixture {
    let root: URL
    let sessions: URL
    let logs: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("copilot-cache-\(UUID().uuidString)", isDirectory: true)
        sessions = root.appendingPathComponent("session-state", isDirectory: true)
        logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    }

    func session(_ id: String) throws -> URL {
        let url = sessions.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func parser() -> CopilotParser {
        CopilotParser(sessionStateURL: sessions, logsURL: logs)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
