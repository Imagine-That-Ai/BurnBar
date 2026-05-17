import CryptoKit
import Foundation
import OpenBurnBarComputerUseCore
@testable import OpenBurnBarDaemon
import XCTest

final class ComputerUseAuditExportSignerProviderTests: XCTestCase {
    func testKeychainProviderPersistsTrustedDeviceSigner() throws {
        let keyStore = InMemoryAuditExportKeyStore()
        let provider = ComputerUseKeychainAuditExportSignerProvider(
            service: "test-service",
            account: "test-account",
            keyStore: keyStore
        )

        let first = try provider.signer()
        let second = try provider.signer()

        XCTAssertEqual(first.publicKeyBase64, second.publicKeyBase64)
        XCTAssertEqual(first.trustRoot, "openburnbar-trusted-device-keychain-v1")
        XCTAssertTrue(first.signerIdentifier.hasPrefix("openburnbar-trusted-device-ed25519-keychain-v1:"))
        XCTAssertEqual(keyStore.writeCount, 1)

        let payload = Data("archive".utf8)
        let signature = try first.sign(payload)
        let publicKeyBase64 = try XCTUnwrap(first.publicKeyBase64)
        let publicKey = try XCTUnwrap(Data(base64Encoded: publicKeyBase64))
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        XCTAssertTrue(verifier.isValidSignature(signature, for: payload))
    }

    func testKeychainProviderMigratesLegacyRawKeyAndRemovesFile() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cu-audit-signer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let legacyKey = Curve25519.Signing.PrivateKey()
        let legacyURL = temp.appendingPathComponent("audit-export-ed25519.raw")
        try legacyKey.rawRepresentation.write(to: legacyURL, options: [.atomic])

        let keyStore = InMemoryAuditExportKeyStore()
        let provider = ComputerUseKeychainAuditExportSignerProvider(
            service: "test-service",
            account: "test-account",
            legacyRawKeyURL: legacyURL,
            keyStore: keyStore
        )

        let signer = try provider.signer()

        XCTAssertEqual(signer.publicKeyBase64, legacyKey.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertEqual(keyStore.writeCount, 1)
    }

    func testSignatureSidecarCarriesTrustedDeviceMetadataAndVerifiesKeyHash() throws {
        let base = try tempDir()
        let logger = try ComputerUseAuditLogger(
            sessionId: ComputerUseSessionID("export-test-session"),
            baseDirectory: base,
            macAppVersion: "test"
        )
        try logger.beginSession(manifest: makeManifest())
        try logger.append(try logger.makeEntry(
            for: .browser(BrowserAction(kind: .click, selector: "button")),
            approvedBy: .mac
        ))

        let signer = try ComputerUseKeychainAuditExportSignerProvider(
            service: "test-service",
            account: "test-account",
            keyStore: InMemoryAuditExportKeyStore()
        ).signer()
        let archive = base.appendingPathComponent("signed.tar.gz")
        let result = try ComputerUseAuditExportWriter().export(
            sessionDirectory: base.appendingPathComponent("export-test-session"),
            destinationURL: archive,
            includeScreenshots: false,
            signer: signer
        )

        let signatureURL = try XCTUnwrap(result.signatureURL)
        let record = try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
            ComputerUseAuditExportSignature.self,
            from: Data(contentsOf: signatureURL)
        )

        XCTAssertEqual(record.signerKind, "openburnbar_trusted_device")
        XCTAssertEqual(record.trustRoot, "openburnbar-trusted-device-keychain-v1")
        let publicKeyBase64 = try XCTUnwrap(record.publicKeyBase64)
        let publicKey = try XCTUnwrap(Data(base64Encoded: publicKeyBase64))
        XCTAssertEqual(record.publicKeySHA256Hex, ComputerUseAuditHasher.current.hash(data: publicKey))
        XCTAssertNoThrow(try ComputerUseAuditExportWriter().verify(archive: archive, signatureURL: signatureURL))

        var tampered = record
        tampered = ComputerUseAuditExportSignature(
            archiveFilename: tampered.archiveFilename,
            archiveSHA256Hex: tampered.archiveSHA256Hex,
            algorithm: tampered.algorithm,
            signerIdentifier: tampered.signerIdentifier,
            signerKind: tampered.signerKind,
            trustRoot: tampered.trustRoot,
            publicKeyBase64: tampered.publicKeyBase64,
            publicKeySHA256Hex: String(repeating: "0", count: 64),
            signatureBase64: tampered.signatureBase64,
            signedAt: tampered.signedAt
        )
        try ComputerUseAuditHasher.canonicalJSONEncoder
            .encode(tampered)
            .write(to: signatureURL, options: [.atomic])
        XCTAssertThrowsError(try ComputerUseAuditExportWriter().verify(archive: archive, signatureURL: signatureURL))
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cu-audit-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeManifest() -> ComputerUseSessionManifest {
        ComputerUseSessionManifest(
            sessionId: ComputerUseSessionID("export-test-session"),
            mode: .browser,
            trustMode: .manual,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            userId: "user",
            macHostNodeId: "mac",
            phoneViewerNodeId: nil,
            scopeRuleIds: [],
            entitlementProductId: "test",
            actionCap: 5,
            sessionTimeoutSeconds: 60
        )
    }
}

private final class InMemoryAuditExportKeyStore: ComputerUseAuditExportKeyStoring, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private(set) var writeCount = 0

    func data(service: String, account: String) throws -> Data? {
        storage["\(service):\(account)"]
    }

    func set(_ data: Data, service: String, account: String) throws {
        storage["\(service):\(account)"] = data
        writeCount += 1
    }
}
