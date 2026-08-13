@testable import BurnBar
import XCTest

// MARK: - Grok CLI Parser Strictness Round 4 Tests

/// Round-4 scrutiny (parser-shape-strictness-repair-3.json, issues 1/2):
/// (1) allowlisted event validation must reject ABSENT and NSNull required
/// fields — optional-field semantics apply only to documented optional
/// keys, and the current shapes have none; (2) dictionary chat parts must
/// carry the `type == "text"` discriminator — a String `text` field alone
/// is not sufficient, and every other dictionary part shape increments
/// typed parse health.
@MainActor
final class GrokCLIParserStrictnessRound4Tests: XCTestCase {

    private func makeParser(sessionsRoot: String) -> GrokCLIParser {
        GrokCLIParser(sessionsRoot: sessionsRoot)
    }

    private func writeSummary(_ sessionDir: URL, id: String) throws {
        let summary = "{\"info\":{\"id\":\"\(id)\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
    }

    private func makeSessionDir(_ name: String, id: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-r4-\(name)-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = tempDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        try writeSummary(sessionDir, id: id)
        return sessionDir
    }

    private func usageEvent(_ id: String, input: Int) -> String {
        "{\"ts\":\"2026-07-14T00:05:17.045Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\","
            + "\"usage\":{\"inputTokens\":\(input),\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,\"reasoningTokens\":0,\"modelCalls\":1,"
            + "\"apiDurationMs\":100,\"modelUsage\":{},\"numTurns\":1}}"
    }

    private func updatesUsageLine(_ id: String, input: Int) -> String {
        "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"\(id)\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":\(input),\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
    }

    /// A fully shaped turn_started event (all required fields present with
    /// correct primitive types).
    private func shapedTurnStarted(_ id: String, turnNumber: String = "1") -> String {
        "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"\(id)\",\"turn_number\":\(turnNumber),"
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
    }

    // MARK: round-4 issue 1 — absent/null required event fields

