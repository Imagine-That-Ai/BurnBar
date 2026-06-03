import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Sync domain for uploading local TokenUsage rows to Firestore.
///
/// Firestore layout: `users/{uid}/usage/{deviceId}_{usageId}`
///
/// Project names are private text BurnBar must not be able to read. They are
/// sealed with the per-user Cloud Vault key (`sealedProjectName`) instead of
/// being written in plaintext. An opaque keyed `projectKeyHash` is also written
/// so on-device readers can group usage by project without decrypting every row.
final class UsageSyncService: CloudSyncDomain, @unchecked Sendable {
    private let context: CloudSyncContext
    private let vaultKeyProvider: any ConversationCloudVaultKeyProviding

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(
        context: CloudSyncContext,
        vaultKeyProvider: any ConversationCloudVaultKeyProviding = MacConversationCloudVaultKeyProvider()
    ) {
        self.context = context
        self.vaultKeyProvider = vaultKeyProvider
    }

    /// Upload all unsynced local usage rows to Firestore.
    /// Call after UsageAggregator.refreshAll().
    func sync() async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              !gate.syncSuppressed,
              !isSyncing,
              let uid = gate.account.uid else { return }

        isSyncing = true
        lastSyncError = nil
        let deviceId = gate.account.deviceId

        defer { isSyncing = false }

        do {
            let collectionRef = context.firestoreGateway.collection("users").document(uid).collection("usage")
            let resolvedVaultKey = try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: deviceId)

            while true {
                let unsynced = try context.dataStore.fetchUnsynced()
                guard !unsynced.isEmpty else { break }

                let batch = context.firestoreGateway.batch()

                for usage in unsynced {
                    let docId = "\(deviceId)_\(usage.id.uuidString)"
                    let docRef = collectionRef.document(docId)
                    let data = try encodeUsage(usage, deviceId: deviceId, vaultKey: resolvedVaultKey.keyData)
                    batch.setData(data, forDocument: docRef, merge: true)
                }

                try await withCloudSyncRetry(
                    policy: context.retryPolicy,
                    circuitBreaker: context.circuitBreaker,
                    domain: "usage"
                ) {
                    try await batch.commit()
                }

                let syncedIds = unsynced.map { $0.id }
                try context.dataStore.markSynced(ids: syncedIds)
            }

            lastSyncDate = Date()
            lastSyncError = nil
            try await publishSyncHeartbeat(uid: uid, deviceId: deviceId, collectionsInSync: ["usage"])
        } catch {
            await recordSyncError(error)
        }
    }

    private func publishSyncHeartbeat(uid: String, deviceId: String, collectionsInSync: [String]) async throws {
        let now = Date()
        let deviceName = Host.current().localizedName ?? "OpenBurnBar Mac"
        let userRef = context.firestoreGateway.collection("users").document(uid)

        try await userRef.collection("devices").document(deviceId).setData([
            "deviceId": deviceId,
            "deviceName": deviceName,
            "platform": "macOS",
            "isLocal": true,
            "lastSeenAt": Timestamp(date: now),
            "updatedAt": Timestamp(date: now)
        ], merge: true)

        try await userRef.collection("sync_status").document(deviceId).setData([
            "deviceId": deviceId,
            "isOnline": true,
            "lastSyncAt": Timestamp(date: now),
            "collectionsInSync": collectionsInSync,
            "updatedAt": Timestamp(date: now)
        ], merge: true)
    }

    private func recordSyncError(_ error: Error) async {
        lastSyncError = error.localizedDescription

        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }
        await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
    }

    private func encodeUsage(_ usage: TokenUsage, deviceId: String, vaultKey: Data) throws -> [String: Any] {
        var data: [String: Any] = [
            "id": usage.id.uuidString,
            "deviceId": deviceId,
            "provider": usage.provider.rawValue,
            "providerID": usage.providerID.rawValue,
            "sessionId": usage.sessionId,
            "model": usage.model,
            "inputTokens": usage.inputTokens,
            "outputTokens": usage.outputTokens,
            "cacheCreationTokens": usage.cacheCreationTokens,
            "cacheReadTokens": usage.cacheReadTokens,
            "reasoningTokens": usage.reasoningTokens,
            "usageSource": usage.usageSource.rawValue,
            "totalTokens": usage.totalTokens,
            "cost": usage.cost,
            "startTime": Timestamp(date: usage.startTime),
            "endTime": Timestamp(date: usage.endTime),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let providerAccountID = usage.providerAccountID {
            data["providerAccountID"] = providerAccountID
        }
        if let providerAccountLabel = usage.providerAccountLabel {
            data["providerAccountLabel"] = providerAccountLabel
        }
        if let providerAccountSource = usage.providerAccountSource {
            data["providerAccountSource"] = providerAccountSource.rawValue
        }

        // Seal the project name instead of writing it in clear. The server stays a
        // blind store-and-forward: only on-device key holders can recover the name.
        let sealedProjectName = try CloudVaultCrypto.sealText(usage.projectName, keyData: vaultKey)
        data["sealedProjectName"] = try CloudVaultCrypto.dictionary(sealedProjectName)
        // Opaque keyed group-by trapdoor so readers can bucket usage by project
        // without decrypting every row. Absent for empty/blank names.
        if let projectKeyHash = CloudVaultCrypto.projectKeyHash(for: usage.projectName, keyData: vaultKey) {
            data["projectKeyHash"] = projectKeyHash
        }
        return data
    }
}

