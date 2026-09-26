import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarDaemon
import XCTest

/// Wave 0.4: `audit-verify --archive` routes through the real chain verifier.
/// An archive that parses but carries no usable head anchor must report
/// `fully_verified=false` — never the old literal `fully_verified=true`.
final class BurnBarCLIAuditVerifyTests: XCTestCase {
    private func tempDir(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-audit-verify-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func makeManifest(sessionId: String) -> ComputerUseSessionManifest {
        ComputerUseSessionManifest(
            sessionId: ComputerUseSessionID(sessionId),
            mode: .browser,
            trustMode: .manual,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            userId: "user-1",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1800
        )
    }

    private func loggedSession(sessionId: String, base: URL, entryCount: Int = 2) throws -> URL {
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID(sessionId),
            baseDirectory: base,
            macAppVersion: "1.0.0"
        )
        try logger.beginSession(manifest: makeManifest(sessionId: sessionId))
        for index in 0..<entryCount {
            try logger.append(try logger.makeEntry(
                for: .browser(BrowserAction(kind: .click, selector: "step-\(index)")),
                approvedBy: .mac
            ))
        }
        return base.appendingPathComponent(sessionId, isDirectory: true)
    }

    func test_archiveWithoutSignedHead_reportsFullyVerifiedFalse() throws {
        let base = try tempDir(named: "unsigned")
        let sessionDir = try loggedSession(sessionId: "unsigned-session", base: base)
        let archiveURL = base.appendingPathComponent("unsigned.tar.gz")
        // No signer: the archive parses but carries no head anchor.
        _ = try ComputerUseAuditExportWriter().export(
            sessionDirectory: sessionDir,
            destinationURL: archiveURL,
            includeScreenshots: false,
            signer: nil
        )

        let result = try BurnBarCLIAuditVerify.run(arguments: ["--archive", archiveURL.path])
        let output = try XCTUnwrap(result.output)
        XCTAssertEqual(result.exitCode, EXIT_FAILURE)
        XCTAssertTrue(output.contains("archive_valid=true"))
        XCTAssertTrue(output.contains("fully_verified=false"))
        XCTAssertTrue(output.contains("first_invalid_reason=head_anchor_missing"))
    }

    func test_signedArchive_reportsFullyVerifiedTrue() throws {
        let base = try tempDir(named: "signed")
        let sessionDir = try loggedSession(sessionId: "signed-session", base: base)
        let signer = ComputerUseEd25519AuditExportSigner(
            privateKey: Curve25519.Signing.PrivateKey(),
            signerIdentifier: "test-signer"
        )
        let archiveURL = base.appendingPathComponent("signed.tar.gz")
        _ = try ComputerUseAuditExportWriter().export(
            sessionDirectory: sessionDir,
            destinationURL: archiveURL,
            includeScreenshots: false,
            signer: signer
        )

        let result = try BurnBarCLIAuditVerify.run(arguments: ["--archive", archiveURL.path])
        let output = try XCTUnwrap(result.output)
        XCTAssertEqual(result.exitCode, EXIT_SUCCESS)
        XCTAssertTrue(output.contains("archive_valid=true"))
        XCTAssertTrue(output.contains("chain_valid=true"))
        XCTAssertTrue(output.contains("head_signature_valid=true"))
        XCTAssertTrue(output.contains("fully_verified=true"))
    }

    func test_corruptArchive_reportsArchiveInvalid() throws {
        let base = try tempDir(named: "corrupt")
        let archiveURL = base.appendingPathComponent("corrupt.tar.gz")
        try Data("not a gzip archive".utf8).write(to: archiveURL)

        let result = try BurnBarCLIAuditVerify.run(arguments: ["--archive", archiveURL.path])
        let output = try XCTUnwrap(result.output)
        XCTAssertEqual(result.exitCode, EXIT_FAILURE)
        XCTAssertTrue(output.contains("archive_valid=false"))
        XCTAssertTrue(output.contains("fully_verified=false"))
    }
}
