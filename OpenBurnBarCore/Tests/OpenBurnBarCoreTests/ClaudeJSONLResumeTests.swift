import XCTest
@testable import OpenBurnBarQuota

final class ClaudeJSONLResumeTests: XCTestCase {
    private var tempHome: URL!
    private var projectsDir: URL!

    override func setUpWithError() throws {
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-jsonl-resume-\(UUID().uuidString)", isDirectory: true)
        projectsDir = tempHome.appendingPathComponent(".claude/projects/proj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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
            now: now
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
