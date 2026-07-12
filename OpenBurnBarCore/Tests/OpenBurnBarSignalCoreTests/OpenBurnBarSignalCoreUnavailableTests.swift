import XCTest
@testable import OpenBurnBarSignalCore
import OpenBurnBarCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Fallback-only regression coverage. On the CryptoKit fallback build the
/// device-trust chain and trusted-device action proof previously "signed" with
/// `HMAC-SHA256(message, key = signerPublicKey)`, so anyone holding the signer's
/// PUBLIC key could recompute an accepted tag. These tests lock in the real
/// asymmetric (P256 ECDSA) signature: a signature forged from public material
/// alone — or made with a different device's private key — must be rejected,
/// while a genuine private-key signature must still verify.
final class OpenBurnBarSignalCoreUnavailableTests: XCTestCase {
#if !canImport(LibSignalClient) || os(Linux) || os(Windows)
    private func trustChainPayload() -> CloudVaultDeviceTrustChainPayload {
        CloudVaultDeviceTrustChainPayload(
            uid: "user-1",
            targetDeviceId: "mac-1",
            targetEscrowPublicKeyFingerprint: "escrow-fingerprint",
            targetKeyVersion: 1,
            targetSignalIdentityKeyId: "mac-1_1",
            targetSignalIdentityPublicKeyFingerprint: "signal-fingerprint",
            approverDeviceId: "phone-a",
            approverSignalIdentityKeyId: "phone-a_1",
            approverSignalIdentityPublicKeyFingerprint: "approver-fingerprint"
        )
    }

    private func publicKeyHMAC(_ message: Data, publicKeyData: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: publicKeyData)
        )).base64EncodedString()
    }

    func testTrustChainSignVerifyRoundTrip() throws {
        let approver = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "phone-a")
        let payload = trustChainPayload()
        let signature = try CloudVaultDeviceTrustChain.sign(payload, approverIdentity: approver)
        XCTAssertTrue(CloudVaultDeviceTrustChain.verify(
            payload,
            signatureBase64: signature,
            approverPublicKeyData: approver.publicKeyData
        ))
    }

    func testTrustChainRejectsSignatureForgedFromPublicKeyHMAC() throws {
        let approver = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "phone-a")
        let payload = trustChainPayload()
        let forged = publicKeyHMAC(
            CloudVaultDeviceTrustChain.canonicalPayload(payload),
            publicKeyData: approver.publicKeyData
        )
        XCTAssertFalse(CloudVaultDeviceTrustChain.verify(
            payload,
            signatureBase64: forged,
            approverPublicKeyData: approver.publicKeyData
        ))
    }

    func testTrustChainRejectsSignatureFromDifferentPrivateKey() throws {
        let approver = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "phone-a")
        let attacker = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "attacker")
        let payload = trustChainPayload()
        let attackerSignature = try CloudVaultDeviceTrustChain.sign(payload, approverIdentity: attacker)
        XCTAssertFalse(CloudVaultDeviceTrustChain.verify(
            payload,
            signatureBase64: attackerSignature,
            approverPublicKeyData: approver.publicKeyData
        ))
    }

    func testTrustedDeviceActionProofRejectsPublicKeyHMACForgery() throws {
        let device = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "phone-a")
        let payload = CloudVaultTrustedDeviceActionProofPayload(
            uid: "user-1",
            deviceId: "phone-a",
            actionKind: "approve-escrow-device-trust",
            subjectId: "mac-1",
            approve: true,
            nonce: "nonce-1",
            issuedAtMillis: 1_700_000_000_000,
            deviceSignalIdentityKeyId: device.identityKeyId,
            deviceSignalIdentityPublicKeyFingerprint: device.publicKeyFingerprint
        )
        let forged = publicKeyHMAC(
            CloudVaultTrustedDeviceActionProof.canonicalPayload(payload),
            publicKeyData: device.publicKeyData
        )
        XCTAssertFalse(CloudVaultTrustedDeviceActionProof.verify(
            payload,
            signatureBase64: forged,
            publicKeyData: device.publicKeyData
        ))

        let genuine = try CloudVaultTrustedDeviceActionProof.sign(payload, identity: device)
        XCTAssertTrue(CloudVaultTrustedDeviceActionProof.verify(
            payload,
            signatureBase64: genuine,
            publicKeyData: device.publicKeyData
        ))
    }

    func testAtRestSenderAuthRejectsPublicKeyHMACForgery() throws {
        let sender = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "phone-a")
        let recipient = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "mac-1")
        let binding = CloudVaultSignalBinding(
            uid: "user-1",
            collection: "users/user-1/vault",
            docId: "doc-1",
            field: "payload"
        )
        let envelope = try OpenBurnBarSignalAtRest.sealPayload(
            Data("hello".utf8),
            recipients: [recipient.atRestRecipient()],
            binding: binding,
            senderIdentityKeyId: sender.identityKeyId,
            senderIdentityPrivateKey: sender.privateKeyData
        )

        // Genuine open succeeds under the pinned sender public key.
        let opened = try OpenBurnBarSignalAtRest.openPayload(
            envelope,
            recipientIdentityKeyId: recipient.identityKeyId,
            recipientIdentityPrivateKey: recipient.privateKeyData,
            expectedBinding: binding,
            trustedSenderPublicKeys: [sender.identityKeyId: sender.publicKeyData]
        )
        XCTAssertEqual(opened, Data("hello".utf8))

        // Rebuild the signed message and forge a sender-auth tag from the public
        // key alone; the tampered envelope must fail sender verification.
        let aadInfo = OpenBurnBarSignalAtRest.atRestInfoPrefix
            + (try signalEnvelopeBindingToAAD(binding.aadBinding))
        let signedMessage = OpenBurnBarSignalAtRest.senderAuthSignedMessage(
            info: aadInfo,
            payloadCiphertextB64: envelope.ciphertextLayer.payloadCiphertextB64,
            wraps: envelope.keyDelivery.wraps
        )
        let forgedSignature = publicKeyHMAC(signedMessage, publicKeyData: sender.publicKeyData)
        let forgedEnvelope = CloudVaultSignalEnvelope(
            ciphertextLayer: envelope.ciphertextLayer,
            keyDelivery: envelope.keyDelivery,
            binding: envelope.binding,
            senderAuth: CloudVaultSignalSenderAuth(
                senderIdentityKeyId: sender.identityKeyId,
                senderIdentityKeyB64: sender.publicKeyData.base64EncodedString(),
                signatureB64: forgedSignature
            )
        )
        XCTAssertThrowsError(try OpenBurnBarSignalAtRest.openPayload(
            forgedEnvelope,
            recipientIdentityKeyId: recipient.identityKeyId,
            recipientIdentityPrivateKey: recipient.privateKeyData,
            expectedBinding: binding,
            trustedSenderPublicKeys: [sender.identityKeyId: sender.publicKeyData]
        )) { error in
            XCTAssertEqual(error as? OpenBurnBarSignalCoreError, .senderSignatureInvalid)
        }
    }
#else
    func testLibSignalBuildSkipsFallbackForgeryCoverage() {
        // Fallback (CryptoKit) forgery-rejection coverage compiles only when the
        // vendored libsignal Swift package is absent; the libsignal build is
        // exercised by CloudVaultDeviceTrustChainTests / SignalAtRestSealerTests.
    }
#endif
}
