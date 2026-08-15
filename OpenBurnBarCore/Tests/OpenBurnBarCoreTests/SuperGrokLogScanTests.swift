import XCTest
@testable import OpenBurnBarQuota

final class SuperGrokLogScanTests: XCTestCase {
    func testScan_tailsPastStalePrefixInsteadOfReadingTheWholeFile() throws {
        let now = Date()
        var events: [Date] = []
        events.reserveCapacity(2_500)
        for index in 0..<2_400 {
            events.append(now.addingTimeInterval(-TimeInterval(4 * 3600 + index)))
        }
        events.append(contentsOf: [
            now.addingTimeInterval(-30 * 60),
            now.addingTimeInterval(-45 * 60),
            now.addingTimeInterval(-90 * 60)
        ])
        let (home, url, fileManager) = try writeLog(events: events)
        defer { try? fileManager.removeItem(at: home) }

        let fileSize = try XCTUnwrap(fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        let scan = XAIQuotaAdapter.scanSuperGrokLog(
            at: url,
            fileManager: fileManager,
            now: now,
            chunkBytes: 8 * 1024
        )

        XCTAssertEqual(scan.inWindowCount, 3)
        XCTAssertTrue(scan.sawAnyEvent)
        XCTAssertLessThan(scan.bytesRead, fileSize / 2, "stale prefix must not be fully scanned")
        XCTAssertGreaterThan(fileSize, 80_000)
    }

    func testScan_oldEventsStillCountAsObserved() throws {
        let now = Date()
        let (home, url, fileManager) = try writeLog(events: [now.addingTimeInterval(-4 * 3600)])
        defer { try? fileManager.removeItem(at: home) }

        let scan = XAIQuotaAdapter.scanSuperGrokLog(
            at: url,
            fileManager: fileManager,
            now: now
        )
        XCTAssertEqual(scan.inWindowCount, 0)
        XCTAssertTrue(scan.sawAnyEvent)
    }

    func testScan_reconstructsALineLongerThanTheTailChunk() throws {
        let now = Date()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-sgrok-\(UUID().uuidString)", isDirectory: true)
        let url = XAIQuotaAdapter.superGrokLogURL(homeDirectoryURL: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let ms = Int(now.addingTimeInterval(-10 * 60).timeIntervalSince1970 * 1000)
        let padding = String(repeating: "x", count: 200)
        let line = "{\"plan\":\"superGrok\",\"timestamp\":\(ms),\"model\":\"\(padding)\"}\n"
        XCTAssertGreaterThan(line.utf8.count, 64)
        try Data(line.utf8).write(to: url)

        let scan = XAIQuotaAdapter.scanSuperGrokLog(
            at: url,
            fileManager: .default,
            now: now,
            chunkBytes: 64
        )
        XCTAssertEqual(scan.inWindowCount, 1)
        XCTAssertTrue(scan.sawAnyEvent)
    }

    private func writeLog(events: [Date]) throws -> (URL, URL, FileManager) {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("obb-sgrok-\(UUID().uuidString)", isDirectory: true)
        let url = XAIQuotaAdapter.superGrokLogURL(homeDirectoryURL: home)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = events.map { date -> String in
            let ms = Int(date.timeIntervalSince1970 * 1000)
            return "{\"plan\":\"superGrok\",\"timestamp\":\(ms)}"
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return (home, url, fileManager)
    }
}
