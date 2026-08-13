@testable import BurnBar
import XCTest

// MARK: - Grok CLI Parser Strictness Round 3 Tests

/// Round-3 scrutiny (parser-shape-strictness-repair-2.json, issues 2/3/4):
/// (2) every allowlisted event NAME must also validate its payload shape —
/// an allowlisted name with a malformed payload degrades typed parse health;
/// (3) when updates.jsonl supplies usage, events.jsonl is still scanned for
/// malformed-shape health WITHOUT double-counting usage; (4) malformed
/// DICTIONARY chat parts must degrade typed parse health instead of being
/// silently dropped.
@MainActor
final class GrokCLIParserStrictnessRound3Tests: XCTestCase {

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
            .appendingPathComponent("grok-r3-\(name)-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: round-3 issue 2 — allowlisted event names need strict shape validation

    func test_allowlistedEventWithWrongTypedRequiredFieldDegradesHealth() async throws {
        // {"type":"turn_started","turn_number":"not-a-number"} is an
        // allowlisted NAME with a malformed payload: it must degrade the
        // typed parse health, never be treated as healthy.
        let sessionDir = try makeSessionDir("badshape", id: "019f0000-0000-0000-0000-000000000021")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000021\",\"turn_number\":\"not-a-number\","
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000021", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000021" }
        XCTAssertNotNil(session, "Valid usage rows must survive malformed allowlisted siblings")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Allowlisted event with a wrong-typed required field must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_allowlistedEventWithMissingRequiredFieldDegradesHealth() async throws {
        // A bare {"type":"turn_started"} object is an allowlisted NAME with
        // a malformed payload (missing required fields): typed malformed.
        let sessionDir = try makeSessionDir("missing", id: "019f0000-0000-0000-0000-000000000022")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let bareEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\"}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (bareEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000022", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000022" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Allowlisted event missing required fields must degrade parse health")
    }

