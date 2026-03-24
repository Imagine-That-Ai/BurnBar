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
        if let summaryTitle = record.summaryTitle {
            data["summaryTitle"] = summaryTitle
        } else {
            data["summaryTitle"] = NSNull()
        }
        if let summaryProvider = record.summaryProvider {
            data["summaryProvider"] = summaryProvider
        } else {
            data["summaryProvider"] = NSNull()
        }
        if let summaryModel = record.summaryModel {
            data["summaryModel"] = summaryModel
        } else {
            data["summaryModel"] = NSNull()
        }
        return data
    }

    private static func capLastAssistantMessage(_ text: String) -> String {
        if text.count <= 500 { return text }
        return String(text.prefix(500))
    }

    // MARK: - Session Log Upload (full Markdown, chunked)

    /// Uploads full session-log Markdown bodies to Firestore.
    /// Layout: `users/{uid}/session_logs/{deviceId}_{escapedId}` (manifest)
    ///         `users/{uid}/session_logs/{docId}/chunks/{index}` (body chunks)
    ///
    /// Gated separately on `sessionLogCloudBackupEnabled`.
    /// Uses its own dirty flag (`logSyncedAt`) so it is independent of metadata sync.
    func uploadPendingSessionLogs() async {
        guard FirebaseApp.app() != nil,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              SettingsManager.shared.sessionLogCloudBackupEnabled,
              !isSyncing,
              let uid = Auth.auth().currentUser?.uid else { return }

        isSyncing = true
        lastSyncError = nil

        do {
            let unsynced = try dataStore.fetchUnsyncedSessionLogs(limit: 50)
            guard !unsynced.isEmpty else {
                isSyncing = false
                lastSyncDate = Date()
                return
            }

            let deviceId = accountManager.deviceId
            let logsRef = db.collection("users").document(uid).collection("session_logs")

            for record in unsynced {
                let markdown = SessionLogMarkdownFormatter.markdown(for: record)
                let safeId = record.id
                    .replacingOccurrences(of: ":", with: "_")
                    .replacingOccurrences(of: "/", with: "_")
                let docId = "\(deviceId)_\(safeId)"
                let manifestRef = logsRef.document(docId)

                let chunks = Self.chunkUTF8String(markdown, maxBytes: 900_000)

                // Write manifest
                var manifest: [String: Any] = [
                    "id": record.id,
                    "deviceId": deviceId,
                    "provider": record.provider.rawValue,
                    "sourceType": record.sourceType.rawValue,
                    "projectName": record.projectName,
                    "inferredTaskTitle": record.inferredTaskTitle,
                    "messageCount": record.messageCount,
                    "chunkCount": chunks.count,
                    "byteCount": markdown.utf8.count,
                    "updatedAt": FieldValue.serverTimestamp()
                ]
                if let start = record.startTime { manifest["startTime"] = Timestamp(date: start) }
                if let end = record.endTime { manifest["endTime"] = Timestamp(date: end) }

                try await manifestRef.setData(manifest, merge: true)

                // Write chunks as sub-documents
                let chunksRef = manifestRef.collection("chunks")
                for (idx, chunk) in chunks.enumerated() {
                    try await chunksRef.document(String(idx)).setData([
                        "index": idx,
                        "body": chunk,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], merge: true)
                }
            }

            let ids = unsynced.map(\.id)
            try dataStore.markSessionLogsSynced(ids: ids)
            lastSyncDate = Date()
            lastSyncError = nil
        } catch {
            lastSyncError = error.localizedDescription
        }

        isSyncing = false
    }

    // MARK: - Session Log Download (Firestore read-back)

    /// Fetches session log manifests from Firestore for the signed-in user.
    /// Returns ConversationRecords with empty fullText; body is fetched lazily via fetchCloudSessionLogBody(docId:).
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [ConversationRecord] {
        guard FirebaseApp.app() != nil,
              accountManager.isSignedIn,
              let uid = Auth.auth().currentUser?.uid else { return [] }

        let snapshot = try await db
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .order(by: "updatedAt", descending: true)
            .limit(to: limit)
            .getDocuments()

        return snapshot.documents.compactMap { doc -> ConversationRecord? in
            let data = doc.data()
            guard let rawProvider = data["provider"] as? String,
                  let provider = AgentProvider(rawValue: rawProvider) else { return nil }

            let id = data["id"] as? String ?? doc.documentID
            let sourceTypeRaw = data["sourceType"] as? String ?? ConversationSourceType.providerLog.rawValue
            let sourceType = ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog

            return ConversationRecord(
                id: id,
                provider: provider,
                // Store Firestore docId in sessionId so fetchCloudSessionLogBody can look up chunks
                sessionId: doc.documentID,
                projectName: data["projectName"] as? String ?? "",
                startTime: (data["startTime"] as? Timestamp)?.dateValue(),
                endTime: (data["endTime"] as? Timestamp)?.dateValue(),
                messageCount: data["messageCount"] as? Int ?? 0,
                userWordCount: 0,
                assistantWordCount: 0,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: data["inferredTaskTitle"] as? String ?? "",
                lastAssistantMessage: "",
                fullText: "",
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: nil,
                sourceType: sourceType
            )
        }
    }

    /// Reassembles chunk sub-documents into the full Markdown body for a session log.
    /// - Parameter docId: The Firestore document ID (stored in `record.sessionId` for cloud-sourced records).
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        guard FirebaseApp.app() != nil,
              let uid = Auth.auth().currentUser?.uid else { return "" }

        let snapshot = try await db
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .document(docId)
            .collection("chunks")
            .order(by: "index")
            .getDocuments()

        return snapshot.documents
            .compactMap { $0.data()["body"] as? String }
            .joined()
    }

    // MARK: - Chunking

    /// Splits a UTF-8 string into chunks each fitting within `maxBytes` bytes.
    private static func chunkUTF8String(_ string: String, maxBytes: Int) -> [String] {
        let data = Data(string.utf8)
        guard data.count > maxBytes else { return [string] }

        var chunks: [String] = []
        var offset = 0
        while offset < data.count {
            var end = min(offset + maxBytes, data.count)
            // Walk back until we find a valid UTF-8 boundary
            while end > offset, String(data: data[offset..<end], encoding: .utf8) == nil {
                end -= 1
            }
            if let chunk = String(data: data[offset..<end], encoding: .utf8) {
                chunks.append(chunk)
            }
            offset = end
        }
        return chunks.isEmpty ? [string] : chunks
    }
}
