import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Sync domain for uploading local TokenUsage rows to Firestore.
///
/// Firestore layout: `users/{uid}/usage/{deviceId}_{usageId}`
@MainActor
final class UsageSyncService: CloudSyncDomain {
    private let context: CloudSyncContext

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(context: CloudSyncContext) {
        self.context = context
    }

    /// Upload all unsynced local usage rows to Firestore.
    /// Call after UsageAggregator.refreshAll().
    func sync() async {
        guard context.accountManager.isFirebaseAvailable,
              context.accountManager.isSignedIn,
              context.accountManager.isCloudSyncEnabled,
              !context.syncIsSuppressed(),
              !isSyncing,
              let uid = context.currentUID else { return }

        isSyncing = true
        lastSyncError = nil

        defer { isSyncing = false }

        do {
            let unsynced = try context.dataStore.fetchUnsynced()
            guard !unsynced.isEmpty else {
                lastSyncDate = Date()
                return
            }

            let batch = context.db.batch()
            let collectionRef = context.db.collection("users").document(uid).collection("usage")

            for usage in unsynced {
                let docId = "\(context.deviceId)_\(usage.id.uuidString)"
                let docRef = collectionRef.document(docId)
                let data = encodeUsage(usage, deviceId: context.deviceId)
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await batch.commit()

            let syncedIds = unsynced.map { $0.id }
            try context.dataStore.markSynced(ids: syncedIds)

            lastSyncDate = Date()
            lastSyncError = nil
        } catch {
            recordSyncError(error)
        }
    }

    private func recordSyncError(_ error: Error) {
        lastSyncError = error.localizedDescription

        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }
        context.suppressedSyncUntil = Date().addingTimeInterval(CloudSyncBackoffPolicy.permissionDeniedCooldown)
    }

    private func encodeUsage(_ usage: TokenUsage, deviceId: String) -> [String: Any] {
        [
            "id": usage.id.uuidString,
            "deviceId": deviceId,
            "provider": usage.provider.rawValue,
            "sessionId": usage.sessionId,
            "projectName": usage.projectName,
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
    }
}
