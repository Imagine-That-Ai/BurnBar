import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation

// MARK: - CloudSyncService

/// Uploads unsynced local TokenUsage rows to Firestore under the authenticated user's namespace.
///
/// Layout: `users/{uid}/usage/{deviceId}_{usageId}`
///
/// Conversation metadata (no full transcripts): `users/{uid}/conversations/{deviceId}_{conversationId}`
///
/// Idempotent: document IDs are deterministic, so re-uploading the same row is a no-op.
@Observable
@MainActor
final class CloudSyncService {

    // MARK: - State

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncError: String?
    private(set) var cloudTotalCost: Double?

    // MARK: - Dependencies

    private let dataStore: DataStore
    private let accountManager: AccountManager

    /// `Firestore.firestore()` is only read from sync methods that guard `FirebaseApp.app()` first.
    private var db: Firestore { Firestore.firestore() }

    // MARK: - Init

    init(dataStore: DataStore, accountManager: AccountManager) {
        self.dataStore = dataStore
        self.accountManager = accountManager
    }

    // MARK: - Sync

    /// Upload all unsynced local rows to Firestore. Call after refreshAll().
    func uploadPending() async {
        guard FirebaseApp.app() != nil,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              !isSyncing,
              let uid = Auth.auth().currentUser?.uid else { return }

        isSyncing = true
        lastSyncError = nil

        do {
            let unsynced = try dataStore.fetchUnsynced()
            guard !unsynced.isEmpty else {
                isSyncing = false
                lastSyncDate = Date()
                return
            }

            let deviceId = accountManager.deviceId

            // Firestore batch limit is 500 ops; we fetch max 400 rows at a time
            let batch = db.batch()
            let collectionRef = db.collection("users").document(uid).collection("usage")

            for usage in unsynced {
                let docId = "\(deviceId)_\(usage.id.uuidString)"
                let docRef = collectionRef.document(docId)
                let data = encodeUsage(usage, deviceId: deviceId)
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await batch.commit()

            let syncedIds = unsynced.map { $0.id }
            try dataStore.markSynced(ids: syncedIds)

            lastSyncDate = Date()
            lastSyncError = nil

            // Refresh cloud aggregate after sync
            await fetchCloudTotal(uid: uid)
        } catch {
            lastSyncError = error.localizedDescription
        }

        isSyncing = false
    }

    /// Uploads unsynced conversation metadata (excluding full transcripts) for cross-device recall.
    /// Runs at the end of `UsageAggregator.refreshAll()` (after `uploadPending()`), matching token sync cadence.
    func uploadPendingConversations() async {
        guard FirebaseApp.app() != nil,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              SettingsManager.shared.conversationCloudBackupEnabled,
              !isSyncing,
              let uid = Auth.auth().currentUser?.uid else { return }

        isSyncing = true
        lastSyncError = nil

        do {
            let unsynced = try dataStore.fetchUnsyncedConversations(limit: 400)
            guard !unsynced.isEmpty else {
                isSyncing = false
                lastSyncDate = Date()
                return
            }

            let deviceId = accountManager.deviceId
            let batch = db.batch()
            let collectionRef = db.collection("users").document(uid).collection("conversations")

            for record in unsynced {
                let docId = "\(deviceId)_\(record.id)"
                let docRef = collectionRef.document(docId)
                let data = Self.encodeConversation(record, deviceId: deviceId)
                batch.setData(data, forDocument: docRef, merge: true)
            }

            try await batch.commit()

            let ids = unsynced.map(\.id)
            try dataStore.markConversationsSynced(ids: ids)

            lastSyncDate = Date()
            lastSyncError = nil

            await fetchCloudTotal(uid: uid)
        } catch {
            lastSyncError = error.localizedDescription
        }

        isSyncing = false
    }

    // MARK: - Cloud Aggregate

    /// Fetch sum of cost across all devices for this user (last 90 days).
    func fetchCloudTotal(uid: String? = nil) async {
        guard FirebaseApp.app() != nil else { return }
        let resolvedUid = uid ?? Auth.auth().currentUser?.uid
        guard let resolvedUid else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date()) ?? Date()

        do {
            let snapshot = try await db
                .collection("users")
                .document(resolvedUid)
                .collection("usage")
                .whereField("startTime", isGreaterThan: Timestamp(date: cutoff))
                .getDocuments()

            let total = snapshot.documents.compactMap { doc -> Double? in
                doc.data()["cost"] as? Double
            }.reduce(0, +)

            cloudTotalCost = total
        } catch {
            // Non-fatal: aggregate failing doesn't break local experience
        }
    }

    // MARK: - Encoding

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
            "totalTokens": usage.totalTokens,
            "cost": usage.cost,
            "startTime": Timestamp(date: usage.startTime),
            "endTime": Timestamp(date: usage.endTime),
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    private static func encodeConversation(_ record: ConversationRecord, deviceId: String) -> [String: Any] {
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
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let start = record.startTime {
            data["startTime"] = Timestamp(date: start)
        } else {
            data["startTime"] = NSNull()
        }
        if let end = record.endTime {
            data["endTime"] = Timestamp(date: end)
        } else {
            data["endTime"] = NSNull()
        }
        if let summary = record.summary {
            data["summary"] = summary
        } else {
            data["summary"] = NSNull()
        }
        return data
    }

    private static func capLastAssistantMessage(_ text: String) -> String {
        if text.count <= 500 { return text }
        return String(text.prefix(500))
    }
}
