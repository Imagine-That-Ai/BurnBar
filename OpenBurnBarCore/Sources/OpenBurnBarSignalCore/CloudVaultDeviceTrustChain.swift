import Foundation
import LibSignalClient

public struct CloudVaultDeviceTrustChainPayload: Sendable, Hashable {
    public let uid: String
    public let targetDeviceId: String
    public let targetEscrowPublicKeyFingerprint: String
    public let targetKeyVersion: Int
    public let targetSignalIdentityKeyId: String
    public let targetSignalIdentityPublicKeyFingerprint: String
    public let approverDeviceId: String
    public let approverSignalIdentityKeyId: String
    public let approverSignalIdentityPublicKeyFingerprint: String

    public init(
        uid: String,
        targetDeviceId: String,
        targetEscrowPublicKeyFingerprint: String,
        targetKeyVersion: Int,
        targetSignalIdentityKeyId: String,
        targetSignalIdentityPublicKeyFingerprint: String,
        approverDeviceId: String,
        approverSignalIdentityKeyId: String,
        approverSignalIdentityPublicKeyFingerprint: String
    ) {
        self.uid = uid
        self.targetDeviceId = targetDeviceId
        self.targetEscrowPublicKeyFingerprint = targetEscrowPublicKeyFingerprint
        self.targetKeyVersion = targetKeyVersion
        self.targetSignalIdentityKeyId = targetSignalIdentityKeyId
        self.targetSignalIdentityPublicKeyFingerprint = targetSignalIdentityPublicKeyFingerprint
        self.approverDeviceId = approverDeviceId
        self.approverSignalIdentityKeyId = approverSignalIdentityKeyId
        self.approverSignalIdentityPublicKeyFingerprint = approverSignalIdentityPublicKeyFingerprint
    }
}

public enum CloudVaultDeviceTrustChain {
    public static let version = 1
    public static let algorithm = "signal-identity-xeddsa-v1"
    public static let domain = "OpenBurnBar-CloudVault-DeviceTrust-v1"

    public static func canonicalPayload(_ payload: CloudVaultDeviceTrustChainPayload) -> Data {
        let segments = [
            "uid", payload.uid,
            "targetDeviceId", payload.targetDeviceId,
            "targetEscrowPublicKeyFingerprint", payload.targetEscrowPublicKeyFingerprint,
            "targetKeyVersion", "\(payload.targetKeyVersion)",
            "targetSignalIdentityKeyId", payload.targetSignalIdentityKeyId,
            "targetSignalIdentityPublicKeyFingerprint", payload.targetSignalIdentityPublicKeyFingerprint,
            "approverDeviceId", payload.approverDeviceId,
            "approverSignalIdentityKeyId", payload.approverSignalIdentityKeyId,
            "approverSignalIdentityPublicKeyFingerprint", payload.approverSignalIdentityPublicKeyFingerprint
        ]
        var canonical = "\(domain)\n"
        for segment in segments {
            let utf8Count = segment.data(using: .utf8)?.count ?? 0
            canonical += "\(utf8Count):\(segment)\n"
        }
        return Data(canonical.utf8)
    }

    public static func sign(
        _ payload: CloudVaultDeviceTrustChainPayload,
        approverIdentity: OpenBurnBarSignalIdentityKeypair
    ) throws -> String {
        let privateKey = try PrivateKey(approverIdentity.privateKeyData)
        return privateKey.generateSignature(message: canonicalPayload(payload)).base64EncodedString()
    }

    public static func verify(
        _ payload: CloudVaultDeviceTrustChainPayload,
        signatureBase64: String,
        approverPublicKeyData: Data
    ) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64) else {
            return false
        }
        do {
            let publicKey = try PublicKey(approverPublicKeyData)
            return try publicKey.verifySignature(message: canonicalPayload(payload), signature: signature)
        } catch {
            return false
        }
    }
}
