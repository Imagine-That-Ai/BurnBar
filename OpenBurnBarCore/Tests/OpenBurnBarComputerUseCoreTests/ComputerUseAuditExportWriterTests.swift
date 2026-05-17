import XCTest
import CryptoKit
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
        let archiveURL = base.appendingPathComponent("export.tar.gz")
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

    func testExportCanIncludeScreenshotArtifacts() throws {
        let base = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID("export-test-session"),
            baseDirectory: base,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest())

        let sessionDir = base.appendingPathComponent("export-test-session", isDirectory: true)
        let screenshotsDir = sessionDir.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        let screenshotBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        try screenshotBytes.write(to: screenshotsDir.appendingPathComponent("000001-before.png"))

        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "button")),
            approvedBy: .mac,
            beforeScreenshotHashHex: "screenshot-before"
        ))

        let writer = ComputerUseAuditExportWriter()
        let archive = base.appendingPathComponent("with-screenshots.tar.gz")
        try writer.export(
            sessionDirectory: sessionDir,
            destinationURL: archive,
            includeScreenshots: true
        )

        let entries = try writer.verify(archive: archive)
        XCTAssertTrue(entries.contains { $0.path == "screenshots/000001-before.png" })
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
        let archive = base.appendingPathComponent("ok.tar.gz")
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
        let archive = base.appendingPathComponent("tampered.tar.gz")
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

    func testExportWritesAndVerifiesDetachedSignature() throws {
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

        let privateKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUseEd25519AuditExportSigner(
            privateKey: privateKey,
            signerIdentifier: "unit-test-device"
        )
        let writer = ComputerUseAuditExportWriter()
        let archive = base.appendingPathComponent("signed.tar.gz")
        let result = try writer.export(
            sessionDirectory: base.appendingPathComponent("export-test-session"),
            destinationURL: archive,
            includeScreenshots: false,
            signer: signer
        )

        XCTAssertNotNil(result.signatureURL)
        XCTAssertEqual(result.signature?.algorithm, "ed25519")
        let entries = try writer.verify(archive: archive, signatureURL: result.signatureURL)
        XCTAssertTrue(entries.contains { $0.path == "chain.jsonl" })
    }

    func testExportIsReadableBySystemTar() throws {
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

        let archive = base.appendingPathComponent("system-readable.tar.gz")
        try ComputerUseAuditExportWriter().export(
            sessionDirectory: base.appendingPathComponent("export-test-session"),
            destinationURL: archive,
            includeScreenshots: false
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", archive.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("manifest.json"), output)
        XCTAssertTrue(output.contains("chain.jsonl"), output)
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
