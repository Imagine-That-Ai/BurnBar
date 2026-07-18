import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarKernel
import OpenBurnBarSQLiteReader

final class LiftedParserBoundaryTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testCursorAgentParserParsesFlatJSONLWithConversationSemantics() async throws {
        let directory = try makeTemporaryDirectory(named: "cursor-agent-flat")
        let sessionID = "019e3403-e9bc-7131-872d-ae2728fb330a"
        let fixtureURL = directory.appendingPathComponent("\(sessionID).jsonl")
        let fixture = """
        {"role":"system","content":"System instructions here.","timestamp":"2026-05-30T01:00:00Z"}
        {"role":"user","content":"Please check the codebase rules.","timestamp":"2026-05-30T01:00:05Z"}
        {"role":"assistant","content":"Sure! Let's do a grep search.","thinking":"Grep is faster here.","tool_calls":[{"name":"grep_search","args":{"Query":"GrokParser"}}],"timestamp":"2026-05-30T01:00:10Z"}
        {"role":"tool","type":"TOOL_OUTPUT","content":"File Path: `file:///path/to/GrokParser.swift`\\nLine Content: final class GrokParser","timestamp":"2026-05-30T01:00:15Z"}
        {"role":"assistant","content":"Found the parser definition. It uses .xAI.","timestamp":"2026-05-30T01:00:20Z"}
        """
        try write(fixture, to: fixtureURL)

