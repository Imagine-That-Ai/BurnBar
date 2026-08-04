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

        let syncStartTime = Date()

        defer { state.endSyncing() }

        do {
            let unsynced = try await context.dataStore.fetchUnsyncedConversations(limit: 400)
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
                data["source"] = "macos-agentlens"
                data = try await MacCloudVaultSignalPayloads.applyingSignalEnvelope(
                    to: data,
                    domainID: "conversations_chat",
                    uid: uid,
                    firestore: Firestore.firestore(),
                    collection: "conversations",
                    docId: docId,
                    plaintext: ConversationCloudSealer.encodePlaintext(ConversationCloudPrivatePayload(record: record)),
                    resolvedKey: vaultKey,
                    legacyPrivateFields: ["sealedPayload", "sealedSchemaVersion", "vaultKeyID", "contentSealed"],
                    mergeWrite: true
                )
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
            try await context.dataStore.markConversationsSynced(ids: ids)

            state.withLock {
                $0.lastSyncDate = Date()
                $0.lastSyncError = nil
            }
            let durationBucket = AnalyticsBuckets.durationMs(Int(Date().timeIntervalSince(syncStartTime) * 1000))
            let itemCountBucket = AnalyticsBuckets.count(unsynced.count)
            Task { @MainActor in
                Analytics.shared.track(.cloudsyncCompleted, [
                    "domain": "conversations",
                    "outcome": "success",
                    "duration_ms_bucket": .string(durationBucket),
                    "item_count_bucket": .string(itemCountBucket)
                ])
            }
        } catch {
            await recordSyncError(error)
        }
    }

    private func recordSyncError(_ error: Error) async {
        state.withLock { $0.lastSyncError = error.localizedDescription }

        let nsError = error as NSError
        let errorType = String(describing: type(of: error))
        let isPermissionDenied = nsError.domain == FirestoreErrorDomain
            && FirestoreErrorCode.Code(rawValue: nsError.code) == .permissionDenied
        Task { @MainActor in
            Analytics.shared.track(.cloudsyncFailed, [
                "domain": "conversations",
                "error_type": .string(errorType),
                "is_permission_denied": .bool(isPermissionDenied)
            ])
        }
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }
        await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
    }

    static func encodeConversation(
        _ record: OpenBurnBarCore.ConversationRecord,
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
