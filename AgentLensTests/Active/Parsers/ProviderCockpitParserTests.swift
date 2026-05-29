import XCTest
import GRDB
@testable import OpenBurnBar
import OpenBurnBarCore

/// SQLite-fixture coverage for the cockpit's flagship transcript parsers:
/// Goose (Block) `sessions.db` and OpenCode `opencode.db`. Both parsers are
/// driven through their explicit override seams (`sessionDirectoryOverride`,
/// `databasePathOverride`) so fixtures stay hermetic and never touch real CLI data.
final class ProviderCockpitParserTests: XCTestCase {

    // MARK: - Goose (SQLite)

    func testGooseParsesSqliteSessionTokensTranscriptAndProject() async throws {
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-goose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let dbPath = sessionsDir.appendingPathComponent("sessions.db").path
        let queue = try DatabaseQueue(path: dbPath)
        try await queue.write { db in
            try db.execute(sql: """
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
            try db.execute(
                sql: """
                    INSERT INTO sessions
                        (id, model, description, working_dir,
                         accumulated_input_tokens, accumulated_output_tokens,
                         cache_read_tokens, cache_write_tokens, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "goose-cockpit-1", "claude-sonnet-4", "Refactor the parser",
                    "/Users/dev/project-x", 1000, 500, 200, 50,
                    "2026-05-20 10:00:00", "2026-05-20 10:05:00",
                ]
            )

            try db.execute(sql: """
                CREATE TABLE messages (
                    session_id TEXT,
                    role TEXT,
                    content TEXT,
                    created_at INTEGER
                )
            """)
            try db.execute(
                sql: "INSERT INTO messages (session_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                arguments: ["goose-cockpit-1", "user", "Please refactor the parser to be testable.", 1]
            )
            try db.execute(
                sql: "INSERT INTO messages (session_id, role, content, created_at) VALUES (?, ?, ?, ?)",
                arguments: ["goose-cockpit-1", "assistant", "Done — extracted a seam and added tests.", 2]
            )
        }

        let result = try await GooseParser(sessionDirectoryOverride: sessionsDir.path).parse()

        let usage = try XCTUnwrap(
            result.usages.first { $0.sessionId == "goose-cockpit-1" },
            "Fixture session should be parsed from the SQLite database"
        )
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
        XCTAssertEqual(usage.cacheReadTokens, 200)
        XCTAssertEqual(usage.cacheCreationTokens, 50, "Goose cache_write maps to cacheCreation")
        XCTAssertEqual(usage.projectName, "project-x", "Project name is the working_dir leaf")
        XCTAssertGreaterThan(usage.costUSD, 0)

        let conversation = try XCTUnwrap(
            result.conversations.first { $0.sessionId == "goose-cockpit-1" }
        )
        XCTAssertEqual(conversation.messageCount, 2)
        XCTAssertEqual(conversation.inferredTaskTitle, "Refactor the parser", "Title prefers the session description")
        XCTAssertTrue(conversation.fullText.contains("refactor the parser to be testable"))
        XCTAssertTrue(conversation.fullText.contains("extracted a seam"))
        XCTAssertEqual(conversation.workingDirectory, "/Users/dev/project-x")
    }

    func testGooseDerivesInputOutputSplitFromTotalTokensOnly() async throws {
        let sessionsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-goose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let dbPath = sessionsDir.appendingPathComponent("sessions.db").path
        let queue = try DatabaseQueue(path: dbPath)
        try await queue.write { db in
            try db.execute(sql: """
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    model TEXT,
                    total_tokens INTEGER,
                    created_at TEXT
                )
            """)
            try db.execute(
                sql: "INSERT INTO sessions (id, model, total_tokens, created_at) VALUES (?, ?, ?, ?)",
                arguments: ["goose-total-only", "gpt-5", 1000, "2026-05-20 11:00:00"]
            )
        }

        let result = try await GooseParser(sessionDirectoryOverride: sessionsDir.path).parse()
        let usage = try XCTUnwrap(result.usages.first { $0.sessionId == "goose-total-only" })
        // Total-only sessions split 85% input / 15% output.
        XCTAssertEqual(usage.inputTokens, 850)
        XCTAssertEqual(usage.outputTokens, 150)
        XCTAssertEqual(usage.totalTokens, 1000)
    }

