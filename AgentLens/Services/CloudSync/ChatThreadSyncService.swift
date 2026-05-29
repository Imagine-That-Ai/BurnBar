import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Sync domain for chat thread and message upload.
///
/// Uploads local chat threads to Firestore for cross-device resume.
///
/// Message bodies, thread titles, and previews are backed up only after explicit
/// `chatThreadContentCloudBackupEnabled` consent. Without that consent, the cloud
/// record contains non-content metadata only.
/// Layout: `users/{uid}/chat_threads/{deviceId}_{threadId}`
///
/// Uses existing DataStore APIs:
///   - `fetchChatThreadSummaries(limit:)` → `[ChatThreadSummary]`
///   - `fetchChatMessages(threadID:)` → `[ChatMessageRecord]`
final class ChatThreadSyncService: CloudSyncDomain, @unchecked Sendable {
    private let context: CloudSyncContext

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(context: CloudSyncContext) {
        self.context = context
    }

    /// Uploads chat threads and messages to Firestore for cross-device resume.
    /// Uses `fetchChatThreadSummaries` and `fetchChatMessages` — no unsynced-tracking needed
    /// since chat threads are idempotently written with merge.
    func sync(progress: CloudBackupProgressTracker? = nil) async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              let uid = gate.account.uid else { return }

        isSyncing = true
        lastSyncError = nil

        defer { isSyncing = false }

        do {
            progress?.setPhase(.chatThreads, operation: "Loading chat threads…")
            let threads = try context.dataStore.fetchChatThreadSummaries(limit: 500)
            guard !threads.isEmpty else {
                lastSyncDate = Date()
                return
            }

            let deviceId = gate.account.deviceId
            let batch = context.firestoreGateway.batch()
            let collectionRef = context.firestoreGateway
                .collection("users")
                .document(uid)
                .collection("chat_threads")

            let includeContent = gate.settings.chatThreadContentCloudBackupEnabled
            for thread in threads {
                let label = thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Thread \(thread.id.prefix(8))"
                    : thread.title
                progress?.setCurrentRecord(
                    label: label,
                    operation: includeContent ? "Packaging thread messages" : "Writing thread metadata"
                )

                let messages = includeContent
                    ? ((try? context.dataStore.fetchChatMessages(threadID: thread.id)) ?? [])
                    : []

                let docId = "\(deviceId)_\(thread.id)"
                let docRef = collectionRef.document(docId)

                var data: [String: Any] = [
                    "threadId": thread.id,
                    "messageCount": thread.messageCount,
                    "createdAt": Timestamp(date: thread.createdAt),
                    "updatedAt": Timestamp(date: thread.lastActivityAt),
                    "deviceId": deviceId,
                    "contentIncluded": includeContent,
                ]

                if includeContent {
                    let encodedMessages: [[String: Any]] = messages.map { msg -> [String: Any] in
                        var m: [String: Any] = [
                            "id": msg.id,
                            "role": msg.role == .user ? "user" : "assistant",
                            "content": String(msg.content.prefix(4000)),
                            "timestamp": Timestamp(date: msg.timestamp),
                        ]
                        if let cli = msg.cliUsed {
                            m["cliUsed"] = cli
                        }
                        if !msg.attachments.isEmpty {
                            // Attachments roundtrip metadata only — bytes stay
                            // on the originating device's chat workspace.
                            m["attachments"] = msg.attachments.map { att -> [String: Any] in
                                [
                                    "id": att.id,
                                    "kind": att.kind.rawValue,
                                    "displayName": att.displayName,
                                    "mimeType": att.mimeType,
                                    "byteSize": att.byteSize,
                                    "workspacePath": att.workspaceRelativePath,
                                ]
                            }
                        }
                        return m
                    }
                    data["title"] = thread.title
                    data["preview"] = String(thread.preview.prefix(500))
                    data["messages"] = encodedMessages
                } else {
                    data["messages"] = FieldValue.delete()
                    data["title"] = FieldValue.delete()
                    data["preview"] = FieldValue.delete()
                }
                batch.setData(data, forDocument: docRef, merge: true)
                progress?.recordChatThreadProcessed(label: label)
            }

            progress?.setCurrentRecord(label: "Chat threads", operation: "Committing Firestore batch")
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: "chatThread"
            ) {
                try await batch.commit()
            }
            lastSyncDate = Date()
            lastSyncError = nil
        } catch {
            progress?.fail(error.localizedDescription)
            lastSyncError = error.localizedDescription
        }
    }
}
