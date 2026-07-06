#if os(Linux)
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore
import XCTest

final class LinuxRemoteUnlockCapabilitySigningKeyStoreTests: XCTestCase {
    private func tempDirectory(_ name: String = #function) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-remote-unlock-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRemoteUnlockSigningKeyPersistsAcrossInstances() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secretService = UnavailableLinuxSecretServiceClient(reason: "forced fallback")
        let firstStore = LinuxRemoteUnlockCapabilityPrivateKeyStore(
            fallbackDirectory: directory,
            secretService: secretService
        )
        let first = try OpenBurnBarRemoteUnlockCapabilitySigningKeyStore(keyStore: firstStore)
            .copyOrCreateKeyMaterial()

        let secondStore = LinuxRemoteUnlockCapabilityPrivateKeyStore(
            fallbackDirectory: directory,
            secretService: secretService
        )
        let second = try OpenBurnBarRemoteUnlockCapabilitySigningKeyStore(keyStore: secondStore)
            .copyOrCreateKeyMaterial()

        XCTAssertEqual(second.keyId, first.keyId)
        XCTAssertEqual(second.publicKey.rawRepresentation, first.publicKey.rawRepresentation)
        XCTAssertEqual(second.privateKey.rawRepresentation, first.privateKey.rawRepresentation)
    }

    func testRemoteUnlockSigningKeyPublishesAndRevokesTrustMaterial() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trustPath = directory.appendingPathComponent("trust.json").path
        let keyStore = LinuxRemoteUnlockCapabilityPrivateKeyStore(
            fallbackDirectory: directory.appendingPathComponent("secrets", isDirectory: true),
            secretService: UnavailableLinuxSecretServiceClient(reason: "forced fallback")
        )
        let store = OpenBurnBarRemoteUnlockCapabilitySigningKeyStore(keyStore: keyStore)

        try store.publishIssuerTrust(path: trustPath)
        let published = try XCTUnwrap(CapabilityTokenIssuerTrustMaterial.load(from: trustPath))
        XCTAssertFalse(published.revoked)
        XCTAssertEqual(try published.signingPublicKey().rawRepresentation, try store.copyOrCreateKeyMaterial().publicKey.rawRepresentation)

        try store.revokePublishedTrust(path: trustPath)
        XCTAssertTrue(try XCTUnwrap(CapabilityTokenIssuerTrustMaterial.load(from: trustPath)).revoked)
    }
}
#endif
