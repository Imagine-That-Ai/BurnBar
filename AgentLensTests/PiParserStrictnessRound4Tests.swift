@testable import BurnBar
import XCTest

// MARK: - Pi Parser Strictness Round 4 Tests

/// Round-4 scrutiny (parser-shape-strictness-repair-3.json, issue 3): the
/// documented first-nonblank rule means whitespace-only preamble lines
/// before a valid session header must be tolerated — they are blank lines,
/// not malformed first bytes. Non-whitespace garbage at the head of the
/// file still invalidates the transcript (round-3 behavior preserved).
@MainActor
final class PiParserStrictnessRound4Tests: XCTestCase {

    private func makeParser(sessionsRoot: String) -> PiParser {
        PiParser(sessionsRoot: sessionsRoot)
    }

    /// Creates a temp tree with one project dir and returns the project dir.
    private func makeProjectDir(_ name: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-r4-\(name)-\(UUID().uuidString)", isDirectory: true)
        let projectDir = tempDir.appendingPathComponent("--Users-test--proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return projectDir
    }

    private func validHeader(_ id: String) -> String {
        "{\"type\":\"session\",\"version\":3,\"id\":\"\(id)\","
            + "\"timestamp\":\"2026-08-11T00:00:00.000Z\",\"cwd\":\"/Users/test/proj\"}"
    }

    private func validMessage(_ id: String, input: Int) -> String {
        "{\"type\":\"message\",\"id\":\"\(id)\",\"timestamp\":\"2026-08-11T00:00:01.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":\(input),\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
    }

    // MARK: round-4 issue 3 — whitespace-only preamble lines

    func test_whitespaceOnlyPreambleBeforeValidHeaderParses() async throws {
        // A transcript whose first physical lines are whitespace-only
        // (spaces, tabs, CRLF) followed by a valid session header must
        // parse: the documented rule is "first NONBLANK record", and
        // whitespace-only lines are blank lines, not malformed first bytes
        // (round-4 scrutiny, issue 3).
        let projectDir = try makeProjectDir("wspreamble")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_w1.jsonl")
        let preamble = "   \n\t\t\n  \t  \n"
        let content = preamble + validHeader("WS1") + "\n" + validMessage("m1", input: 100) + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "WS1" }
        XCTAssertNotNil(session, "Whitespace-only preamble must not invalidate the transcript")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertEqual(session?.projectName, "/Users/test/proj", "Header cwd stays authoritative")
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Whitespace-only preamble lines are blank lines, not malformed input")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    func test_whitespaceOnlyPreambleWithCRLFAndSpacesParses() async throws {
        // CRLF line endings with trailing spaces/tabs on the preamble lines
        // are trimmed for blank-line detection.
        let projectDir = try makeProjectDir("crlfpreamble")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_w2.jsonl")
        let preamble = " \r\n\t \r\n  \r\n"
        let content = preamble + validHeader("WS2") + "\n" + validMessage("m1", input: 100) + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "WS2" }
        XCTAssertNotNil(session, "CRLF whitespace-only preamble must not invalidate the transcript")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertFalse(parser.lastParseHealth.isDegraded)
    }

    func test_whitespaceOnlyFileIsSilentNoOp() async throws {
        // A file containing ONLY whitespace-only lines is a blank-lines-only
        // file: silent no-op, never a malformed-first-bytes invalidation
        // (VAL-PROV-013 preserved).
        let projectDir = try makeProjectDir("wsonly")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_w3.jsonl")
        try "   \n\t\n  \n".write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Whitespace-only file is a silent no-op, not malformed input")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    func test_nonWhitespaceGarbagePreambleStillInvalidates() async throws {
        // Round-3 behavior preserved: a preamble line containing
        // NON-whitespace garbage (lossy-decoded bytes) before a valid
        // header still invalidates the transcript — the later header is
        // never the line-1 authority.
        let projectDir = try makeProjectDir("garbagews")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_w4.jsonl")
        var data = Data("   \n".utf8)
        data.append(Data([0xFF, 0xFE, 0x80, 0x81])) // invalid UTF-8 garbage
        data.append(0x0A)
        data.append(Data((validHeader("LATER") + "\n" + validMessage("m1", input: 100) + "\n").utf8))
        try data.write(to: file)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty,
                      "Non-whitespace garbage first bytes must still invalidate the transcript")
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Non-whitespace garbage must still degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_whitespacePreambleThenWrongShapedFirstRecordStillInvalidates() async throws {
        // Whitespace-only lines are skipped, but the FIRST NONBLANK record
        // must still be a well-formed session record: a wrong-shaped first
        // record after a whitespace preamble invalidates the transcript
        // (round-2 line-1 authority preserved).
        let projectDir = try makeProjectDir("wrongafterws")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_w5.jsonl")
        let wrongFirst = "{\"type\":\"message\",\"id\":\"m0\",\"timestamp\":\"2026-08-11T00:00:00.000Z\","
            + "\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"early\"}],"
            + "\"model\":\"deepseek-v4-flash\","
            + "\"usage\":{\"input\":100,\"output\":50,\"cacheRead\":0,\"cacheWrite\":0}}}"
        let content = "  \n\t\n" + wrongFirst + "\n" + validHeader("LATER") + "\n"
            + validMessage("m1", input: 100) + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty,
                      "A wrong-shaped first NONBLANK record must still invalidate the transcript")
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(parser.lastParseHealth.isDegraded)
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }
}
