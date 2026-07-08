import CryptoKit
import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

protocol SessionLogVaultKeyProviding: Sendable {
    func loadKey(uid: String) throws -> Data?
    func getOrCreateKey(uid: String) throws -> Data
}

extension CloudVaultKeyStore: SessionLogVaultKeyProviding {}

protocol SessionLogArchivedSessionMirroring {
    func mirrorArchivedLog(_ conversation: ConversationRecord, cloudLogDocumentID: String?) async
}

extension CLIAgentSessionMirror: SessionLogArchivedSessionMirroring {}

@MainActor
protocol SessionLogVaultKeyPublishing: Sendable {
    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws
}

enum CloudSyncEscrowPublicKeyPublisher {
    static func publishIfNeeded(
        userRef: CloudSyncDocumentGateway,
        deviceId: String,
        publicKeyData: Data,
        publicKeyFingerprint: String,
        keyVersion: Int
    ) async throws {
        let publicKeyBase64 = publicKeyData.base64EncodedString()
        let documentRef = userRef.collection("escrow_public_keys").document("\(deviceId)_\(keyVersion)")

        if let data = try await documentRef.getData() {
            guard EscrowPublicKeyPublisher.matchesExistingPublicKey(
                data,
                deviceId: deviceId,
                publicKeyBase64: publicKeyBase64,
                publicKeyFingerprint: publicKeyFingerprint,
                keyVersion: keyVersion
            ) else {
                throw EscrowPublicKeyPublishError.immutablePublicKeyConflict(
                    deviceId: deviceId,
                    keyVersion: keyVersion
                )
            }
            return
        }

        try await documentRef.setData([
            "deviceId": deviceId,
            "publicKeyData": publicKeyBase64,
            "publicKeyFingerprint": publicKeyFingerprint,
            "keyVersion": keyVersion,
            "algorithm": "ECIES-P256-AESGCM",
            "createdAt": FieldValue.serverTimestamp()
        ], merge: false)
    }
}

enum CloudSyncSignalIdentityPublicKeyPublisher {
    static func publishIfNeeded(
        userRef: CloudSyncDocumentGateway,
        deviceId: String,
        platform: String,
        identity: OpenBurnBarSignalIdentityKeypair
    ) async throws {
        let documentRef = userRef.collection("signal_identity_public_keys").document(identity.identityKeyId)
        if let data = try await documentRef.getData() {
            guard data["deviceId"] as? String == deviceId,
                  data["platform"] as? String == platform,
                  data["identityKeyId"] as? String == identity.identityKeyId,
                  data["publicKeyData"] as? String == identity.publicKeyBase64,
                  data["publicKeyFingerprint"] as? String == identity.publicKeyFingerprint,
                  data["keyVersion"] as? Int == identity.keyVersion,
                  data["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption else {
                throw SignalIdentityPublicKeyPublishError.immutablePublicKeyConflict(
                    deviceId: deviceId,
                    keyVersion: identity.keyVersion
                )
            }
            return
        }
        try await documentRef.setData([
            "deviceId": deviceId,
            "platform": platform,
            "identityKeyId": identity.identityKeyId,
            "publicKeyData": identity.publicKeyBase64,
            "publicKeyFingerprint": identity.publicKeyFingerprint,
            "keyVersion": identity.keyVersion,
            "algorithm": CloudVaultCrypto.signalAtRestEncryption,
            "createdAt": FieldValue.serverTimestamp()
        ], merge: false)
    }
}

