#if canImport(AppKit)
import XCTest
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
@testable import OpenBurnBar

final class PhoneControlAuthorityValidatorAttestationTests: XCTestCase {
    private let phoneSigner = ComputerUsePhoneControlSigner()

    func test_rejectsAttestationMismatchWhenRequired() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)

        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: "intent-1",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: "",
                attestationHashBlake3: "observed-hash"
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: intent.authority.timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64

        XCTAssertThrowsError(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                requiredAttestationHashBlake3: "required-hash"
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.attestationMismatch = error else {
                return XCTFail("Expected attestationMismatch, got \(error)")
            }
        }
    }

    func test_requirePresent_rejectsMissingEnvelopeAttestation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: nil)

        XCTAssertThrowsError(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .requirePresent
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.missingAttestation = error else {
                return XCTFail("Expected missingAttestation, got \(error)")
            }
        }
    }

    func test_requirePresent_acceptsNonEmptyAttestation() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: "phone-digest")

        XCTAssertNoThrow(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .requirePresent
            )
        )
    }

    func test_strictMode_rejectsMacUnbound() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: "any")

        XCTAssertThrowsError(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .rejectUnboundHost
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.macAttestationUnbound = error else {
                return XCTFail("Expected macAttestationUnbound, got \(error)")
            }
        }
    }

    func test_strictMode_acceptsMatchingDigest() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let digest = AppCheckAttestationBinding.digestHex(
            appId: "1:123:ios:abc",
            boundAtMillis: 1_700_000_000_000
        )
        let intent = try signedTapIntent(privateKey: privateKey, attestationDigest: digest)

        XCTAssertNoThrow(
            try validator.validate(
                envelope: intent.authority,
                intent: intent,
                attestation: .required(digest: digest)
            )
        )
    }

    func test_revokedPeerRejected() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        validator.revokePeer(nodeId: "peer-1")

        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: "intent-2",
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: ""
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: intent.authority.timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64

        XCTAssertThrowsError(try validator.validate(envelope: intent.authority, intent: intent)) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.peerRevoked = error else {
                return XCTFail("Expected peerRevoked, got \(error)")
            }
        }
    }

    private func signedTapIntent(
        privateKey: Curve25519.Signing.PrivateKey,
        attestationDigest: String?
    ) throws -> HermesRealtimeRelayInputIntent {
        var intent = HermesRealtimeRelayInputIntent(
            kind: .tap,
            displayId: nil,
            normalizedX: 0.5,
            normalizedY: 0.5,
            normalizedX2: nil,
            normalizedY2: nil,
            text: nil,
            key: nil,
            modifiers: nil,
            mouseButton: nil,
            clientIntentId: UUID().uuidString,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: Date(),
                intentHashBlake3: "",
                signatureEd25519: "",
                attestationHashBlake3: attestationDigest
            )
        )
        let signed = try phoneSigner.sign(
            intent: intent,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: intent.authority.timestamp,
            privateKey: privateKey
        )
        intent.authority.intentHashBlake3 = signed.intentHashHex
        intent.authority.signatureEd25519 = signed.signatureBase64
        return intent
    }
}
#endif
