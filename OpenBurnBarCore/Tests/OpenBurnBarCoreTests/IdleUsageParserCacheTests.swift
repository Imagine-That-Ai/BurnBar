import Foundation
import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

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

    func test_macSemanticsCacheURLsAreDistinctFromCoreParserCaches() {
        let paths = OpenBurnBarAppPaths(
            applicationSupportRoot: URL(fileURLWithPath: "/tmp/obb-mac-semantics-cache-urls")
        )
        XCTAssertNotEqual(paths.macCopilotParserCacheURL, paths.copilotParserCacheURL)
        XCTAssertNotEqual(paths.macAiderParserCacheURL, paths.aiderParserCacheURL)
        XCTAssertNotEqual(paths.macCursorParserCacheURL, paths.cursorParserCacheURL)
        XCTAssertNotEqual(paths.macOpenCodeParserCacheURL, paths.openCodeParserCacheURL)
        XCTAssertNotEqual(paths.macPiAgentParserCacheURL, paths.piAgentParserCacheURL)
        XCTAssertNotEqual(paths.macOpenClawParserCacheURL, paths.openClawParserCacheURL)
        XCTAssertNotEqual(paths.macJunieParserCacheURL, paths.junieParserCacheURL)
        XCTAssertEqual(paths.macSemanticsParserCacheURLs.count, 7)
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
        XCTAssertTrue(try XCTUnwrap(indexed.conversations.first?.fullText).contains("Please inspect this project."))
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
        } else if let warp = parser as? WarpParser {
            XCTAssertEqual(warp.lastSessionScanCount, 0)
            XCTAssertEqual(warp.lastSessionCacheHitCount, 1)
        } else if let prime = parser as? PrimeAgentParser {
            XCTAssertEqual(prime.lastSessionScanCount, 0)
            XCTAssertEqual(prime.lastSessionCacheHitCount, 1)
        } else if let muse = parser as? MuseParser {
            XCTAssertEqual(muse.lastSessionScanCount, 0)
            XCTAssertEqual(muse.lastSessionCacheHitCount, 1)
        } else if let kimi = parser as? KimiParser {
            XCTAssertEqual(kimi.lastSessionScanCount, 0)
            XCTAssertEqual(kimi.lastSessionCacheHitCount, 1)
        } else if let windsurf = parser as? WindsurfParser {
            XCTAssertEqual(windsurf.lastSessionScanCount, 0)
            XCTAssertEqual(windsurf.lastSessionCacheHitCount, 1)
        } else if let hermes = parser as? HermesParser {
            XCTAssertEqual(hermes.lastSessionScanCount, 0)
            XCTAssertEqual(hermes.lastSessionCacheHitCount, 1)
        } else if let forge = parser as? ForgeDevParser {
            XCTAssertEqual(forge.lastSessionScanCount, 0)
            XCTAssertEqual(forge.lastSessionCacheHitCount, 1)
        } else if let augment = parser as? AugmentParser {
            XCTAssertEqual(augment.lastSessionScanCount, 0)
            XCTAssertEqual(augment.lastSessionCacheHitCount, 1)
        } else if let aider = parser as? AiderParser {
            XCTAssertEqual(aider.lastSessionScanCount, 0)
            XCTAssertEqual(aider.lastSessionCacheHitCount, 1)
        } else if let pi = parser as? PiAgentParser {
            XCTAssertEqual(pi.lastSessionScanCount, 0)
            XCTAssertEqual(pi.lastSessionCacheHitCount, 1)
        } else if let ollama = parser as? OllamaParser {
            XCTAssertEqual(ollama.lastSessionScanCount, 0)
            XCTAssertEqual(ollama.lastSessionCacheHitCount, 1)
        } else if let junie = parser as? JunieParser {
            XCTAssertEqual(junie.lastSessionScanCount, 0)
            XCTAssertEqual(junie.lastSessionCacheHitCount, 1)
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

    private struct OpenCodeMessageSeed {
        let id: String
        let role: String
        let tokens: (input: Int, output: Int)?
        let partText: String
    }

    private struct OpenCodeSessionSeed {
        let id: String
        let messages: [OpenCodeMessageSeed]
    }

    private func makeOpenCodeDatabase(sessions: [OpenCodeSessionSeed]) throws -> URL {
        let root = try makeTemporaryDirectory("opencode-part")
        let path = root.appendingPathComponent("opencode.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        try db.execute("CREATE TABLE session (id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER)")
        try db.execute("CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT, time_created INTEGER)")
        try db.execute("CREATE TABLE part (messageID TEXT, data TEXT)")
        var created = 1_750_000_000
        for session in sessions {
            try db.execute(
                "INSERT INTO session VALUES (?, ?, ?, ?)",
                arguments: [
                    .text(session.id),
                    .text(#"{"title":"Demo","directory":"/tmp/demo","time":{"created":\#(created),"updated":\#(created + 2)}}"#),
                    .int(Int64(created)),
                    .int(Int64(created + 2))
                ]
            )
            for message in session.messages {
                let tokenJSON: String
                if let tokens = message.tokens {
                    tokenJSON = #""tokens":{"input":\#(tokens.input),"output":\#(tokens.output)},"#
                } else {
                    tokenJSON = ""
                }
                try db.execute(
                    "INSERT INTO message VALUES (?, ?, ?, ?)",
                    arguments: [
                        .text(message.id),
                        .text(session.id),
                        .text("{\"role\":\"\(message.role)\",\"model\":\"gpt-4o\",\(tokenJSON)\"cost\":0.02,\"time\":{\"created\":\(created + 1)}}"),
                        .int(Int64(created + 1))
                    ]
                )
                try db.execute(
                    "INSERT INTO part VALUES (?, ?)",
                    arguments: [
                        .text(message.id),
                        .text("{\"type\":\"text\",\"text\":\"\(message.partText)\"}")
                    ]
                )
                created += 10
            }
        }
        db.close()
        return path
    }

    private func makeOpenCodeJSONOnlyPartDatabase(
        decoyPartCount: Int
    ) throws -> URL {
        let root = try makeTemporaryDirectory("opencode-json-only-part")
        let path = root.appendingPathComponent("opencode.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        try db.execute("CREATE TABLE session (id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER)")
        try db.execute("CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT, time_created INTEGER)")
        try db.execute("CREATE TABLE part (data TEXT)")
        try db.execute(
            "INSERT INTO session VALUES (?, ?, ?, ?)",
            arguments: [
                .text("session-explicit"),
                .text(#"{"title":"Demo","directory":"/tmp/demo","time":{"created":1750000000,"updated":1750000002}}"#),
                .int(1_750_000_000),
                .int(1_750_000_002)
            ]
        )
        try db.execute(
            "INSERT INTO session VALUES (?, ?, ?, ?)",
            arguments: [
                .text("session-heuristic"),
                .text(#"{"title":"Heuristic","directory":"/tmp/demo","time":{"created":1750000010,"updated":1750000012}}"#),
                .int(1_750_000_010),
                .int(1_750_000_012)
            ]
        )
        try db.execute(
            "INSERT INTO message VALUES (?, ?, ?, ?)",
            arguments: [
                .text("message-explicit"),
                .text("session-explicit"),
                .text(#"{"role":"assistant","model":"gpt-4o","tokens":{"input":21,"output":9},"cost":0.02,"time":{"created":1750000001}}"#),
                .int(1_750_000_001)
            ]
        )
        try db.execute(
            "INSERT INTO message VALUES (?, ?, ?, ?)",
            arguments: [
                .text("message-h-user"),
                .text("session-heuristic"),
                .text(#"{"role":"user","model":"gpt-4o","cost":0.02,"time":{"created":1750000011}}"#),
                .int(1_750_000_011)
            ]
        )
        try db.execute(
            "INSERT INTO message VALUES (?, ?, ?, ?)",
            arguments: [
                .text("message-h-assistant"),
                .text("session-heuristic"),
                .text(#"{"role":"assistant","model":"gpt-4o","cost":0.02,"time":{"created":1750000012}}"#),
                .int(1_750_000_012)
            ]
        )
        try db.execute(
            "INSERT INTO part VALUES (?)",
            arguments: [.text(#"{"type":"text","text":"explicit body","messageID":"message-explicit"}"#)]
        )
        try db.execute(
            "INSERT INTO part VALUES (?)",
            arguments: [.text(#"{"type":"text","text":"hello from the user","messageID":"message-h-user"}"#)]
        )
        try db.execute(
            "INSERT INTO part VALUES (?)",
            arguments: [.text(#"{"type":"text","text":"hello from the assistant","messageID":"message-h-assistant"}"#)]
        )
        for index in 0..<decoyPartCount {
            try db.execute(
                "INSERT INTO part VALUES (?)",
                arguments: [
                    .text("{\"type\":\"text\",\"text\":\"decoy \(index)\",\"messageID\":\"decoy-\(index)\"}")
                ]
            )
        }
        db.close()
        return path
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

    // MARK: - Warp

    func test_warp_skipsUnchangedNetworkLogOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("warp-cache")
        try write(warpExactBodyLog(), to: root.appendingPathComponent("warp_network.log"))
        let parser = WarpParser(logDirectory: root)
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.inputTokens, 120)
        XCTAssertEqual(firstUsage.outputTokens, 45)
        XCTAssertEqual(firstUsage.sessionId, "warp-session-1")
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 120)
        XCTAssertEqual(second.usages.first?.sessionId, "warp-session-1")
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)

        let existing = try String(contentsOf: root.appendingPathComponent("warp_network.log"), encoding: .utf8)
        try (existing + "\nBody { \"event\": \"AgentResponse.Completed\", \"originalTimestamp\": \"2026-05-01T12:00:01Z\", \"properties\": { \"payload\": { \"session_id\": \"warp-session-2\", \"model\": \"claude-sonnet-4\", \"usage\": { \"input_tokens\": 3, \"output_tokens\": 1 } } } }\n")
            .write(to: root.appendingPathComponent("warp_network.log"), atomically: true, encoding: .utf8)

        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionAppendResumeCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        XCTAssertEqual(third.usages.count, 2)
        XCTAssertEqual(Set(third.usages.map(\.sessionId)), ["warp-session-1", "warp-session-2"])

        let fourth = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionAppendResumeCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(fourth.usages.count, 2)
    }

    func test_warp_rewrittenHeadDoesNotResumeAppend() async throws {
        let root = try makeTemporaryDirectory("warp-rewrite")
        try write(warpExactBodyLog(), to: root.appendingPathComponent("warp_network.log"))
        let parser = WarpParser(logDirectory: root)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        _ = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)

        try write(
            """
            [rewritten-head]
            Body { "event": "AgentResponse.Completed", "originalTimestamp": "2026-05-01T12:00:00Z", "properties": { "payload": { "session_id": "warp-rewritten", "model": "claude-sonnet-4", "usage": { "input_tokens": 9, "output_tokens": 2 } } } }
            """,
            to: root.appendingPathComponent("warp_network.log")
        )
        let rewritten = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionAppendResumeCount, 0)
        XCTAssertEqual(rewritten.usages.count, 1)
        XCTAssertEqual(rewritten.usages.first?.sessionId, "warp-rewritten")
        XCTAssertEqual(rewritten.usages.first?.inputTokens, 9)
    }

    func test_warp_watermarkSkipDoesNotDropUsageCache() async throws {
        let root = try makeTemporaryDirectory("warp-watermark")
        try write(warpExactBodyLog(), to: root.appendingPathComponent("warp_network.log"))
        try await assertWatermarkKeepsCache(
            parser: WarpParser(logDirectory: root),
            expectedInput: 120
        )
    }

    // MARK: - Prime / Muse / Kimi / Windsurf / Hermes / Forge / Augment

    func test_prime_skipsUnchangedJSONLOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("prime-cache")
        try write(
            """
            {"type":"session","id":"sess-cache","cwd":"/tmp/demo","timestamp":"2026-08-01T12:00:00Z"}
            {"type":"message","timestamp":"2026-08-01T12:00:01Z","message":{"role":"assistant","model":"muse-spark-1.2","provider":"prime","content":[{"type":"text","text":"hello"}],"usage":{"input":21,"output":7,"cacheRead":2,"cacheWrite":1,"cost":{"total":0.02}}}}
            """,
            to: root.appendingPathComponent("session-cache.jsonl")
        )
        let parser = PrimeAgentParser(logDirectoryOverride: root.path)
        try await assertUsageOnlySecondPassHit(
            parser: parser,
            expectedInput: 21,
            expectedOutput: 7
        )
        let existing = try String(contentsOf: root.appendingPathComponent("session-cache.jsonl"), encoding: .utf8)
        try (existing + "\n{\"type\":\"message\",\"timestamp\":\"2026-08-01T12:00:02Z\",\"message\":{\"role\":\"assistant\",\"model\":\"muse-spark-1.2\",\"usage\":{\"input\":4,\"output\":1}}}\n")
            .write(to: root.appendingPathComponent("session-cache.jsonl"), atomically: true, encoding: .utf8)
        let grown = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(grown.usages.first?.inputTokens, 25)
    }

    func test_muse_skipsUnchangedSessionOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("muse-cache")
        try write(
            #"{"stream":{"id":"sess-muse"},"recorded_at":1772323200000000,"payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_completed","model":"muse-spark-1.2-contributor","usage":{"input_tokens":40,"output_tokens":9,"cache_read_tokens":2}}}}"#,
            to: root.appendingPathComponent("sess-muse/session.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: MuseParser(logDirectoryOverride: root.path),
            expectedInput: 40,
            expectedOutput: 9
        )
    }

    func test_kimi_skipsUnchangedWireSessionOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("kimi-cache")
        let session = root.appendingPathComponent("workspace/session-1", isDirectory: true)
        try write(
            """
            {"role":"user","content":"Test","created_at":"2026-05-04T08:00:00Z"}
            {"role":"assistant","content":"Done","created_at":"2026-05-04T08:00:01Z"}
            """,
            to: session.appendingPathComponent("context.jsonl")
        )
        try write(
            #"{"message":{"type":"StatusUpdate","payload":{"message_id":"msg-1","token_usage":{"input_other":100,"output":25,"input_cache_read":10,"input_cache_creation":5}}}}"#,
            to: session.appendingPathComponent("wire.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: KimiParser(logDirectoryOverride: root.path),
            expectedInput: 100,
            expectedOutput: 25
        )
    }

    func test_windsurf_skipsUnchangedProtobufOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("windsurf-cache")
        let cascade = root.appendingPathComponent("cascade", isDirectory: true)
        let globalStorage = root.appendingPathComponent("globalStorage", isDirectory: true)
        try write(String(repeating: "x", count: 512), to: cascade.appendingPathComponent("session-1.pb"))
        let parser = WindsurfParser(
            cascadeDirectoryOverride: cascade.path,
            globalStorageOverride: globalStorage.path
        )
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        let firstUsage = try XCTUnwrap(first.usages.first)
        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, firstUsage.inputTokens)
        XCTAssertEqual(second.usages.first?.model, firstUsage.model)

        try write(String(repeating: "y", count: 1024), to: cascade.appendingPathComponent("session-1.pb"))
        let third = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(third.usages.first?.inputTokens), firstUsage.inputTokens)
    }

    func test_hermes_skipsUnchangedGatewayAndLegacyOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("hermes-cache")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try write(
            #"{"gateway":{"session_id":"gateway-1","created_at":"2026-05-06T10:00:00Z","updated_at":"2026-05-06T10:01:00Z","model":"hermes-model","platform":"gateway","input_tokens":50,"output_tokens":12}}"#,
            to: sessions.appendingPathComponent("sessions.json")
        )
        try write(
            """
            {"role":"user","content":"Gateway request","timestamp":"2026-05-06T10:00:00Z"}
            {"role":"assistant","content":"Gateway response","timestamp":"2026-05-06T10:01:00Z","model":"hermes-model","usage":{"input_tokens":20,"output_tokens":5}}
            """,
            to: sessions.appendingPathComponent("gateway-1.jsonl")
        )
        try write(
            """
            {"role":"user","content":"Legacy request","timestamp":"2026-05-06T11:00:00Z"}
            {"role":"assistant","content":"Legacy response","timestamp":"2026-05-06T11:01:00Z","model":"hermes-model","usage":{"input_tokens":8,"output_tokens":3}}
            """,
            to: sessions.appendingPathComponent("legacy-1.jsonl")
        )
        let parser = HermesParser(fileManager: fileManager, hermesRootURL: root)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(first.usages.count, 2)
        XCTAssertGreaterThan(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(second.usages.count, 2)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertGreaterThan(parser.lastSessionCacheHitCount, 0)
        XCTAssertEqual(
            Set(second.usages.map(\.inputTokens)),
            Set(first.usages.map(\.inputTokens))
        )
    }

    func test_forge_skipsUnchangedJSONLOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("forge-cache")
        try write(
            #"{"role":"assistant","model":"forge-model","content":"hi","timestamp":"2026-05-01T00:00:00Z","usage":{"input_tokens":10,"output_tokens":4}}"#,
            to: root.appendingPathComponent("forge-session.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: ForgeDevParser(logDirectoryOverride: root.path),
            expectedInput: 10,
            expectedOutput: 4
        )
    }

    func test_forge_skipsChildDatabaseProbeWhenHomeChildMtimeUnchanged() async throws {
        let home = try makeTemporaryDirectory("forge-home-probe")
        let project = home.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
        let db = project.appendingPathComponent(".forge.db")
        try Data("not-a-real-sqlite".utf8).write(to: db)
        let parser = ForgeDevParser(homeDirectoryURL: home)

        _ = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(parser.lastHomeChildProbeHitCount, 0)
        XCTAssertEqual(parser.lastHomeListingHitCount, 0)

        _ = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertGreaterThanOrEqual(parser.lastHomeChildProbeHitCount, 1)
        XCTAssertGreaterThanOrEqual(parser.lastHomeListingHitCount, 1)

        let extra = home.appendingPathComponent("other", isDirectory: true)
        try fileManager.createDirectory(at: extra, withIntermediateDirectories: true)
        _ = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertGreaterThanOrEqual(
            parser.lastHomeListingHitCount,
            1,
            "A new home child should change ~ mtime and force a readdir"
        )
        XCTAssertGreaterThanOrEqual(
            parser.lastHomeChildProbeHitCount,
            1,
            "Unchanged project/ still skips the .forge.db fileExists probe"
        )
    }

    func test_augment_skipsUnchangedJSONOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("augment-cache")
        try write(
            #"{"role":"assistant","model":"gpt-4","content":"ok","timestamp":"2026-05-01T00:00:00Z","usage":{"input_tokens":8,"output_tokens":3}}"#,
            to: root.appendingPathComponent("session.json")
        )
        try await assertUsageOnlySecondPassHit(
            parser: AugmentParser(logDirectoryOverride: root.path),
            expectedInput: 8,
            expectedOutput: 3
        )
    }

    func test_aider_skipsUnchangedAnalyticsOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("aider-cache")
        try write(
            """
            {"event":"launched","time":100,"properties":{"main_model":"claude-3-7-sonnet"}}
            {"event":"message_send","time":110,"properties":{"prompt_tokens":120,"completion_tokens":30,"cost":0.12}}
            {"event":"exit","time":120}
            """,
            to: root.appendingPathComponent("analytics.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: AiderParser(rootOverride: root),
            expectedInput: 120,
            expectedOutput: 30
        )
    }

    func test_pi_skipsUnchangedJSONLOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("pi-cache")
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"gpt-4o","role":"user","content":"hello"}
            {"timestamp":"2026-07-01T00:00:01Z","model":"gpt-4o","role":"assistant","content":"world","usage":{"input_tokens":11,"output_tokens":7}}
            """,
            to: root.appendingPathComponent("pi-session.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: PiAgentParser(sessionsOverride: root),
            expectedInput: 11,
            expectedOutput: 7
        )
    }

    func test_ollama_skipsUnchangedServerLogOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("ollama-cache")
        try write(
            #"{"time":"2026-07-01T00:00:00Z","model":"llama3.2","prompt_eval_count":44,"eval_count":9}"#,
            to: root.appendingPathComponent("server.log")
        )
        try await assertUsageOnlySecondPassHit(
            parser: OllamaParser(logsOverride: root),
            expectedInput: 44,
            expectedOutput: 9
        )
    }

    func test_junie_skipsUnchangedEventsOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("junie-cache")
        let session = root.appendingPathComponent("session-cache", isDirectory: true)
        try write(
            #"{"timestamp":"2026-07-01T00:00:00Z","event":{"message":{"role":"assistant","content":"done","usage":{"input_tokens":15,"output_tokens":6}}}}"#,
            to: session.appendingPathComponent("events.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: JunieParser(sessionsOverride: root),
            expectedInput: 15,
            expectedOutput: 6
        )
    }

    func test_cursorSQLite_skipsUnchangedTrackingDbOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("cursor-sqlite-cache")
        let path = root.appendingPathComponent("ai-code-tracking.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        try db.execute("CREATE TABLE ai_code_hashes (conversationId TEXT, model TEXT, createdAt INTEGER)")
        try db.execute(
            "INSERT INTO ai_code_hashes VALUES (?, ?, ?)",
            arguments: [.text("conversation-1"), .text("gpt-4o"), .int(1_750_000_000)]
        )
        db.close()
        try await assertUsageOnlySecondPassHit(
            parser: CursorParser(databaseOverride: path),
            expectedInput: 500,
            expectedOutput: 150
        )
    }

    func test_openCode_skipsUnchangedSQLiteOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("opencode-cache")
        let path = root.appendingPathComponent("opencode.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        try db.execute("CREATE TABLE session (id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER)")
        try db.execute("CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT, time_created INTEGER)")
        try db.execute("CREATE TABLE part (messageID TEXT, data TEXT)")
        try db.execute(
            "INSERT INTO session VALUES (?, ?, ?, ?)",
            arguments: [
                .text("session-1"),
                .text(#"{"title":"Demo","directory":"/tmp/demo","time":{"created":1750000000,"updated":1750000002}}"#),
                .int(1_750_000_000),
                .int(1_750_000_002)
            ]
        )
        try db.execute(
            "INSERT INTO message VALUES (?, ?, ?, ?)",
            arguments: [
                .text("message-1"),
                .text("session-1"),
                .text(#"{"role":"assistant","model":"gpt-4o","tokens":{"input":21,"output":9},"cost":0.02,"time":{"created":1750000001}}"#),
                .int(1_750_000_001)
            ]
        )
        try db.execute(
            "INSERT INTO part VALUES (?, ?)",
            arguments: [.text("message-1"), .text(#"{"type":"text","text":"done"}"#)]
        )
        db.close()
        try await assertUsageOnlySecondPassHit(
            parser: OpenCodeParser(databaseOverride: path),
            expectedInput: 21,
            expectedOutput: 9
        )
    }

    func test_openCode_usageOnlySkipsPartWhenEverySessionHasExplicitTokens() async throws {
        let path = try makeOpenCodeDatabase(
            sessions: [
                OpenCodeSessionSeed(
                    id: "session-explicit",
                    messages: [
                        OpenCodeMessageSeed(
                            id: "message-explicit",
                            role: "assistant",
                            tokens: (21, 9),
                            partText: "explicit body that usage-only must not read"
                        )
                    ]
                )
            ]
        )
        let parser = OpenCodeParser(databaseOverride: path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastPartReadCount, 0)
        XCTAssertEqual(first.usages.first?.inputTokens, 21)
        XCTAssertEqual(first.usages.first?.outputTokens, 9)
        XCTAssertEqual(first.usages.first?.provenanceConfidence, .exact)
    }

    func test_openCode_usageOnlyReadsPartOnlyForSessionsMissingExplicitTokens() async throws {
        let path = try makeOpenCodeDatabase(
            sessions: [
                OpenCodeSessionSeed(
                    id: "session-explicit",
                    messages: [
                        OpenCodeMessageSeed(
                            id: "message-explicit",
                            role: "assistant",
                            tokens: (21, 9),
                            partText: "explicit body"
                        )
                    ]
                ),
                OpenCodeSessionSeed(
                    id: "session-heuristic",
                    messages: [
                        OpenCodeMessageSeed(
                            id: "message-h-user",
                            role: "user",
                            tokens: nil,
                            partText: "hello from the user"
                        ),
                        OpenCodeMessageSeed(
                            id: "message-h-assistant",
                            role: "assistant",
                            tokens: nil,
                            partText: "hello from the assistant"
                        )
                    ]
                )
            ]
        )
        let parser = OpenCodeParser(databaseOverride: path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastPartReadCount, 2)
        let bySession = Dictionary(uniqueKeysWithValues: first.usages.map { ($0.sessionId, $0) })
        XCTAssertEqual(bySession["session-explicit"]?.inputTokens, 21)
        XCTAssertEqual(bySession["session-explicit"]?.provenanceConfidence, .exact)
        let heuristic = try XCTUnwrap(bySession["session-heuristic"])
        XCTAssertGreaterThan(heuristic.inputTokens, 0)
        XCTAssertEqual(heuristic.provenanceConfidence, .lowConfidenceEstimate)

        let bodies = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(parser.lastPartReadCount, 3)
        XCTAssertEqual(bodies.conversations.count, 2)
    }

    func test_openCodePartQuery_rejectsUnknownIdentifiers() throws {
        XCTAssertNil(OpenCodePartQuery.jsonExtractWhereSQL(payloadColumn: "blob", placeholderCount: 1))
        XCTAssertNil(OpenCodePartQuery.idColumnWhereSQL(idColumn: "id", placeholderCount: 1))
        XCTAssertNil(OpenCodePartQuery.jsonExtractWhereSQL(payloadColumn: "data", placeholderCount: 0))
        let clause = try XCTUnwrap(OpenCodePartQuery.jsonExtractWhereSQL(payloadColumn: "data", placeholderCount: 2))
        XCTAssertTrue(clause.contains("json_extract(data, '$.messageID')"))
        XCTAssertTrue(clause.contains("IN (?,?)"))
        XCTAssertFalse(clause.contains("FROM part"))
    }

    func test_openCode_usageOnlyJSONOnlyPartBoundsByJsonExtract() async throws {
        let path = try makeOpenCodeJSONOnlyPartDatabase(decoyPartCount: 20)
        let parser = OpenCodeParser(databaseOverride: path)
        let usageOnly = LogParseOptions.usageAccounting()
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(
            parser.lastPartReadCount,
            2,
            "JSON-only part must json_extract the heuristic ids, not SELECT the whole table"
        )
        let heuristic = try XCTUnwrap(first.usages.first { $0.sessionId == "session-heuristic" })
        XCTAssertGreaterThan(heuristic.inputTokens, 0)
        XCTAssertEqual(heuristic.provenanceConfidence, .lowConfidenceEstimate)
        XCTAssertEqual(first.usages.first { $0.sessionId == "session-explicit" }?.inputTokens, 21)

        let bodies = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(parser.lastPartReadCount, 23)
        XCTAssertEqual(bodies.conversations.count, 2)
    }

    func test_omp_skipsUnchangedJSONLOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("omp-cache")
        try write(
            """
            {"type":"session","version":3,"id":"omp-session","timestamp":"2026-07-01T00:00:00Z","cwd":"/tmp/omp-demo"}
            {"type":"message","message":{"role":"user","content":[{"type":"text","text":"inspect"}],"timestamp":"2026-07-01T00:00:01Z"}}
            {"type":"message","message":{"role":"assistant","model":"claude-3-7-sonnet","content":[{"type":"text","text":"done"}],"usage":{"input":17,"output":4,"cacheRead":2,"cacheWrite":1},"timestamp":"2026-07-01T00:00:02Z"}}
            """,
            to: root.appendingPathComponent("omp-session.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: OMPParser(sessionsOverride: root),
            expectedInput: 17,
            expectedOutput: 4
        )
    }

    func test_openClaw_skipsUnchangedJSONLOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("openclaw-cache")
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"claude-3-7-sonnet","role":"user","content":"hello","usage":{"input_tokens":13,"output_tokens":5}}
            {"timestamp":"2026-07-01T00:00:01Z","role":"assistant","content":"world"}
            """,
            to: root.appendingPathComponent("claw-session.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: OpenClawParser(sessionsOverride: root),
            expectedInput: 13,
            expectedOutput: 5
        )
    }

    func test_modelFilter_skipsUnchangedMatchingSessionOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("model-filter-cache")
        try write(
            #"{"timestamp":"2026-07-01T00:00:00Z","model":"zai-glm-5","message":{"role":"assistant","content":"done","usage":{"input_tokens":8,"output_tokens":3}}}"#,
            to: root.appendingPathComponent("project/session.jsonl")
        )
        try await assertUsageOnlySecondPassHit(
            parser: ModelFilterParser(modelPattern: "zai", provider: .zai, sessionsOverride: root),
            expectedInput: 8,
            expectedOutput: 3
        )
    }

    func test_modelFilter_cachesNonMatchingFactorySessions() async throws {
        let root = try makeTemporaryDirectory("model-filter-nonmatch")
        try write(
            #"{"timestamp":"2026-07-01T00:00:00Z","model":"gpt-4o","message":{"role":"assistant","content":"skip","usage":{"input_tokens":8,"output_tokens":3}}}"#,
            to: root.appendingPathComponent("project/other.jsonl")
        )
        let parser = ModelFilterParser(modelPattern: "zai", provider: .zai, sessionsOverride: root)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertTrue(first.usages.isEmpty)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertTrue(second.usages.isEmpty)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
    }

    func test_databaseSignatureIgnoresShmAndIncludesWal() throws {
        let root = try makeTemporaryDirectory("db-signature")
        let db = root.appendingPathComponent("state.db")
        try Data("sqlite".utf8).write(to: db)
        let first = FileSetSignature(databaseURL: db, using: fileManager)
        try Data("shm".utf8).write(to: URL(fileURLWithPath: db.path + "-shm"))
        let withShm = FileSetSignature(databaseURL: db, using: fileManager)
        XCTAssertEqual(first, withShm)

        try Data("wal".utf8).write(to: URL(fileURLWithPath: db.path + "-wal"))
        let withWal = FileSetSignature(databaseURL: db, using: fileManager)
        XCTAssertNotEqual(first, withWal)
    }

    private func assertUsageOnlySecondPassHit(
        parser: some LogParser,
        expectedInput: Int,
        expectedOutput: Int
    ) async throws {
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.inputTokens, expectedInput)
        XCTAssertEqual(firstUsage.outputTokens, expectedOutput)
        XCTAssertTrue(first.conversations.isEmpty)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(second.usages.first?.inputTokens, expectedInput)
        XCTAssertEqual(second.usages.first?.outputTokens, expectedOutput)
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)
        XCTAssertEqual(second.usages.first?.sessionId, firstUsage.sessionId)

        if let scan = lastScan(parser), let hits = lastHits(parser) {
            XCTAssertEqual(scan, 0)
            XCTAssertGreaterThanOrEqual(hits, 1)
        }
    }

    private func lastScan(_ parser: some LogParser) -> Int? {
        if let parser = parser as? PrimeAgentParser { return parser.lastSessionScanCount }
        if let parser = parser as? MuseParser { return parser.lastSessionScanCount }
        if let parser = parser as? KimiParser { return parser.lastSessionScanCount }
        if let parser = parser as? ForgeDevParser { return parser.lastSessionScanCount }
        if let parser = parser as? AugmentParser { return parser.lastSessionScanCount }
        if let parser = parser as? AiderParser { return parser.lastSessionScanCount }
        if let parser = parser as? PiAgentParser { return parser.lastSessionScanCount }
        if let parser = parser as? OllamaParser { return parser.lastSessionScanCount }
        if let parser = parser as? JunieParser { return parser.lastSessionScanCount }
        if let parser = parser as? CursorParser { return parser.lastSessionScanCount }
        if let parser = parser as? OpenCodeParser { return parser.lastSessionScanCount }
        if let parser = parser as? OMPParser { return parser.lastSessionScanCount }
        if let parser = parser as? OpenClawParser { return parser.lastSessionScanCount }
        if let parser = parser as? ModelFilterParser { return parser.lastSessionScanCount }
        return nil
    }

    private func lastHits(_ parser: some LogParser) -> Int? {
        if let parser = parser as? PrimeAgentParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? MuseParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? KimiParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? ForgeDevParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? AugmentParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? AiderParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? PiAgentParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? OllamaParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? JunieParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? CursorParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? OpenCodeParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? OMPParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? OpenClawParser { return parser.lastSessionCacheHitCount }
        if let parser = parser as? ModelFilterParser { return parser.lastSessionCacheHitCount }
        return nil
    }

    private func warpExactBodyLog() -> String {
        """
        [2026-05-01 12:00:00,000]: Request {}
        Body {
          "batch": [
            {
              "event": "AgentResponse.Completed",
              "originalTimestamp": "2026-05-01T12:00:00Z",
              "properties": {
                "payload": {
                  "session_id": "warp-session-1",
                  "model": "claude-sonnet-4",
                  "workspace": "/tmp/BurnBar",
                  "prompt": "Summarize quota usage",
                  "response": "Quota usage is healthy.",
                  "usage": {
                    "input_tokens": 120,
                    "output_tokens": 45,
                    "cache_read_input_tokens": 10
                  }
                }
              }
            }
          ]
        }
        """
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
