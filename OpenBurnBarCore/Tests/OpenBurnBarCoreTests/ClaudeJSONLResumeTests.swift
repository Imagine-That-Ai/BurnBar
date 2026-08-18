import XCTest
import OpenBurnBarKernel
@testable import OpenBurnBarQuota

final class ClaudeJSONLResumeTests: XCTestCase {
    private var tempHome: URL!
    private var projectsDir: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-jsonl-resume-\(UUID().uuidString)", isDirectory: true)
        projectsDir = tempHome.appendingPathComponent(".claude/projects/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        cacheURL = tempHome.appendingPathComponent("claude-jsonl-quota-cache.plist")
    }

    override func tearDownWithError() throws {
        if let cacheURL {
            ClaudeQuotaAdapter.resetJSONLQuotaCacheMemoryForTesting(cacheURL: cacheURL)
        }
        if let tempHome { try? FileManager.default.removeItem(at: tempHome) }
    }

    func testScan_resumesFromPreviousSizeWhenTranscriptGrows() throws {
        let now = Date()
        let url = projectsDir.appendingPathComponent("live.jsonl")
        try writeTurns(to: url, count: 80, firstTimestamp: now.addingTimeInterval(-3_600), inputTokens: 10)

        let first = try scan(now: now)
        XCTAssertEqual(first.fiveHourTokens, 800)
        XCTAssertGreaterThan(first.bytesRead, 4_000)

        let extraTimestamp = now.addingTimeInterval(-300)
        try appendTurn(to: url, timestamp: extraTimestamp, inputTokens: 50, fileModified: extraTimestamp)

        let second = try scan(now: now)
        XCTAssertEqual(second.fiveHourTokens, 850)
        XCTAssertLessThan(second.bytesRead, first.bytesRead / 2, "grown file must resume from the previous newline boundary")
        XCTAssertEqual(second.filesScanned, 1)
    }

    func testScan_persistsFactsAcrossRelaunchWithoutTranscriptContent() throws {
        let now = Date()
        let url = projectsDir.appendingPathComponent("persisted.jsonl")
        let privateMarker = "PRIVATE-PROMPT-MUST-NOT-ENTER-CACHE"
        let timestamp = now.addingTimeInterval(-600)
        let ts = isoFractional.string(from: timestamp)
        let line = """
        {"type":"assistant","timestamp":"\(ts)","message":{"content":[{"type":"text","text":"\(privateMarker)"}],"usage":{"input_tokens":120,"output_tokens":30}}}
        """
        try Data((line + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: url.path)

        let cold = try scan(now: now)
        XCTAssertEqual(cold.fiveHourTokens, 150)
        XCTAssertGreaterThan(cold.bytesRead, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))

        ClaudeQuotaAdapter.resetJSONLQuotaCacheMemoryForTesting(cacheURL: cacheURL)
        let relaunched = try scan(now: now.addingTimeInterval(1))
        XCTAssertEqual(relaunched.fiveHourTokens, 150)
        XCTAssertEqual(relaunched.bytesRead, 0, "an unchanged process restart must load facts from disk")

        let cacheData = try Data(contentsOf: cacheURL)
        XCTAssertNil(
            cacheData.range(of: Data(privateMarker.utf8)),
            "the persisted quota cache must never contain transcript text"
        )
    }

    func testScan_keepsLoadedDiskCacheInMemoryForLaterRefreshes() throws {
        let now = Date()
        let url = projectsDir.appendingPathComponent("warm.jsonl")
        try writeTurns(to: url, count: 10, firstTimestamp: now.addingTimeInterval(-600), inputTokens: 10)

        let cold = try scan(now: now)
        XCTAssertEqual(cold.fiveHourTokens, 100)
        XCTAssertGreaterThan(cold.bytesRead, 0)

        try Data("deliberately invalidated disk cache".utf8).write(to: cacheURL, options: .atomic)

        let warm = try scan(now: now.addingTimeInterval(1))
        XCTAssertEqual(warm.fiveHourTokens, 100)
        XCTAssertEqual(
            warm.bytesRead,
            0,
            "same-process refreshes must reuse memory instead of decoding the disk cache repeatedly"
        )
    }

