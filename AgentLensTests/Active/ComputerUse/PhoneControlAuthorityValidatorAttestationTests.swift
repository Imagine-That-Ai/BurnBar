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
}
#endif
