import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarSignalCore

#if !canImport(LibSignalClient)
final class OpenBurnBarSignalCoreUnavailableTests: XCTestCase {
    func testUnavailableSignalCoreFailsClosedForAtRestOperations() throws {
        XCTAssertFalse(OpenBurnBarSignalCoreAvailability.isLibSignalBacked)
        XCTAssertTrue(OpenBurnBarSignalCoreAvailability.unavailableReason.contains("unavailable"))

        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "device-a")
        let cloudBinding = CloudVaultSignalBinding(
            uid: "uid-1",
            collection: "sessions",
            docId: "doc-1",
            field: "payload"
        )
        let binding = cloudBinding.aadBinding

        XCTAssertThrowsError(try OpenBurnBarSignalAtRest.atRestSeal(
            Data("content-key".utf8),
            recipientIdentityPublicKey: identity.publicKeyData,
            binding: binding
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }

        XCTAssertThrowsError(try OpenBurnBarSignalAtRest.atRestOpen(
            Data("ciphertext".utf8),
            recipientIdentityPrivateKey: identity.privateKeyData,
            binding: binding
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }

        XCTAssertThrowsError(try OpenBurnBarSignalAtRest.sealPayload(
            Data("protected payload".utf8),
            recipients: [identity.atRestRecipient()],
            binding: cloudBinding,
            senderIdentityKeyId: identity.identityKeyId,
            senderIdentityPrivateKey: identity.privateKeyData
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }
    }

    func testUnavailableSignalCoreRejectsStrippedSenderAuthBeforeFallback() throws {
        let binding = CloudVaultSignalBinding(
            uid: "uid-1",
            collection: "conversations",
            docId: "doc-1",
            field: "signalEnvelope"
        )
        let envelope = CloudVaultSignalEnvelope(
            ciphertextLayer: CloudVaultSignalCiphertextLayer(
                payloadCiphertextB64: "Y2lwaGVydGV4dA==",
                payloadAADLabel: "bindingToAAD-sha256:fixture",
                schemaVersion: 1
            ),
            keyDelivery: CloudVaultSignalAtRestKeyDelivery(wraps: []),
            binding: binding
        )

        XCTAssertThrowsError(
            try OpenBurnBarSignalAtRest.openPayload(
                envelope,
                recipientIdentityKeyId: "device-1",
                recipientIdentityPrivateKey: Data(repeating: 0, count: 32),
                expectedBinding: binding,
                trustedSenderPublicKeys: [:]
            )
        ) { error in
            let signalError = error as? OpenBurnBarSignalCoreError
            XCTAssertEqual(signalError, .senderAuthMissing)
            XCTAssertFalse(signalError?.allowsLegacyAtRestFallback(senderSetComplete: false) ?? true)
        }
    }

    func testUnavailableSignalCoreFailsClosedForTrustProofs() throws {
        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "approver")
        let trustPayload = CloudVaultDeviceTrustChainPayload(
            uid: "uid-1",
            targetDeviceId: "target",
            targetEscrowPublicKeyFingerprint: "escrow-fp",
            targetKeyVersion: 1,
            targetSignalIdentityKeyId: "target-signal",
            targetSignalIdentityPublicKeyFingerprint: "target-signal-fp",
            approverDeviceId: "approver",
            approverSignalIdentityKeyId: identity.identityKeyId,
            approverSignalIdentityPublicKeyFingerprint: identity.publicKeyFingerprint
        )

        XCTAssertThrowsError(try CloudVaultDeviceTrustChain.sign(trustPayload, approverIdentity: identity)) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }
        XCTAssertFalse(CloudVaultDeviceTrustChain.verify(
            trustPayload,
            signatureBase64: Data("public-key-hmac".utf8).base64EncodedString(),
            approverPublicKeyData: identity.publicKeyData
        ))

        let actionPayload = CloudVaultTrustedDeviceActionProofPayload(
            uid: "uid-1",
            deviceId: "approver",
            actionKind: "approveMission",
            subjectId: "mission-1",
            approve: true,
            nonce: "nonce-1",
            issuedAtMillis: 1_725_000_000_000,
            deviceSignalIdentityKeyId: identity.identityKeyId,
            deviceSignalIdentityPublicKeyFingerprint: identity.publicKeyFingerprint
        )
        XCTAssertThrowsError(try CloudVaultTrustedDeviceActionProof.sign(actionPayload, identity: identity)) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .libSignalUnavailable)
        }
        XCTAssertFalse(CloudVaultTrustedDeviceActionProof.verify(
            actionPayload,
            signatureBase64: Data("public-key-hmac".utf8).base64EncodedString(),
            publicKeyData: identity.publicKeyData
        ))
    }
}
#else
final class OpenBurnBarSignalCoreUnavailableTests: XCTestCase {
    func testLibSignalBuildUsesBackedImplementation() throws {
        let identity = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "test-device")
        XCTAssertFalse(identity.identityKeyId.isEmpty)
        XCTAssertFalse(identity.publicKeyData.isEmpty)
    }
}
#endif
