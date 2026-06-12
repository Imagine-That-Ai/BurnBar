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

public struct CloudVaultTrustedDeviceActionProofPayload: Sendable, Hashable {
    public let uid: String
    public let deviceId: String
    public let actionKind: String
    public let subjectId: String
    public let approve: Bool
    public let nonce: String
    public let issuedAtMillis: Int64
    public let deviceSignalIdentityKeyId: String
    public let deviceSignalIdentityPublicKeyFingerprint: String

    public init(
        uid: String,
        deviceId: String,
        actionKind: String,
        subjectId: String,
        approve: Bool,
        nonce: String,
        issuedAtMillis: Int64,
        deviceSignalIdentityKeyId: String,
        deviceSignalIdentityPublicKeyFingerprint: String
    ) {
        self.uid = uid
        self.deviceId = deviceId
        self.actionKind = actionKind
        self.subjectId = subjectId
        self.approve = approve
        self.nonce = nonce
        self.issuedAtMillis = issuedAtMillis
        self.deviceSignalIdentityKeyId = deviceSignalIdentityKeyId
        self.deviceSignalIdentityPublicKeyFingerprint = deviceSignalIdentityPublicKeyFingerprint
    }
}

public enum CloudVaultTrustedDeviceActionProof {
    public static let version = 1
    public static let algorithm = CloudVaultDeviceTrustChain.algorithm
    public static let domain = "OpenBurnBar-TrustedDeviceAction-v1"

    public static func canonicalPayload(_ payload: CloudVaultTrustedDeviceActionProofPayload) -> Data {
        let segments = [
            "uid", payload.uid,
            "deviceId", payload.deviceId,
            "actionKind", payload.actionKind,
            "subjectId", payload.subjectId,
            "approve", payload.approve ? "true" : "false",
            "nonce", payload.nonce,
            "issuedAtMillis", "\(payload.issuedAtMillis)",
            "deviceSignalIdentityKeyId", payload.deviceSignalIdentityKeyId,
            "deviceSignalIdentityPublicKeyFingerprint", payload.deviceSignalIdentityPublicKeyFingerprint
        ]
        var canonical = "\(domain)\n"
        for segment in segments {
            let utf8Count = segment.data(using: .utf8)?.count ?? 0
            canonical += "\(utf8Count):\(segment)\n"
        }
        return Data(canonical.utf8)
    }

    public static func sign(
        _ payload: CloudVaultTrustedDeviceActionProofPayload,
        identity: OpenBurnBarSignalIdentityKeypair
    ) throws -> String {
        let privateKey = try PrivateKey(identity.privateKeyData)
        return privateKey.generateSignature(message: canonicalPayload(payload)).base64EncodedString()
    }

    public static func verify(
        _ payload: CloudVaultTrustedDeviceActionProofPayload,
        signatureBase64: String,
        publicKeyData: Data
    ) -> Bool {
        guard let signature = Data(base64Encoded: signatureBase64) else {
            return false
        }
        do {
            let publicKey = try PublicKey(publicKeyData)
            return try publicKey.verifySignature(message: canonicalPayload(payload), signature: signature)
        } catch {
            return false
        }
    }
}
