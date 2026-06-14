#if canImport(AppKit) && !DISTRIBUTION_MAS
import CryptoKit
import Foundation
import XCTest
@testable import OpenBurnBar

/// Remote Unlock certification is recorded against the HPKE recipient key material
/// (`credentialRecipientKeyId` / `credentialRecipientPublicKeyBase64`). The read/create of
/// that material used to be a `try?` that silently swallowed keychain faults — which would
/// either skip certification with no signal or, worse, risk recording a half-formed
/// certification. These tests pin the security-correct behavior of the replacement helper:
/// on a key-material fault we fail closed (return nil → no certification recorded) and the
/// loss is observable, while a healthy store still yields the material to certify with.
@MainActor
final class RemoteClipboardControllerMattersTests: XCTestCase {

    // MARK: - Fakes

    private struct FaultingKeyStore: RemoteUnlockCredentialKeyProviding {
        struct Boom: Error {}

        func copyPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
            throw Boom()
        }

        func copyOrCreateKeyMaterial() throws -> RemoteUnlockCredentialKeyMaterial {
            throw Boom()
        }
    }

    private struct HealthyKeyStore: RemoteUnlockCredentialKeyProviding {
        let material: RemoteUnlockCredentialKeyMaterial

        func copyPrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
            material.privateKey
        }

        func copyOrCreateKeyMaterial() throws -> RemoteUnlockCredentialKeyMaterial {
            material
        }
    }

    private func makeMaterial() -> RemoteUnlockCredentialKeyMaterial {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKeyData = privateKey.publicKey.rawRepresentation
        let keyId = SHA256.hash(data: publicKeyData)
            .prefix(12)
            .map { String(format: "%02x", $0) }
            .joined()
        return RemoteUnlockCredentialKeyMaterial(
            keyId: "hpke-\(keyId)",
            publicKeyBase64: publicKeyData.base64EncodedString(),
            privateKey: privateKey
        )
    }

    // MARK: - Tests

    /// A keychain / key-material fault must fail closed: the helper returns nil so the caller
    /// skips `recordCertification` entirely rather than advertising a missing/empty recipient
    /// key (which would silently break later credential opens). The previous `try?` made this
    /// failure indistinguishable from "no key material" and unobservable.
    func testKeyMaterialFaultFailsClosedAndDoesNotCertify() {
        let controller = RemoteUnlockCredentialController(
            keyStore: FaultingKeyStore()
        )

        let material = controller.certificationKeyMaterial(requestId: "req-fault")

        XCTAssertNil(
            material,
            "A key-material fault must fail closed (nil) so no half-formed certification is recorded."
        )
    }

    /// A healthy key store must still surface fully-formed recipient key material so the caller
    /// can record a real certification — the fix must not regress the happy path.
    func testHealthyKeyStoreYieldsFullyFormedMaterial() throws {
        let expected = makeMaterial()
        let controller = RemoteUnlockCredentialController(
            keyStore: HealthyKeyStore(material: expected)
        )

        let material = try XCTUnwrap(
            controller.certificationKeyMaterial(requestId: "req-ok"),
            "A healthy key store must yield certification material."
        )

        XCTAssertEqual(material.keyId, expected.keyId)
        XCTAssertEqual(material.publicKeyBase64, expected.publicKeyBase64)
        XCTAssertFalse(
            material.keyId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Recipient key id must be non-empty so recordCertification does not fail closed downstream."
        )
        XCTAssertFalse(
            material.publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "Recipient public key must be non-empty so recordCertification does not fail closed downstream."
        )
    }

    /// The default (production) construction path must keep compiling against the real
    /// `RemoteUnlockCredentialKeyStore` seam — guards the injectable-init signature.
    func testDefaultControllerConstructs() {
        _ = RemoteUnlockCredentialController()
    }
}
#endif
