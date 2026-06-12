import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Sync domain for chat thread and message upload.
///
/// Uploads local chat threads to Firestore for cross-device resume.
///
/// Message bodies, thread titles, and previews are backed up only after explicit
/// `chatThreadContentCloudBackupEnabled` consent and are sealed before upload.
/// Without that consent, the cloud record contains non-content metadata only.
/// Layout: `users/{uid}/chat_threads/{deviceId}_{threadId}`
///
/// Uses existing DataStore APIs:
///   - `fetchChatThreadSummaries(limit:)` → `[ChatThreadSummary]`
///   - `fetchChatMessages(threadID:)` → `[ChatMessageRecord]`
final class ChatThreadSyncService: CloudSyncDomain, @unchecked Sendable {
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

    func sync() async {
        await sync(progress: nil)
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
            let resolvedKey = includeContent
                ? try await vaultKeyProvider.keyForWriting(uid: uid, deviceId: deviceId)
                : nil
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
                    "contentIncluded": includeContent
                ]

                if includeContent, let resolvedKey {
                    let payload = ChatThreadSealedPayload(
                        threadId: thread.id,
                        title: thread.title,
                        preview: String(thread.preview.prefix(500)),
                        messages: messages.map(ChatThreadSealedPayload.Message.init)
                    )
                    let payloadData = try Self.sealedPayloadEncoder.encode(payload)
                    let sealedPayload = try CloudVaultCrypto.sealPayload(
                        payloadData,
                        keyData: resolvedKey.keyData,
                        vaultKeyID: resolvedKey.vaultKeyID
                    )
                    data["contentSealed"] = true
                    data["sealedSchemaVersion"] = 2
                    data["vaultKeyID"] = resolvedKey.vaultKeyID
                    data["sealedPayload"] = CloudVaultCrypto.sealedPayloadDictionary(sealedPayload)
                    // L41/at-rest Signal dual-write (item 3). The legacy AES-GCM sealedPayload
                    // above is the FLOOR; the additive Signal envelope is BEST-EFFORT and gated
                    // by the conversations_chat sealingScheme. On ANY seal failure we log and
                    // write legacy-only (legacy is already E2EE) rather than abort the record or
                    // batch, and clear a stale envelope so it can never outlive its sealedPayload.
                    do {
                        if let signalEnvelope = try await MacCloudVaultSignalPayloads.signalEnvelopeIfEnabled(
                            domainID: "conversations_chat",
                            uid: uid,
                            firestore: Firestore.firestore(),
                            collection: "chat_threads",
                            docId: docId,
                            plaintext: payloadData,
                            resolvedKey: resolvedKey
                        ) {
                            data["signalEnvelope"] = signalEnvelope
                        } else {
                            data["signalEnvelope"] = FieldValue.delete()
                        }
                    } catch {
                        AppLogger.sync.error(
                            "chat_thread_signal_seal_failed_legacy_only",
                            metadata: ["accountUid": uid, "docId": docId, "error": String(describing: error)]
                        )
                        data["signalEnvelope"] = FieldValue.delete()
                    }
                    data["title"] = FieldValue.delete()
                    data["preview"] = FieldValue.delete()
                    data["messages"] = FieldValue.delete()
                } else {
                    data["messages"] = FieldValue.delete()
                    data["title"] = FieldValue.delete()
                    data["preview"] = FieldValue.delete()
                    data["sealedPayload"] = FieldValue.delete()
                    data["vaultKeyID"] = FieldValue.delete()
                    data["contentSealed"] = false
                    // Content is being UN-sealed; the at-rest Signal envelope must not survive
                    // its sealedPayload (a Signal-first reader would otherwise prefer stale text).
                    data["signalEnvelope"] = FieldValue.delete()
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

    private static var sealedPayloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private struct ChatThreadSealedPayload: Codable {
    struct Message: Codable {
        struct Attachment: Codable {
            let id: String
            let kind: String
            let displayName: String
            let mimeType: String
            let byteSize: Int
            let workspacePath: String
        }

        let id: String
        let role: String
        let content: String
        let timestamp: Date
        let cliUsed: String?
        let attachments: [Attachment]

        init(_ message: ChatMessageRecord) {
            id = message.id
            switch message.role {
            case .user:
                role = "user"
            case .assistant:
                role = "assistant"
            case .system:
                role = "system"
            }
            content = String(message.content.prefix(4000))
            timestamp = message.timestamp
            cliUsed = message.cliUsed
            attachments = message.attachments.map { attachment in
                Attachment(
                    id: attachment.id,
                    kind: attachment.kind.rawValue,
                    displayName: attachment.displayName,
                    mimeType: attachment.mimeType,
                    byteSize: attachment.byteSize,
                    workspacePath: attachment.workspaceRelativePath
                )
            }
        }
    }

    let threadId: String
    let title: String
    let preview: String
    let messages: [Message]
}
