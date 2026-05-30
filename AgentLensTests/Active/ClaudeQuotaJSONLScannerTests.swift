import XCTest
@testable import OpenBurnBar

/// Regression tests for the Claude JSONL quota scanner hardening (May 2026).
///
/// Context: the statusline watcher re-runs this scan on every Claude hook
/// write. The previous scanner re-read every transcript in `~/.claude/projects`
/// on every fire, allocated an `ISO8601DateFormatter` per line, and — because
/// the default formatter rejects Claude's fractional-second timestamps —
/// counted zero tokens for all of it, pegging the CPU and starving the UI.
final class ClaudeQuotaJSONLScannerTests: XCTestCase {

    private var tempHome: URL!
    private var projectsDir: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-jsonl-scan-\(UUID().uuidString)", isDirectory: true)
        projectsDir = tempHome.appendingPathComponent(".claude/projects/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Write a single assistant-turn JSONL line and stamp the file's
    /// modification date (the scanner's window cutoff key).
    @discardableResult
    private func writeTranscript(
        named name: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        fileModified: Date
    ) throws -> URL {
        let url = projectsDir.appendingPathComponent(name)
        let ts = Self.isoFractional.string(from: timestamp)
        let line = """
        {"type":"assistant","timestamp":"\(ts)","message":{"usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}
        """
        try (line + "\n").data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: fileModified], ofItemAtPath: url.path)
        return url
    }

    private func scan(now: Date) throws -> ClaudeQuotaAdapter.JSONLTokenWindows {
        try ClaudeQuotaAdapter.scanJSONLTokenWindows(
            homeDirectoryURL: tempHome,
            fileManager: FileManager.default,
            environment: [:],
            now: now
        )
    }

    // MARK: - Tests

    /// Fractional-second timestamps must be counted (the silent-zero bug), and
    /// the in-window tokens must land in the correct rolling buckets.
    func testCountsFractionalTimestampTokensInWindows() throws {
        let now = Date()
        // 1 hour ago → inside both the 5-hour and 7-day windows.
        try writeTranscript(
            named: "recent.jsonl",
            timestamp: now.addingTimeInterval(-3600),
            inputTokens: 1000,
            outputTokens: 234,
            fileModified: now.addingTimeInterval(-3600)
        )

        let windows = try scan(now: now)
        XCTAssertEqual(windows.fiveHourTokens, 1234, "fractional-timestamp tokens must reach the 5h window")
        XCTAssertEqual(windows.sevenDayTokens, 1234, "fractional-timestamp tokens must reach the 7d window")
        XCTAssertEqual(windows.filesScanned, 1)
    }

    /// A transcript last written before the 7-day window opened cannot
    /// contribute and must be skipped without being read.
    func testSkipsTranscriptsOlderThanSevenDayWindow() throws {
        let now = Date()
        try writeTranscript(
            named: "recent.jsonl",
            timestamp: now.addingTimeInterval(-3600),
            inputTokens: 500,
            outputTokens: 100,
            fileModified: now.addingTimeInterval(-3600)
        )
        // Modified 10 days ago → before the 7-day cutoff → skipped entirely.
        try writeTranscript(
            named: "old.jsonl",
            timestamp: now.addingTimeInterval(-10 * 86_400),
            inputTokens: 9_000_000,
            outputTokens: 9_000_000,
            fileModified: now.addingTimeInterval(-10 * 86_400)
        )

        let windows = try scan(now: now)
        XCTAssertEqual(windows.filesScanned, 1, "stale transcript must not be opened")
        XCTAssertEqual(windows.sevenDayTokens, 600, "stale transcript tokens must not leak into the window")
    }

    /// Tokens older than 5 hours but within 7 days count toward the 7-day
    /// window only.
    func testSplitsFiveHourAndSevenDayWindows() throws {
        let now = Date()
        // 2 days ago → inside 7d, outside 5h. File still in-window (mtime 2d).
        try writeTranscript(
            named: "twoDaysAgo.jsonl",
            timestamp: now.addingTimeInterval(-2 * 86_400),
            inputTokens: 700,
            outputTokens: 0,
            fileModified: now.addingTimeInterval(-2 * 86_400)
        )

        let windows = try scan(now: now)
        XCTAssertEqual(windows.fiveHourTokens, 0, "2-day-old turn must be outside the 5h window")
        XCTAssertEqual(windows.sevenDayTokens, 700, "2-day-old turn must be inside the 7d window")
    }

    /// Re-scanning after the file changes (new signature) must pick up the
    /// appended tokens — the cache invalidates on size/mtime change.
    func testCacheInvalidatesWhenTranscriptChanges() throws {
        let now = Date()
        let url = try writeTranscript(
            named: "live.jsonl",
            timestamp: now.addingTimeInterval(-600),
            inputTokens: 100,
            outputTokens: 0,
            fileModified: now.addingTimeInterval(-600)
        )
        XCTAssertEqual(try scan(now: now).fiveHourTokens, 100)

        // Append a second assistant turn and bump the modification date.
        let ts = Self.isoFractional.string(from: now.addingTimeInterval(-300))
        let extra = "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"usage\":{\"input_tokens\":50,\"output_tokens\":0}}}\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: extra.data(using: .utf8)!)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: url.path)

        XCTAssertEqual(try scan(now: now).fiveHourTokens, 150, "cache must invalidate when the transcript changes")
    }
}
