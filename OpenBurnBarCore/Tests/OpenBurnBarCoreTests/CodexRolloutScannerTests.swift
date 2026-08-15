import XCTest
@testable import OpenBurnBarQuota
import OpenBurnBarKernel

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

    func testScan_prunesOnlyFilesUnderScannedDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-scoped-prune-\(UUID().uuidString)", isDirectory: true)
        let defaultSessions = root.appendingPathComponent("default/sessions", isDirectory: true)
        let switcherSessions = root.appendingPathComponent("switcher/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: defaultSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: switcherSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let keptDefault = defaultSessions.appendingPathComponent("rollout-keep.jsonl")
        let staleDefault = defaultSessions.appendingPathComponent("rollout-gone.jsonl")
        let switcherFile = switcherSessions.appendingPathComponent("rollout-switcher.jsonl")
        try Data("{}\n".utf8).write(to: keptDefault)
        try Data("{}\n".utf8).write(to: switcherFile)

        let existing = CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: [
                keptDefault.standardizedFileURL.path: Self.placeholderEntry(),
                staleDefault.standardizedFileURL.path: Self.placeholderEntry(),
                switcherFile.standardizedFileURL.path: Self.placeholderEntry()
            ],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil
        )

        let cutoff = Date().addingTimeInterval(-CodexQuotaScanPolicy.freshnessWindow)
        let result = try CodexRolloutScanner.scanCodexRateLimitEvents(
            in: [defaultSessions],
            freshnessCutoff: cutoff,
            existingCache: existing
        )

        XCTAssertEqual(
            Set(result.cache.fileEntries.keys),
            [keptDefault.standardizedFileURL.path, switcherFile.standardizedFileURL.path]
        )
        XCTAssertEqual(result.scannedDirectoryPaths, [defaultSessions.standardizedFileURL.path])
        XCTAssertEqual(result.cache.scannedDirectoryPaths, [defaultSessions.standardizedFileURL.path])
    }

    func testMerge_overlaysScannedRootsAndKeepsOtherTrees() {
        let defaultPath = "/tmp/codex-default/sessions/rollout-a.jsonl"
        let switcherPath = "/tmp/codex-switcher/sessions/rollout-b.jsonl"
        let defaultEntry = Self.placeholderEntry(size: 10)
        let updatedSwitcher = Self.placeholderEntry(size: 99)
        let existing = CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: [
                defaultPath: defaultEntry,
                switcherPath: Self.placeholderEntry(size: 1)
            ],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil
        )
        let incoming = CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: [
                defaultPath: Self.placeholderEntry(size: 1),
                switcherPath: updatedSwitcher
            ],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil,
            scannedDirectoryPaths: ["/tmp/codex-switcher/sessions"]
        )

        let merged = existing.mergingScan(incoming: incoming)
        XCTAssertEqual(merged.fileEntries[defaultPath], defaultEntry)
        XCTAssertEqual(merged.fileEntries[switcherPath], updatedSwitcher)
        XCTAssertTrue(merged.scannedDirectoryPaths.isEmpty)
    }

    func testMerge_emptyScannedRootsReplacesTheWholeMap() {
        let existing = CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: ["/a/rollout.jsonl": Self.placeholderEntry()],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil
        )
        let incoming = CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: ["/b/rollout.jsonl": Self.placeholderEntry(size: 4)],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil
        )
        let merged = existing.mergingScan(incoming: incoming)
        XCTAssertEqual(Array(merged.fileEntries.keys), ["/b/rollout.jsonl"])
    }

    func testLockedApply_mergesAgainstTheLiveBox() {
        let defaultPath = "/tmp/codex-default/sessions/rollout-a.jsonl"
        let switcherPath = "/tmp/codex-switcher/sessions/rollout-b.jsonl"
        let box = Locked(CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: [defaultPath: Self.placeholderEntry(size: 10)],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil
        ))
        let incoming = CodexRolloutScanCache(
            schemaVersion: 1,
            fileEntries: [switcherPath: Self.placeholderEntry(size: 7)],
            latestRateLimitEvent: nil,
            lastUpdatedAt: nil,
            scannedDirectoryPaths: ["/tmp/codex-switcher/sessions"]
        )
        let applied = CodexRolloutScanCacheUpdate.apply(
            incoming: incoming,
            didChangeIncoming: true,
            to: box
        )
        XCTAssertTrue(applied.didChange)
        XCTAssertEqual(Set(applied.cache.fileEntries.keys), [defaultPath, switcherPath])
        XCTAssertEqual(Set(box.read().fileEntries.keys), [defaultPath, switcherPath])
    }

    private static func placeholderEntry(size: Int64 = 1) -> CodexRolloutFileCacheEntry {
        CodexRolloutFileCacheEntry(
            signature: CodexRolloutFileSignature(modifiedAt: 1, sizeBytes: size),
            latestRateLimitEvent: nil
        )
    }
}
