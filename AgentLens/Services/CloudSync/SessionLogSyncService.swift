import FirebaseAuth
import FirebaseFirestore
import Foundation
import CryptoKit

/// Sync domain for uploading full session-log Markdown bodies to Firestore.
///
/// Firestore layout:
///   `users/{uid}/session_logs/{deviceId}_{escapedId}` (manifest)
///   `users/{uid}/session_logs/{docId}/chunks/{index}` (body chunks)
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

    /// Upload full session-log Markdown bodies to Firestore.
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
            let searchRef = userRef.collection("stream_search_chunks")
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
                let searchChunks = Self.makeSearchChunks(
                    markdown: markdown,
                    record: record,
                    docId: docId,
                    deviceId: context.deviceId,
                    model: model,
                    bodyHash: bodyHash
                )

                if let existing = try await manifestRef.getData(),
                   existing["bodyHash"] as? String == bodyHash,
                   existing["searchIndexVersion"] as? Int == Self.searchIndexVersion {
                    try context.dataStore.markSessionLogsSynced(ids: [record.id])
                    continue
                }

                let chunks = Self.chunkUTF8String(markdown, maxBytes: 900_000)

                var manifest: [String: Any] = [
                    "id": record.id,
                    "deviceId": context.deviceId,
                    "provider": record.provider.rawValue,
                    "sessionId": record.sessionId,
                    "sourceType": record.sourceType.rawValue,
                    "projectName": record.projectName,
                    "inferredTaskTitle": record.inferredTaskTitle,
                    "messageCount": record.messageCount,
                    "chunkCount": chunks.count,
                    "byteCount": markdown.utf8.count,
                    "bodyHash": bodyHash,
                    "chunkSize": 900_000,
                    "chunkHashes": chunks.map(Self.sha256Hex),
                    "searchChunkCount": searchChunks.count,
                    "searchIndexVersion": Self.searchIndexVersion,
                    "updatedAt": FieldValue.serverTimestamp()
                ]
                if let start = record.startTime { manifest["startTime"] = Timestamp(date: start) }
                if let end = record.endTime { manifest["endTime"] = Timestamp(date: end) }

                var batch = context.firestoreGateway.batch()
                var pendingWrites = 0
                func enqueue(_ data: [String: Any], for document: CloudSyncDocumentGateway, merge: Bool) async throws {
                    batch.setData(data, forDocument: document, merge: merge)
                    pendingWrites += 1
                    if pendingWrites >= 450 {
                        try await withCloudSyncRetry(
                            policy: context.retryPolicy,
                            circuitBreaker: context.circuitBreaker,
                            domain: "sessionLog.batch"
                        ) {
                            try await batch.commit()
                        }
                        batch = context.firestoreGateway.batch()
                        pendingWrites = 0
                    }
                }

                try await enqueue(manifest, for: manifestRef, merge: true)

                let chunksRef = manifestRef.collection("chunks")
                for (idx, chunk) in chunks.enumerated() {
                    try await enqueue([
                        "index": idx,
                        "body": chunk,
                        "hash": Self.sha256Hex(chunk),
                        "updatedAt": FieldValue.serverTimestamp()
                    ], for: chunksRef.document(String(idx)), merge: true)
                }

                for searchChunk in searchChunks {
                    try await enqueue(searchChunk.data, for: searchRef.document(searchChunk.id), merge: true)
                }

                if pendingWrites > 0 {
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

    private static let searchIndexVersion = 1

    private struct SearchChunk {
        let id: String
        let data: [String: Any]
    }

    private static func makeSearchChunks(
        markdown: String,
        record: ConversationRecord,
        docId: String,
        deviceId: String,
        model: String,
        bodyHash: String
    ) -> [SearchChunk] {
        chunkUTF8String(markdown, maxBytes: 16_000).enumerated().map { index, text in
            let chunkID = "\(docId)_\(String(format: "%04d", index))"
            let title = record.summaryTitle ?? record.inferredTaskTitle
            let snippet = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var data: [String: Any] = [
                "id": chunkID,
                "docId": docId,
                "conversationId": record.id,
                "sessionId": record.sessionId,
                "deviceId": deviceId,
                "provider": record.provider.rawValue,
                "model": model,
                "projectName": record.projectName,
                "title": title.isEmpty ? record.projectName : title,
                "snippet": String(snippet.prefix(500)),
                "text": text,
                "terms": normalizedTerms(from: text + " " + title + " " + record.projectName + " " + model),
                "ordinal": index,
                "chunkHash": sha256Hex(text),
                "bodyHash": bodyHash,
                "schemaVersion": searchIndexVersion,
                "updatedAt": FieldValue.serverTimestamp()
            ]
            if let start = record.startTime { data["startTime"] = Timestamp(date: start) }
            if let end = record.endTime { data["endTime"] = Timestamp(date: end) }
            return SearchChunk(id: chunkID, data: data)
        }
    }

    private static func normalizedTerms(from text: String) -> [String] {
        let parts = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        var seen = Set<String>()
        var terms: [String] = []
        for part in parts where seen.insert(part).inserted {
            terms.append(part)
            if terms.count >= 80 { break }
        }
        return terms
    }

    private static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension CloudSyncService {
    // MARK: - Session Log Upload (full Markdown, chunked)

    /// Uploads full session-log Markdown bodies to Firestore.
    /// Layout: `users/{uid}/session_logs/{deviceId}_{escapedId}` (manifest)
    ///         `users/{uid}/session_logs/{docId}/chunks/{index}` (body chunks)
    ///
    /// Gated separately on `sessionLogCloudBackupEnabled`.
    /// Uses its own dirty flag (`logSyncedAt`) so it is independent of metadata sync.
    func uploadPendingSessionLogs() async {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              accountManager.isCloudSyncEnabled,
              settingsManager.sessionLogCloudBackupEnabled,
              !syncIsSuppressed(),
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
                let safeStart = record.startTime.map { TimestampNormalizationUtility.firestoreSafeDate($0) }
                let safeEnd = record.endTime.map { rawEnd in
                    let normalizedEnd = TimestampNormalizationUtility.firestoreSafeDate(rawEnd, fallback: safeStart ?? rawEnd)
                    if let safeStart {
                        return max(safeStart, normalizedEnd)
                    }
                    return normalizedEnd
                }
                if let safeStart { manifest["startTime"] = Timestamp(date: safeStart) }
                if let safeEnd { manifest["endTime"] = Timestamp(date: safeEnd) }

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
            recordSyncError(error)
        }

        isSyncing = false
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

    /// Reassembles chunk sub-documents into the full Markdown body for a session log.
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
