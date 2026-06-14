import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Sync domain for uploading conversation metadata to Firestore.
///
/// Firestore layout: `users/{uid}/conversations/{deviceId}_{conversationId}`
/// Note: Full transcripts are NOT uploaded here; only metadata for cross-device recall.
final class ConversationSyncService: CloudSyncDomain, Sendable {
    private let context: CloudSyncContext
    private let vaultKeyProvider: any ConversationCloudVaultKeyProviding

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

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
              let uid = gate.account.uid else { return }

        guard state.beginSyncingIfIdle() else { return }

        defer { state.endSyncing() }

        do {
            let unsynced = try context.dataStore.fetchUnsyncedConversations(limit: 400)
            guard !unsynced.isEmpty else {
                state.withLock { $0.lastSyncDate = Date() }
                return
            }

            let batch = context.firestoreGateway.batch()
            let collectionRef = context.firestoreGateway.collection("users").document(uid).collection("conversations")
            let deviceId = gate.account.deviceId
            let vaultKey = try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: deviceId)

            for record in unsynced {
                let docId = "\(deviceId)_\(record.id)"
                let docRef = collectionRef.document(docId)
                var data = try Self.encodeConversation(
                    record,
                    uid: uid,
                    deviceId: deviceId,
                    docId: docId,
                    vaultKey: vaultKey
                )
                // L41/at-rest Signal dual-write (item 3). The legacy AES-GCM sealedPayload
                // is the FLOOR and is already in `data`; the additive Signal envelope is
                // BEST-EFFORT and gated by the conversations_chat sealingScheme. On ANY seal
                // failure (e.g. a trusted device without a published identity) we log and
                // write legacy-only for THIS record rather than abort it or the whole batch —
                // legacy is already end-to-end so no confidentiality is lost. We also clear a
                // stale envelope (merge:true) so a signalEnvelope can never outlive its
                // sealedPayload after a gate-off / rollback / consent-revoke.
                do {
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
                    } else {
                        data["signalEnvelope"] = FieldValue.delete()
                    }
                } catch {
                    AppLogger.sync.error(
                        "conversation_signal_seal_failed_legacy_only",
                        metadata: ["accountUid": uid, "docId": docId, "error": String(describing: error)]
                    )
                    data["signalEnvelope"] = FieldValue.delete()
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

            state.withLock {
                $0.lastSyncDate = Date()
                $0.lastSyncError = nil
            }
        } catch {
            await recordSyncError(error)
        }
    }

    private func recordSyncError(_ error: Error) async {
        state.withLock { $0.lastSyncError = error.localizedDescription }

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
        uid: String,
        deviceId: String,
        docId: String,
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
            "sealedPayload": try ConversationCloudSealer.seal(
                ConversationCloudPrivatePayload(record: record),
                key: vaultKey,
                uid: uid,
                docId: docId
            )
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
