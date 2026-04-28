import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Sync domain for uploading conversation metadata to Firestore.
///
/// Firestore layout: `users/{uid}/conversations/{deviceId}_{conversationId}`
/// Note: Full transcripts are NOT uploaded here; only metadata for cross-device recall.
@MainActor
final class ConversationSyncService: CloudSyncDomain {
    private let context: CloudSyncContext

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(context: CloudSyncContext) {
        self.context = context
    }

    /// Upload unsynced conversation metadata (excluding full transcripts).
    /// Runs after UsageAggregator.refreshAll(), matching token sync cadence.
    func sync() async {
        guard context.accountManager.isFirebaseAvailable,
              context.accountManager.isSignedIn,
              context.accountManager.isCloudSyncEnabled,
              context.settingsManager.conversationCloudBackupEnabled,
              !context.syncIsSuppressed(),
              !isSyncing,
              let uid = context.currentUID else { return }

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

            for record in unsynced {
                let docId = "\(context.deviceId)_\(record.id)"
                let docRef = collectionRef.document(docId)
                let data = Self.encodeConversation(record, deviceId: context.deviceId)
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

    static func encodeConversation(_ record: ConversationRecord, deviceId: String) -> [String: Any] {
        var data: [String: Any] = [
            "id": record.id,
            "deviceId": deviceId,
            "provider": record.provider.rawValue,
            "sessionId": record.sessionId,
            "projectName": record.projectName,
            "messageCount": record.messageCount,
            "userWordCount": record.userWordCount,
            "assistantWordCount": record.assistantWordCount,
            "keyFiles": record.keyFiles,
            "keyCommands": record.keyCommands,
            "keyTools": record.keyTools,
            "inferredTaskTitle": record.inferredTaskTitle,
            "lastAssistantMessage": capLastAssistantMessage(record.lastAssistantMessage),
            "updatedAt": FieldValue.serverTimestamp(),
            "sourceType": record.sourceType.rawValue
        ]
        data["startTime"] = record.startTime.map { Timestamp(date: $0) } as Any
        data["endTime"] = record.endTime.map { Timestamp(date: $0) } as Any
        if let summary = record.summary { data["summary"] = summary }
        if let summaryTitle = record.summaryTitle { data["summaryTitle"] = summaryTitle }
        if let summaryProvider = record.summaryProvider { data["summaryProvider"] = summaryProvider }
        if let summaryModel = record.summaryModel { data["summaryModel"] = summaryModel }
        return data
    }

    private static func capLastAssistantMessage(_ text: String) -> String {
        if text.count <= 500 { return text }
        return String(text.prefix(500))
    }
}