enum CloudSyncTrustedDeviceChainVerifier {
    static func verifiedTrustedDevice(
        uid: String,
        userRef: CloudSyncDocumentGateway,
        deviceDocument: CloudSyncDocumentSnapshotGateway,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> CloudVaultVerifiedTrustedDevice {
        let data = deviceDocument.data()
        let deviceId = ((data["deviceId"] as? String) ?? deviceDocument.documentID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: deviceId,
            localIdentity: localIdentity,
            visited: []
        )
    }

    private static func verifiedTrustedDevice(
        uid: String,
        userRef: CloudSyncDocumentGateway,
        deviceId: String,
        localIdentity: OpenBurnBarSignalIdentityKeypair,
        visited: Set<String>
    ) async throws -> CloudVaultVerifiedTrustedDevice {
        guard !deviceId.isEmpty, !visited.contains(deviceId) else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        guard let deviceData = try await userRef.collection("escrow_devices").document(deviceId).getData(),
              deviceData["trustState"] as? String == EscrowDeviceTrustState.trusted.rawValue,
              let keyVersion = deviceData["keyVersion"] as? Int,
              let escrowFingerprint = deviceData["publicKeyFingerprint"] as? String else {
            throw CloudVaultTrustChainVerificationError.invalidTrustedDevice(deviceId: deviceId)
        }
        guard let publicKeyData = try await userRef.collection("escrow_public_keys")
            .document("\(deviceId)_\(keyVersion)")
            .getData(),
              publicKeyData["deviceId"] as? String == deviceId,
              publicKeyData["keyVersion"] as? Int == keyVersion,
              publicKeyData["publicKeyFingerprint"] as? String == escrowFingerprint,
              let escrowPublicKeyBase64 = publicKeyData["publicKeyData"] as? String,
              let escrowPublicKey = Data(base64Encoded: escrowPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.missingEscrowPublicKey(deviceId: deviceId, keyVersion: keyVersion)
        }
        // H1: bind the server fingerprint to the actual escrow key bytes — the
        // trust-chain signature only covers the fingerprint string, so a backend
        // byte-swap would otherwise be invisible. Recompute and reject on mismatch.
        guard EscrowDeviceSafetyCode.isFingerprint(escrowFingerprint, boundTo: escrowPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        let signalIdentityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(deviceId: deviceId, keyVersion: keyVersion)
        guard let signalData = try await userRef.collection("signal_identity_public_keys")
            .document(signalIdentityKeyId)
            .getData(),
              signalData["deviceId"] as? String == deviceId,
              signalData["identityKeyId"] as? String == signalIdentityKeyId,
              signalData["keyVersion"] as? Int == keyVersion,
              signalData["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption,
              let signalFingerprint = signalData["publicKeyFingerprint"] as? String,
              let signalPublicKeyBase64 = signalData["publicKeyData"] as? String,
              let signalPublicKey = Data(base64Encoded: signalPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.missingSignalIdentity(deviceId: deviceId, keyVersion: keyVersion)
        }
        // H1: bind the Signal identity fingerprint to its actual key bytes.
        guard Data(SHA256.hash(data: signalPublicKey)).base64EncodedString() == signalFingerprint else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
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

@MainActor
struct FirebaseSessionLogVaultKeyPublisher: SessionLogVaultKeyPublishing {
    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws {
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: vaultKey)
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(context.deviceId)")
        let userRef = context.firestoreGateway.collection("users").document(uid)
        let deviceRef = userRef.collection("escrow_devices").document(context.deviceId)
        let existingDevice: [String: Any]?
        do {
            existingDevice = try await deviceRef.getData()
        } catch {
            existingDevice = nil
        }
        let existingTrustState = existingDevice?["trustState"] as? String
        let sourceIsTrusted = existingTrustState == EscrowDeviceTrustState.trusted.rawValue
        var devicePayload: [String: Any] = [
            "deviceId": context.deviceId,
            "deviceName": Host.current().localizedName ?? "Mac",
            "platform": "macOS",
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if existingDevice == nil {
            devicePayload["trustState"] = EscrowDeviceTrustState.pending.rawValue
        }
        try await deviceRef.setData(devicePayload, merge: true)
        try await CloudSyncEscrowPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: context.deviceId,
            publicKeyData: keypair.publicKeyData,
            publicKeyFingerprint: keypair.publicKeyFingerprint,
            keyVersion: keypair.keyVersion
        )
        let signalIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: context.deviceId)
        try await CloudSyncSignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: context.deviceId,
            platform: "macOS",
            identity: signalIdentity
        )
        guard sourceIsTrusted else {
            return
        }

        let trusted = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()
        for doc in trusted.documents {
            let target = try await CloudSyncTrustedDeviceChainVerifier.verifiedTrustedDevice(
                uid: uid,
                userRef: userRef,
                deviceDocument: doc,
                localIdentity: signalIdentity
            )
            let wrapped = try CloudVaultCrypto.wrapVaultKey(
                vaultKey,
                recipientPublicKey: target.escrowPublicKeyData
            )
            try await userRef.collection("cloud_vault_key_wrappers")
                .document("\(target.deviceId)_\(target.keyVersion)")
                .setData([
                    "uid": uid,
                    "vaultKeyID": vaultKeyID,
                    "targetDeviceId": target.deviceId,
                    "sourceDeviceId": context.deviceId,
                    "publicKeyFingerprint": target.escrowPublicKeyFingerprint,
                    "keyVersion": target.keyVersion,
                    "wrappedVaultKey": wrapped.base64EncodedString(),
                    "algorithm": "ECIES-P256-AESGCM",
                    "status": "active",
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "schemaVersion": 2
                ], merge: true)
        }
    }
}
