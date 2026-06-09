import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

struct CloudVaultVerifiedTrustedDevice {
    let deviceId: String
    let keyVersion: Int
    let escrowPublicKeyFingerprint: String
    let escrowPublicKeyData: Data
    let signalIdentityKeyId: String
    let signalIdentityPublicKeyFingerprint: String
    let signalIdentityPublicKeyData: Data
}

enum CloudVaultTrustChainVerificationError: LocalizedError {
    case invalidTrustedDevice(deviceId: String)
    case missingEscrowPublicKey(deviceId: String, keyVersion: Int)
    case missingSignalIdentity(deviceId: String, keyVersion: Int)
    case missingTrustChain(deviceId: String)
    case invalidTrustChain(deviceId: String)

    var errorDescription: String? {
        switch self {
        case .invalidTrustedDevice(let deviceId):
            return "Trusted device \(deviceId) is malformed."
        case .missingEscrowPublicKey(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) has no escrow public key."
        case .missingSignalIdentity(let deviceId, let keyVersion):
            return "Trusted device \(deviceId)_\(keyVersion) has no Signal identity."
        case .missingTrustChain(let deviceId):
            return "Trusted device \(deviceId) is missing a verifiable trust chain."
        case .invalidTrustChain(let deviceId):
            return "Trusted device \(deviceId) has an invalid trust chain."
        }
    }
}

enum CloudVaultTrustedDeviceChainVerifier {
    static func verifiedTrustedDevice(
        uid: String,
        userRef: DocumentReference,
        deviceDocument: QueryDocumentSnapshot,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> CloudVaultVerifiedTrustedDevice {
        try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: (deviceDocument.data()["deviceId"] as? String) ?? deviceDocument.documentID,
            localIdentity: localIdentity,
            visited: []
        )
    }

    static func verifiedTrustedDevice(
        uid: String,
        userRef: DocumentReference,
        deviceId: String,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> CloudVaultVerifiedTrustedDevice {
        try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: deviceId,
            localIdentity: localIdentity,
            visited: []
        )
    }

    private static func verifiedTrustedDevice(
        uid: String,
        userRef: DocumentReference,
        deviceId rawDeviceId: String,
        localIdentity: OpenBurnBarSignalIdentityKeypair,
        visited: Set<String>
    ) async throws -> CloudVaultVerifiedTrustedDevice {
        let deviceId = rawDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceId.isEmpty, !visited.contains(deviceId) else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: rawDeviceId)
        }
        let deviceSnapshot = try await userRef.collection("escrow_devices").document(deviceId).getDocument()
        guard let deviceData = deviceSnapshot.data(),
              deviceData["trustState"] as? String == EscrowDeviceTrustState.trusted.rawValue,
              let keyVersion = deviceData["keyVersion"] as? Int,
              let escrowFingerprint = deviceData["publicKeyFingerprint"] as? String else {
            throw CloudVaultTrustChainVerificationError.invalidTrustedDevice(deviceId: deviceId)
        }

        let publicKeySnapshot = try await userRef.collection("escrow_public_keys")
            .document("\(deviceId)_\(keyVersion)")
            .getDocument()
        guard let publicKeyData = publicKeySnapshot.data(),
              publicKeyData["deviceId"] as? String == deviceId,
              publicKeyData["keyVersion"] as? Int == keyVersion,
              publicKeyData["publicKeyFingerprint"] as? String == escrowFingerprint,
              let escrowPublicKeyBase64 = publicKeyData["publicKeyData"] as? String,
              let escrowPublicKey = Data(base64Encoded: escrowPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.missingEscrowPublicKey(deviceId: deviceId, keyVersion: keyVersion)
        }

        let signalIdentityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(
            deviceId: deviceId,
            keyVersion: keyVersion
        )
        let signalSnapshot = try await userRef.collection("signal_identity_public_keys")
            .document(signalIdentityKeyId)
            .getDocument()
        guard let signalData = signalSnapshot.data(),
              signalData["deviceId"] as? String == deviceId,
              signalData["identityKeyId"] as? String == signalIdentityKeyId,
              signalData["keyVersion"] as? Int == keyVersion,
              signalData["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption,
              let signalFingerprint = signalData["publicKeyFingerprint"] as? String,
              let signalPublicKeyBase64 = signalData["publicKeyData"] as? String,
              let signalPublicKey = Data(base64Encoded: signalPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.missingSignalIdentity(deviceId: deviceId, keyVersion: keyVersion)
        }

        let verified = CloudVaultVerifiedTrustedDevice(
            deviceId: deviceId,
            keyVersion: keyVersion,
            escrowPublicKeyFingerprint: escrowFingerprint,
            escrowPublicKeyData: escrowPublicKey,
            signalIdentityKeyId: signalIdentityKeyId,
            signalIdentityPublicKeyFingerprint: signalFingerprint,
            signalIdentityPublicKeyData: signalPublicKey
        )

        if signalIdentityKeyId == localIdentity.identityKeyId {
            guard signalPublicKey == localIdentity.publicKeyData else {
                throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
            }
            return verified
        }

        guard deviceData["trustChainVersion"] as? Int == CloudVaultDeviceTrustChain.version,
              deviceData["trustChainAlgorithm"] as? String == CloudVaultDeviceTrustChain.algorithm,
              deviceData["targetSignalIdentityKeyId"] as? String == signalIdentityKeyId,
              deviceData["targetSignalIdentityPublicKeyFingerprint"] as? String == signalFingerprint,
              let approvedByDeviceId = deviceData["approvedByDeviceId"] as? String,
              let approvedBySignalIdentityKeyId = deviceData["approvedBySignalIdentityKeyId"] as? String,
              let approvedBySignalFingerprint = deviceData["approvedBySignalIdentityPublicKeyFingerprint"] as? String,
              let signature = deviceData["trustChainSignature"] as? String else {
            throw CloudVaultTrustChainVerificationError.missingTrustChain(deviceId: deviceId)
        }

        let approver = try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: approvedByDeviceId,
            localIdentity: localIdentity,
            visited: visited.union([deviceId])
        )
        guard approver.signalIdentityKeyId == approvedBySignalIdentityKeyId,
              approver.signalIdentityPublicKeyFingerprint == approvedBySignalFingerprint else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }

        let payload = CloudVaultDeviceTrustChainPayload(
            uid: uid,
            targetDeviceId: deviceId,
            targetEscrowPublicKeyFingerprint: escrowFingerprint,
            targetKeyVersion: keyVersion,
            targetSignalIdentityKeyId: signalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint: signalFingerprint,
            approverDeviceId: approver.deviceId,
            approverSignalIdentityKeyId: approver.signalIdentityKeyId,
            approverSignalIdentityPublicKeyFingerprint: approver.signalIdentityPublicKeyFingerprint
        )
        guard CloudVaultDeviceTrustChain.verify(
            payload,
            signatureBase64: signature,
            approverPublicKeyData: approver.signalIdentityPublicKeyData
        ) else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        return verified
    }
}