    func test_allowlistedEventWithWrongTypedOptionalFieldDegradesHealth() async throws {
        // loop_started with a wrong-typed loop_index (string) is malformed.
        let sessionDir = try makeSessionDir("badoptional", id: "019f0000-0000-0000-0000-000000000023")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.575Z\",\"type\":\"loop_started\",\"loop_index\":\"zero\"}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000023", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000023" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Allowlisted event with a wrong-typed optional field must degrade parse health")
    }

    func test_allowlistedEventWithBooleanWhereIntegerRequiredDegradesHealth() async throws {
        // A JSON boolean in an integer field is wrong-typed (strict
        // primitive validation, mirroring the daemon's NSNumber-boolean
        // rejection).
        let sessionDir = try makeSessionDir("boolint", id: "019f0000-0000-0000-0000-000000000024")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000024\",\"turn_number\":true,"
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000024", input: 100) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000024" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Boolean in an integer field must degrade parse health")
    }

    func test_fullyShapedAllowlistedEventsStayHealthy() async throws {
        // Control: canonical allowlisted events (all required fields with
        // correct primitive types) must NOT degrade parse health.
        let sessionDir = try makeSessionDir("canonical", id: "019f0000-0000-0000-0000-000000000025")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let events = [
            "{\"ts\":\"2026-07-14T00:05:03.819Z\",\"type\":\"mcp_config_resolved\","
                + "\"servers\":[],\"disabled\":[]}",
            "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
                + "\"session_id\":\"019f0000-0000-0000-0000-000000000025\",\"turn_number\":1,"
                + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
                + "\"session_relationship\":\"new\",\"schema_version\":1}",
            "{\"ts\":\"2026-07-14T00:05:04.575Z\",\"type\":\"loop_started\",\"loop_index\":0}",
            "{\"ts\":\"2026-07-14T00:05:06.443Z\",\"type\":\"first_token\"}",
            usageEvent("019f0000-0000-0000-0000-000000000025", input: 100)
        ]
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (events.joined(separator: "\n") + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000025" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Canonical allowlisted events must not degrade parse health")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: round-3 issue 3 — secondary events scanned for health when updates supplies usage

    func test_malformedSecondaryEventsDegradeHealthWhenUpdatesSuppliesUsage() async throws {
        // Normal two-file layout: updates.jsonl provides usage, events.jsonl
        // carries a malformed allowlisted event. The events stream must be
        // scanned for parse health WITHOUT double-counting usage.
        let sessionDir = try makeSessionDir("secondary", id: "019f0000-0000-0000-0000-000000000026")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000026", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
            + "\"session_id\":\"019f0000-0000-0000-0000-000000000026\",\"turn_number\":\"nope\","
            + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
            + "\"session_relationship\":\"new\",\"schema_version\":1}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000026" }
        XCTAssertNotNil(session, "Usage from updates.jsonl must still produce a row")
        XCTAssertEqual(session?.inputTokens, 100, "Usage must come from updates.jsonl only")
        XCTAssertEqual(session?.outputTokens, 20)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Malformed secondary events must degrade parse health even when updates supplies usage")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_secondaryEventsWithUsageAreNotDoubleCounted() async throws {
        // events.jsonl carries BOTH a malformed allowlisted event AND a
        // turn_ended usage frame. updates.jsonl supplies usage; the events
        // usage must NOT be double-counted, but the malformed event must
        // still degrade health.
        let sessionDir = try makeSessionDir("nocount", id: "019f0000-0000-0000-0000-000000000027")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000027", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let badEvent = "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\",\"turn_number\":\"nope\"}"
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (badEvent + "\n" + usageEvent("019f0000-0000-0000-0000-000000000027", input: 500) + "\n")
            .write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000027" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100,
                       "Events usage must not be double-counted when updates supplies usage")
        XCTAssertEqual(session?.outputTokens, 20)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Malformed secondary event must degrade health")
    }

    func test_healthySecondaryEventsStayHealthyWhenUpdatesSuppliesUsage() async throws {
        // Control: canonical events.jsonl alongside updates.jsonl usage must
        // not degrade parse health.
        let sessionDir = try makeSessionDir("healthy2", id: "019f0000-0000-0000-0000-000000000028")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000028", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let events = [
            "{\"ts\":\"2026-07-14T00:05:04.468Z\",\"type\":\"turn_started\","
                + "\"session_id\":\"019f0000-0000-0000-0000-000000000028\",\"turn_number\":1,"
                + "\"model_id\":\"grok-4.5\",\"yolo_mode\":false,\"conversation_message_count\":0,"
                + "\"session_relationship\":\"new\",\"schema_version\":1}",
            "{\"ts\":\"2026-07-14T00:05:17.045Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\"}"
        ]
        let eventsFile = sessionDir.appendingPathComponent("events.jsonl")
        try (events.joined(separator: "\n") + "\n").write(to: eventsFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000028" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Healthy secondary events must not degrade parse health")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: round-3 issue 4 — malformed dictionary chat parts

    func test_malformedDictionaryChatPartsDegradeHealth() async throws {
        // content:[{"type":"image","url":"x"}] and content:[{"other":"value"}]
        // are dictionary parts that do NOT match the documented text-part
        // shape: they must degrade typed parse health, never be silently
        // dropped.
        let sessionDir = try makeSessionDir("badparts", id: "019f0000-0000-0000-0000-000000000029")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000029", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let chat = "{\"type\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":[{\"type\":\"image\",\"url\":\"x\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":[{\"other\":\"value\"}]}\n"
            + "{\"type\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hello\"}]}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000029" }
        XCTAssertNotNil(session, "Valid rows must survive malformed chat-part siblings")
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000029" }
        XCTAssertEqual(conversation?.messageCount, 2, "Only well-formed text parts count as messages")
        XCTAssertTrue(conversation?.fullText.contains("hello") == true)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Malformed dictionary chat parts must degrade parse health")
        XCTAssertGreaterThanOrEqual(parser.lastParseHealth.malformedLines, 2)
    }

    func test_mixedTextAndToolCallPartsStayHealthy() async throws {
        // Control: real-shaped assistant lines carry text parts alongside
        // tool_calls; the text part is extracted and the line stays healthy.
        let sessionDir = try makeSessionDir("toolcalls", id: "019f0000-0000-0000-0000-000000000030")
        defer { try? FileManager.default.removeItem(at: sessionDir.deletingLastPathComponent()) }
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (updatesUsageLine("019f0000-0000-0000-0000-000000000030", input: 100) + "\n")
            .write(to: updatesFile, atomically: true, encoding: .utf8)
        let chat = "{\"type\":\"assistant\",\"content\":\"I'll inspect the disk usage.\","
            + "\"tool_calls\":[{\"id\":\"call-1\",\"name\":\"run_terminal_command\","
            + "\"arguments\":\"{\\\"command\\\":\\\"df -h\\\"}\"}],"
            + "\"model_id\":\"grok-4.5\",\"model_fingerprint\":\"fp_1\",\"reasoning_effort\":\"high\"}\n"
            + "{\"type\":\"assistant\",\"content\":\"Done.\",\"status\":\"completed\"}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: sessionDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000030" }
        XCTAssertEqual(conversation?.messageCount, 2)
        XCTAssertTrue(conversation?.fullText.contains("I'll inspect") == true)
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Real-shaped assistant lines with tool_calls must stay healthy")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }
}
