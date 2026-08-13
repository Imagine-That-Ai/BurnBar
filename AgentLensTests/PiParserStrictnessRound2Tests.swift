@testable import BurnBar
import XCTest

// MARK: - Pi Parser Strictness Round 2 Tests

/// Round-2 scrutiny (parser-strictness-repair.json, issues 1/2/5): PiParser
/// must degrade typed parse health for present wrong-typed usage containers,
/// unknown record kinds, and a later session header after a wrong-shaped
/// first record — never silent acceptance.
@MainActor
final class PiParserStrictnessRound2Tests: XCTestCase {

    private func makeParser(sessionsRoot: String) -> PiParser {
        PiParser(sessionsRoot: sessionsRoot)
    }

    // MARK: round-2 issue 1 — wrong-typed usage containers

    func test_presentWrongTypedUsageContainerDegradesHealth() async throws {
        // A PRESENT usage value that is not an object (string, array,
        // number) is wrong-typed input: it must degrade the typed parse
        // health, never be silently skipped (round-2 scrutiny, issue 1).
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-badusagecontainer-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_buc1.jsonl")
        let sessionLine = "{\"type\":\"session\",\"version\":3,\"id\":\"buc1\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
        let stringUsage = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T00:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\",\"usage\":\"not-an-object\"}}"
        let arrayUsage = "{\"type\":\"message\",\"id\":\"m2\",\"timestamp\":\"2026-08-11T00:00:02.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\",\"usage\":[1, 2, 3]}}"
        let goodLine = "{\"type\":\"message\",\"id\":\"m3\",\"timestamp\":\"2026-08-11T00:00:03.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = sessionLine + "\n" + stringUsage + "\n" + arrayUsage + "\n" + goodLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "buc1" }
        XCTAssertNotNil(session, "Valid rows must survive wrong-typed usage siblings")
        XCTAssertEqual(session?.inputTokens, 100, "Only the well-formed usage object counts")
        XCTAssertEqual(session?.outputTokens, 50)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Present wrong-typed usage container must degrade parse health")
        XCTAssertGreaterThanOrEqual(parser.lastParseHealth.malformedLines, 2)
    }

    func test_nullUsageIsNotMalformed() async throws {
        // Absent and null usage remain acceptable (the provider schema
        // permits them); only PRESENT wrong-typed values degrade.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-nullusage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_nu1.jsonl")
        let sessionLine = "{\"type\":\"session\",\"version\":3,\"id\":\"nu1\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
        let nullUsage = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T00:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\",\"usage\":null}}"
        let goodLine = "{\"type\":\"message\",\"id\":\"m2\",\"timestamp\":\"2026-08-11T00:00:02.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = sessionLine + "\n" + nullUsage + "\n" + goodLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "nu1" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Null usage is not malformed input")
    }

    // MARK: round-2 issue 2 — unknown record types

    func test_unknownRecordTypeDegradesHealth() async throws {
        // An arbitrary unknown top-level record kind (e.g. {"type":"bogus"})
        // is wrong-shaped input: it must degrade the typed parse health,
        // never be silently accepted (round-2 scrutiny, issue 2). The
        // tolerated kinds are the explicit allowlist (session, model_change,
        // thinking_level_change, message) documented in
        // docs/fleet/BURNBAR_FLEET_SIGNALS.md §7.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-unknowntype-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_ut1.jsonl")
        let sessionLine = "{\"type\":\"session\",\"version\":3,\"id\":\"ut1\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
        let unknownLine = "{\"type\":\"bogus\",\"id\":\"x\",\"timestamp\":\"2026-08-11T00:00:01.000Z\"}"
        let goodLine = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T00:00:02.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = sessionLine + "\n" + unknownLine + "\n" + goodLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "ut1" }
        XCTAssertNotNil(session, "Valid rows must survive unknown-type siblings")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Unknown record type must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_toleratedRecordKindsStayHealthy() async throws {
        // The documented allowlist (session, model_change,
        // thinking_level_change, message) must not degrade parse health.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-tolerated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_tol1.jsonl")
        let sessionLine = "{\"type\":\"session\",\"version\":3,\"id\":\"tol1\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
        let modelChange = "{\"type\":\"model_change\",\"id\":\"mc1\",\"parentId\":null,"
            + "\"timestamp\":\"2026-08-11T00:00:01.000Z\",\"provider\":\"deepseek\","
            + "\"modelId\":\"deepseek-v4-flash\"}"
        let thinkingChange = "{\"type\":\"thinking_level_change\",\"id\":\"tc1\",\"parentId\":null,"
            + "\"timestamp\":\"2026-08-11T00:00:02.000Z\",\"thinkingLevel\":\"high\"}"
        let goodLine = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T00:00:03.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = sessionLine + "\n" + modelChange + "\n" + thinkingChange + "\n" + goodLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "tol1" }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.model, "deepseek-v4-flash", "model_change fallback still applies")
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Tolerated record kinds must not degrade parse health")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: round-2 issue 5 — line-1 authority vs later header

    func test_laterSessionHeaderCannotBecomeLine1AuthorityAfterWrongShapedFirstRecord() async throws {
        // When the FIRST nonblank record is valid JSON but not a session
        // record, the transcript is invalid: a LATER session header must
        // not be accepted as the line-1 authority (round-2 scrutiny,
        // issue 5). The transcript degrades/skips honestly.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-lateheader-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_lh1.jsonl")
        let wrongFirst = "{\"type\":\"message\",\"id\":\"m0\",\"timestamp\":\"2026-08-11T00:00:00.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"early\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let laterHeader = "{\"type\":\"session\",\"version\":3,\"id\":\"LATER\","
            + "\"timestamp\":\"2026-08-11T01:00:00.000Z\",\"cwd\":\"/Users/later\"}"
        let messageLine = "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"2026-08-11T01:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = wrongFirst + "\n" + laterHeader + "\n" + messageLine
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty,
                      "A later session header must never become the line-1 authority")
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Wrong-shaped first record must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }
}
