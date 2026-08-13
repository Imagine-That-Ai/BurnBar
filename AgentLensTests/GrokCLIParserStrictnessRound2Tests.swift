@testable import BurnBar
import XCTest

// MARK: - Grok CLI Parser Strictness Round 2 Tests

/// Round-2 scrutiny (parser-strictness-repair.json, issues 3/4): GrokCLIParser
/// must degrade typed parse health for unknown/wrong-shaped event records and
/// present wrong-typed chat content — never silent acceptance.
@MainActor
final class GrokCLIParserStrictnessRound2Tests: XCTestCase {

    private func makeParser(sessionsRoot: String) -> GrokCLIParser {
        GrokCLIParser(sessionsRoot: sessionsRoot)
    }

    private func writeSummary(_ sessionDir: URL, id: String) throws {
        let summary = "{\"info\":{\"id\":\"\(id)\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
    }

    // MARK: round-2 issue 3 — unknown/wrong-shaped event records

    func test_unknownEventTypeDegradesHealth() async throws {
        // An events.jsonl line with an unknown event type (e.g.
        // {"type":"bogus"}) is wrong-shaped input: it must degrade the
        // typed parse health, never be silently accepted (round-2
        // scrutiny, issue 3). Known non-usage event kinds
        // (mcp_config_resolved, turn_started, loop_started, first_token)
        // are the documented allowlist.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-unknownevent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000011", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeSummary(sessionDir, id: "019f0000-0000-0000-0000-000000000011")

        let knownEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000011\",\"turn_number\":1,"
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
        let unknownEvent = "{\"ts\":\"2026-07-14T00:05:05.000Z\",\"type\":\"bogus_event\",\"payload\":{}}"
        let usageEvent = "{\"ts\":\"2026-07-14T00:05:17.045Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,\"reasoningTokens\":0,\"modelCalls\":1,"
            + "\"apiDurationMs\":100,\"modelUsage\":{},\"numTurns\":1}}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (knownEvent + "\n" + unknownEvent + "\n" + usageEvent + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000011" }
        XCTAssertNotNil(session, "Valid usage rows must survive unknown-event siblings")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertEqual(session?.outputTokens, 20)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Unknown event type must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_knownNonUsageEventsStayHealthy() async throws {
        // The documented allowlist of non-usage event kinds must not
        // degrade parse health.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-knownevents-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000012", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeSummary(sessionDir, id: "019f0000-0000-0000-0000-000000000012")

        let events = [
            "{\"ts\":\"2026-07-14T00:05:03.819Z\",\"type\":\"mcp_config_resolved\","
                + "\"servers\":[],\"disabled\":[]}",
            "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
                + "\"session_id\":\"019f0000-0000-0000-0000-000000000012\",\"turn_number\":1,"
                + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
                + "\"session_relationship\":\"new\",\"schema_version\":1}",
            "{\"ts\":\"2026-07-14T00:05:04.575Z\",\"type\":\"loop_started\",\"loop_index\":0}",
            "{\"ts\":\"2026-07-14T00:05:06.443Z\",\"type\":\"first_token\"}",
            "{\"ts\":\"2026-07-14T00:05:17.045Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\","
                + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
                + "\"cachedReadTokens\":0,\"reasoningTokens\":0,\"modelCalls\":1,"
                + "\"apiDurationMs\":100,\"modelUsage\":{},\"numTurns\":1}}"
        ]
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (events.joined(separator: "\n") + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000012" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Known non-usage event kinds must not degrade parse health")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    func test_wrongShapedUsageOnKnownEventDegradesHealth() async throws {
        // A known event kind carrying a present-but-wrong-typed usage value
        // is still wrong-shaped input.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-eventbadusage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000013", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeSummary(sessionDir, id: "019f0000-0000-0000-0000-000000000013")

        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\",\"usage\":\"nope\"}"
        let usageEvent = "{\"ts\":\"2026-07-14T00:05:17.045Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,\"reasoningTokens\":0,\"modelCalls\":1,"
            + "\"apiDurationMs\":100,\"modelUsage\":{},\"numTurns\":1}}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000013" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Wrong-typed usage on a known event must degrade parse health")
    }

    // MARK: round-2 issue 4 — wrong-typed chat content

    func test_presentWrongTypedChatContentDegradesHealth() async throws {
        // A chat line with a PRESENT wrong-typed content value (number,
        // boolean, object, non-part array) is malformed input: it must
        // degrade the typed parse health, never be silently skipped
        // (round-2 scrutiny, issue 4). Legitimate content-less lines
        // (tool results, reasoning) remain ignorable.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-badcontent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000014", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeSummary(sessionDir, id: "019f0000-0000-0000-0000-000000000014")

        let usageLine = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000014\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (usageLine + "\n").write(to: updatesFile, atomically: true, encoding: .utf8)
        let chat = "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":42}\n"
            + "{\"type\":\"assistant\",\"content\":{\"type\":\"text\",\"text\":\"nested\"}}\n"
            + "{\"type\":\"assistant\",\"content\":[42, \"raw\"]}\n"
            + "{\"type\":\"assistant\",\"content\":\"hello\"}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000014" }
        XCTAssertNotNil(session, "Valid rows must survive wrong-typed chat siblings")
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000014" }
        XCTAssertEqual(conversation?.messageCount, 2, "Only well-formed chat lines count")
        XCTAssertTrue(conversation?.fullText.contains("hello") == true)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Present wrong-typed chat content must degrade parse health")
        XCTAssertGreaterThanOrEqual(parser.lastParseHealth.malformedLines, 3)
    }

    func test_contentLessChatLinesRemainIgnorable() async throws {
        // Legitimate content-less lines (tool results, reasoning) are not
        // malformed; only PRESENT wrong-typed content degrades.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-nocontent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000015", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeSummary(sessionDir, id: "019f0000-0000-0000-0000-000000000015")

        let usageLine = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000015\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (usageLine + "\n").write(to: updatesFile, atomically: true, encoding: .utf8)
        let chat = "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":\"hello\"}\n"
            + "{\"type\":\"tool_result\",\"tool_use_id\":\"t1\"}\n"
            + "{\"type\":\"assistant\",\"content\":null}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000015" }
        XCTAssertEqual(conversation?.messageCount, 2, "Content-less lines are not messages")
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Absent/null content is not malformed input")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }
}
