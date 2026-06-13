import FirebaseAuth
import FirebaseFirestore
import Foundation
import OpenBurnBarCore

/// Garbage-collects conversation tombstones after the cross-device retention
/// window (B-DATA-2).
///
/// A soft-delete sets `deletedAt` on the local row and uploads it so every other
/// device observes the deletion. The row, its Cloud Storage body, the
/// `session_logs` manifest + cloud search index rows, and the `conversations`
/// metadata doc must all survive long enough for offline devices to sync the
/// tombstone — but no longer. After `retentionWindow` has elapsed this sweep:
///
/// 1. deletes the encrypted session body blob from Cloud Storage,
/// 2. deletes legacy `session_logs/{docId}/chunks/*` rows if present,
/// 3. deletes `cloud_search_documents/chunks/postings` rows for the document,
/// 4. deletes the `session_logs/{docId}` manifest,
/// 5. hard-deletes the local SQLite row.
///
/// The tiny `conversations/{deviceId}_{id}` metadata doc is deliberately left in
/// place — `firestore.rules` makes it non-deletable and it is the durable
/// tombstone marker that lets a long-offline device still learn the conversation
/// was deleted. Only the heavy bytes (encrypted body + search index) are purged.
///
/// Any per-conversation cloud failure is logged and the local row is preserved
/// so the next sweep retries; partial cloud cleanup never strands a local
/// tombstone in a state where the user keeps seeing it.
final class ConversationTombstoneGCService: CloudSyncDomain, @unchecked Sendable {
    /// Conversations stay recoverable for this long after a delete so offline
    /// devices can sync the tombstone before the cloud body is purged.
    static let retentionWindow: TimeInterval = 30 * 24 * 60 * 60

    private let context: CloudSyncContext
    private let encryptedCloudClient: SessionLogEncryptedCloudClient
    private let retentionWindow: TimeInterval
    private let now: () -> Date

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

    init(
        context: CloudSyncContext,
        encryptedCloudClient: SessionLogEncryptedCloudClient? = nil,
        retentionWindow: TimeInterval = ConversationTombstoneGCService.retentionWindow,
        now: @escaping () -> Date = Date.init
    ) {
        self.context = context
        self.encryptedCloudClient = encryptedCloudClient ?? FirebaseSessionLogEncryptedCloudClient()
        self.retentionWindow = retentionWindow
        self.now = now
    }

    func sync() async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              !gate.syncSuppressed,
              let uid = gate.account.uid else { return }

        guard state.beginSyncingIfIdle() else { return }
        defer { state.endSyncing() }

        let deviceId = gate.account.deviceId
        let cutoff = now().addingTimeInterval(-max(retentionWindow, 0))

        let expired: [ConversationRecord]
        do {
            expired = try context.dataStore.fetchExpiredConversationTombstones(before: cutoff, limit: 200)
        } catch {
            await recordSyncError(error)
            return
        }
        guard !expired.isEmpty else {
            state.withLock { $0.lastSyncDate = now() }
            return
        }

        var purgedCount = 0
        for record in expired {
            do {
                try await purgeRemoteArtifacts(record: record, uid: uid, localDeviceId: deviceId)
                try context.dataStore.deleteConversation(id: record.id)
                purgedCount += 1
            } catch {
                // Preserve the local row so the next sweep retries the cloud
                // cleanup; never hard-delete locally while cloud bytes remain.
                AppLogger.sync.error(
                    "conversation_tombstone_gc_purge_failed",
                    metadata: ["conversationId": record.id, "error": String(describing: error)]
                )
            }
        }

        AppLogger.sync.info(
            "conversation_tombstone_gc_swept",
            metadata: ["expired": "\(expired.count)", "purged": "\(purgedCount)"]
        )
        state.withLock {
            $0.lastSyncDate = now()
            $0.lastSyncError = nil
        }
    }

    /// Removes every cloud artifact backing a single tombstoned conversation.
    private func purgeRemoteArtifacts(record: ConversationRecord, uid: String, localDeviceId: String) async throws {
        // Remote rows are keyed by their origin device; local rows by this device.
        let manifestDeviceId = record.sourceDeviceId ?? localDeviceId
        let docId = SessionLogSyncService.cloudDocumentID(deviceId: manifestDeviceId, record: record)

        let userRef = context.firestoreGateway.collection("users").document(uid)
        let manifestRef = userRef.collection("session_logs").document(docId)

        // 1. Cloud Storage body — read the manifest's storagePath first.
        if let manifest = try await manifestRef.getData(),
           let storagePath = manifest["storagePath"] as? String,
           !storagePath.isEmpty {
            try await encryptedCloudClient.deleteEncryptedSessionBlob(
                documentID: docId,
                storagePath: storagePath
            )
        }

        // 2. Legacy search-index chunks under the manifest.
        let chunksRef = manifestRef.collection("chunks")
        let chunkSnapshot = try await chunksRef.getDocuments()
        for chunk in chunkSnapshot.documents {
            try await chunksRef.document(chunk.documentID).deleteDocument()
        }

        // 3. Current cloud-search index rows keyed by the same document id.
        try await userRef.collection("cloud_search_documents").document(docId).deleteDocument()
        try await deleteCloudSearchRows(
            userRef: userRef,
            collectionPath: "cloud_search_chunks",
            documentID: docId
        )
        try await deleteCloudSearchRows(
            userRef: userRef,
            collectionPath: "cloud_search_postings",
            documentID: docId
        )

        // 4. Manifest document itself.
        try await manifestRef.deleteDocument()
    }

    private func deleteCloudSearchRows(
        userRef: CloudSyncDocumentGateway,
        collectionPath: String,
        documentID: String
    ) async throws {
        let collectionRef = userRef.collection(collectionPath)
        while true {
            let snapshot = try await collectionRef
                .whereField("documentID", isEqualTo: documentID)
                .limit(to: 500)
                .getDocuments()
            let documents = snapshot.documents
            guard !documents.isEmpty else { return }
            for document in documents {
                try await collectionRef.document(document.documentID).deleteDocument()
            }
            if documents.count < 500 { return }
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
}
