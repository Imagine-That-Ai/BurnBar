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

    func test_clipboardValidationRequiresAttestationWhenPolicyRequiresIt() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let request = try signedClipboardRequest(privateKey: privateKey, attestationDigest: nil)

        XCTAssertThrowsError(
            try validator.validate(
                envelope: request.authority,
                clipboardRequest: request,
                attestation: .requirePresent
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.missingAttestation = error else {
                return XCTFail("Expected missingAttestation, got \(error)")
            }
        }
    }

    func test_remoteUnlockCredentialValidationRequiresAttestationWhenPolicyRequiresIt() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        let credential = try signedRemoteUnlockCredential(privateKey: privateKey, attestationDigest: nil)

        XCTAssertThrowsError(
            try validator.validate(
                envelope: credential.authority,
                remoteUnlockCredential: credential,
                attestation: .requirePresent
            )
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.missingAttestation = error else {
                return XCTFail("Expected missingAttestation, got \(error)")
            }
        }
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

    func test_registerPeerRefusesRevokedPeerAndFailsClosed() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        // Revoke BEFORE any (re)registration — simulates a revoked device
        // reconnecting and trying to re-admit its pubkey via controlClassify.
        validator.revokePeer(nodeId: "peer-1")
        XCTAssertTrue(validator.isPeerRevoked(nodeId: "peer-1"))

        let registered = validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        XCTAssertFalse(registered, "A revoked peer must NOT be re-registrable.")
        XCTAssertFalse(validator.hasPeer(nodeId: "peer-1"), "The revoked peer's pubkey must not be stored.")

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
            clientIntentId: "intent-reconnect",
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

        XCTAssertThrowsError(
            try validator.validate(envelope: intent.authority, intent: intent),
            "A reconnecting revoked peer must fail closed."
        ) { error in
            switch error {
            case PhoneControlAuthorityValidator.ValidationError.peerRevoked,
                 PhoneControlAuthorityValidator.ValidationError.missingPeerPubKey:
                break
            default:
                XCTFail("Expected peerRevoked or missingPeerPubKey, got \(error)")
            }
        }
    }

    func test_escrowDeviceRevokedRejectsGrantRequest() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let validator = PhoneControlAuthorityValidator()
        validator.registerPeer(nodeId: "peer-1", publicKey: privateKey.publicKey)
        validator.revokeEscrowDevice(deviceId: "escrow-device-1")
        XCTAssertTrue(validator.isEscrowDeviceRevoked(deviceId: "escrow-device-1"))

        let now = Date()
        var request = HermesRealtimeRelayAgentGrantRequest(
            requestId: UUID().uuidString,
            runtime: "claude",
            threadId: "thread-1",
            preset: "default",
            capabilities: ["chat"],
            trustMode: "manual",
            deliveryMode: "push",
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60),
            grantDurationSeconds: 60,
            sourceDeviceId: "escrow-device-1",
            clientIntentId: UUID().uuidString,
            localAuthenticationSatisfied: true,
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: now,
                intentHashBlake3: "",
                signatureEd25519: ""
            )
        )
        let signed = try phoneSigner.sign(
            request: request,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: now,
            privateKey: privateKey
        )
        request.authority.intentHashBlake3 = signed.intentHashHex
        request.authority.signatureEd25519 = signed.signatureBase64

        XCTAssertThrowsError(
            try validator.validate(envelope: request.authority, grantRequest: request)
        ) { error in
            guard case PhoneControlAuthorityValidator.ValidationError.escrowDeviceRevoked(let deviceId) = error else {
                return XCTFail("Expected escrowDeviceRevoked, got \(error)")
            }
            XCTAssertEqual(deviceId, "escrow-device-1")
        }
    }

    func test_revocationQueryHelpersReflectState() {
        let validator = PhoneControlAuthorityValidator()
        XCTAssertFalse(validator.isPeerRevoked(nodeId: "peer-9"))
        XCTAssertFalse(validator.isEscrowDeviceRevoked(deviceId: "device-9"))
        validator.revokePeer(nodeId: "peer-9")
        validator.revokeEscrowDevice(deviceId: "device-9")
        XCTAssertTrue(validator.isPeerRevoked(nodeId: "peer-9"))
        XCTAssertTrue(validator.isEscrowDeviceRevoked(deviceId: "device-9"))
        validator.clearRevocations()
        XCTAssertFalse(validator.isPeerRevoked(nodeId: "peer-9"))
        XCTAssertFalse(validator.isEscrowDeviceRevoked(deviceId: "device-9"))
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

    private func signedClipboardRequest(
        privateKey: Curve25519.Signing.PrivateKey,
        attestationDigest: String?
    ) throws -> HermesRealtimeRelayClipboardRequest {
        var request = HermesRealtimeRelayClipboardRequest(
            requestId: UUID().uuidString,
            action: .pasteToMac,
            contentType: "text/plain",
            text: "hello",
            maxBytes: 65_536,
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
            clipboardRequest: request,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: request.authority.timestamp,
            privateKey: privateKey
        )
        request.authority.intentHashBlake3 = signed.intentHashHex
        request.authority.signatureEd25519 = signed.signatureBase64
        return request
    }

    private func signedRemoteUnlockCredential(
        privateKey: Curve25519.Signing.PrivateKey,
        attestationDigest: String?
    ) throws -> HermesRealtimeRelayRemoteUnlockCredentialEnvelope {
        let now = Date()
        var credential = HermesRealtimeRelayRemoteUnlockCredentialEnvelope(
            requestId: UUID().uuidString,
            sessionId: "remote-unlock-session",
            clientIntentId: UUID().uuidString,
            credentialKind: .typedPassword,
            recipientKeyId: "recipient-key",
            algorithm: "X25519-XSalsa20Poly1305",
            ciphertextBase64: Data("ciphertext".utf8).base64EncodedString(),
            aadBase64: Data("aad".utf8).base64EncodedString(),
            redactedByteCount: 12,
            requestedAt: now,
            expiresAt: now.addingTimeInterval(60),
            authority: HermesRealtimeRelayAuthorityEnvelope(
                peerNodeId: "peer-1",
                counter: 1,
                timestamp: now,
                intentHashBlake3: "",
                signatureEd25519: "",
                attestationHashBlake3: attestationDigest
            )
        )
        let signed = try phoneSigner.sign(
            remoteUnlockCredential: credential,
            peerNodeId: "peer-1",
            counter: 1,
            timestamp: credential.authority.timestamp,
            privateKey: privateKey
        )
        credential.authority.intentHashBlake3 = signed.intentHashHex
        credential.authority.signatureEd25519 = signed.signatureBase64
        return credential
    }
}
#endif
