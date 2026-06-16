import Foundation
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

final class CastleStatusReaderTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDown() {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots.removeAll()
        super.tearDown()
    }

    func testLoadStatusRecordsKeepsNoOpOutOfLandedTallyAndReportsBadFiles() throws {
        let root = try makeTemporaryRoot()
        let good = root.appendingPathComponent("run-a/status.json")
        let bad = root.appendingPathComponent("run-b/status.json")
        try FileManager.default.createDirectory(at: good.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-06-16T03:12:09Z",
          "runtime": "gemini",
          "modelArg": "gemini-3.1-pro-preview",
          "phase": "no_op",
          "landsCommit": false,
          "baseSHA": "same",
          "headSHA": "same",
          "honesty": ["no_op"]
        }
        """.write(to: good, atomically: true, encoding: .utf8)
        try "{ nope".write(to: bad, atomically: true, encoding: .utf8)

        let result = CastleStatusReader.loadStatusRecords(at: [good, bad])

        XCTAssertEqual(result.snapshot.totalCount, 1)
        XCTAssertEqual(result.snapshot.landedCount, 0)
        XCTAssertEqual(result.snapshot.noOpCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.path, bad.path)
    }

    func testRecentStatusURLsDiscoversNewestStatusFilesOnly() throws {
        let root = try makeTemporaryRoot()
        let older = root.appendingPathComponent("run-a/status.json")
        let newer = root.appendingPathComponent("run-b/status.json")
        let unrelated = root.appendingPathComponent("run-c/result.json")
        for url in [older, newer, unrelated] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{}".write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newer.path)

        let urls = CastleStatusReader.recentStatusURLs(root: root, limit: 1)

        XCTAssertEqual(urls, [newer.resolvingSymlinksInPath().standardizedFileURL])
    }

    func testCastleStatusDecodesNoOpAndLandedWithoutGreenwashing() throws {
        let noOp = try JSONDecoder().decode(CastleWorkerStatus.self, from: Data("""
        {
          "schemaVersion": 1,
          "updatedAt": "2026-06-16T03:12:09Z",
          "runtime": "gemini",
          "modelArg": "gemini-3.1-pro-preview",
          "phase": "no_op",
          "landsCommit": false,
          "baseSHA": "1111111",
          "headSHA": "1111111",
          "honesty": ["quota_unknown", "no_op"]
        }
        """.utf8))
        let landed = try JSONDecoder().decode(CastleWorkerStatus.self, from: Data("""
        {
          "schemaVersion": 1,
          "runtime": "claude",
          "modelArg": "claude-opus-4-8",
          "phase": "completed",
          "landsCommit": true,
          "baseSHA": "1111111",
          "headSHA": "2222222",
          "honesty": ["quota_unknown"]
        }
        """.utf8))

        let snapshot = CastleRunSnapshot(workers: [noOp, landed])

        XCTAssertEqual(noOp.phase, .noOp)
        XCTAssertFalse(noOp.landsCommit)
        XCTAssertEqual(noOp.houseModel.provider, .geminiCLI)
        XCTAssertEqual(noOp.honesty, [.quotaUnknown, .noOp])
        XCTAssertEqual(landed.phase, .landed)
        XCTAssertTrue(landed.landsCommit)
        XCTAssertEqual(snapshot.landedCount, 1)
        XCTAssertEqual(snapshot.noOpCount, 1)
        XCTAssertEqual(snapshot.headline, "1 of 2 banners raised")
    }

    func testSwitcherRegistryIncludesCastleRuntimeProfiles() {
        XCTAssertTrue(SwitcherCLIProfileType.allCases.contains(.gemini))
        XCTAssertTrue(SwitcherCLIProfileType.allCases.contains(.kimi))
        XCTAssertTrue(SwitcherCLIProfileType.allCases.contains(.pi))
        XCTAssertEqual(SwitcherCLIProfileType.gemini.canonicalAgentProvider, .geminiCLI)
        XCTAssertEqual(SwitcherCLIProfileType.kimi.canonicalAgentProvider, .kimi)
        XCTAssertEqual(SwitcherCLIProfileType.pi.canonicalAgentProvider, .piAgent)
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-castle-reader-\(UUID().uuidString)", isDirectory: true)
        temporaryRoots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