    // MARK: - OpenCode (SQLite)

    func testOpenCodeParsesSessionMessagePartTablesIntoCockpitFacets() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-opencode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbPath = dir.appendingPathComponent("opencode.db").path
        let queue = try DatabaseQueue(path: dbPath)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE session (data TEXT)")
            try db.execute(sql: "CREATE TABLE message (data TEXT)")
            try db.execute(sql: "CREATE TABLE part (data TEXT)")

            let session = #"{"id":"oc-1","title":"Build the feature","directory":"/Users/dev/acme","time":{"created":1716200000,"updated":1716200600}}"#
            try db.execute(sql: "INSERT INTO session (data) VALUES (?)", arguments: [session])

            let userMsg = #"{"id":"m1","sessionID":"oc-1","role":"user","time":{"created":1716200001},"tokens":{"input":800,"output":0}}"#
            let assistantMsg = #"{"id":"m2","sessionID":"oc-1","role":"assistant","time":{"created":1716200002},"modelID":"claude-sonnet-4","cost":0.012,"tokens":{"input":0,"output":400,"cache":{"read":100,"write":20}}}"#
            try db.execute(sql: "INSERT INTO message (data) VALUES (?)", arguments: [userMsg])
            try db.execute(sql: "INSERT INTO message (data) VALUES (?)", arguments: [assistantMsg])

            let userPart = #"{"messageID":"m1","type":"text","text":"Please build the feature."}"#
            let assistantPart = #"{"messageID":"m2","type":"text","text":"Done, the feature is built."}"#
            try db.execute(sql: "INSERT INTO part (data) VALUES (?)", arguments: [userPart])
            try db.execute(sql: "INSERT INTO part (data) VALUES (?)", arguments: [assistantPart])
        }

        let result = try await OpenCodeParser(databasePathOverride: dbPath).parse()

        let usage = try XCTUnwrap(
            result.usages.first { $0.sessionId == "oc-1" },
            "Fixture OpenCode session should be parsed"
        )
        XCTAssertEqual(usage.inputTokens, 800)
        XCTAssertEqual(usage.outputTokens, 400)
        XCTAssertEqual(usage.cacheReadTokens, 100)
        XCTAssertEqual(usage.cacheCreationTokens, 20, "OpenCode cache.write maps to cacheCreation")
        XCTAssertEqual(usage.projectName, "acme", "Project name is the directory leaf")
        XCTAssertEqual(usage.costUSD, 0.012, accuracy: 0.0001, "Per-message cost should be summed, not re-priced")

        let conversation = try XCTUnwrap(result.conversations.first { $0.sessionId == "oc-1" })
        XCTAssertEqual(conversation.messageCount, 2)
        XCTAssertEqual(conversation.inferredTaskTitle, "Build the feature", "Title prefers the session title")
        XCTAssertTrue(conversation.fullText.contains("Please build the feature"))
        XCTAssertTrue(conversation.fullText.contains("the feature is built"))
        XCTAssertEqual(conversation.workingDirectory, "/Users/dev/acme")
    }

    func testOpenCodeReturnsEmptyWhenDatabaseMissing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-opencode-missing-\(UUID().uuidString)/opencode.db").path

        let result = try await OpenCodeParser(databasePathOverride: missing).parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
    }

    func testProvidersReportExpectedEnumValues() {
        XCTAssertEqual(GooseParser().provider, .goose)
        XCTAssertEqual(OpenCodeParser().provider, .openCode)
    }
}
