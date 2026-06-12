import FirebaseFirestore
import Foundation
import OpenBurnBarCore
import OpenBurnBarSignalCore

struct CloudVaultResolvedKey: Sendable {
    let keyData: Data
    let vaultKeyID: String
    let signalIdentity: OpenBurnBarSignalIdentityKeypair?

    init(
        keyData: Data,
        vaultKeyID: String,
        signalIdentity: OpenBurnBarSignalIdentityKeypair? = nil
    ) {
        self.keyData = keyData
        self.vaultKeyID = vaultKeyID
        self.signalIdentity = signalIdentity
    }
}

enum CloudVaultAccessError: LocalizedError {
    case vaultKeyUnavailable
    case vaultKeyMismatch(expected: String, actual: String)
    case invalidWrappedKey

    var errorDescription: String? {
        switch self {
        case .vaultKeyUnavailable:
            return "Cloud vault key is unavailable on this device."
        case .vaultKeyMismatch(let expected, let actual):
            return "Cloud vault key mismatch. Expected \(expected), got \(actual)."
        case .invalidWrappedKey:
            return "Cloud vault wrapper could not be decrypted."
        }
    }
}

enum EscrowPublicKeyPublishError: LocalizedError {
    case immutablePublicKeyConflict(deviceId: String, keyVersion: Int)

    var errorDescription: String? {
        switch self {
        case .immutablePublicKeyConflict(let deviceId, let keyVersion):
            return "Escrow public key conflict for \(deviceId)_\(keyVersion)."
        }
    }
}

enum SignalIdentityPublicKeyPublishError: LocalizedError {
    case immutablePublicKeyConflict(deviceId: String, keyVersion: Int)

    var errorDescription: String? {
        switch self {
        case .immutablePublicKeyConflict(let deviceId, let keyVersion):
            return "Signal identity public key conflict for \(deviceId)_\(keyVersion)."
        }
    }
}

