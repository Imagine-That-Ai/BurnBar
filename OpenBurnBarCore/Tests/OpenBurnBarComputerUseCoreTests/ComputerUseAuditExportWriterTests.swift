import XCTest
@testable import OpenBurnBarComputerUseCore

final class ComputerUseAuditExportWriterTests: XCTestCase {
    private let macAppVersion = "1.0.0"

    private func makeManifest() -> ComputerUseSessionManifest {
        ComputerUseSessionManifest(
            sessionId: ComputerUseSessionID("export-test-session"),
            mode: .browser,
            trustMode: .manual,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            userId: "user-1",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1800
        )
    }

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cu-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testExportContainsExpectedEntries() throws {
        let base = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID("export-test-session"),
            baseDirectory: base,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest())
        for _ in 0..<3 {
            try logger.append(try logger.makeEntry(
                for: .browser(BrowserAction(kind: .click, selector: "button")),
                approvedBy: .mac
            ))
        }
        let sessionDir = base.appendingPathComponent("export-test-session")
        let archiveURL = base.appendingPathComponent("export.cua")
        let writer = ComputerUseAuditExportWriter()
        let result = try writer.export(
            sessionDirectory: sessionDir,
            destinationURL: archiveURL,
            includeScreenshots: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        XCTAssertGreaterThan(result.archiveSizeBytes, 0)
        XCTAssertGreaterThanOrEqual(result.entryCount, 3)
    }

    func testVerifyAcceptsUnmodifiedArchive() throws {
        let base = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID("export-test-session"),
            baseDirectory: base,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest())
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "button")),
            approvedBy: .mac
        ))
        let writer = ComputerUseAuditExportWriter()
        let archive = base.appendingPathComponent("ok.cua")
        try writer.export(
            sessionDirectory: base.appendingPathComponent("export-test-session"),
            destinationURL: archive,
            includeScreenshots: false
        )
        let entries = try writer.verify(archive: archive)
        XCTAssertFalse(entries.isEmpty)
        XCTAssertTrue(entries.contains { $0.path == "manifest.json" })
        XCTAssertTrue(entries.contains { $0.path == "chain.jsonl" })
    }

    func testVerifyRejectsTamperedArchive() throws {
        let base = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID("export-test-session"),
            baseDirectory: base,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest())
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "button")),
            approvedBy: .mac
        ))
        let writer = ComputerUseAuditExportWriter()
        let archive = base.appendingPathComponent("tampered.cua")
        try writer.export(
            sessionDirectory: base.appendingPathComponent("export-test-session"),
            destinationURL: archive,
            includeScreenshots: false
        )
        // Flip a byte in the middle of the archive — not in the magic.
        var data = try Data(contentsOf: archive)
        let target = data.count / 2
        data[target] = data[target] ^ 0xFF
        try data.write(to: archive)
        XCTAssertThrowsError(try writer.verify(archive: archive))
    }
}

final class ComputerUseScopeLibraryTests: XCTestCase {
    func testStarterBundlesAreNonEmpty() {
        XCTAssertGreaterThanOrEqual(ComputerUseStarterBundles.all.count, 3)
        XCTAssertTrue(ComputerUseStarterBundles.all.allSatisfy { !$0.rules.isEmpty })
    }

    func testFreshlyStampedRulesGetNewIDsAndExpiries() {
        let bundle = ComputerUseStarterBundles.calculator
        let stamped = bundle.freshlyStampedRules()
        XCTAssertEqual(stamped.count, bundle.rules.count)
        for (orig, fresh) in zip(bundle.rules, stamped) {
            XCTAssertNotEqual(orig.id, fresh.id)
            XCTAssertEqual(fresh.origin, .imported)
            XCTAssertNotNil(fresh.expiresAt)
        }
    }
}
