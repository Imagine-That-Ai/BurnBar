@testable import BurnBar
import XCTest

// MARK: - Pi Parser Strictness Round 3 Tests

/// Round-3 scrutiny (parser-shape-strictness-repair-2.json, issue 1): the
/// line-1 authority rule extends to malformed FIRST PHYSICAL BYTES. Garbage
/// (lossy-decode) or truncated JSON at the head of the file invalidates the
/// transcript even when a later line is a well-formed session header — the
/// later header is never accepted as the line-1 authority.
@MainActor
final class PiParserStrictnessRound3Tests: XCTestCase {

    private func makeParser(sessionsRoot: String) -> PiParser {
        PiParser(sessionsRoot: sessionsRoot)
    }

    /// Creates a temp tree with one project dir and returns the project dir.
    private func makeProjectDir(_ name: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-r3-\(name)-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: round-3 issue 1 — malformed first bytes invalidate the transcript

    func test_lossyDecodeGarbageFirstBytesInvalidateTranscript() async throws {
        // A file whose FIRST PHYSICAL BYTES are invalid UTF-8 (lossy-decoded
        // to U+FFFD garbage) followed by a well-formed session header must
        // be invalidated: the later header is never the line-1 authority.
        let projectDir = try makeProjectDir("garbage")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_g1.jsonl")
        var data = Data([0xFF, 0xFE, 0x80, 0x81]) // invalid UTF-8 bytes
        data.append(0x0A) // newline
        data.append(Data((validHeader("LATER") + "\n" + validMessage("m1", input: 100) + "\n").utf8))
        try data.write(to: file)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty,
                      "Malformed first bytes must invalidate the transcript")
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Malformed first bytes must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_truncatedJSONFirstLineInvalidatesTranscript() async throws {
        // A first line that is valid UTF-8 but truncated JSON (unterminated
        // string) followed by a well-formed session header must also
        // invalidate the transcript.
        let projectDir = try makeProjectDir("truncated")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_t1.jsonl")
        let truncated = "{\"type\":\"session\",\"id\":\"trunc"
        let content = truncated + "\n" + validHeader("LATER") + "\n" + validMessage("m1", input: 100) + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        XCTAssertTrue(result.usages.isEmpty,
                      "Truncated JSON first line must invalidate the transcript")
        XCTAssertTrue(result.conversations.isEmpty)
        XCTAssertTrue(parser.lastParseHealth.isDegraded)
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    func test_malformedLinesAfterValidHeaderStillDegradeButKeepRows() async throws {
        // Control: malformed lines AFTER a valid header degrade health but
        // do NOT invalidate the transcript (round-2 behavior preserved).
        let projectDir = try makeProjectDir("afterheader")
        defer { try? FileManager.default.removeItem(at: projectDir.deletingLastPathComponent()) }
        let file = projectDir.appendingPathComponent("2026-08-11T00-00-00-000Z_a1.jsonl")
        let content = validHeader("OK1") + "\n" + "this is garbage bytes not json at all\n"
            + validMessage("m1", input: 100) + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)

        let parser = makeParser(sessionsRoot: projectDir.deletingLastPathComponent().path)
        let result = try await parser.parse()
        let session = result.usages.first { $0.sessionId == "OK1" }
        XCTAssertNotNil(session, "Malformed lines after a valid header must not drop valid rows")
        XCTAssertEqual(session?.inputTokens, 100)
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "Malformed lines after the header still degrade parse health")
    }
}