        let result = try await CursorAgentParser(logDirectoryOverride: directory.path).parse()

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .cursorAgent)
        XCTAssertEqual(usage.sessionId, sessionID)
        XCTAssertEqual(usage.model, "cursor-agent-pro")
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertEqual(usage.provenanceConfidence, .exact)

        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.provider, .cursorAgent)
        XCTAssertEqual(conversation.sessionId, sessionID)
        XCTAssertEqual(conversation.projectName, "Cursor Agent")
        XCTAssertEqual(conversation.messageCount, 2)
        XCTAssertTrue(conversation.fullText.contains("Please check the codebase rules."))
        XCTAssertTrue(conversation.fullText.contains("Found the parser definition."))
        XCTAssertFalse(conversation.fullText.contains("Grep is faster here."))
        XCTAssertTrue(conversation.keyTools.contains("grep_search"))
        XCTAssertTrue(conversation.keyFiles.contains("GrokParser.swift"))
    }

    func testWarpParserPreservesExactUsageAndProviderLogProvenance() async throws {
        let directory = try makeTemporaryDirectory(named: "warp-exact")
        let fixture = """
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
        try write(fixture, to: directory.appendingPathComponent("warp_network.log"))

        let result = try await WarpParser(logDirectory: directory).parse()

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .warp)
        XCTAssertEqual(usage.sessionId, "warp-session-1")
        XCTAssertEqual(usage.projectName, "BurnBar")
        XCTAssertEqual(usage.model, "claude-sonnet-4")
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 45)
        XCTAssertEqual(usage.cacheCreationTokens, 0)
        XCTAssertEqual(usage.cacheReadTokens, 10)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)

        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.provider, .warp)
        XCTAssertEqual(conversation.sessionId, "warp-session-1")
        XCTAssertEqual(conversation.projectName, "BurnBar")
        XCTAssertTrue(conversation.fullText.contains("Summarize quota usage"))
        XCTAssertTrue(conversation.fullText.contains("Quota usage is healthy."))
    }

    func testClineFormatParserParsesExactUsageAndConversationBodies() async throws {
        let storageRoot = try makeTemporaryDirectory(named: "cline-storage")
        let taskID = "cline-task-42"
        let taskDirectory = storageRoot.appendingPathComponent(taskID, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        let historyURL = taskDirectory.appendingPathComponent("api_conversation_history.json")
        let fixture = """
        [
          {
            "role": "user",
            "content": "Inspect the parser boundary carefully.",
            "ts": 1772323200000,
            "model": "claude-3-5-sonnet"
          },
          {
            "role": "assistant",
            "content": [
              {"type": "text", "text": "The parser boundary is covered exactly."}
            ],
            "ts": 1772323260000,
            "model": "claude-3-5-sonnet",
            "usage": {
              "input_tokens": 321,
              "output_tokens": 87,
              "cache_creation_input_tokens": 43,
              "cache_read_input_tokens": 29
            }
          }
        ]
        """
        try write(fixture, to: historyURL)

        let parser = ClineFormatParser(provider: .cline, storagePaths: [storageRoot.path])
        let result = try await parser.parse(
            options: LogParseOptions(includeConversationBodies: true)
        )

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .cline)
        XCTAssertEqual(usage.sessionId, taskID)
        XCTAssertEqual(usage.projectName, taskID)
        XCTAssertEqual(usage.model, "claude-3-5-sonnet")
        XCTAssertEqual(usage.inputTokens, 321)
        XCTAssertEqual(usage.outputTokens, 87)
        XCTAssertEqual(usage.cacheCreationTokens, 43)
        XCTAssertEqual(usage.cacheReadTokens, 29)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        XCTAssertEqual(usage.startTime, Date(timeIntervalSince1970: 1_772_323_200))
        XCTAssertEqual(usage.endTime, Date(timeIntervalSince1970: 1_772_323_260))

        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.provider, .cline)
        XCTAssertEqual(conversation.sessionId, taskID)
        XCTAssertEqual(conversation.projectName, taskID)
        XCTAssertEqual(conversation.messageCount, 2)
        XCTAssertEqual(conversation.inferredTaskTitle, "Inspect the parser boundary carefully.")
        XCTAssertEqual(conversation.lastAssistantMessage, "The parser boundary is covered exactly.")
        XCTAssertTrue(conversation.fullText.contains("Inspect the parser boundary carefully."))
        XCTAssertTrue(conversation.fullText.contains("The parser boundary is covered exactly."))
        XCTAssertEqual(conversation.startTime, usage.startTime)
        XCTAssertEqual(conversation.endTime, usage.endTime)
    }

    func testGooseParserParsesLegacyJSONLExactNestedUsageAndConversation() async throws {
        let directory = try makeTemporaryDirectory(named: "goose-legacy")
        let sessionID = "goose-legacy-session"
        let fixtureURL = directory.appendingPathComponent("\(sessionID).jsonl")
        let fixture = """
        {"timestamp":"2026-06-01T10:00:00Z","model":"anthropic/claude-sonnet-4","message":{"role":"user","content":"Review the legacy Goose session."}}
        {"timestamp":"2026-06-01T10:01:30Z","model":"anthropic/claude-sonnet-4","message":{"role":"assistant","content":"The legacy Goose session is valid.","usage":{"input_tokens":210,"output_tokens":55,"cache_creation_input_tokens":34,"cache_read_input_tokens":13}}}
        """
        try write(fixture, to: fixtureURL)

        let result = try await GooseParser(sessionDirectoryOverride: directory.path).parse()

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.conversations.count, 1)

        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .goose)
        XCTAssertEqual(usage.sessionId, sessionID)
        XCTAssertEqual(usage.projectName, sessionID)
        XCTAssertEqual(usage.model, "anthropic/claude-sonnet-4")
        XCTAssertEqual(usage.inputTokens, 210)
        XCTAssertEqual(usage.outputTokens, 55)
        XCTAssertEqual(usage.cacheCreationTokens, 34)
        XCTAssertEqual(usage.cacheReadTokens, 13)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)

        let expectedStart = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-01T10:00:00Z"))
        let expectedEnd = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-01T10:01:30Z"))
        XCTAssertEqual(usage.startTime, expectedStart)
        XCTAssertEqual(usage.endTime, expectedEnd)

        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.provider, .goose)
        XCTAssertEqual(conversation.sessionId, sessionID)
        XCTAssertEqual(conversation.projectName, sessionID)
        XCTAssertEqual(conversation.messageCount, 2)
        XCTAssertEqual(conversation.inferredTaskTitle, "Review the legacy Goose session.")
        XCTAssertEqual(conversation.lastAssistantMessage, "The legacy Goose session is valid.")
        XCTAssertTrue(conversation.fullText.contains("Review the legacy Goose session."))
        XCTAssertTrue(conversation.fullText.contains("The legacy Goose session is valid."))
        XCTAssertEqual(conversation.startTime, expectedStart)
        XCTAssertEqual(conversation.endTime, expectedEnd)
    }

    func testGooseParserReadsSQLiteTokensAndFlattensOrderedConversationBlocks() async throws {
        let directory = try makeTemporaryDirectory(named: "goose-sqlite")
        let databasePath = directory.appendingPathComponent("sessions.db").path
        let connection = try SQLiteConnection.openForWriting(creatingAt: databasePath)

        try connection.execute("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                model TEXT,
                description TEXT,
                working_dir TEXT,
                accumulated_input_tokens INTEGER,
                accumulated_output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                created_at TEXT,
                updated_at TEXT
            )
            """)
        try connection.execute("""
            CREATE TABLE messages (
                session_id TEXT,
                role TEXT,
                content TEXT,
                created_at INTEGER
            )
            """)
        try connection.execute(
            """
            INSERT INTO sessions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                .text("goose-sqlite-session"),
                .text("anthropic/claude-sonnet-4"),
                .text("Inspect Goose SQLite parsing"),
                .text("/tmp/GooseProject"),
                .int(120),
                .int(30),
                .int(5),
                .int(4),
                .text("2026-03-01T00:00:00Z"),
                .text("2026-03-01T00:01:30Z")
            ]
        )
        try connection.execute(
            "INSERT INTO messages VALUES (?, ?, ?, ?)",
            arguments: [
                .text("goose-sqlite-session"),
                .text("assistant"),
                .text("""
                    [{"type":"reasoning","text":"Check the schema."},{"type":"tool_response","text":"ignore this tool payload"},{"type":"text","text":"SQLite parsing is sound."}]
                    """),
                .int(2)
            ]
        )
        try connection.execute(
            "INSERT INTO messages VALUES (?, ?, ?, ?)",
            arguments: [
                .text("goose-sqlite-session"),
                .text("user"),
                .text("""
                    [{"type":"text","text":"Read the SQLite session."},{"type":"tool_request","text":"ignore this call"},{"type":"text","text":"Preserve message order."}]
                    """),
                .int(1)
            ]
        )
        connection.close()

        let result = try await GooseParser(sessionDirectoryOverride: directory.path).parse(
            options: LogParseOptions(includeConversationBodies: true)
        )

        XCTAssertEqual(result.usages.count, 1)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .goose)
        XCTAssertEqual(usage.sessionId, "goose-sqlite-session")
        XCTAssertEqual(usage.projectName, "GooseProject")
        XCTAssertEqual(usage.model, "anthropic/claude-sonnet-4")
        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.cacheReadTokens, 5)
        XCTAssertEqual(usage.cacheCreationTokens, 4)
        XCTAssertEqual(usage.provenanceMethod, .providerLog)
        XCTAssertEqual(usage.provenanceConfidence, .exact)
        XCTAssertEqual(
            usage.startTime,
            ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z")
        )
        XCTAssertEqual(
            usage.endTime,
            ISO8601DateFormatter().date(from: "2026-03-01T00:01:30Z")
        )

        let conversation = try XCTUnwrap(result.conversations.first)
        XCTAssertEqual(conversation.sessionId, "goose-sqlite-session")
        XCTAssertEqual(conversation.projectName, "GooseProject")
        XCTAssertEqual(conversation.workingDirectory, "/tmp/GooseProject")
        XCTAssertEqual(conversation.inferredTaskTitle, "Inspect Goose SQLite parsing")
        XCTAssertEqual(conversation.messageCount, 2)
        XCTAssertEqual(conversation.userWordCount, 7)
        XCTAssertEqual(conversation.assistantWordCount, 7)
        XCTAssertEqual(conversation.lastAssistantMessage, "Check the schema.\n\nSQLite parsing is sound.")
        XCTAssertTrue(conversation.fullText.contains("Read the SQLite session."))
        XCTAssertTrue(conversation.fullText.contains("Preserve message order."))
        XCTAssertTrue(conversation.fullText.contains("SQLite parsing is sound."))
        XCTAssertFalse(conversation.fullText.contains("ignore this"))
        let userRange = try XCTUnwrap(conversation.fullText.range(of: "Read the SQLite session."))
        let assistantRange = try XCTUnwrap(conversation.fullText.range(of: "SQLite parsing is sound."))
        XCTAssertLessThan(userRange.lowerBound, assistantRange.lowerBound)
    }

    func testClineFormatParserSkipsMalformedTasksAndEstimatesBodylessUsage() async throws {
        let storageRoot = try makeTemporaryDirectory(named: "cline-fallback")
        let malformedDirectory = storageRoot.appendingPathComponent("malformed", isDirectory: true)
        let validDirectory = storageRoot.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: malformedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: validDirectory, withIntermediateDirectories: true)
        try write(
            "{not valid JSON",
            to: malformedDirectory.appendingPathComponent("api_conversation_history.json")
        )
        try write(
            """
            [
              {"role":"user","content":"Estimate these input tokens.","ts":1772323200000,"model":"claude-3-5-sonnet"},
              {"role":"assistant","content":[{"type":"text","text":"Estimated output is available."}],"ts":1772323260000,"model":"claude-3-5-sonnet"}
            ]
            """,
            to: validDirectory.appendingPathComponent("api_conversation_history.json")
        )

        let parser = ClineFormatParser(provider: .cline, storagePaths: [storageRoot.path])
        let result = try await parser.parse(
            options: LogParseOptions(includeConversationBodies: false)
        )

        XCTAssertEqual(result.usages.count, 1, "Malformed tasks must not abort the storage-root scan")
        XCTAssertTrue(result.conversations.isEmpty, "Body-disabled scans must not retain transcripts")
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .cline)
        XCTAssertEqual(usage.sessionId, "valid")
        XCTAssertEqual(usage.projectName, "valid")
        XCTAssertEqual(usage.model, "claude-3-5-sonnet")
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertEqual(usage.cacheCreationTokens, 0)
        XCTAssertEqual(usage.cacheReadTokens, 0)
        XCTAssertEqual(usage.startTime, Date(timeIntervalSince1970: 1_772_323_200))
        XCTAssertEqual(usage.endTime, Date(timeIntervalSince1970: 1_772_323_260))
    }

    func testCursorAgentParserUsesNestedSummaryWithoutRetainingConversationBodies() async throws {
        let sessionsRoot = try makeTemporaryDirectory(named: "cursor-agent-nested")
        let sessionDirectory = sessionsRoot.appendingPathComponent("nested-session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try write(
            """
            {"role":"system","content":"System context.","timestamp":"2026-03-01T00:00:00Z"}
            {"role":"user","content":"Inspect the nested session.","timestamp":"2026-03-01T00:00:05Z"}
            {"role":"assistant","content":"The nested parser path is sound.","thinking":"Check summary precedence.","tool_calls":[{"name":"read_file","args":{"path":"Parser.swift"}}],"timestamp":"2026-03-01T00:00:10Z"}
            """,
            to: sessionDirectory.appendingPathComponent("chat_history.jsonl")
        )
        try write(
            """
            {"current_model_id":"cursor-summary-model","generated_title":"Nested summary title","project":"SummaryProject","info":{"cwd":"/tmp/ignored-cwd"}}
            """,
            to: sessionDirectory.appendingPathComponent("summary.json")
        )

        let result = try await CursorAgentParser(logDirectoryOverride: sessionsRoot.path).parse(
            options: LogParseOptions(includeConversationBodies: false)
        )

        XCTAssertEqual(result.usages.count, 1)
        XCTAssertTrue(result.conversations.isEmpty)
        let usage = try XCTUnwrap(result.usages.first)
        XCTAssertEqual(usage.provider, .cursorAgent)
        XCTAssertEqual(usage.sessionId, "nested-session")
        XCTAssertEqual(usage.projectName, "SummaryProject")
        XCTAssertEqual(usage.model, "cursor-summary-model")
        XCTAssertGreaterThan(usage.inputTokens, 0)
        XCTAssertGreaterThan(usage.outputTokens, 0)
        XCTAssertGreaterThan(usage.cacheCreationTokens, 0)
        XCTAssertEqual(usage.startTime, ISO8601DateFormatter().date(from: "2026-03-01T00:00:00Z"))
        XCTAssertEqual(usage.endTime, ISO8601DateFormatter().date(from: "2026-03-01T00:00:10Z"))
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .atomic)
    }
}
