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
