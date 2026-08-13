import XCTest
@testable import OpenBurnBarQuota

final class CodexRolloutScannerTests: XCTestCase {
    func testFindRolloutFiles_skipsFilesOlderThanFreshnessCutoff() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-rollout-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stale = sessions.appendingPathComponent("rollout-stale.jsonl")
        let fresh = sessions.appendingPathComponent("rollout-fresh.jsonl")
        try Data("{}\n".utf8).write(to: stale)
        try Data("{}\n".utf8).write(to: fresh)

        let staleDate = Date().addingTimeInterval(-10 * 24 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: staleDate],
            ofItemAtPath: stale.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: fresh.path
        )

        let cutoff = Date().addingTimeInterval(-CodexQuotaScanPolicy.freshnessWindow)
        let found = CodexRolloutScanner.findRolloutFiles(
            in: sessions,
            freshnessCutoff: cutoff
        )
        XCTAssertEqual(found.map(\.lastPathComponent).sorted(), ["rollout-fresh.jsonl"])
    }
}
