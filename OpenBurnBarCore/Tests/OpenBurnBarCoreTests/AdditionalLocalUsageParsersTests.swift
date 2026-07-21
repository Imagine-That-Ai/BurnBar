import Foundation
import XCTest
@testable import OpenBurnBarLogParsers
import OpenBurnBarSQLiteReader

final class AdditionalLocalUsageParsersTests: XCTestCase {
    func testAiderAnalyticsGroupsExactMessageUsage() async throws {
        let root = try makeDirectory("aider")
        defer { remove(root) }
        try write(
            """
            {"event":"launched","time":100,"properties":{"main_model":"claude-3-7-sonnet"}}
            {"event":"message_send","time":110,"properties":{"prompt_tokens":120,"completion_tokens":30,"cost":0.12}}
            {"event":"exit","time":120}
            """,
            to: root.appendingPathComponent("analytics.jsonl")
        )

        let result = try await AiderParser(rootOverride: root).parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.inputTokens, 120)
        XCTAssertEqual(result.usages.first?.outputTokens, 30)
        XCTAssertEqual(result.usages.first?.provenanceConfidence, .exact)
    }

    func testPiAgentAndOpenClawPreserveExplicitUsageAndTranscript() async throws {
        let piRoot = try makeDirectory("pi")
        let clawRoot = try makeDirectory("claw")
        defer { remove(piRoot); remove(clawRoot) }
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"gpt-4o","role":"user","content":"hello"}
            {"timestamp":"2026-07-01T00:00:01Z","model":"gpt-4o","role":"assistant","content":"world","usage":{"input_tokens":11,"output_tokens":7}}
            """,
            to: piRoot.appendingPathComponent("pi-session.jsonl")
        )
        try write(
            """
            {"timestamp":"2026-07-01T00:00:00Z","model":"claude-3-7-sonnet","role":"user","content":"hello","usage":{"input_tokens":13,"output_tokens":5}}
            {"timestamp":"2026-07-01T00:00:01Z","role":"assistant","content":"world"}
            """,
            to: clawRoot.appendingPathComponent("claw-session.jsonl")
        )

        let pi = try await PiAgentParser(sessionsOverride: piRoot).parse()
        let claw = try await OpenClawParser(sessionsOverride: clawRoot).parse()
        XCTAssertEqual(pi.usages.first?.inputTokens, 11)
        XCTAssertEqual(pi.usages.first?.outputTokens, 7)
        XCTAssertEqual(pi.conversations.count, 1)
        XCTAssertEqual(claw.usages.first?.inputTokens, 13)
        XCTAssertEqual(claw.usages.first?.outputTokens, 5)
        XCTAssertEqual(claw.conversations.count, 1)
    }

    func testOllamaReadsOnlyExplicitServerCounters() async throws {
        let root = try makeDirectory("ollama")
        defer { remove(root) }
        try write(
            #"{"time":"2026-07-01T00:00:00Z","model":"llama3.2","prompt_eval_count":44,"eval_count":9}"#,
            to: root.appendingPathComponent("server.log")
        )
        let result = try await OllamaParser(logsOverride: root).parse()
        XCTAssertEqual(result.usages.first?.inputTokens, 44)
        XCTAssertEqual(result.usages.first?.outputTokens, 9)
        XCTAssertEqual(result.usages.first?.provenanceConfidence, .exact)
    }

    func testCursorSQLiteAggregatesCodeHashesWithExplicitLowConfidenceMarker() async throws {
        let root = try makeDirectory("cursor")
        defer { remove(root) }
        let path = root.appendingPathComponent("ai-code-tracking.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        defer { db.close() }
        try db.execute("CREATE TABLE ai_code_hashes (conversationId TEXT, model TEXT, createdAt INTEGER)")
        try db.execute("INSERT INTO ai_code_hashes VALUES (?, ?, ?)", arguments: [.text("conversation-1"), .text("gpt-4o"), .int(1_750_000_000)])
        try db.execute("INSERT INTO ai_code_hashes VALUES (?, ?, ?)", arguments: [.text("conversation-1"), .text("gpt-4o"), .int(1_750_000_001)])
        let result = try await CursorParser(databaseOverride: path).parse()
        XCTAssertEqual(result.usages.first?.sessionId, "conversation-1")
        XCTAssertEqual(result.usages.first?.inputTokens, 1_000)
        XCTAssertEqual(result.usages.first?.outputTokens, 300)
        XCTAssertEqual(result.usages.first?.provenanceConfidence, .lowConfidenceEstimate)
    }

    func testOpenCodeSQLiteJoinsMessagePartsAndUsage() async throws {
        let root = try makeDirectory("opencode")
        defer { remove(root) }
        let path = root.appendingPathComponent("opencode.db")
        let db = try SQLiteConnection.openForWriting(creatingAt: path.path)
        defer { db.close() }
        try db.execute("CREATE TABLE session (id TEXT, data TEXT, time_created INTEGER, time_updated INTEGER)")
        try db.execute("CREATE TABLE message (id TEXT, sessionID TEXT, data TEXT, time_created INTEGER)")
        try db.execute("CREATE TABLE part (messageID TEXT, data TEXT)")
        try db.execute("INSERT INTO session VALUES (?, ?, ?, ?)", arguments: [.text("session-1"), .text(#"{"title":"Demo","directory":"/tmp/demo","time":{"created":1750000000,"updated":1750000002}}"#), .int(1_750_000_000), .int(1_750_000_002)])
        try db.execute("INSERT INTO message VALUES (?, ?, ?, ?)", arguments: [.text("message-1"), .text("session-1"), .text(#"{"role":"assistant","model":"gpt-4o","tokens":{"input":21,"output":9},"cost":0.02,"time":{"created":1750000001}}"#), .int(1_750_000_001)])
        try db.execute("INSERT INTO part VALUES (?, ?)", arguments: [.text("message-1"), .text(#"{"type":"text","text":"done"}"#)])
        let result = try await OpenCodeParser(databaseOverride: path).parse()
        XCTAssertEqual(result.usages.first?.inputTokens, 21)
        XCTAssertEqual(result.usages.first?.outputTokens, 9)
        XCTAssertEqual(try XCTUnwrap(result.usages.first?.costUSD), 0.02, accuracy: 0.000_001)
        XCTAssertEqual(result.conversations.first?.lastAssistantMessage, "done")
    }

    func testJunieReadsIndexProjectAndUsageEnvelope() async throws {
        let root = try makeDirectory("junie")
        defer { remove(root) }
        let session = root.appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try write(#"{"sessionId":"session-1","projectPath":"/tmp/demo"}"#, to: root.appendingPathComponent("index.jsonl"))
        try write(
            """
            {"payload":{"role":"user","content":"inspect","usage":{"input_tokens":17,"output_tokens":4},"model":"gemini-2.5-pro"},"timestamp":"2026-07-01T00:00:00Z"}
            {"payload":{"role":"assistant","content":"done"},"timestamp":"2026-07-01T00:00:01Z"}
            """,
            to: session.appendingPathComponent("events.jsonl")
        )
        let result = try await JunieParser(sessionsOverride: root).parse()
        XCTAssertEqual(result.usages.first?.inputTokens, 17)
        XCTAssertEqual(result.usages.first?.outputTokens, 4)
        XCTAssertEqual(result.usages.first?.projectName, "/tmp/demo")
    }

    func testModelFilterKeepsProviderSpecificFactorySessions() async throws {
        let root = try makeDirectory("factory")
        defer { remove(root) }
        try write(
            #"{"timestamp":"2026-07-01T00:00:00Z","model":"zai-glm-5","message":{"role":"assistant","content":"done","usage":{"input_tokens":8,"output_tokens":3}}}"#,
            to: root.appendingPathComponent("project/session.jsonl")
        )
        let result = try await ModelFilterParser(modelPattern: "zai", provider: .zai, sessionsOverride: root).parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertEqual(result.usages.first?.provider, .zai)
        XCTAssertEqual(result.usages.first?.inputTokens, 8)
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("obb-additional-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