    func testScan_replacementThatGrowsDoesNotReuseOldPrefix() throws {
        let now = Date()
        let url = projectsDir.appendingPathComponent("rewritten.jsonl")
        try writeTurns(to: url, count: 2, firstTimestamp: now.addingTimeInterval(-600), inputTokens: 10)
        XCTAssertEqual(try scan(now: now).fiveHourTokens, 20)

        try writeTurns(to: url, count: 3, firstTimestamp: now.addingTimeInterval(-300), inputTokens: 100)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-300)],
            ofItemAtPath: url.path
        )

        let rewritten = try scan(now: now)
        XCTAssertEqual(
            rewritten.fiveHourTokens,
            300,
            "a larger replacement must fail closed to a full parse instead of appending to stale facts"
        )
    }

    func testScan_cachedFutureTurnBecomesVisibleAsWindowAdvances() throws {
        let now = Date()
        let futureTimestamp = now.addingTimeInterval(60)
        let url = projectsDir.appendingPathComponent("future.jsonl")
        try writeTurns(to: url, count: 1, firstTimestamp: futureTimestamp, inputTokens: 40)

        let beforeTurn = try scan(now: now)
        XCTAssertEqual(beforeTurn.fiveHourTokens, 0)
        XCTAssertGreaterThan(beforeTurn.bytesRead, 0)

        let afterTurn = try scan(now: futureTimestamp.addingTimeInterval(1))
        XCTAssertEqual(afterTurn.fiveHourTokens, 40)
        XCTAssertEqual(
            afterTurn.bytesRead,
            0,
            "window movement must re-sum cached facts without requiring another file write"
        )
    }

    func testCanonicalTimestampParserMatchesFoundationWithoutICUFallback() throws {
        let text = "2026-08-17T01:23:45.123456Z"
        let bytes = Array(text.utf8)
        let fast = bytes.withUnsafeBufferPointer { ClaudeJSONLTimestamp.parseCanonicalUTC($0) }
        let expected = try XCTUnwrap(ThreadSafeISO8601DateFormatter.parse(text))
        XCTAssertEqual(try XCTUnwrap(fast).timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000_001)

        XCTAssertNil(
            Array("2026-08-17T01:23:45+00:00".utf8).withUnsafeBufferPointer {
                ClaudeJSONLTimestamp.parseCanonicalUTC($0)
            }
        )
        XCTAssertNotNil(ClaudeJSONLTimestamp.parse("2026-08-17T01:23:45+00:00"))
        XCTAssertNil(
            Array("2026-02-30T01:23:45Z".utf8).withUnsafeBufferPointer {
                ClaudeJSONLTimestamp.parseCanonicalUTC($0)
            }
        )
    }

    func testScan_fullReparsesWhenPreviousParseDidNotEndOnANewline() throws {
        let now = Date()
        let url = projectsDir.appendingPathComponent("partial.jsonl")
        let firstLine = assistantLine(timestamp: now.addingTimeInterval(-600), inputTokens: 100)
            .trimmingCharacters(in: .newlines)
        try Data(firstLine.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-600)],
            ofItemAtPath: url.path
        )

        XCTAssertEqual(try scan(now: now).fiveHourTokens, 100)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                ("\n" + assistantLine(timestamp: now.addingTimeInterval(-300), inputTokens: 50)).utf8
            )
        )
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-300)],
            ofItemAtPath: url.path
        )

        let second = try scan(now: now)
        XCTAssertEqual(second.fiveHourTokens, 150)
        XCTAssertGreaterThan(second.bytesRead, 200, "mid-line cache entries must fail closed to a full reparse")
    }

    private func scan(now: Date) throws -> ClaudeQuotaAdapter.JSONLTokenWindows {
        try ClaudeQuotaAdapter.scanJSONLTokenWindows(
            homeDirectoryURL: tempHome,
            fileManager: FileManager.default,
            environment: [:],
            now: now,
            cacheURL: cacheURL
        )
    }

    private func writeTurns(to url: URL, count: Int, firstTimestamp: Date, inputTokens: Int) throws {
        var payload = ""
        payload.reserveCapacity(count * 160)
        for index in 0..<count {
            let timestamp = firstTimestamp.addingTimeInterval(Double(index))
            payload += assistantLine(timestamp: timestamp, inputTokens: inputTokens)
        }
        try Data(payload.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: firstTimestamp],
            ofItemAtPath: url.path
        )
    }

    private func appendTurn(to url: URL, timestamp: Date, inputTokens: Int, fileModified: Date) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine(timestamp: timestamp, inputTokens: inputTokens).utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: fileModified], ofItemAtPath: url.path)
    }

    private func assistantLine(timestamp: Date, inputTokens: Int) -> String {
        let ts = isoFractional.string(from: timestamp)
        return "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"usage\":{\"input_tokens\":\(inputTokens),\"output_tokens\":0}}}\n"
    }

    private let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
