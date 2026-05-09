import FirebaseAuth
import FirebaseFirestore
import Foundation
import CryptoKit

/// Sync domain for uploading session-log manifests/search metadata to Firestore.
///
/// Firestore layout:
///   `users/{uid}/session_logs/{deviceId}_{escapedId}` (manifest)
///   `users/{uid}/session_logs/{docId}/chunks/{index}` (search metadata only)
///
/// Gated separately on `sessionLogCloudBackupEnabled`.
/// Uses its own dirty flag (`logSyncedAt`) so it is independent of metadata sync.
@MainActor
final class SessionLogSyncService: CloudSyncDomain {
    private let context: CloudSyncContext

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(context: CloudSyncContext) {
        self.context = context
    }

    /// Upload session-log manifests and search metadata to Firestore.
    func sync() async {
        guard context.accountManager.isFirebaseAvailable,
              context.accountManager.isSignedIn,
              context.accountManager.isCloudSyncEnabled,
              context.settingsManager.sessionLogCloudBackupEnabled,
              !context.syncIsSuppressed(),
              !isSyncing,
              let uid = context.currentUID else { return }

        isSyncing = true
        lastSyncError = nil

        defer { isSyncing = false }

        do {
            let unsynced = try context.dataStore.fetchUnsyncedSessionLogs(limit: 50)
            guard !unsynced.isEmpty else {
                lastSyncDate = Date()
                return
            }

            let userRef = context.firestoreGateway.collection("users").document(uid)
            let logsRef = userRef.collection("session_logs")
            let sessionModelMap = (try? context.dataStore.sessionModelMap()) ?? [:]

            for record in unsynced {
                let markdown = SessionLogMarkdownFormatter.markdown(for: record)
                let safeId = record.id
                    .replacingOccurrences(of: ":", with: "_")
                    .replacingOccurrences(of: "/", with: "_")
                let docId = "\(context.deviceId)_\(safeId)"
                let manifestRef = logsRef.document(docId)
                let bodyHash = Self.sha256Hex(markdown)
                let model = sessionModelMap["\(record.provider.rawValue):\(record.sessionId)"] ?? "unknown"

                if let existing = try await manifestRef.getData(),
                   existing["bodyHash"] as? String == bodyHash,
                   existing["chunkMetadataVersion"] as? Int == Self.chunkMetadataVersion {
                    try context.dataStore.markSessionLogsSynced(ids: [record.id])
                    continue
                }

                let chunks = Self.chunkUTF8String(markdown, maxBytes: 64_000)

                var manifest: [String: Any] = [
                    "id": record.id,
                    "deviceId": context.deviceId,
                    "provider": record.provider.rawValue,
                    "sessionId": record.sessionId,
                    "sourceType": record.sourceType.rawValue,
                    "projectName": record.projectName,
                    "inferredTaskTitle": record.inferredTaskTitle,
                    "messageCount": record.messageCount,
                    "bodyStorage": "local_or_icloud",
                    "chunkCount": 0,
                    "searchChunkCount": chunks.count,
                    "byteCount": markdown.utf8.count,
                    "bodyHash": bodyHash,
                    "chunkSize": 0,
                    "chunkHashes": chunks.map(Self.sha256Hex),
                    "chunkMetadataVersion": Self.chunkMetadataVersion,
                    "model": model,
                    "updatedAt": FieldValue.serverTimestamp()
                ]
                if let start = record.startTime { manifest["startTime"] = Timestamp(date: start) }
                if let end = record.endTime { manifest["endTime"] = Timestamp(date: end) }

                var writes: [(data: [String: Any], document: CloudSyncDocumentGateway, merge: Bool)] = [
                    (manifest, manifestRef, true)
                ]

                let chunksRef = manifestRef.collection("chunks")
                for (idx, chunk) in chunks.enumerated() {
                    let snippet = chunk
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    writes.append(([
                        "index": idx,
                        "hash": Self.sha256Hex(chunk),
                        "uid": uid,
                        "docId": docId,
                        "conversationId": record.id,
                        "sessionId": record.sessionId,
                        "deviceId": context.deviceId,
                        "provider": record.provider.rawValue,
                        "model": model,
                        "projectName": record.projectName,
                        "title": record.summaryTitle ?? record.inferredTaskTitle,
                        "snippet": String(snippet.prefix(500)),
                        "terms": Self.normalizedTerms(from: chunk + " " + record.inferredTaskTitle + " " + record.projectName + " " + model),
                        "bodyStorage": "local_or_icloud",
                        "bodyHash": bodyHash,
                        "schemaVersion": Self.chunkMetadataVersion,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], chunksRef.document(String(idx)), true))
                }

                for start in stride(from: 0, to: writes.count, by: 450) {
                    let batch = context.firestoreGateway.batch()
                    for write in writes[start..<min(start + 450, writes.count)] {
                        batch.setData(write.data, forDocument: write.document, merge: write.merge)
                    }
                    try await withCloudSyncRetry(
                        policy: context.retryPolicy,
                        circuitBreaker: context.circuitBreaker,
                        domain: "sessionLog.batch"
                    ) {
                        try await batch.commit()
                    }
                }
            }

            let ids = unsynced.map(\.id)
            try context.dataStore.markSessionLogsSynced(ids: ids)
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

    /// Splits a UTF-8 string into chunks each fitting within `maxBytes` bytes.
    static func chunkUTF8String(_ string: String, maxBytes: Int) -> [String] {
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

    private static let chunkMetadataVersion = 1

    private static func normalizedTerms(from text: String) -> [String] {
        let stopwords: Set<String> = ["the", "and", "for", "with", "that", "this", "from", "how", "what", "where", "when", "why", "are", "was"]
        let parts = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
        var seen = Set<String>()
        var terms: [String] = []
        for part in parts where seen.insert(part).inserted {
            terms.append(part)
            if terms.count >= 250 { break }
        }
        return terms
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension CloudSyncService {
    // MARK: - Session Log Upload (manifest + search metadata)

    /// Uploads session-log manifests and search metadata to Firestore.
    /// Layout: `users/{uid}/session_logs/{deviceId}_{escapedId}` (manifest)
    ///         `users/{uid}/session_logs/{docId}/chunks/{index}` (search metadata only)
    ///
    /// Gated separately on `sessionLogCloudBackupEnabled`.
    /// Uses its own dirty flag (`logSyncedAt`) so it is independent of metadata sync.
    func uploadPendingSessionLogs() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        let service = SessionLogSyncService(context: context)
        await service.sync()
        lastSyncDate = service.lastSyncDate
        lastSyncError = service.lastSyncError
    }

    // MARK: - Session Log Download (Firestore read-back)

    /// Fetches session log manifests from Firestore for the signed-in user.
    /// Returns ConversationRecords with empty fullText; body is fetched lazily via fetchCloudSessionLogBody(docId:).
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [ConversationRecord] {
        guard accountManager.isFirebaseAvailable,
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

    /// Reassembles legacy chunk sub-documents into the full Markdown body for a session log.
    ///
    /// New paid-scale backups keep large bodies out of Firestore. Those manifests
    /// intentionally return an empty string here; local SQLite or iCloud remains
    /// the body source.
    /// - Parameter docId: The Firestore document ID (stored in `record.sessionId` for cloud-sourced records).
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        guard accountManager.isFirebaseAvailable,
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
