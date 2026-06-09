import XCTest
@testable import OpenBurnBarSignalCore

final class CloudVaultDeviceTrustChainTests: XCTestCase {
    func testSignalIdentityTrustChainSignatureVerifiesAndBindsTarget() throws {
        let approver = OpenBurnBarSignalIdentityKeypair.generateInMemory(deviceId: "phone-a")
        let payload = CloudVaultDeviceTrustChainPayload(
            uid: "user-1",
            targetDeviceId: "mac-1",
            targetEscrowPublicKeyFingerprint: "escrow-fingerprint",
            targetKeyVersion: 1,
            targetSignalIdentityKeyId: "mac-1_1",
            targetSignalIdentityPublicKeyFingerprint: "signal-fingerprint",
            approverDeviceId: "phone-a",
            approverSignalIdentityKeyId: approver.identityKeyId,
            approverSignalIdentityPublicKeyFingerprint: approver.publicKeyFingerprint
        )

        let signature = try CloudVaultDeviceTrustChain.sign(payload, approverIdentity: approver)

        XCTAssertTrue(CloudVaultDeviceTrustChain.verify(
            payload,
            signatureBase64: signature,
            approverPublicKeyData: approver.publicKeyData
        ))
        let tampered = CloudVaultDeviceTrustChainPayload(
            uid: payload.uid,
            targetDeviceId: "mac-2",
            targetEscrowPublicKeyFingerprint: payload.targetEscrowPublicKeyFingerprint,
            targetKeyVersion: payload.targetKeyVersion,
            targetSignalIdentityKeyId: payload.targetSignalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint: payload.targetSignalIdentityPublicKeyFingerprint,
            approverDeviceId: payload.approverDeviceId,
            approverSignalIdentityKeyId: payload.approverSignalIdentityKeyId,
            approverSignalIdentityPublicKeyFingerprint: payload.approverSignalIdentityPublicKeyFingerprint
        )
        XCTAssertFalse(CloudVaultDeviceTrustChain.verify(
            tampered,
            signatureBase64: signature,
            approverPublicKeyData: approver.publicKeyData
        ))
    }
}
