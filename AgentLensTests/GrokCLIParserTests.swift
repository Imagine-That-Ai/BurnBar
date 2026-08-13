@testable import BurnBar
import XCTest

// MARK: - Grok CLI Parser Tests

/// VAL-PROV-005/006/007/013/014/015/016/017: GrokCLIParser parses real-shaped
/// `~/.grok/sessions/<url-encoded-project>/` session directories into
/// TokenUsage rows with honest degradation for malformed/empty/missing inputs.
@MainActor
final class GrokCLIParserTests: XCTestCase {

    private var fixturesRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/grok/sessions", isDirectory: true)
            .path
    }

    private func makeParser(sessionsRoot: String? = nil) -> GrokCLIParser {
        GrokCLIParser(sessionsRoot: sessionsRoot ?? fixturesRoot)
    }

    // MARK: VAL-PROV-005 — real-shaped sessions

    func test_parsesRealShapedSessions() async throws {
        let result = try await makeParser().parse()
        let usages = result.usages

        // Session 1: %2FUsers%2Falbertonunez/019f5df0-… with summary cwd
        // /Users/albertonunez; usage from updates.jsonl turn_completed.
        let session1 = usages.first { $0.sessionId == "019f5df0-f85a-7fb3-9a08-7a957d5f0893" }
        XCTAssertNotNil(session1, "Real-shaped session 1 must parse")
        XCTAssertEqual(session1?.provider, .grokCLI)
        XCTAssertEqual(session1?.projectName, "/Users/albertonunez")
        XCTAssertEqual(session1?.model, "grok-4.5")
        XCTAssertEqual(session1?.inputTokens, 28476)
        XCTAssertEqual(session1?.outputTokens, 416)
        XCTAssertEqual(session1?.cacheReadTokens, 11264)
        XCTAssertEqual(
            session1?.startTime,
            Self.isoDate("2026-07-14T00:05:01.332073Z")
        )
        XCTAssertEqual(
            session1?.endTime,
            Self.isoDate("2026-07-14T00:05:17.045026Z")
        )
        XCTAssertGreaterThan(session1?.cost ?? 0, 0)

        // Session 2: %2FUsers%2Falbertonunez%2FDocuments%2FDeveloper%2FMy%2520App
        // dir; the summary cwd (/Users/albertonunez/Documents/Developer/My App)
        // is authoritative over the URL-decoded dir name.
        let session2 = usages.first { $0.sessionId == "019f75d7-c41c-7e80-9bf2-91f610480d17" }
        XCTAssertNotNil(session2, "Real-shaped session 2 must parse")
        XCTAssertEqual(session2?.projectName, "/Users/albertonunez/Documents/Developer/My App")
        XCTAssertEqual(session2?.model, "grok-4.5")
        XCTAssertEqual(session2?.inputTokens, 15000)
        XCTAssertEqual(session2?.outputTokens, 800)
        XCTAssertEqual(session2?.cacheReadTokens, 3000)
    }

    func test_eventsFallbackUsageSource() async throws {
        // 019fc5a8-…ed9 has no updates.jsonl; usage comes from events.jsonl
        // turn_ended frames.
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019fc5a8-19e4-71d0-99ad-ba073a3c0ed9" }
        XCTAssertNotNil(session, "Events-only session must parse")
        XCTAssertEqual(session?.inputTokens, 7000)
        XCTAssertEqual(session?.outputTokens, 150)
        XCTAssertEqual(session?.cacheReadTokens, 500)
    }

    func test_conversationRecordsProduced() async throws {
        let result = try await makeParser().parse()
        let conversations = result.conversations
        XCTAssertTrue(conversations.contains { $0.sessionId == "019f5df0-f85a-7fb3-9a08-7a957d5f0893" })
        let first = conversations.first { $0.sessionId == "019f5df0-f85a-7fb3-9a08-7a957d5f0893" }
        XCTAssertEqual(first?.provider, .grokCLI)
        XCTAssertEqual(first?.projectName, "/Users/albertonunez")
        XCTAssertEqual(first?.messageCount, 4)
        XCTAssertTrue(first?.fullText.contains("cleanup script") == true)
    }

    // MARK: VAL-PROV-006 — missing directory

    func test_missingDirectoryReturnsEmpty() async throws {
        let parser = makeParser(sessionsRoot: "/nonexistent/grok/sessions")
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertFalse(parser.lastParseHealth.isDegraded)
    }

    // MARK: VAL-PROV-007 — malformed lines degrade without corruption

    func test_malformedLinesDegradeWithoutDroppingValidRows() async throws {
        // The real-shaped sessions contain no malformed lines; the parse
        // health must be healthy for them. Malformed-line behavior is
        // exercised by the torn-tail fixture below.
        let parser = makeParser()
        let result = try await parser.parse()
        XCTAssertFalse(parser.lastParseHealth.isDegraded)
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
        XCTAssertEqual(result.usages.count, 5)
    }

    func test_tornTailLineIsSkippedNotHalfParsed() async throws {
        // A session whose updates.jsonl ends with a torn multi-byte sequence
        // must still parse its valid rows and skip the torn tail.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-torn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000001", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000001\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)

        let validLine = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000001\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\",\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
        let tornTail = "{\"timestamp\":1783987508,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000001\","
            + "\"update\":{\"sessionUpdate\":\"agent_thought_chunk\","
            + "\"content\":{\"type\":\"text\",\"text\":\"torn \u{1F680}"
        let data = (validLine + "\n" + tornTail).data(using: .utf8)!
        try data.write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000001" }
        XCTAssertNotNil(session, "Valid rows must survive the torn tail")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertEqual(session?.outputTokens, 20)
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Torn tail must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: VAL-PROV-013 — empty and zero-byte files

    func test_sessionWithoutUsageIsSkipped() async throws {
        // 019fc5a8-…eda has summary + chat but no usage frames: honest skip.
        let result = try await makeParser().parse()
        XCTAssertNil(result.usages.first { $0.sessionId == "019fc5a8-19e4-71d0-99ad-ba073a3c0eda" })
    }

    func test_emptySessionDirectoryIsSilentNoOp() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000002", isDirectory: true),
            withIntermediateDirectories: true
        )
        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertFalse(parser.lastParseHealth.isDegraded)
    }

    // MARK: VAL-PROV-015 — timestamp variants

    func test_timestampVariantsParseHonestly() async throws {
        let result = try await makeParser().parse()

        // (a) ISO-8601 fractional (6-digit) from summary.json
        let fractional = result.usages.first { $0.sessionId == "019f5df0-f85a-7fb3-9a08-7a957d5f0893" }
        XCTAssertEqual(fractional?.startTime, Self.isoDate("2026-07-14T00:05:01.332073Z"))

        // (b) no fraction
        let noFraction = result.usages.first { $0.sessionId == "019f75d7-c41c-7e80-9bf2-91f610480d17" }
        XCTAssertEqual(noFraction?.startTime, Self.isoDate("2026-07-15T10:00:00Z"))

        // (c) fractional 3-digit + no-fraction end
        let mixed = result.usages.first { $0.sessionId == "019f7bb7-de81-7623-8058-60c31dd48eb0" }
        XCTAssertEqual(mixed?.startTime, Self.isoDate("2026-07-16T08:00:00.123Z"))
        XCTAssertEqual(mixed?.endTime, Self.isoDate("2026-07-16T08:00:03Z"))

        for usage in result.usages {
            XCTAssertNotEqual(usage.startTime.timeIntervalSince1970, 0, "Never epoch-zero")
            XCTAssertNotEqual(usage.endTime.timeIntervalSince1970, 0, "Never epoch-zero")
        }
    }

    // MARK: VAL-PROV-016 — URL-encoded project dirs

    func test_urlEncodedProjectDirsDecode() async throws {
        let result = try await makeParser().parse()
        // %2FUsers%2Falbertonunez → /Users/albertonunez
        XCTAssertNotNil(result.usages.first { $0.projectName == "/Users/albertonunez" })
        // %2FUsers%2Falbertonunez%2FDocuments%2FDeveloper%2Fimaginethat-llc → decoded path
        let decoded = "/Users/albertonunez/Documents/Developer/imaginethat-llc"
        XCTAssertNotNil(result.usages.first { $0.projectName == decoded })
        // %E3%83%97%E3%83%AD%E3%82%B8%E3%82%A7%E3%82%AF%E3%83%88%F0%9F%9A%80 → プロジェクト🚀
        let unicode = "/Users/albertonunez/Documents/Developer/プロジェクト🚀"
        XCTAssertNotNil(result.usages.first { $0.projectName == unicode })
    }

    func test_decodeProjectNamePercentEscapes() {
        XCTAssertEqual(GrokCLIParser.decodeProjectName("%2FUsers%2Falbertonunez"), "/Users/albertonunez")
        XCTAssertEqual(GrokCLIParser.decodeProjectName("My%20App"), "My App")
        XCTAssertEqual(GrokCLIParser.decodeProjectName("caf%C3%A9"), "café")
        let unicode = "%E3%83%97%E3%83%AD%E3%82%B8%E3%82%A7%E3%82%AF%E3%83%88%F0%9F%9A%80"
        XCTAssertEqual(GrokCLIParser.decodeProjectName(unicode), "プロジェクト🚀")
        // Undecodable names pass through unchanged.
        XCTAssertEqual(GrokCLIParser.decodeProjectName("100%"), "100%")
    }

    // MARK: strictness repair — double-encoded project dirs

    func test_decodeProjectName_doubleEncodedResolvesUntilStable() {
        // The real agent double-encodes spaces in project dirs
        // (`My%2520App` → `My App`); the fallback decoder must resolve the
        // checked-in double-encoded fixture (usage-parsers scrutiny,
        // reviewer issue 6).
        XCTAssertEqual(
            GrokCLIParser.decodeProjectName("%2FUsers%2Falbertonunez%2FDocuments%2FDeveloper%2FMy%2520App"),
            "/Users/albertonunez/Documents/Developer/My App"
        )
        // Triple-encoded values also resolve.
        XCTAssertEqual(GrokCLIParser.decodeProjectName("My%252520App"), "My App")
        // A lone % stops the loop and keeps the last decoded form.
        XCTAssertEqual(GrokCLIParser.decodeProjectName("100%25"), "100%")
        XCTAssertEqual(GrokCLIParser.decodeProjectName("100%"), "100%")
    }

    func test_doubleEncodedProjectDirFallbackWhenCwdAbsent() async throws {
        // A session whose summary has no cwd and whose dir name is
        // double-encoded must resolve the project name through the fallback.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-dblenc-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000003", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000003\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let validLine = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000003\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (validLine + "\n").write(to: updatesFile, atomically: true, encoding: .utf8)

        let projectDir = tempDir.appendingPathComponent("My%2520App", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let movedSession = projectDir.appendingPathComponent("019f0000-0000-0000-0000-000000000003")
        try FileManager.default.moveItem(at: sessionDir, to: movedSession)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first {
            $0.sessionId == "019f0000-0000-0000-0000-000000000003"
        }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.projectName, "My App", "Double-encoded dir must resolve via the fallback")
    }

    // MARK: strictness repair — wrong-shape lines degrade parse health

    func test_wrongShapeUpdateLineDegradesHealthWithoutDroppingValidRows() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-wrongshape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000004", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000004\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)

        let validLine = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000004\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\",\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
        let wrongShape = "{\"timestamp\":1783987508,\"method\":\"session/update\",\"params\":{\"sessionId\":\"x\"}}"
        let data = (validLine + "\n" + wrongShape).data(using: .utf8)!
        try data.write(to: sessionDir.appendingPathComponent("updates.jsonl"))

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000004" }
        XCTAssertNotNil(session, "Valid rows must survive wrong-shape siblings")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertEqual(session?.outputTokens, 20)
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Wrong-shape update line must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_malformedUsageFieldDegradesHealthNotSilentlyCoerced() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-badusage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000005", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000005\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)

        let line = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000005\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\","
            + "\"prompt_id\":\"p1\",\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":\"not-a-number\",\"outputTokens\":20,"
            + "\"totalTokens\":120,\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (line + "\n").write(to: updatesFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000005" }
        XCTAssertNotNil(session, "Row with a valid output field must survive")
        XCTAssertEqual(session?.inputTokens, 0, "Malformed input must not be coerced")
        XCTAssertEqual(session?.outputTokens, 20, "Valid output must be preserved")
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Malformed usage field must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_wrongShapeChatLineDegradesHealth() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-badchat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000006", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000006\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let usageLine = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000006\","
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
            + "{\"content\":\"no type field\"}\n"
            + "{\"type\":\"assistant\",\"content\":\"hello\"}\n"
        try chat.write(to: sessionDir.appendingPathComponent("chat_history.jsonl"), atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000006" }
        XCTAssertNotNil(session, "Valid rows must survive wrong-shape chat lines")
        let conversation = result.conversations.first { $0.sessionId == "019f0000-0000-0000-0000-000000000006" }
        XCTAssertEqual(conversation?.messageCount, 2, "Valid chat lines still count")
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Wrong-shape chat line must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: strictness repair — numeric update timestamps

    func test_invalidNumericTimestampsNeverEmitEpochZeroRows() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-badts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000007", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        // Summary has NO timestamps; the only timestamps come from the
        // update frames. A zero timestamp must not become an epoch-zero row.
        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000007\",\"cwd\":\"/Users/test/proj\"},"
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let zeroTs = "{\"timestamp\":0,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000007\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":0}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (zeroTs + "\n").write(to: updatesFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        XCTAssertNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000007" },
                     "Zero timestamp must skip the session honestly, never emit an epoch-zero row")
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Invalid numeric timestamp must degrade parse health")
    }

    func test_negativeAndNonNumericTimestampsDegradeHonestly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-negts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000008", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000008\",\"cwd\":\"/Users/test/proj\"},"
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let negTs = "{\"timestamp\":-5,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000008\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":0}}}"
        let stringTs = "{\"timestamp\":\"not-a-number\",\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000008\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e2\",\"agentTimestampMs\":0}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (negTs + "\n" + stringTs).write(to: updatesFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        XCTAssertNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000008" })
        XCTAssertTrue(parser.lastParseHealth.isDegraded)
        XCTAssertGreaterThanOrEqual(parser.lastParseHealth.malformedLines, 2)
    }

    func test_validNumericTimestampStillParses() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-okts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000009", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000009\",\"cwd\":\"/Users/test/proj\"},"
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let okTs = "{\"timestamp\":1783987507.5,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000009\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
            + "\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507500}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (okTs + "\n").write(to: updatesFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-000000000009" }
        XCTAssertNotNil(session, "Valid positive numeric timestamps must parse")
        XCTAssertEqual(session?.startTime.timeIntervalSince1970, 1783987507.5)
        XCTAssertFalse(parser.lastParseHealth.isDegraded)
    }

    // MARK: strictness repair — exact integer bounds and checked accumulation

    func test_strictIntExactBoundaryValues() {
        var malformed = false
        // Int64.max is representable as Int on 64-bit.
        XCTAssertEqual(GrokCLIParser.strictInt(NSNumber(value: Int64.max), malformed: &malformed), Int.max)
        XCTAssertFalse(malformed)
        // 2^63 (Double(Int.max) rounds to this) must be rejected, never trap.
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(NSNumber(value: Double(Int64.max)), malformed: &malformed), 0)
        XCTAssertTrue(malformed, "Double(Int.max) boundary value must be rejected")
        // Huge non-integral values are rejected.
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(NSNumber(value: 1e19), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        // Booleans, fractional, negative, and string values are rejected.
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(NSNumber(value: true), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(NSNumber(value: 5.5), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(NSNumber(value: -1), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt("5", malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        // Integral doubles and absent/null fields are accepted.
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(NSNumber(value: 5.0), malformed: &malformed), 5)
        XCTAssertFalse(malformed)
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(nil, malformed: &malformed), 0)
        XCTAssertFalse(malformed, "Absent field is not malformed")
        malformed = false
        XCTAssertEqual(GrokCLIParser.strictInt(NSNull(), malformed: &malformed), 0)
        XCTAssertFalse(malformed, "Null field is not malformed")
    }

    func test_checkedAccumulationSaturatesInsteadOfTrapping() {
        XCTAssertEqual(GrokCLIParser.addingChecked(10, 5), 15)
        XCTAssertEqual(GrokCLIParser.addingChecked(Int.max, 1), Int.max, "Overflow must saturate, never trap")
        XCTAssertEqual(GrokCLIParser.addingChecked(Int.max - 1, 1), Int.max)
    }

    func test_hugeUsageValuesNeverTrap() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-huge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-000000000010", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-000000000010\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        let line1 = "{\"timestamp\":1783987507,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000010\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p1\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":9223372036854775807,\"outputTokens\":10,"
            + "\"totalTokens\":120,\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e1\",\"agentTimestampMs\":1783987507000}}}"
        let line2 = "{\"timestamp\":1783987508,\"method\":\"session/update\","
            + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-000000000010\","
            + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p2\","
            + "\"stop_reason\":\"completed\","
            + "\"usage\":{\"inputTokens\":9223372036854775808,\"outputTokens\":20,"
            + "\"totalTokens\":120,\"cachedReadTokens\":0,"
            + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
            + "\"modelUsage\":{},\"numTurns\":1}},"
            + "\"_meta\":{\"eventId\":\"e2\",\"agentTimestampMs\":1783987508000}}}"
        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        try (line1 + "\n" + line2).write(to: updatesFile, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first {
            $0.sessionId == "019f0000-0000-0000-0000-000000000010"
        }
        XCTAssertNotNil(session, "Boundary usage values must not crash the parser")
        XCTAssertEqual(session?.inputTokens, Int.max, "Int64.max is accepted; 2^63 is rejected")
        XCTAssertEqual(session?.outputTokens, 30)
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "2^63 usage value must degrade parse health")
    }

    // MARK: VAL-PROV-017 — unknown model never fabricated exact $0.00

    func test_unknownModelCostIsNotExactZero() async throws {
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019fc5a4-7846-7853-af1d-681599d64f12" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.model, "grok-4.5-ultra-unknown")
        // Fallback pricing (2.5/10 per M) yields a non-zero cost for 5000/200 tokens.
        XCTAssertGreaterThan(session?.cost ?? 0, 0)
    }

    // MARK: helpers

    private static func isoDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: string)
        }()
    }
}