enum CloudVaultProjectSealError: Error {
    case encodingFailed
}

extension CloudVaultCrypto {
    /// Serializes a `Codable` sealed envelope into a Firestore-native dictionary.
    static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudVaultProjectSealError.encodingFailed
        }
        return dictionary
    }

    /// Stable opaque group-by token for a project name (32 hex chars), derived via
    /// the existing keyed search trapdoor. Collapses the name to a single canonical
    /// alphanumeric term so multi-word names hash to one stable bucket, then HMACs
    /// it under the per-user search key. Returns `nil` for empty/blank names.
    ///
    /// Reuses `CloudVaultCrypto.tokenHashes` only — no new crypto is introduced.
    static func projectKeyHash(for projectName: String, keyData: Data) -> String? {
        let normalized = normalizedTokens(from: projectName).joined()
        guard normalized.isEmpty == false else { return nil }
        return try? tokenHashes(for: normalized, keyData: keyData, limit: 1).first
    }

    /// Opens a sealed project name from a Firestore document, falling back to the
    /// legacy plaintext `projectName` field for in-flight / pre-migration docs.
    /// Returns `nil` only when neither the sealed field nor a legacy field is present.
    static func openSealedProjectName(
        from data: [String: Any],
        sealedField: String = "sealedProjectName",
        legacyField: String = "projectName",
        keyData: Data?
    ) -> String? {
        if let raw = data[sealedField],
           let envelope = decodeSealedText(from: raw) {
            if let keyData, let plaintext = try? openText(envelope, keyData: keyData) {
                return plaintext
            }
            // Sealed but unreadable on this device — do not leak a legacy value.
            return nil
        }
        return data[legacyField] as? String
    }

    /// Decodes a `CloudVaultSealedText` envelope from a Firestore-native dictionary.
    static func decodeSealedText(from raw: Any?) -> CloudVaultSealedText? {
        guard let dict = raw as? [String: Any],
              let algorithm = dict["algorithm"] as? String,
              let keyVersion = (dict["keyVersion"] as? Int) ?? (dict["keyVersion"] as? NSNumber)?.intValue,
              let nonce = dict["nonce"] as? String,
              let ciphertext = dict["ciphertext"] as? String,
              let tag = dict["tag"] as? String else {
            return nil
        }
        return CloudVaultSealedText(
            algorithm: algorithm,
            keyVersion: keyVersion,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
    }
}
