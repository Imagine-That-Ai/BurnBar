import XCTest
import GRDB
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Mac Copilot / Aider / Cursor / OpenCode / Pi / OpenClaw keep AgentLens
/// parse math. These tests pin usage-only second-pass hits on that math
/// (Copilot shutdown double-count, OpenClaw nested wrappers) rather than
/// Core totals.
final class MacIdleUsageParserCacheTests: XCTestCase {
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
        for url in paths.macSemanticsParserCacheURLs {
            XCTAssertTrue(url.lastPathComponent.hasPrefix("mac_"))
        }
    }

    func test_macCopilot_skipsUnchangedEventsOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("mac-copilot")
        let sessions = root.appendingPathComponent("session-state", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let session = sessions.appendingPathComponent("session-cache", isDirectory: true)
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logs, withIntermediateDirectories: true)
        try write(
            """
            {"type":"assistant.usage","model":"gpt-5","usage":{"input_tokens":10,"output_tokens":4},"timestamp":"2026-07-20T10:00:01Z"}
            {"type":"session.shutdown","usage":{"input_tokens":10,"output_tokens":4},"timestamp":"2026-07-20T10:00:02Z"}
            """,
            to: session.appendingPathComponent("events.jsonl")
        )
        let parser = OpenBurnBar.CopilotParser(sessionStateURL: sessions, logsURL: logs)
        let usageOnly = LogParseOptions(includeConversationBodies: false)

        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 0)
        let firstUsage = try XCTUnwrap(first.usages.first)
        XCTAssertEqual(firstUsage.inputTokens, 20)
        XCTAssertEqual(firstUsage.outputTokens, 8)

        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 20)
        XCTAssertEqual(second.usages.first?.outputTokens, 8)
        XCTAssertEqual(second.usages.first?.costUSD, firstUsage.costUSD)
    }

    func test_macAider_skipsUnchangedAnalyticsOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("mac-aider")
        try write(
            """
            {"event":"launched","time":1752408000,"properties":{"main_model":"claude-sonnet-4-20250514"}}
            {"event":"message_send","time":1752408001,"properties":{"prompt_tokens":100,"completion_tokens":50,"cost":0.01,"main_model":"claude-sonnet-4-20250514"}}
            {"event":"exit","time":1752408002,"properties":{}}
            """,
            to: root.appendingPathComponent("analytics.jsonl")
        )
        let parser = OpenBurnBar.AiderParser(rootOverride: root)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(first.usages.first?.inputTokens, 100)
        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 100)
        XCTAssertEqual(second.usages.first?.outputTokens, 50)
    }

    func test_macCursor_skipsUnchangedSQLiteOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("mac-cursor")
        let path = root.appendingPathComponent("ai-code-tracking.db").path
        let db = try DatabaseQueue(path: path)
        try await db.write { db in
            try db.execute(sql: """
                CREATE TABLE ai_code_hashes (
                    conversationId TEXT,
                    model TEXT,
                    createdAt DOUBLE
                )
                """)
            try db.execute(
                sql: "INSERT INTO ai_code_hashes (conversationId, model, createdAt) VALUES (?, ?, ?)",
                arguments: ["conversation-1", "gpt-4o", 1_750_000_000.0]
            )
        }
        let parser = CursorParser(databasePathOverride: path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(first.usages.first?.inputTokens, 500)
        XCTAssertEqual(first.usages.first?.outputTokens, 150)
        XCTAssertEqual(first.usages.first?.estimatorVersion, "hash-count-ratio-v1")
        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 500)
        XCTAssertEqual(second.usages.first?.estimatorVersion, "hash-count-ratio-v1")
    }

    func test_macOpenCode_skipsUnchangedSQLiteOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("mac-opencode")
        let path = root.appendingPathComponent("opencode.db").path
        let db = try DatabaseQueue(path: path)
        try await db.write { db in
            try db.execute(sql: "CREATE TABLE session (id TEXT, data TEXT)")
            try db.execute(sql: "CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT)")
            try db.execute(sql: "CREATE TABLE part (messageID TEXT, data TEXT)")
            try db.execute(
                sql: "INSERT INTO session (id, data) VALUES (?, ?)",
                arguments: ["session-1", #"{"title":"Demo","directory":"/tmp/demo","id":"session-1"}"#]
            )
            try db.execute(
                sql: "INSERT INTO message (id, sessionID, data) VALUES (?, ?, ?)",
                arguments: [
                    "message-1",
                    "session-1",
                    #"{"role":"assistant","model":"gpt-4o","tokens":{"input":21,"output":9},"cost":0.02}"#
                ]
            )
        }
        let parser = OpenCodeParser(databasePathOverride: path)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertFalse(first.usages.isEmpty)
        let firstInput = try XCTUnwrap(first.usages.first?.inputTokens)
        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, firstInput)
    }

    func test_macOpenCode_usageOnlySkipsPartWhenEverySessionHasExplicitTokens() async throws {
        let path = try makeMacOpenCodeDatabase(
            sessions: [
                MacOpenCodeSessionSeed(
                    id: "session-explicit",
                    messages: [
                        MacOpenCodeMessageSeed(
                            id: "message-explicit",
                            role: "assistant",
                            tokens: (21, 9),
                            partText: "explicit body that usage-only must not read"
                        )
                    ]
                )
            ]
        )
        let parser = OpenCodeParser(databasePathOverride: path)
        let first = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(parser.lastPartReadCount, 0)
        XCTAssertEqual(first.usages.first?.inputTokens, 21)
        XCTAssertEqual(first.usages.first?.provenanceConfidence, .exact)
    }

    func test_macOpenCode_usageOnlyReadsPartOnlyForSessionsMissingExplicitTokens() async throws {
        let path = try makeMacOpenCodeDatabase(
            sessions: [
                MacOpenCodeSessionSeed(
                    id: "session-explicit",
                    messages: [
                        MacOpenCodeMessageSeed(
                            id: "message-explicit",
                            role: "assistant",
                            tokens: (21, 9),
                            partText: "explicit body"
                        )
                    ]
                ),
                MacOpenCodeSessionSeed(
                    id: "session-heuristic",
                    messages: [
                        MacOpenCodeMessageSeed(
                            id: "message-h-user",
                            role: "user",
                            tokens: nil,
                            partText: "hello from the user"
                        ),
                        MacOpenCodeMessageSeed(
                            id: "message-h-assistant",
                            role: "assistant",
                            tokens: nil,
                            partText: "hello from the assistant"
                        )
                    ]
                )
            ]
        )
        let parser = OpenCodeParser(databasePathOverride: path)
        let first = try await parser.parse(options: LogParseOptions(includeConversationBodies: false))
        XCTAssertEqual(parser.lastPartReadCount, 2)
        let bySession = Dictionary(uniqueKeysWithValues: first.usages.map { ($0.sessionId, $0) })
        XCTAssertEqual(bySession["session-explicit"]?.inputTokens, 21)
        let heuristic = try XCTUnwrap(bySession["session-heuristic"])
        XCTAssertGreaterThan(heuristic.inputTokens, 0)
        XCTAssertEqual(heuristic.provenanceConfidence, .lowConfidenceEstimate)

        let bodies = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(parser.lastPartReadCount, 3)
        XCTAssertFalse(bodies.conversations.isEmpty)
    }

    func test_macOpenCode_usageOnlyJSONOnlyPartBoundsByJsonExtract() async throws {
        let path = try makeMacOpenCodeJSONOnlyPartDatabase(decoyPartCount: 20)
        let parser = OpenCodeParser(databasePathOverride: path)
        let first = try await parser.parse(options: LogParseOptions.usageAccounting())
        XCTAssertEqual(
            parser.lastPartReadCount,
            2,
            "JSON-only part must json_extract the heuristic ids, not SELECT the whole table"
        )
        let bySession = Dictionary(uniqueKeysWithValues: first.usages.map { ($0.sessionId, $0) })
        XCTAssertEqual(bySession["session-explicit"]?.inputTokens, 21)
        let heuristic = try XCTUnwrap(bySession["session-heuristic"])
        XCTAssertGreaterThan(heuristic.inputTokens, 0)
        XCTAssertEqual(heuristic.provenanceConfidence, .lowConfidenceEstimate)

        let bodies = try await parser.parse(options: LogParseOptions(includeConversationBodies: true))
        XCTAssertEqual(parser.lastPartReadCount, 23)
        XCTAssertFalse(bodies.conversations.isEmpty)
    }

    func test_macPi_skipsUnchangedJSONLOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("mac-pi")
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"gpt-4o","role":"user","content":"hello"}
            {"timestamp":"2026-07-01T00:00:01Z","model":"gpt-4o","role":"assistant","content":"world","usage":{"input_tokens":11,"output_tokens":7}}
            """,
            to: root.appendingPathComponent("pi-session.jsonl")
        )
        let parser = PiAgentParser(sessionsDirectoryOverride: root)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(first.usages.first?.inputTokens, 11)
        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 11)
        XCTAssertEqual(second.usages.first?.outputTokens, 7)
    }

    func test_macPi_usageOnlyDoesNotExtractBodiesBeforeLateExplicitUsage() async throws {
        let root = try makeTemporaryDirectory("mac-pi-streaming")
        let file = root.appendingPathComponent("pi-large-session.jsonl")
        let payload = String(repeating: "x", count: 1_024)
        var data = Data()
        for index in 0..<2_048 {
            if index.isMultiple(of: 257) {
                data.append(Data("malformed-\(index)\n".utf8))
            } else {
                data.append(
                    Data(
                        #"{"timestamp":"2026-07-01T00:00:00Z","model":"gpt-5","role":"user","content":"\#(payload)"}\#n"#
                            .utf8
                    )
                )
            }
        }
        data.append(
            Data(
                #"{"timestamp":"2026-07-01T00:00:01Z","model":"gpt-5","role":"assistant","content":"done","usage":{"input_tokens":77,"output_tokens":19}}\#n"#
                    .utf8
            )
        )
        try data.write(to: file, options: .atomic)

        let parser = PiAgentParser(sessionsDirectoryOverride: root)
        let result = try await parser.parse(
            options: LogParseOptions(includeConversationBodies: false)
        )

        XCTAssertEqual(result.usages.first?.inputTokens, 77)
        XCTAssertEqual(result.usages.first?.outputTokens, 19)
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertEqual(parser.lastContentExtractionLineCount, 0)
    }

    func test_macOpenClaw_skipsUnchangedNestedWrapperOnUsageOnlySecondPass() async throws {
        let root = try makeTemporaryDirectory("mac-openclaw")
        try write(
            """
            {
              "messages": [
                {"timestamp":"2026-07-01T00:00:00Z","model":"claude-3-7-sonnet","role":"user","content":"hello","usage":{"input_tokens":13,"output_tokens":5}},
                {"timestamp":"2026-07-01T00:00:01Z","role":"assistant","content":"world"}
              ]
            }
            """,
            to: root.appendingPathComponent("claw-session.json")
        )
        let parser = OpenClawParser(fileManager: fileManager, sessionsDirectory: root)
        let usageOnly = LogParseOptions(includeConversationBodies: false)
        let first = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 1)
        XCTAssertEqual(first.usages.first?.inputTokens, 13)
        let second = try await parser.parse(options: usageOnly)
        XCTAssertEqual(parser.lastSessionScanCount, 0)
        XCTAssertEqual(parser.lastSessionCacheHitCount, 1)
        XCTAssertEqual(second.usages.first?.inputTokens, 13)
        XCTAssertEqual(second.usages.first?.outputTokens, 5)
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("obb-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private struct MacOpenCodeMessageSeed {
        let id: String
        let role: String
        let tokens: (input: Int, output: Int)?
        let partText: String
    }

    private struct MacOpenCodeSessionSeed {
        let id: String
        let messages: [MacOpenCodeMessageSeed]
    }

    private func makeMacOpenCodeDatabase(sessions: [MacOpenCodeSessionSeed]) throws -> String {
        let root = try makeTemporaryDirectory("mac-opencode-part")
        let path = root.appendingPathComponent("opencode.db").path
        let db = try DatabaseQueue(path: path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE session (id TEXT, data TEXT)")
            try db.execute(sql: "CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT)")
            try db.execute(sql: "CREATE TABLE part (messageID TEXT, data TEXT)")
            for session in sessions {
                try db.execute(
                    sql: "INSERT INTO session (id, data) VALUES (?, ?)",
                    arguments: [session.id, #"{"title":"Demo","directory":"/tmp/demo","id":"\#(session.id)"}"#]
                )
                for message in session.messages {
                    let tokenJSON: String
                    if let tokens = message.tokens {
                        tokenJSON = #""tokens":{"input":\#(tokens.input),"output":\#(tokens.output)},"#
                    } else {
                        tokenJSON = ""
                    }
                    try db.execute(
                        sql: "INSERT INTO message (id, sessionID, data) VALUES (?, ?, ?)",
                        arguments: [
                            message.id,
                            session.id,
                            "{\"role\":\"\(message.role)\",\"model\":\"gpt-4o\",\(tokenJSON)\"cost\":0.02}"
                        ]
                    )
                    try db.execute(
                        sql: "INSERT INTO part (messageID, data) VALUES (?, ?)",
                        arguments: [message.id, "{\"type\":\"text\",\"text\":\"\(message.partText)\"}"]
                    )
                }
            }
        }
        return path
    }

    private func makeMacOpenCodeJSONOnlyPartDatabase(decoyPartCount: Int) throws -> String {
        let root = try makeTemporaryDirectory("mac-opencode-json-only-part")
        let path = root.appendingPathComponent("opencode.db").path
        let db = try DatabaseQueue(path: path)
        try db.write { db in
            try db.execute(sql: "CREATE TABLE session (id TEXT, data TEXT)")
            try db.execute(sql: "CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT)")
            try db.execute(sql: "CREATE TABLE part (data TEXT)")
            try db.execute(
                sql: "INSERT INTO session (id, data) VALUES (?, ?)",
                arguments: ["session-explicit", #"{"title":"Demo","directory":"/tmp/demo","id":"session-explicit"}"#]
            )
            try db.execute(
                sql: "INSERT INTO session (id, data) VALUES (?, ?)",
                arguments: ["session-heuristic", #"{"title":"Heuristic","directory":"/tmp/demo","id":"session-heuristic"}"#]
            )
            try db.execute(
                sql: "INSERT INTO message (id, sessionID, data) VALUES (?, ?, ?)",
                arguments: [
                    "message-explicit",
                    "session-explicit",
                    #"{"role":"assistant","model":"gpt-4o","tokens":{"input":21,"output":9},"cost":0.02}"#
                ]
            )
            try db.execute(
                sql: "INSERT INTO message (id, sessionID, data) VALUES (?, ?, ?)",
                arguments: [
                    "message-h-user",
                    "session-heuristic",
                    #"{"role":"user","model":"gpt-4o","cost":0.02}"#
                ]
            )
            try db.execute(
                sql: "INSERT INTO message (id, sessionID, data) VALUES (?, ?, ?)",
                arguments: [
                    "message-h-assistant",
                    "session-heuristic",
                    #"{"role":"assistant","model":"gpt-4o","cost":0.02}"#
                ]
            )
            try db.execute(
                sql: "INSERT INTO part (data) VALUES (?)",
                arguments: [#"{"type":"text","text":"explicit body","messageID":"message-explicit"}"#]
            )
            try db.execute(
                sql: "INSERT INTO part (data) VALUES (?)",
                arguments: [#"{"type":"text","text":"hello from the user","messageID":"message-h-user"}"#]
            )
            try db.execute(
                sql: "INSERT INTO part (data) VALUES (?)",
                arguments: [#"{"type":"text","text":"hello from the assistant","messageID":"message-h-assistant"}"#]
            )
            for index in 0..<decoyPartCount {
                try db.execute(
                    sql: "INSERT INTO part (data) VALUES (?)",
                    arguments: ["{\"type\":\"text\",\"text\":\"decoy \(index)\",\"messageID\":\"decoy-\(index)\"}"]
                )
            }
        }
        return path
    }

    private func write(_ string: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(string.utf8).write(to: url, options: .atomic)
    }
}
