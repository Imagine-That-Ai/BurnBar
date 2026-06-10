import XCTest
import CryptoKit
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

/// F2 — key-kind-aware signing identity (`PhoneControlAuthoritySigningKey`).
final class PhoneControlAuthoritySigningKeyTests: XCTestCase {
    private let signer = ComputerUsePhoneControlSigner()

    func testEd25519SignAuthorityIsWireIdenticalToLegacyPath() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let timestamp = Date(timeIntervalSince1970: 1_762_000_000.123)
        let hashHex = String(repeating: "ab", count: 32)

        let viaIdentity = try signer.signAuthority(
            intentHashHex: hashHex,
            peerNodeId: "ios-phone-test",
            counter: 7,
            timestamp: timestamp,
            key: .ed25519(privateKey)
        )
        // CryptoKit Ed25519 signing is randomized, so byte equality with the
        // legacy path cannot be asserted — wire identity means the same
        // payload bytes verify under the same public key on both paths.
        let payload = signer.signablePayload(intentHashHex: hashHex, counter: 7, timestamp: timestamp)
        guard let identitySignature = Data(base64Encoded: viaIdentity.signatureBase64) else {
            return XCTFail("identity signature is not base64")
        }
        XCTAssertTrue(privateKey.publicKey.isValidSignature(identitySignature, for: payload))
        XCTAssertTrue(signer.isValidAuthoritySignature(
            intentHashHex: hashHex,
            counter: 7,
            timestamp: timestamp,
            signatureBase64: viaIdentity.signatureBase64,
            key: .ed25519(privateKey.publicKey)
        ))
    }

    func testP256SignAuthorityVerifiesWithSecureEnclaveVerifyingKey() throws {
        let privateKey = P256.Signing.PrivateKey()
        let identity = PhoneControlAuthoritySigningKey.secureEnclaveP256(privateKey)
        let timestamp = Date()
        let hashHex = String(repeating: "5e", count: 32)

        let signed = try signer.signAuthority(
            intentHashHex: hashHex,
            peerNodeId: "ios-se-test",
            counter: 42,
            timestamp: timestamp,
            key: identity
        )
        XCTAssertTrue(signer.isValidAuthoritySignature(
            intentHashHex: hashHex,
            counter: 42,
            timestamp: timestamp,
            signatureBase64: signed.signatureBase64,
            key: identity.verifyingKey
        ))
        // The wire signature is the fixed-size raw r‖s form.
        XCTAssertEqual(Data(base64Encoded: signed.signatureBase64)?.count, 64)
        // And it must NOT verify as Ed25519 — algorithm confusion fails closed.
        XCTAssertFalse(signer.isValidAuthoritySignature(
            intentHashHex: hashHex,
            counter: 42,
            timestamp: timestamp,
            signatureBase64: signed.signatureBase64,
            key: .ed25519(Curve25519.Signing.PrivateKey().publicKey)
        ))
    }

    func testPublicKeyRepresentationShapes() {
        let ed = PhoneControlAuthoritySigningKey.ed25519(Curve25519.Signing.PrivateKey())
        XCTAssertEqual(ed.kind, .ed25519)
        XCTAssertEqual(ed.publicKeyRepresentation.count, 32)

        let se = PhoneControlAuthoritySigningKey.secureEnclaveP256(P256.Signing.PrivateKey())
        XCTAssertEqual(se.kind, .secureEnclaveP256)
        XCTAssertEqual(se.publicKeyRepresentation.count, 65)
        XCTAssertEqual(se.publicKeyRepresentation.first, 0x04)
    }

    func testPeerNodeIdDerivationMatchesPublishedRepresentation() {
        let se = PhoneControlAuthoritySigningKey.secureEnclaveP256(P256.Signing.PrivateKey())
        let derived = PhoneControlPeerNodeIdDerivation.derive(
            kind: .secureEnclaveP256,
            platform: .iOS,
            publicKeyRepresentation: se.publicKeyRepresentation
        )
        XCTAssertTrue(derived.hasPrefix("ios-se-"))
        XCTAssertEqual(derived.count, "ios-se-".count + 24)
    }

    func testLocalAuthProofRoundTripsForBothKinds() throws {
        let now = Date()
        let expires = now.addingTimeInterval(60)

        for identity in [
            PhoneControlAuthoritySigningKey.ed25519(Curve25519.Signing.PrivateKey()),
            PhoneControlAuthoritySigningKey.secureEnclaveP256(P256.Signing.PrivateKey()),
        ] {
            let proof = try signer.signLocalAuthProof(
                deviceId: "device-1",
                signedIntentHash: "ABCDEF",
                authenticatedAt: now,
                expiresAt: expires,
                key: identity
            )
            let payload = signer.localAuthProofSignablePayload(
                proofId: proof.proofId,
                deviceId: proof.deviceId,
                signedIntentHash: proof.signedIntentHash,
                authenticatedAt: proof.authenticatedAt,
                expiresAt: proof.expiresAt
            )
            guard let signature = Data(base64Encoded: proof.signatureEd25519) else {
                return XCTFail("proof signature is not base64")
            }
            XCTAssertTrue(
                identity.verifyingKey.isValidSignature(signature, for: payload),
                "local-auth proof must verify for \(identity.kind.rawValue)"
            )
        }
    }
}
