import FirebaseAuth
import FirebaseFirestore
import Foundation

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

            let logsRef = context.db.collection("users").document(uid).collection("session_logs")

            for record in unsynced {
                let markdown = SessionLogMarkdownFormatter.markdown(for: record)
                let safeId = record.id
                    .replacingOccurrences(of: ":", with: "_")
                    .replacingOccurrences(of: "/", with: "_")
                let docId = "\(context.deviceId)_\(safeId)"
                let manifestRef = logsRef.document(docId)

                let chunks = Self.chunkUTF8String(markdown, maxBytes: 900_000)

                // Write manifest
                var manifest: [String: Any] = [
                    "id": record.id,
                    "deviceId": context.deviceId,
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