enum EscrowPublicKeyPublisher {
    static func publishIfNeeded(
        userRef: DocumentReference,
        deviceId: String,
        publicKeyData: Data,
        publicKeyFingerprint: String,
        keyVersion: Int
    ) async throws {
        let publicKeyBase64 = publicKeyData.base64EncodedString()
        let documentRef = userRef.collection("escrow_public_keys").document("\(deviceId)_\(keyVersion)")
        let existing = try await documentRef.getDocument()

        if let data = existing.data() {
            guard matchesExistingPublicKey(
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

    static func matchesExistingPublicKey(
        _ data: [String: Any],
        deviceId: String,
        publicKeyBase64: String,
        publicKeyFingerprint: String,
        keyVersion: Int
    ) -> Bool {
        guard data["deviceId"] as? String == deviceId,
              data["publicKeyData"] as? String == publicKeyBase64,
              data["keyVersion"] as? Int == keyVersion,
              data["algorithm"] as? String == "ECIES-P256-AESGCM" else {
            return false
        }

        if let existingFingerprint = data["publicKeyFingerprint"] as? String {
            return existingFingerprint == publicKeyFingerprint
        }
        return true
    }
}

enum SignalIdentityPublicKeyPublisher {
    static func publishIfNeeded(
        userRef: DocumentReference,
        deviceId: String,
        platform: String,
        identity: OpenBurnBarSignalIdentityKeypair
    ) async throws {
        let documentRef = userRef.collection("signal_identity_public_keys")
            .document(identity.identityKeyId)
        let existing = try await documentRef.getDocument()

        if let data = existing.data() {
            guard matchesExistingPublicKey(data, deviceId: deviceId, platform: platform, identity: identity) else {
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

    private static func matchesExistingPublicKey(
        _ data: [String: Any],
        deviceId: String,
        platform: String,
        identity: OpenBurnBarSignalIdentityKeypair
    ) -> Bool {
        guard data["deviceId"] as? String == deviceId,
              data["platform"] as? String == platform,
              data["identityKeyId"] as? String == identity.identityKeyId,
              data["publicKeyData"] as? String == identity.publicKeyBase64,
              data["publicKeyFingerprint"] as? String == identity.publicKeyFingerprint,
              data["keyVersion"] as? Int == identity.keyVersion,
              data["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption else {
            return false
        }
        return true
    }
}

enum MacCloudVaultKeyAccess {
    static func keyForWriting(uid: String, deviceId: String, firestore: Firestore) async throws -> CloudVaultResolvedKey {
        let userRef = firestore.collection("users").document(uid)
        let keyStore = CloudVaultKeyStore()
        if let local = try keyStore.loadKey(uid: uid) {
            let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: local)
            if let stateVaultKeyID = try await currentVaultKeyID(userRef: userRef),
               stateVaultKeyID != vaultKeyID {
                if let unwrapped = try await unwrapExistingKey(uid: uid, deviceId: deviceId, userRef: userRef) {
                    try keyStore.saveKey(unwrapped.keyData, uid: uid)
                    try await ensureState(userRef: userRef, uid: uid, vaultKeyID: unwrapped.vaultKeyID, deviceId: deviceId)
                    let signalIdentity = try await publishCloudVaultKey(
                        uid: uid,
                        vaultKey: unwrapped.keyData,
                        vaultKeyID: unwrapped.vaultKeyID,
                        deviceId: deviceId,
                        userRef: userRef
                    )
                    return CloudVaultResolvedKey(keyData: unwrapped.keyData, vaultKeyID: unwrapped.vaultKeyID, signalIdentity: signalIdentity)
                }
                throw CloudVaultAccessError.vaultKeyMismatch(expected: stateVaultKeyID, actual: vaultKeyID)
            }
            try await ensureState(userRef: userRef, uid: uid, vaultKeyID: vaultKeyID, deviceId: deviceId)
            let signalIdentity = try await publishCloudVaultKey(uid: uid, vaultKey: local, vaultKeyID: vaultKeyID, deviceId: deviceId, userRef: userRef)
            return CloudVaultResolvedKey(keyData: local, vaultKeyID: vaultKeyID, signalIdentity: signalIdentity)
        }

        if let unwrapped = try await unwrapExistingKey(uid: uid, deviceId: deviceId, userRef: userRef) {
            try keyStore.saveKey(unwrapped.keyData, uid: uid)
            try await ensureState(userRef: userRef, uid: uid, vaultKeyID: unwrapped.vaultKeyID, deviceId: deviceId)
            let signalIdentity = try await publishCloudVaultKey(uid: uid, vaultKey: unwrapped.keyData, vaultKeyID: unwrapped.vaultKeyID, deviceId: deviceId, userRef: userRef)
            return CloudVaultResolvedKey(keyData: unwrapped.keyData, vaultKeyID: unwrapped.vaultKeyID, signalIdentity: signalIdentity)
        }

        let existingState = try await userRef.collection("cloud_vault_state").document("current").getDocument().data()
        if existingState != nil {
            throw CloudVaultAccessError.vaultKeyUnavailable
        }

        let created = CloudVaultCrypto.generateVaultKey()
        try keyStore.saveKey(created, uid: uid)
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: created)
        try await ensureState(userRef: userRef, uid: uid, vaultKeyID: vaultKeyID, deviceId: deviceId)
        let signalIdentity = try await publishCloudVaultKey(uid: uid, vaultKey: created, vaultKeyID: vaultKeyID, deviceId: deviceId, userRef: userRef)
        return CloudVaultResolvedKey(keyData: created, vaultKeyID: vaultKeyID, signalIdentity: signalIdentity)
    }

    static func keyForReading(uid: String, deviceId: String, firestore: Firestore) async throws -> CloudVaultResolvedKey? {
        let userRef = firestore.collection("users").document(uid)
        let keyStore = CloudVaultKeyStore()
        // Local-only load (reading never creates) so Mac read paths can open at-rest Signal
        // envelopes; nil until the device has a Signal identity (item 3 read side).
        let signalIdentity = try? OpenBurnBarSignalIdentityKeyStore().load(uid: uid, deviceId: deviceId)
        if let local = try keyStore.loadKey(uid: uid) {
            let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: local)
            if let stateVaultKeyID = try await currentVaultKeyID(userRef: userRef),
               stateVaultKeyID != vaultKeyID {
                if let unwrapped = try await unwrapExistingKey(uid: uid, deviceId: deviceId, userRef: userRef) {
                    try keyStore.saveKey(unwrapped.keyData, uid: uid)
                    return CloudVaultResolvedKey(
                        keyData: unwrapped.keyData,
                        vaultKeyID: unwrapped.vaultKeyID,
                        signalIdentity: signalIdentity
                    )
                }
                throw CloudVaultAccessError.vaultKeyMismatch(expected: stateVaultKeyID, actual: vaultKeyID)
            }
            return CloudVaultResolvedKey(keyData: local, vaultKeyID: vaultKeyID, signalIdentity: signalIdentity)
        }
        if let unwrapped = try await unwrapExistingKey(uid: uid, deviceId: deviceId, userRef: userRef) {
            try keyStore.saveKey(unwrapped.keyData, uid: uid)
            return CloudVaultResolvedKey(
                keyData: unwrapped.keyData, vaultKeyID: unwrapped.vaultKeyID, signalIdentity: signalIdentity
            )
        }
        return nil
    }

    private static func unwrapExistingKey(uid: String, deviceId: String, userRef: DocumentReference) async throws -> CloudVaultResolvedKey? {
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(deviceId)")
        let snapshot = try await userRef.collection("cloud_vault_key_wrappers")
            .whereField("targetDeviceId", isEqualTo: deviceId)
            .whereField("status", isEqualTo: "active")
            .limit(to: 10)
            .getDocuments()
        for document in snapshot.documents {
            let data = document.data()
            guard let wrappedBase64 = data["wrappedVaultKey"] as? String,
                  let wrapped = Data(base64Encoded: wrappedBase64) else {
                continue
            }
            let key = try keypair.decrypt(wrapped)
            let actual = try CloudVaultCrypto.vaultKeyID(for: key)
            if let wrapperVaultKeyID = data["vaultKeyID"] as? String, wrapperVaultKeyID != actual {
                throw CloudVaultAccessError.vaultKeyMismatch(expected: wrapperVaultKeyID, actual: actual)
            }
            if let stateVaultKeyID = try await currentVaultKeyID(userRef: userRef), stateVaultKeyID != actual {
                throw CloudVaultAccessError.vaultKeyMismatch(expected: stateVaultKeyID, actual: actual)
            }
            return CloudVaultResolvedKey(keyData: key, vaultKeyID: actual)
        }
        return nil
    }

    private static func currentVaultKeyID(userRef: DocumentReference) async throws -> String? {
        try await userRef.collection("cloud_vault_state").document("current").getDocument().data()?["vaultKeyID"] as? String
    }

    private static func ensureState(userRef: DocumentReference, uid: String, vaultKeyID: String, deviceId: String) async throws {
        let stateRef = userRef.collection("cloud_vault_state").document("current")
        if let existing = try await stateRef.getDocument().data(),
           let existingID = existing["vaultKeyID"] as? String {
            guard existingID == vaultKeyID else {
                throw CloudVaultAccessError.vaultKeyMismatch(expected: existingID, actual: vaultKeyID)
            }
            try await stateRef.setData(["updatedAt": FieldValue.serverTimestamp()], merge: true)
            return
        }

        try await stateRef.setData([
            "uid": uid,
            "vaultKeyID": vaultKeyID,
            "keyVersion": CloudVaultCrypto.currentKeyVersion,
            "algorithm": CloudVaultCrypto.aesGCMAlgorithm,
            "status": "active",
            "createdByDeviceId": deviceId,
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "schemaVersion": 1
        ], merge: false)
    }

    @discardableResult
    private static func publishCloudVaultKey(
        uid: String,
        vaultKey: Data,
        vaultKeyID: String,
        deviceId: String,
        userRef: DocumentReference
    ) async throws -> OpenBurnBarSignalIdentityKeypair {
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(deviceId)")
        let deviceRef = userRef.collection("escrow_devices").document(deviceId)
        let existingSnapshot: DocumentSnapshot?
        do {
            existingSnapshot = try await deviceRef.getDocument()
        } catch {
            existingSnapshot = nil
        }
        let existingDevice = existingSnapshot?.data()
        let existingTrustState = existingDevice?["trustState"] as? String
        let sourceIsTrusted = existingTrustState == EscrowDeviceTrustState.trusted.rawValue

        var devicePayload: [String: Any] = [
            "deviceId": deviceId,
            "deviceName": Host.current().localizedName ?? "Mac",
            "platform": "macOS",
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if existingSnapshot?.exists == false {
            devicePayload["trustState"] = EscrowDeviceTrustState.pending.rawValue
        }
        try await deviceRef.setData(devicePayload, merge: true)
        try await EscrowPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: deviceId,
            publicKeyData: keypair.publicKeyData,
            publicKeyFingerprint: keypair.publicKeyFingerprint,
            keyVersion: keypair.keyVersion
        )
        let signalIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: deviceId)
        try await SignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: deviceId,
            platform: "macOS",
            identity: signalIdentity
        )
        guard sourceIsTrusted else {
            return signalIdentity
        }

        let trusted = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()
        for doc in trusted.documents {
            let target = try await CloudVaultTrustedDeviceChainVerifier.verifiedTrustedDevice(
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
                .document("\(vaultKeyID)_\(target.deviceId)_\(target.keyVersion)")
                .setData([
                    "uid": uid,
                    "vaultKeyID": vaultKeyID,
                    "targetDeviceId": target.deviceId,
                    "sourceDeviceId": deviceId,
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
        return signalIdentity
    }
}
