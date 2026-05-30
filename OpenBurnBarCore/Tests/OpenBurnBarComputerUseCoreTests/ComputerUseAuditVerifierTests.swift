import XCTest
import CryptoKit
@testable import OpenBurnBarComputerUseCore

final class ComputerUseAuditVerifierTests: XCTestCase {
    private let macAppVersion = "1.0.0"

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cu-verify-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    func test_verifyEmptyChainAgainstGenesis() {
        let verifier = ComputerUseAuditVerifier()
        let report = verifier.verify(
            chainJSONL: Data(),
            sessionManifestHashHex: ComputerUseAuditHasher.genesisParentHashHex,
            signedHead: nil,
            maxEntryIndexInclusive: nil
        )
        XCTAssertTrue(report.chainValid)
        XCTAssertEqual(report.entryCount, 0)
    }

    func test_signedHeadRejectsPostPanicForgery() throws {
        let base = try tempDir()
        let sessionId = "panic-proof-session"
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID(sessionId),
            baseDirectory: base,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest(sessionId: sessionId))

        for index in 0..<3 {
            try logger.append(try logger.makeEntry(
                for: .browser(BrowserAction(kind: .click, selector: "button-\(index)")),
                approvedBy: .mac
            ))
        }

        let panicIndex = 3
        try logger.append(try logger.makeEntry(
            for: .macInspect(MacInspectAction(kind: .accessibility)),
            approvedBy: .panic,
            denyReason: "hotkey"
        ))

        let signerKey = Curve25519.Signing.PrivateKey()
        let signer = ComputerUseEd25519AuditExportSigner(
            privateKey: signerKey,
            signerIdentifier: "test-signer"
        )
        let signedHead = try ComputerUseAuditHeadFinalizer.finalize(
            logger: logger,
            signer: signer
        )
        XCTAssertEqual(signedHead.lastEntryIndex, panicIndex)

        let sessionDir = base.appendingPathComponent(sessionId, isDirectory: true)
        let verifier = ComputerUseAuditVerifier()
        let honestReport = try verifier.verifySessionDirectory(
            sessionDir,
            maxEntryIndexInclusive: panicIndex,
            verifyOpenTimestamps: false
        )
        XCTAssertTrue(honestReport.isFullyVerified)
        XCTAssertTrue(honestReport.noEntriesAfterIndex ?? false)

        // Attacker appends a post-panic action locally.
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "forged-after-panic")),
            approvedBy: .mac
        ))

        let tamperedReport = try verifier.verifySessionDirectory(
            sessionDir,
            maxEntryIndexInclusive: panicIndex,
            verifyOpenTimestamps: false
        )
        XCTAssertFalse(tamperedReport.isFullyVerified)
        XCTAssertFalse(tamperedReport.noEntriesAfterIndex ?? true)
    }

    func test_tamperedSignedHeadFailsSignatureCheck() throws {
        let base = try tempDir()
        let sessionId = "signed-head-tamper"
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID(sessionId),
            baseDirectory: base,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest(sessionId: sessionId))
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "ok")),
            approvedBy: .mac
        ))

        let signer = ComputerUseEd25519AuditExportSigner(
            privateKey: Curve25519.Signing.PrivateKey(),
            signerIdentifier: "test-signer"
        )
        var signedHead = try ComputerUseAuditHeadFinalizer.finalize(logger: logger, signer: signer)

        signedHead = ComputerUseAuditSignedHead(
            sessionId: signedHead.sessionId,
            lastEntryIndex: signedHead.lastEntryIndex,
            headHashHex: String(repeating: "a", count: 64),
            closedAt: signedHead.closedAt,
            signatureEd25519Base64: signedHead.signatureEd25519Base64,
            signerPublicKeyEd25519Base64: signedHead.signerPublicKeyEd25519Base64
        )

        let sessionDir = base.appendingPathComponent(sessionId, isDirectory: true)
        try ComputerUseAuditHeadFinalizer.write(signedHead, to: sessionDir)
        let manifestHash = try ComputerUseAuditChain().hashSessionManifest(makeManifest(sessionId: sessionId))
        let chainData = try Data(contentsOf: sessionDir.appendingPathComponent("chain.jsonl"))

        let report = ComputerUseAuditVerifier().verify(
            chainJSONL: chainData,
            sessionManifestHashHex: manifestHash,
            signedHead: signedHead,
            maxEntryIndexInclusive: nil,
            openTimestampsProofURL: nil
        )
        XCTAssertFalse(report.headSignatureValid ?? true)
    }

    func test_exportWriterEmbedsSignedHead() throws {
        let base = try tempDir()
        let sessionId = "export-signed-head"
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID(sessionId),
            baseDirectory: base,
            macAppVersion: macAppVersion
        )
        try logger.beginSession(manifest: makeManifest(sessionId: sessionId))
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "ok")),
            approvedBy: .mac
        ))

        let sessionDir = base.appendingPathComponent(sessionId, isDirectory: true)
        let signer = ComputerUseEd25519AuditExportSigner(
            privateKey: Curve25519.Signing.PrivateKey(),
            signerIdentifier: "test-signer"
        )
        let archiveURL = base.appendingPathComponent("export.tar.gz")
        _ = try ComputerUseAuditExportWriter().export(
            sessionDirectory: sessionDir,
            destinationURL: archiveURL,
            includeScreenshots: false,
            signer: signer
        )

        let unpacked = try ComputerUseAuditExportWriter().verify(archive: archiveURL)
        XCTAssertTrue(unpacked.contains { $0.path == ComputerUseAuditHeadFinalizer.signedHeadFilename })
    }
}