    func test_turnStartedMissingOneRequiredFieldDegradesHealth() async throws {
        // A turn_started with ALL other fields present but `turn_number`
        // absent is still malformed: every listed field is required
        // (round-4 scrutiny, issue 1). The round-3 coverage only exercised
        // a bare {"type":"turn_started"}.
        let sessionDir = try makeSessionDir("missingone", id: "019f0000-0000-0000-0000-000000000040")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000040\","
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000040", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000040" }
        XCTAssertNotNil(session, "Valid usage rows must survive malformed allowlisted siblings")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "turn_started missing a required field must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_turnStartedMissingYoloModeDegradesHealth() async throws {
        // `yolo_mode` absent (all other required fields present) is
        // malformed — booleans are required fields too.
        let sessionDir = try makeSessionDir("missingyolo", id: "019f0000-0000-0000-0000-000000000041")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000041\",\"turn_number\":1,"
            + "\"model_id\":\"grok-4.5\",\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000041", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertNotNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000041" })
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "turn_started missing yolo_mode must degrade parse health")
    }

    func test_turnStartedMissingSchemaVersionDegradesHealth() async throws {
        // `schema_version` absent (all other required fields present) is
        // malformed.
        let sessionDir = try makeSessionDir("missingschema", id: "019f0000-0000-0000-0000-000000000042")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000042\",\"turn_number\":1,"
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\"}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000042", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertNotNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000042" })
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "turn_started missing schema_version must degrade parse health")
    }

    func test_bareLoopStartedWithoutLoopIndexDegradesHealth() async throws {
        // A bare {"type":"loop_started"} with no loop_index is malformed:
        // loop_index is a required field (round-4 scrutiny, issue 1).
        let sessionDir = try makeSessionDir("bareloop", id: "019f0000-0000-0000-0000-000000000043")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let bareEvent = "{\"ts\":\"2026-07-14T00:05:04.575Z\",\"type\":\"loop_started\"}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (bareEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000043", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertNotNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000043" })
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "loop_started without loop_index must degrade parse health")
    }

    func test_nullRequiredFieldDegradesHealth() async throws {
        // NSNull in a required field is malformed exactly like an absent
        // field: {"turn_number":null} and {"schema_version":null} must
        // degrade parse health (round-4 scrutiny, issue 1).
        let sessionDir = try makeSessionDir("nullfields", id: "019f0000-0000-0000-0000-000000000044")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let nullInt = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000044\",\"turn_number\":null,"
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
        let nullSchema = "{\"ts\":\"2026-07-14T00:05:04.469Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000044\",\"turn_number\":1,"
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":null}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (nullInt + "\n" + nullSchema + "\n"
            + usageEvent("019f0000-0000-0000-0000-000000000044", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertNotNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000044" })
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "NSNull in a required field must degrade parse health")
        XCTAssertGreaterThanOrEqual(parser.lastParseHealth.malformedLines, 2)
    }

    func test_fullyShapedAllowlistedEventsStayHealthy() async throws {
        // Control: canonical allowlisted events (every required field
        // present with the correct primitive type) must NOT degrade parse
        // health — the required-field rule must not reject valid events.
        let sessionDir = try makeSessionDir("canonical4", id: "019f0000-0000-0000-0000-000000000045")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let events = [
            "{\"ts\":\"2026-07-14T00:05:03.819Z\",\"type\":\"mcp_config_resolved\","
                + "\"servers\":[],\"disabled\":[]}",
            shapedTurnStarted("019f0000-0000-0000-0000-000000000045"),
            "{\"ts\":\"2026-07-14T00:05:04.575Z\",\"type\":\"loop_started\",\"loop_index\":0}",
            "{\"ts\":\"2026-07-14T00:05:06.443Z\",\"type\":\"first_token\"}",
            usageEvent("019f0000-0000-0000-0000-000000000045", input: 100)
        ]
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (events.joined(separator: "\n") + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertNotNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000045" })
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Canonical allowlisted events must not degrade parse health")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: round-4 issue 2 — dictionary chat part type discriminator

    func test_dictionaryPartWithWrongTypeDiscriminatorDegradesHealth() async throws {
        // {"type":"image","text":"..."} carries a String text field but the
        // type discriminator is not "text": it must NOT contribute
        // conversation text and must degrade typed parse health (round-4
        // scrutiny, issue 2).
        let sessionDir = try makeSessionDir("wrongdisc", id: "019f0000-0000-0000-0000-000000000046")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000046", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let chat = "{\"type\":\"assistant\",\"content\":[{\"type\":\"image\",\"text\":\"alt text\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"real text\"}]}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000046" }
        XCTAssertNotNil(session, "Valid rows must survive malformed chat-part siblings")
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000046" }
        XCTAssertEqual(conversation?.messageCount, 1, "Only the text-discriminated part counts as a message")
        XCTAssertTrue(conversation?.fullText.contains("real text") == true)
        XCTAssertFalse(conversation?.fullText.contains("alt text") == true,
                       "A non-text part must never contribute conversation text")
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Dictionary part with a wrong type discriminator must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_dictionaryPartWithMissingTypeDiscriminatorDegradesHealth() async throws {
        // {"text":"..."} with NO type field is malformed: the discriminator
        // is required even when text is a String (round-4 scrutiny,
        // issue 2).
        let sessionDir = try makeSessionDir("missingdisc", id: "019f0000-0000-0000-0000-000000000047")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000047", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let chat = "{\"type\":\"assistant\",\"content\":[{\"text\":\"no discriminator\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000047" }
        XCTAssertEqual(conversation?.messageCount, 1, "Only text-discriminated parts count as messages")
        XCTAssertTrue(conversation?.fullText.contains("ok") == true)
        XCTAssertFalse(conversation?.fullText.contains("no discriminator") == true)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Dictionary part without a type discriminator must degrade parse health")
    }

    func test_textDiscriminatedPartsStayHealthy() async throws {
        // Control: {"type":"text","text":...} parts (the documented shape)
        // must stay healthy and contribute text.
        let sessionDir = try makeSessionDir("gooddisc", id: "019f0000-0000-0000-0000-000000000048")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000048", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let chat = "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000048" }
        XCTAssertEqual(conversation?.messageCount, 2)
        XCTAssertTrue(conversation?.fullText.contains("hello") == true)
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Text-discriminated parts must not degrade parse health")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }
}
