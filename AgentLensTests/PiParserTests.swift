@testable import BurnBar
import XCTest

// MARK: - Pi Parser Tests

/// VAL-PROV-004/006/007/011/013/014/015/016/017: PiParser parses real-shaped
/// `~/.pi/agent/sessions/<project-dir>/*.jsonl` transcripts into TokenUsage
/// rows with honest degradation for malformed/empty/missing inputs.
@MainActor
final class PiParserTests: XCTestCase {

    private var fixturesRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/pi/agent/sessions", isDirectory: true)
            .path
    }

    private func makeParser(sessionsRoot: String? = nil) -> PiParser {
        PiParser(sessionsRoot: sessionsRoot ?? fixturesRoot)
    }

    // MARK: VAL-PROV-004 — real-shaped transcripts

    func test_parsesRealShapedTranscripts() async throws {
        let result = try await makeParser().parse()
        let usages = result.usages

        // Session 1: --Users-albertonunez-- with cwd /Users/albertonunez
        let session1 = usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e127" }
        XCTAssertNotNil(session1, "Real-shaped session 1 must parse")
        XCTAssertEqual(session1?.provider, .pi)
        XCTAssertEqual(session1?.projectName, "/Users/albertonunez")
        XCTAssertEqual(session1?.model, "deepseek-v4-flash")
        XCTAssertEqual(session1?.inputTokens, 4302 + 5120)
        XCTAssertEqual(session1?.outputTokens, 199 + 88)
        XCTAssertEqual(session1?.cacheReadTokens, 2048)
        XCTAssertEqual(session1?.cacheCreationTokens, 0)
        XCTAssertEqual(
            session1?.startTime,
            Self.isoDate("2026-08-10T23:06:04.080Z")
        )
        XCTAssertEqual(
            session1?.endTime,
            Self.isoDate("2026-08-11T00:04:02.000Z")
        )
        XCTAssertGreaterThan(session1?.cost ?? 0, 0)

        // Session 2: --Users-albertonunez-Documents-Developer-imaginethat-llc--
        // with cwd /Users/albertonunez/Documents/Developer/imaginethat-llc
        // (the real hyphenated-component encoding; cwd is authoritative).
        let session2 = usages.first { $0.sessionId == "019fec49-f825-7f5f-895e-004e4300057d" }
        XCTAssertNotNil(session2, "Real-shaped session 2 must parse")
        XCTAssertEqual(session2?.provider, .pi)
        XCTAssertEqual(session2?.projectName, "/Users/albertonunez/Documents/Developer/imaginethat-llc")
        XCTAssertEqual(session2?.model, "deepseek-v4-flash")
        XCTAssertEqual(session2?.inputTokens, 1200)
        XCTAssertEqual(session2?.outputTokens, 240)
        XCTAssertEqual(
            session2?.startTime,
            Self.isoDate("2026-08-10T15:28:18.469Z")
        )
        XCTAssertEqual(
            session2?.endTime,
            Self.isoDate("2026-08-10T15:28:25.300Z")
        )
    }

    func test_conversationRecordsProduced() async throws {
        let result = try await makeParser().parse()
        let conversations = result.conversations
        XCTAssertTrue(conversations.contains { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e127" })
        XCTAssertTrue(conversations.contains { $0.sessionId == "019fec49-f825-7f5f-895e-004e4300057d" })
        let first = conversations.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e127" }
        XCTAssertEqual(first?.provider, .pi)
        XCTAssertEqual(first?.projectName, "/Users/albertonunez")
        XCTAssertEqual(first?.messageCount, 3)
        XCTAssertEqual(first?.userWordCount, 9)
        XCTAssertGreaterThan(first?.assistantWordCount ?? 0, 0)
        XCTAssertTrue(first?.fullText.contains("babysit the pr") == true)
    }

    // MARK: VAL-PROV-011/016 — project-name decoding

    func test_projectNameDecoding_splitOnlyOnDoubleHyphen() {
        // Contract split rule: split only on `--` boundaries; single hyphens
        // inside one path component are preserved.
        XCTAssertEqual(PiParser.decodeProjectName("--Users-test--proj"), "/Users-test/proj")
        XCTAssertEqual(PiParser.decodeProjectName("--Users-test--my-cool-proj"), "/Users-test/my-cool-proj")
        XCTAssertEqual(PiParser.decodeProjectName("--Users-albertonunez--"), "/Users-albertonunez")
        // The real encoding (`--` + `-`-joined components + `--`) is ambiguous
        // for hyphenated components: the contract rule yields one component.
        XCTAssertEqual(
            PiParser.decodeProjectName("--Users-albertonunez-Documents-Developer-imaginethat-llc--"),
            "/Users-albertonunez-Documents-Developer-imaginethat-llc"
        )
        // Percent-encoded components decode to their Unicode form.
        let encoded = "--Users-test--caf%C3%A9--%E3%83%97%E3%83%AD%E3%82%B8%E3%82%A7%E3%82%AF%E3%83%88%F0%9F%9A%80"
        XCTAssertEqual(
            PiParser.decodeProjectName(encoded),
            "/Users-test/café/プロジェクト🚀"
        )
        // Non-slug names pass through unchanged.
        XCTAssertEqual(PiParser.decodeProjectName("plain-name"), "plain-name")
    }

    func test_cwdFieldIsAuthoritativeOverSlugDecode() async throws {
        // The real encoding is ambiguous for hyphenated components
        // (imaginethat-llc); the transcript line-1 cwd must win.
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019fec49-f825-7f5f-895e-004e4300057d" }
        XCTAssertEqual(session?.projectName, "/Users/albertonunez/Documents/Developer/imaginethat-llc")
    }

    func test_slugFallbackWhenCwdAbsent() async throws {
        // --Users-test--my-cool-proj has no cwd line: slug decode applies
        // (split only on `--`; the single hyphen is preserved).
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e211" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.projectName, "/Users-test/my-cool-proj")
    }

    func test_unicodeSlugDecode() async throws {
        // --Users-test--caf%C3%A9--%E3%83%97%E3%83%AD%E3%82%B8%E3%82%A7%E3%82%AF%E3%83%88%F0%9F%9A%80
        // decodes to /Users-test/café/プロジェクト🚀 (percent-decoded components).
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e212" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.projectName, "/Users-test/café/プロジェクト🚀")
    }

    // MARK: VAL-PROV-006 — missing directory

    func test_missingDirectoryReturnsEmpty() async throws {
        let parser = makeParser(sessionsRoot: "/nonexistent/pi/sessions")
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertFalse(parser.lastParseHealth.isDegraded)
    }

    // MARK: VAL-PROV-007 — malformed lines degrade without corruption

    func test_malformedLinesDegradeWithoutDroppingValidRows() async throws {
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e200" }
        XCTAssertNotNil(session, "Valid rows must survive malformed siblings")
        XCTAssertEqual(session?.inputTokens, 100 + 200 + 300)
        XCTAssertEqual(session?.outputTokens, 50 + 80 + 90)
    }

    func test_parseHealthReportsMalformedLines() async throws {
        let parser = makeParser()
        _ = try await parser.parse()
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Malformed lines must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
        XCTAssertGreaterThan(parser.lastParseHealth.itemsScanned, 0)
        XCTAssertGreaterThan(parser.lastParseHealth.itemsParsed, 0)
    }

    func test_cleanFixturesReportHealthyParse() async throws {
        // A tree with only well-formed transcripts stays healthy.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-health-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_abc.jsonl")
        let sessionLine = """
        {"type":"session","version":3,"id":"abc","timestamp":"2026-08-11T00:00:00.000Z","cwd":"/Users/test/proj"}
        """
        let messageLine = "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,"
            + "\"timestamp\":\"2026-08-11T00:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}],"
            + "\"api\":\"openai-completions\",\"provider\":\"deepseek\",\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":10,\"output\":5,\"cacheRead\":0,\"cacheWrite\":0,\"reasoning\":0,"
            + "\"totalTokens\":15,\"cost\":{\"total\":0.000001}},"
            + "\"stopReason\":\"end_turn\",\"timestamp\":1786496401000,"
            + "\"responseId\":\"r1\",\"rawStopReason\":\"stop\"}}"
        let content = sessionLine + "\n" + messageLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        XCTAssertEqual(result.usages.count, 1)
        XCTAssertFalse(parser.lastParseHealth.isDegraded)
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: VAL-PROV-013 — empty and zero-byte files

    func test_zeroByteFileIsSilentNoOp() async throws {
        let result = try await makeParser().parse()
        XCTAssertNil(result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e222" })
    }

    func test_blankLinesOnlyFileIsSilentNoOp() async throws {
        let result = try await makeParser().parse()
        XCTAssertNil(result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e226" })
    }

    func test_validFileAlongsideEmptyFilesParses() async throws {
        let result = try await makeParser().parse()
        XCTAssertNotNil(result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e223" })
        XCTAssertNotNil(result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e127" })
    }

    // MARK: VAL-PROV-014 — concurrent write never yields torn rows

    func test_tornTailLineIsSkippedNotHalfParsed() async throws {
        // e210 ends with a torn multi-byte UTF-8 sequence mid-line: the valid
        // rows must parse and the torn tail must not produce a row or crash.
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e210" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 700)
        XCTAssertEqual(session?.outputTokens, 140)
    }

    // MARK: VAL-PROV-015 — timestamp variants

    func test_timestampVariantsParseHonestly() async throws {
        let result = try await makeParser().parse()

        // (a) ISO-8601 fractional
        let fractional = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e127" }
        XCTAssertEqual(fractional?.startTime, Self.isoDate("2026-08-10T23:06:04.080Z"))

        // (b) no fraction
        let noFraction = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e201" }
        XCTAssertEqual(noFraction?.startTime, Self.isoDate("2026-08-11T02:00:00Z"))

        // (c) non-UTC offset (+02:00 → 01:00 UTC)
        let offset = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e202" }
        XCTAssertEqual(offset?.startTime, Self.isoDate("2026-08-11T01:00:00Z"))

        // (d) no timestamp → skipped, never epoch-zero
        XCTAssertNil(result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e203" })
        for usage in result.usages {
            XCTAssertNotEqual(usage.startTime.timeIntervalSince1970, 0, "Never epoch-zero")
            XCTAssertNotEqual(usage.endTime.timeIntervalSince1970, 0, "Never epoch-zero")
        }
    }

    // MARK: VAL-PROV-017 — unknown model never fabricated exact $0.00

    func test_unknownModelCostIsNotExactZero() async throws {
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e204" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.model, "mystery-model-9000")
        // Fallback pricing (2.5/10 per M) yields a non-zero cost for 400/100 tokens.
        XCTAssertGreaterThan(session?.cost ?? 0, 0)
    }

    func test_emptyModelStaysEmpty() async throws {
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e213" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.model, "", "Missing model stays honestly empty")
    }

    // MARK: strict usage decoding

    func test_booleanAndFractionalUsageRejected() async throws {
        let result = try await makeParser().parse()
        // e208: input=true (boolean) → rejected; output=130 kept.
        let boolean = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e208" }
        XCTAssertNotNil(boolean)
        XCTAssertEqual(boolean?.inputTokens, 0)
        XCTAssertEqual(boolean?.outputTokens, 130)
        // e209: input=600.5 (fractional) → rejected; output=130 kept.
        let fractional = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e209" }
        XCTAssertNotNil(fractional)
        XCTAssertEqual(fractional?.inputTokens, 0)
        XCTAssertEqual(fractional?.outputTokens, 130)
    }

    func test_cacheTokensMapped() async throws {
        let result = try await makeParser().parse()
        let session = result.usages.first { $0.sessionId == "019feded-0fb0-7b52-9d6d-b2d26d75e207" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 600)
        XCTAssertEqual(session?.outputTokens, 130)
        XCTAssertEqual(session?.cacheReadTokens, 200)
        XCTAssertEqual(session?.cacheCreationTokens, 50)
    }

    // MARK: strictness repair — wrong-shape lines and malformed usage fields

    func test_wrongShapeMessageLineDegradesHealthWithoutDroppingValidRows() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-wrongshape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_ws1.jsonl")
        let sessionLine = "{\"type\":\"session\",\"version\":3,\"id\":\"ws1\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
        let badLine = "{\"type\":\"message\",\"id\":\"bad\",\"timestamp\":\"2026-08-11T00:00:01.000Z\","
            + "\"message\":\"not-a-dict\"}"
        let goodLine = "{\"type\":\"message\",\"id\":\"good\",\"timestamp\":\"2026-08-11T00:00:02.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = sessionLine + "\n" + badLine + "\n" + goodLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "ws1" }
        XCTAssertNotNil(session, "Valid rows must survive wrong-shape siblings")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertEqual(session?.outputTokens, 50)
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Wrong-shape line must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_malformedUsageFieldDegradesHealthNotSilentlyCoerced() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-badusage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_bu1.jsonl")
        let sessionLine = "{\"type\":\"session\",\"version\":3,\"id\":\"bu1\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
        let messageLine = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T00:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\",\"usage\":{\"input\":\"not-a-number\",\"output\":130,"
            + "\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = sessionLine + "\n" + messageLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "bu1" }
        XCTAssertNotNil(session, "Row with a valid output field must survive")
        XCTAssertEqual(session?.inputTokens, 0, "Malformed input must not be coerced")
        XCTAssertEqual(session?.outputTokens, 130, "Valid output must be preserved")
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "Malformed usage field must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: strictness repair — line-1 header authority

    func test_line1HeaderAuthority_laterSessionRecordCannotReplaceIdentity() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-header-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_h1.jsonl")
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"AAA\","
            + "\"timestamp\":\"2026-08-11T01:00:00.000Z\",\"cwd\":\"/Users/alpha\"}"
        let laterHeader = "{\"type\":\"session\",\"version\":3,\"id\":\"BBB\","
            + "\"timestamp\":\"2026-08-11T02:00:00.000Z\",\"cwd\":\"/Users/beta\"}"
        let messageLine = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T02:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = header + "\n" + laterHeader + "\n" + messageLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "AAA" }
        XCTAssertNotNil(session, "Line-1 session identity must win")
        XCTAssertNil(result.usages.first { $0.sessionId == "BBB" }, "Later session record must never replace identity")
        XCTAssertEqual(session?.projectName, "/Users/alpha")
        XCTAssertEqual(session?.startTime, Self.isoDate("2026-08-11T01:00:00.000Z"))
        XCTAssertEqual(session?.endTime, Self.isoDate("2026-08-11T02:00:01.000Z"))
        XCTAssertFalse(parser.lastParseHealth.isDegraded, "Well-formed duplicate session record is not malformed")
    }

    func test_malformedFirstHeaderSkipsTranscriptHonestly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-badheader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_bh1.jsonl")
        let badHeader = "{\"type\":\"session\",\"version\":3,\"id\":123,"
            + "\"timestamp\":\"2026-08-11T01:00:00.000Z\",\"cwd\":\"/Users/alpha\"}"
        let messageLine = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T01:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = badHeader + "\n" + messageLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty, "Malformed header must not yield a row with fabricated identity")
        XCTAssertTrue(parser.lastParseHealth.isDegraded)
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_transcriptWithoutSessionRecordIsSkippedHonestly() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-nosession-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_ns1.jsonl")
        let messageLine = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T01:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        try messageLine.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty, "No session record means no row with fabricated identity")
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "First line without a session record is wrong-shape")
    }

    // MARK: strictness repair — exact integer bounds and checked accumulation

    func test_strictIntExactBoundaryValues() {
        var malformed = false
        // Int64.max is representable as Int on 64-bit.
        XCTAssertEqual(PiParser.strictInt(NSNumber(value: Int64.max), malformed: &malformed), Int.max)
        XCTAssertFalse(malformed)
        // 2^63 (Double(Int.max) rounds to this) must be rejected, never trap.
        malformed = false
        XCTAssertEqual(PiParser.strictInt(NSNumber(value: Double(Int64.max)), malformed: &malformed), 0)
        XCTAssertTrue(malformed, "Double(Int.max) boundary value must be rejected")
        // Huge non-integral values are rejected.
        malformed = false
        XCTAssertEqual(PiParser.strictInt(NSNumber(value: 1e19), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        // Booleans, fractional, negative, and string values are rejected.
        malformed = false
        XCTAssertEqual(PiParser.strictInt(NSNumber(value: true), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        malformed = false
        XCTAssertEqual(PiParser.strictInt(NSNumber(value: 5.5), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        malformed = false
        XCTAssertEqual(PiParser.strictInt(NSNumber(value: -1), malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        malformed = false
        XCTAssertEqual(PiParser.strictInt("5", malformed: &malformed), 0)
        XCTAssertTrue(malformed)
        // Integral doubles and absent/null fields are accepted.
        malformed = false
        XCTAssertEqual(PiParser.strictInt(NSNumber(value: 5.0), malformed: &malformed), 5)
        XCTAssertFalse(malformed)
        malformed = false
        XCTAssertEqual(PiParser.strictInt(nil, malformed: &malformed), 0)
        XCTAssertFalse(malformed, "Absent field is not malformed")
        malformed = false
        XCTAssertEqual(PiParser.strictInt(NSNull(), malformed: &malformed), 0)
        XCTAssertFalse(malformed, "Null field is not malformed")
    }

    func test_checkedAccumulationSaturatesInsteadOfTrapping() {
        XCTAssertEqual(PiParser.addingChecked(10, 5), 15)
        XCTAssertEqual(PiParser.addingChecked(Int.max, 1), Int.max, "Overflow must saturate, never trap")
        XCTAssertEqual(PiParser.addingChecked(Int.max - 1, 1), Int.max)
    }

    func test_hugeUsageValuesNeverTrap() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-huge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_hg1.jsonl")
        let sessionLine = "{\"type\":\"session\",\"version\":3,\"id\":\"hg1\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
        let line1 = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T00:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\",\"usage\":{\"input\":9223372036854775807,\"output\":10,"
            + "\"cacheRead\":0,\"cacheWrite\":0}}}"
        let line2 = "{\"type\":\"message\",\"id\":\"m2\",\"timestamp\":\"2026-08-11T00:00:02.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\",\"usage\":{\"input\":9223372036854775808,\"output\":20,"
            + "\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = sessionLine + "\n" + line1 + "\n" + line2
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "hg1" }
        XCTAssertNotNil(session, "Boundary usage values must not crash the parser")
        XCTAssertEqual(session?.inputTokens, Int.max, "Int64.max is accepted; 2^63 is rejected")
        XCTAssertEqual(session?.outputTokens, 30)
        XCTAssertTrue(parser.lastParseHealth.isDegraded, "2^63 usage value must degrade parse health")
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
