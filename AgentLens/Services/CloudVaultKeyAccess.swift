import FirebaseFirestore
import Foundation
import OpenBurnBarCore

struct CloudVaultResolvedKey: Sendable {
    let keyData: Data
    let vaultKeyID: String
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

enum MacCloudVaultKeyAccess {
    static func keyForWriting(uid: String, deviceId: String, firestore: Firestore) async throws -> CloudVaultResolvedKey {
        let userRef = firestore.collection("users").document(uid)
        let keyStore = CloudVaultKeyStore()
        if let local = try keyStore.loadKey(uid: uid) {
            let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: local)
            try await ensureState(userRef: userRef, uid: uid, vaultKeyID: vaultKeyID, deviceId: deviceId)
            try await publishCloudVaultKey(uid: uid, vaultKey: local, vaultKeyID: vaultKeyID, deviceId: deviceId, userRef: userRef)
            return CloudVaultResolvedKey(keyData: local, vaultKeyID: vaultKeyID)
        }

        if let unwrapped = try await unwrapExistingKey(uid: uid, deviceId: deviceId, userRef: userRef) {
            try keyStore.saveKey(unwrapped.keyData, uid: uid)
            return unwrapped
        }

        let existingState = try await userRef.collection("cloud_vault_state").document("current").getDocument().data()
        if existingState != nil {
            throw CloudVaultAccessError.vaultKeyUnavailable
        }

        let created = CloudVaultCrypto.generateVaultKey()
        try keyStore.saveKey(created, uid: uid)
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: created)
        try await ensureState(userRef: userRef, uid: uid, vaultKeyID: vaultKeyID, deviceId: deviceId)
        try await publishCloudVaultKey(uid: uid, vaultKey: created, vaultKeyID: vaultKeyID, deviceId: deviceId, userRef: userRef)
        return CloudVaultResolvedKey(keyData: created, vaultKeyID: vaultKeyID)
    }

    static func keyForReading(uid: String, deviceId: String, firestore: Firestore) async throws -> CloudVaultResolvedKey? {
        let userRef = firestore.collection("users").document(uid)
        let keyStore = CloudVaultKeyStore()
        if let local = try keyStore.loadKey(uid: uid) {
            let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: local)
            return CloudVaultResolvedKey(keyData: local, vaultKeyID: vaultKeyID)
        }
        if let unwrapped = try await unwrapExistingKey(uid: uid, deviceId: deviceId, userRef: userRef) {
            try keyStore.saveKey(unwrapped.keyData, uid: uid)
            return unwrapped
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

    private static func publishCloudVaultKey(
        uid: String,
        vaultKey: Data,
        vaultKeyID: String,
        deviceId: String,
        userRef: DocumentReference
    ) async throws {
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(deviceId)")
        let deviceRef = userRef.collection("escrow_devices").document(deviceId)
        let existingDevice: [String: Any]?
        do {
            existingDevice = try await deviceRef.getDocument().data()
        } catch {
            existingDevice = nil
        }
        let existingTrustState = existingDevice?["trustState"] as? String
        let trustState = existingTrustState == EscrowDeviceTrustState.trusted.rawValue
            ? EscrowDeviceTrustState.trusted.rawValue
            : EscrowDeviceTrustState.pending.rawValue

        try await deviceRef.setData([
            "deviceId": deviceId,
            "deviceName": Host.current().localizedName ?? "Mac",
            "platform": "macOS",
            "trustState": trustState,
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
        try await userRef.collection("escrow_public_keys").document("\(deviceId)_\(keypair.keyVersion)").setData([
            "deviceId": deviceId,
            "publicKeyData": keypair.publicKeyData.base64EncodedString(),
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "algorithm": "ECIES-P256-AESGCM",
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true)

        let trusted = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()
        for doc in trusted.documents {
            let data = doc.data()
            let targetDeviceId = (data["deviceId"] as? String) ?? doc.documentID
            guard targetDeviceId.isEmpty == false,
                  let keyVersion = data["keyVersion"] as? Int,
                  let fingerprint = data["publicKeyFingerprint"] as? String else {
                continue
            }
            let publicKeyDoc = try await userRef.collection("escrow_public_keys")
                .document("\(targetDeviceId)_\(keyVersion)")
                .getDocument()
            guard let publicKeyBase64 = publicKeyDoc.data()?["publicKeyData"] as? String,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
                continue
            }
            let wrapped = try CloudVaultCrypto.wrapVaultKey(vaultKey, recipientPublicKey: publicKeyData)
            try await userRef.collection("cloud_vault_key_wrappers")
                .document("\(vaultKeyID)_\(targetDeviceId)_\(keyVersion)")
                .setData([
                    "uid": uid,
                    "vaultKeyID": vaultKeyID,
                    "targetDeviceId": targetDeviceId,
                    "sourceDeviceId": deviceId,
                    "publicKeyFingerprint": fingerprint,
                    "keyVersion": keyVersion,
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
