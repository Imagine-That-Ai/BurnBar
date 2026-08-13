@testable import BurnBar
import Darwin
import XCTest

// MARK: - Grok CLI Parser Proof-Gap Tests

/// Round-1 user-testing proof gaps (parser-proof-gap-repair): the Grok CLI
/// parser lacked (1) checked-in true zero-byte and blank-lines-only fixtures
/// with NON-degraded-health no-op assertions (VAL-PROV-013), (2) a concurrent
/// writer appending an unterminated line while parsing is in flight
/// (VAL-PROV-014), and (3) a fixture covering BOTH absent summary timestamps
/// AND absent usage-frame timestamps (VAL-PROV-015). The checked-in fixtures
/// live under `AgentLensTests/Fixtures/grok/sessions/%2FUsers%2Ftest%2F…`.
@MainActor
final class GrokCLIParserProofGapTests: XCTestCase {

    private var fixturesRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/grok/sessions", isDirectory: true)
            .path
    }

    private func makeParser(sessionsRoot: String? = nil) -> GrokCLIParser {
        GrokCLIParser(sessionsRoot: sessionsRoot ?? fixturesRoot)
    }

    // MARK: VAL-PROV-013 — true zero-byte and blank-lines-only fixtures

    func test_zeroByteAndBlankLinesOnlyFixturesAreHealthyNoOps() async throws {
        // The checked-in fixtures e000 (updates.jsonl is truly 0 bytes) and
        // e001 (updates.jsonl is blank-lines-only) must yield zero rows with
        // NON-degraded parse health — empty inputs are a healthy no-op,
        // never a malformed state (round-1 gap: no such Grok fixtures or
        // health assertions existed).
        let parser = makeParser()
        let result = try await parser.parse()

        XCTAssertNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-00000000e000" },
                     "Zero-byte updates.jsonl must not yield a row")
        XCTAssertNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-00000000e001" },
                     "Blank-lines-only updates.jsonl must not yield a row")

        // The checked-in zero-byte fixture is truly 0 bytes.
        let zeroBytePath = fixturesRoot
            + "/%2FUsers%2Ftest%2Fempty-zero/019f0000-0000-0000-0000-00000000e000/updates.jsonl"
        let zeroByteAttributes = try FileManager.default.attributesOfItem(atPath: zeroBytePath)
        let size = (zeroByteAttributes[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, 0, "The checked-in zero-byte fixture must be truly 0 bytes")

        // The blank-lines-only fixture contains only newline bytes.
        let blankPath = fixturesRoot
            + "/%2FUsers%2Ftest%2Fempty-blank/019f0000-0000-0000-0000-00000000e001/updates.jsonl"
        let blankData = try Data(contentsOf: URL(fileURLWithPath: blankPath))
        XCTAssertFalse(blankData.isEmpty, "Blank-lines fixture must exist")
        XCTAssertTrue(blankData.allSatisfy { $0 == 0x0A }, "Blank-lines fixture must contain only newline bytes")

        // The valid fixture tree still parses its 5 real rows.
        XCTAssertEqual(result.usages.count, 5, "Valid rows must be unaffected by the empty fixtures")
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Empty files are a healthy no-op, never a malformed state (VAL-PROV-013)")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: VAL-PROV-014 — concurrent writer appending a torn tail

    func test_concurrentWriterAppendingTornTailNeverYieldsTornRows() async throws {
        // Round-1 gap: the static torn-tail fixture is fully written before
        // parse begins. This test uses a FIFO updates.jsonl: the parser
        // blocks in open() while a detached writer task writes 500 complete
        // turn_completed frames and then appends an unterminated JSONL line
        // (no trailing newline) — the append lands WHILE parsing is in
        // flight, and only complete rows are emitted. Never a half-parsed
        // row, never a crash.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-concurrent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sessionDir = tempDir.appendingPathComponent("019f0000-0000-0000-0000-00000000c001", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let summary = "{\"info\":{\"id\":\"019f0000-0000-0000-0000-00000000c001\",\"cwd\":\"/Users/test/proj\"},"
            + "\"created_at\":\"2026-07-14T00:05:01.332073Z\",\"updated_at\":\"2026-07-14T00:05:17.045026Z\","
            + "\"current_model_id\":\"grok-4.5\"}"
        try summary.write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)

        let updatesFile = sessionDir.appendingPathComponent("updates.jsonl")
        XCTAssertEqual(mkfifo(updatesFile.path, 0o600), 0, "mkfifo failed with errno \(errno)")

        let writer = Task.detached(priority: .userInitiated) {
            let handle = try FileHandle(forWritingTo: updatesFile)
            defer { try? handle.close() }
            var lines: [String] = []
            for index in 0..<500 {
                lines.append(
                    "{\"timestamp\":1783987507,\"method\":\"session/update\","
                        + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-00000000c001\","
                        + "\"update\":{\"sessionUpdate\":\"turn_completed\",\"prompt_id\":\"p\(index)\","
                        + "\"stop_reason\":\"completed\","
                        + "\"usage\":{\"inputTokens\":100,\"outputTokens\":20,\"totalTokens\":120,"
                        + "\"cachedReadTokens\":0,"
                        + "\"reasoningTokens\":0,\"modelCalls\":1,\"apiDurationMs\":100,"
                        + "\"modelUsage\":{},\"numTurns\":1}},"
                        + "\"_meta\":{\"eventId\":\"e\(index)\",\"agentTimestampMs\":1783987507000}}}"
                )
            }
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            // Append an unterminated line (no trailing newline) while the
            // parser is in flight: a partial record that must be skipped,
            // never half-parsed.
            let torn = "{\"timestamp\":1783987508,\"method\":\"session/update\","
                + "\"params\":{\"sessionId\":\"019f0000-0000-0000-0000-00000000c001\","
                + "\"update\":{\"sessionUpdate\":\"agent_thought_chunk\","
                + "\"content\":{\"type\":\"text\",\"text\":\"torn \u{1F680}"
            try handle.write(contentsOf: Data(torn.utf8))
        }

        let parser = makeParser(sessionsRoot: tempDir.path)
        let result = try await parser.parse()
        try await writer.value

        let session = result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-00000000c001" }
        XCTAssertNotNil(session, "Complete rows must survive the concurrent torn append")
        XCTAssertEqual(session?.inputTokens, 500 * 100, "All 500 complete frames must be counted")
        XCTAssertEqual(session?.outputTokens, 500 * 20)
        XCTAssertEqual(result.usages.count, 1, "The torn tail must never yield a second row")
        XCTAssertTrue(parser.lastParseHealth.isDegraded,
                      "The torn tail is malformed input and must degrade parse health")
        XCTAssertGreaterThan(parser.lastParseHealth.malformedLines, 0)
    }

    // MARK: VAL-PROV-015 — absent summary AND usage-frame timestamps

    func test_absentSummaryAndUsageFrameTimestampsSkipHonestly() async throws {
        // The checked-in e010 fixture covers BOTH absent timestamp surfaces
        // (round-1 gap): summary.json has NO created_at/updated_at (absent
        // summary timestamps) and the updates.jsonl turn_completed frame has
        // NO timestamp field (absent usage-frame timestamps). The session
        // must be skipped honestly — never an epoch-zero row — and absent
        // timestamps are legitimate variants, not malformed input.
        let parser = makeParser()
        let result = try await parser.parse()
        XCTAssertNil(result.usages.first { $0.sessionId == "019f0000-0000-0000-0000-00000000e010" },
                     "A session with no parseable timestamps must be skipped honestly")
        XCTAssertFalse(parser.lastParseHealth.isDegraded,
                       "Absent timestamps are a legitimate variant, not malformed input")
        XCTAssertEqual(parser.lastParseHealth.malformedLines, 0)
        for usage in result.usages {
            XCTAssertNotEqual(usage.startTime.timeIntervalSince1970, 0, "Never epoch-zero")
            XCTAssertNotEqual(usage.endTime.timeIntervalSince1970, 0, "Never epoch-zero")
        }
    }
}
