import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Sync domain for uploading conversation metadata to Firestore.
///
/// Firestore layout: `users/{uid}/conversations/{deviceId}_{conversationId}`
/// Note: Full transcripts are NOT uploaded here; only metadata for cross-device recall.
final class ConversationSyncService: CloudSyncDomain, @unchecked Sendable {
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

    /// Upload unsynced conversation metadata (excluding full transcripts).
    /// Runs after UsageAggregator.refreshAll(), matching token sync cadence.
    func sync() async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              gate.settings.conversationCloudBackupEnabled,
              !gate.syncSuppressed,
              !isSyncing,
              let uid = gate.account.uid else { return }

        isSyncing = true
        lastSyncError = nil

        defer { isSyncing = false }

        do {
            let unsynced = try context.dataStore.fetchUnsyncedConversations(limit: 400)
            guard !unsynced.isEmpty else {
                lastSyncDate = Date()
                return
            }

            let batch = context.firestoreGateway.batch()
            let collectionRef = context.firestoreGateway.collection("users").document(uid).collection("conversations")
            let deviceId = gate.account.deviceId
            let vaultKey = try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: deviceId)

            for record in unsynced {
                let docId = "\(deviceId)_\(record.id)"
                let docRef = collectionRef.document(docId)
                var data = try Self.encodeConversation(record, deviceId: deviceId, vaultKey: vaultKey)
                // L41/at-rest Signal dual-write (item 3). Inert in production until the
                // conversations_chat sealingScheme is flipped; seals the SAME plaintext bytes
                // the legacy AES-GCM sealedPayload uses, never replacing it.
                if let signalEnvelope = try await MacCloudVaultSignalPayloads.signalEnvelopeIfEnabled(
                    domainID: "conversations_chat",
                    uid: uid,
                    firestore: Firestore.firestore(),
                    collection: "conversations",
                    docId: docId,
                    plaintext: ConversationCloudSealer.encodePlaintext(ConversationCloudPrivatePayload(record: record)),
                    resolvedKey: vaultKey
                ) {
                    data["signalEnvelope"] = signalEnvelope
                }
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "conversation"
            ) {
                try await batch.commit()
            }

            let ids = unsynced.map(\.id)
            try context.dataStore.markConversationsSynced(ids: ids)

            lastSyncDate = Date()
            lastSyncError = nil
        } catch {
            await recordSyncError(error)
        }
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

    static func encodeConversation(
        _ record: ConversationRecord,
        deviceId: String,
        vaultKey: CloudVaultResolvedKey
    ) throws -> [String: Any] {
        var data: [String: Any] = [
            "id": record.id,
            "deviceId": deviceId,
            "provider": record.provider.rawValue,
            "sessionId": record.sessionId,
            "messageCount": record.messageCount,
            "userWordCount": record.userWordCount,
            "assistantWordCount": record.assistantWordCount,
            "updatedAt": FieldValue.serverTimestamp(),
            "sourceType": record.sourceType.rawValue,
            "version": record.version,
            "contentSealed": true,
            "sealedSchemaVersion": ConversationCloudSealer.sealedSchemaVersion,
            "vaultKeyID": vaultKey.vaultKeyID,
            "sealedPayload": try ConversationCloudSealer.seal(ConversationCloudPrivatePayload(record: record), key: vaultKey)
        ]
        ConversationCloudSealer.plaintextFieldDeletes.forEach { data[$0.key] = $0.value }
        // Tombstone propagation (B-DATA-2): a non-nil `deletedAt` tells every
        // other device to soft-delete its local copy. We still upload the rest of
        // the metadata so the doc carries a coherent last-known state.
        if let deletedAt = record.deletedAt {
            data["deletedAt"] = Timestamp(date: deletedAt)
        }
        data["startTime"] = record.startTime.map { Timestamp(date: $0) } as Any
        data["endTime"] = record.endTime.map { Timestamp(date: $0) } as Any
        return data
    }
}
