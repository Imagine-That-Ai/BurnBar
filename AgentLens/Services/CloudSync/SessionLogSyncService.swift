import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import CryptoKit
import OpenBurnBarCore

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
    private let functions: Functions
    private let urlSession: URLSession
    private let vaultKeyStore: CloudVaultKeyStore

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(
        context: CloudSyncContext,
        functions: Functions = Functions.functions(region: "us-central1"),
        urlSession: URLSession = .shared,
        vaultKeyStore: CloudVaultKeyStore = CloudVaultKeyStore()
    ) {
        self.context = context
        self.functions = functions
        self.urlSession = urlSession
        self.vaultKeyStore = vaultKeyStore
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
                let vaultKey = try vaultKeyStore.getOrCreateKey(uid: uid)
                try await publishCloudVaultKey(uid: uid, vaultKey: vaultKey)
                let sealedBody = try CloudVaultCrypto.sealBlob(Data(markdown.utf8), keyData: vaultKey)
                let sealedBodyData = try Self.jsonData(sealedBody)
                let uploadTicket = try await beginEncryptedSessionBlobUpload(
                    documentID: docId,
                    bodyHash: bodyHash,
                    byteCount: sealedBodyData.count
                )

                if let existing = try await manifestRef.getData(),
                   existing["bodyHash"] as? String == bodyHash,
                   existing["chunkMetadataVersion"] as? Int == Self.chunkMetadataVersion,
                   existing["bodyStorage"] as? String == "firebase_storage_encrypted" {
                    try context.dataStore.markSessionLogsSynced(ids: [record.id])
                    continue
                }

                try await uploadEncryptedBody(data: sealedBodyData, ticket: uploadTicket)
                let chunks = Self.chunkUTF8String(markdown, maxBytes: 64_000)
                let sealedTitle = try CloudVaultCrypto.sealText(record.summaryTitle ?? record.inferredTaskTitle, keyData: vaultKey)
                let previewText = String(markdown.prefix(500))
                let sealedPreview = try CloudVaultCrypto.sealText(previewText, keyData: vaultKey)

                var manifest: [String: Any] = [
                    "id": record.id,
                    "deviceId": context.deviceId,
                    "provider": record.provider.rawValue,
                    "sessionId": record.sessionId,
                    "sourceType": record.sourceType.rawValue,
                    "projectName": record.projectName,
                    "inferredTaskTitle": "Encrypted session",
                    "messageCount": record.messageCount,
                    "bodyStorage": "firebase_storage_encrypted",
                    "storagePath": uploadTicket.storagePath,
                    "sealedTitle": try Self.dictionary(sealedTitle),
                    "sealedBodyPreview": try Self.dictionary(sealedPreview),
                    "encryption": [
                        "algorithm": CloudVaultCrypto.aesGCMAlgorithm,
                        "keyVersion": CloudVaultCrypto.currentKeyVersion,
                        "tokenHashVersion": CloudVaultCrypto.tokenHashVersion
                    ],
                    "chunkCount": 0,
                    "searchChunkCount": chunks.count,
                    "byteCount": markdown.utf8.count,
                    "encryptedByteCount": sealedBodyData.count,
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
                var cloudSearchChunks: [[String: Any]] = []
                for (idx, chunk) in chunks.enumerated() {
                    let snippet = chunk
                        .replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let chunkHash = Self.sha256Hex(chunk)
                    let sealedSnippet = try CloudVaultCrypto.sealText(String(snippet.prefix(500)), keyData: vaultKey)
                    let tokenHashes = try CloudVaultCrypto.tokenHashes(
                        for: chunk + " " + record.inferredTaskTitle + " " + record.projectName + " " + model,
                        keyData: vaultKey
                    )
                    writes.append(([
                        "index": idx,
                        "hash": chunkHash,
                        "uid": uid,
                        "docId": docId,
                        "conversationId": record.id,
                        "sessionId": record.sessionId,
                        "deviceId": context.deviceId,
                        "provider": record.provider.rawValue,
                        "model": model,
                        "projectName": record.projectName,
                        "sealedSnippet": try Self.dictionary(sealedSnippet),
                        "tokenHashes": tokenHashes,
                        "bodyStorage": "firebase_storage_encrypted",
                        "storagePath": uploadTicket.storagePath,
                        "bodyHash": bodyHash,
                        "schemaVersion": Self.chunkMetadataVersion,
                        "updatedAt": FieldValue.serverTimestamp()
                    ], chunksRef.document(String(idx)), true))
                    cloudSearchChunks.append([
                        "chunkID": "\(docId)_\(idx)",
                        "documentID": docId,
                        "sourceKind": "conversation",
                        "sourceID": record.id,
                        "ordinal": idx,
                        "startOffset": 0,
                        "endOffset": chunk.utf8.count,
                        "contentHash": chunkHash,
                        "bodyHash": bodyHash,
                        "storagePath": uploadTicket.storagePath,
                        "sealedSnippet": try Self.dictionary(sealedSnippet),
                        "tokenHashes": tokenHashes,
                        "provider": record.provider.rawValue,
                        "projectName": record.projectName
                    ])
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

                try await commitEncryptedSearchIndex(
                    document: [
                        "documentID": docId,
                        "sourceKind": "conversation",
                        "sourceID": record.id,
                        "sourceVersionID": bodyHash,
                        "provider": record.provider.rawValue,
                        "projectName": record.projectName,
                        "bodyHash": bodyHash,
                        "storagePath": uploadTicket.storagePath,
                        "sealedTitle": try Self.dictionary(sealedTitle),
                        "sealedBodyPreview": try Self.dictionary(sealedPreview),
                        "byteCount": markdown.utf8.count
                    ],
                    chunks: cloudSearchChunks
                )
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

    private struct EncryptedUploadTicket {
        let storagePath: String
        let uploadURL: URL
    }

    private func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedUploadTicket {
        let result = try await functions.httpsCallable("beginEncryptedSessionBlobUpload").call([
            "documentID": documentID,
            "bodyHash": bodyHash,
            "encryptedByteCount": byteCount,
            "contentType": "application/octet-stream"
        ])
        guard let dict = result.data as? [String: Any],
              let storagePath = dict["storagePath"] as? String,
              let uploadURLString = dict["uploadURL"] as? String,
              let uploadURL = URL(string: uploadURLString) else {
            throw CloudSessionLogUploadError.invalidUploadTicket
        }
        return EncryptedUploadTicket(storagePath: storagePath, uploadURL: uploadURL)
    }

    private func uploadEncryptedBody(data: Data, ticket: EncryptedUploadTicket) async throws {
        var request = URLRequest(url: ticket.uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await urlSession.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw CloudSessionLogUploadError.storageUploadFailed
        }
    }

    private func commitEncryptedSearchIndex(document: [String: Any], chunks: [[String: Any]]) async throws {
        _ = try await functions.httpsCallable("commitEncryptedSearchIndexBatch").call([
            "deviceId": context.deviceId,
            "indexVersion": 1,
            "documents": [document],
            "chunks": chunks
        ])
    }

    private func publishCloudVaultKey(uid: String, vaultKey: Data) async throws {
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(context.deviceId)")
        let userRef = context.firestoreGateway.collection("users").document(uid)
        try await userRef.collection("escrow_devices").document(context.deviceId).setData([
            "deviceId": context.deviceId,
            "deviceName": Host.current().localizedName ?? "Mac",
            "platform": "macOS",
            "trustState": EscrowDeviceTrustState.trusted.rawValue,
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)
        try await userRef.collection("escrow_public_keys").document("\(context.deviceId)_\(keypair.keyVersion)").setData([
            "deviceId": context.deviceId,
            "publicKeyData": keypair.publicKeyData.base64EncodedString(),
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "algorithm": "ECIES-P256-AESGCM",
            "createdAt": FieldValue.serverTimestamp()
        ], merge: true)

        let trusted = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()
        for doc in trusted.documents {
            let data = doc.data()
            let targetDeviceId = (data["deviceId"] as? String) ?? doc.documentID
            guard targetDeviceId.isEmpty == false,
                  let keyVersion = data["keyVersion"] as? Int,
                  let fingerprint = data["publicKeyFingerprint"] as? String else {
                continue
            }
            let publicKeyDoc = try await userRef.collection("escrow_public_keys")
                .document("\(targetDeviceId)_\(keyVersion)")
                .getData()
            guard let publicKeyBase64 = publicKeyDoc?["publicKeyData"] as? String,
                  let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
                continue
            }
            let wrapped = try CloudVaultCrypto.wrapVaultKey(vaultKey, recipientPublicKey: publicKeyData)
            try await userRef.collection("cloud_vault_key_wrappers")
                .document("\(targetDeviceId)_\(keyVersion)")
                .setData([
                    "uid": uid,
                    "targetDeviceId": targetDeviceId,
                    "sourceDeviceId": context.deviceId,
                    "publicKeyFingerprint": fingerprint,
                    "keyVersion": keyVersion,
                    "wrappedVaultKey": wrapped.base64EncodedString(),
                    "algorithm": "ECIES-P256-AESGCM",
                    "status": "active",
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "schemaVersion": 1
                ], merge: true)
        }
    }

    private static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudSessionLogUploadError.encodingFailed
        }
        return dictionary
    }

    private static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

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

private enum CloudSessionLogUploadError: LocalizedError {
    case invalidUploadTicket
    case storageUploadFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidUploadTicket:
            return "The encrypted session-log upload ticket was invalid."
        case .storageUploadFailed:
            return "Uploading the encrypted session log to Firebase Storage failed."
        case .encodingFailed:
            return "Encoding encrypted session-log metadata failed."
        }
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
        let vaultKey = try? await cloudVaultKey(uid: uid)

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
            let decryptedTitle: String? = vaultKey.flatMap { key in
                guard let envelope = Self.decodeSealedText(data["sealedTitle"]) else { return nil }
                return try? CloudVaultCrypto.openText(envelope, keyData: key)
            }
            let title = decryptedTitle ?? data["inferredTaskTitle"] as? String ?? ""

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
                inferredTaskTitle: title,
                lastAssistantMessage: "",
                fullText: "",
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: nil,
                summaryTitle: title.isEmpty ? nil : title,
                sourceType: sourceType
            )
        }
    }

    func searchCloudSessionLogs(query: String, limit: Int = 50) async throws -> [ConversationRecord] {
        guard accountManager.isFirebaseAvailable,
              accountManager.isSignedIn,
              let uid = Auth.auth().currentUser?.uid else { return [] }
        guard let vaultKey = try await cloudVaultKey(uid: uid) else { return [] }
        let tokenHashes = try CloudVaultCrypto.tokenHashes(for: query, keyData: vaultKey, limit: 10)
        guard tokenHashes.isEmpty == false else { return [] }

        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable("searchEncryptedConversationIndex")
            .call([
                "tokenHashes": tokenHashes,
                "limit": max(1, min(limit, 50))
            ])
        guard let dict = result.data as? [String: Any],
              let hits = dict["hits"] as? [[String: Any]] else { return [] }

        return hits.compactMap { hit in
            guard let rawProvider = hit["provider"] as? String,
                  let provider = AgentProvider(rawValue: rawProvider),
                  let documentID = hit["documentID"] as? String else { return nil }
            let title = Self.decodeSealedText(hit["sealedTitle"])
                .flatMap { try? CloudVaultCrypto.openText($0, keyData: vaultKey) }
                ?? "Encrypted session"
            let snippet = Self.decodeSealedText(hit["sealedSnippet"])
                .flatMap { try? CloudVaultCrypto.openText($0, keyData: vaultKey) }
                ?? ""
            return ConversationRecord(
                id: hit["sourceID"] as? String ?? documentID,
                provider: provider,
                sessionId: documentID,
                projectName: hit["projectName"] as? String ?? "",
                startTime: nil,
                endTime: nil,
                messageCount: 0,
                userWordCount: 0,
                assistantWordCount: 0,
                keyFiles: [],
                keyCommands: [],
                keyTools: [],
                inferredTaskTitle: title,
                lastAssistantMessage: snippet,
                fullText: snippet,
                indexedAt: Date(),
                fileModifiedAt: nil,
                summary: snippet,
                summaryTitle: title,
                sourceType: .providerLog,
                sourceDeviceId: nil,
                sourceDeviceName: nil,
                isRemote: true
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

        let manifest = try await db
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .document(docId)
            .getDocument()
        let manifestData = manifest.data() ?? [:]
        if manifestData["bodyStorage"] as? String == "firebase_storage_encrypted",
           let storagePath = manifestData["storagePath"] as? String {
            guard let vaultKey = try await cloudVaultKey(uid: uid) else { return "" }
            let url = try await encryptedSessionBlobDownloadURL(storagePath: storagePath)
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return ""
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(CloudVaultBlobEnvelope.self, from: data)
            let plaintext = try CloudVaultCrypto.openBlob(envelope, keyData: vaultKey)
            return String(data: plaintext, encoding: .utf8) ?? ""
        }

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

    private func encryptedSessionBlobDownloadURL(storagePath: String) async throws -> URL {
        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable("getEncryptedSessionBlobDownloadUrl")
            .call(["storagePath": storagePath])
        guard let dict = result.data as? [String: Any],
              let raw = dict["downloadURL"] as? String,
              let url = URL(string: raw) else {
            throw URLError(.badServerResponse)
        }
        return url
    }

    private func cloudVaultKey(uid: String) async throws -> Data? {
        let store = CloudVaultKeyStore()
        if let cached = try store.loadKey(uid: uid) {
            return cached
        }
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(accountManager.deviceId)")
        let snapshot = try await db
            .collection("users")
            .document(uid)
            .collection("cloud_vault_key_wrappers")
            .whereField("targetDeviceId", isEqualTo: accountManager.deviceId)
            .whereField("status", isEqualTo: "active")
            .limit(to: 5)
            .getDocuments()
        for document in snapshot.documents {
            let data = document.data()
            guard let wrappedBase64 = data["wrappedVaultKey"] as? String,
                  let wrapped = Data(base64Encoded: wrappedBase64) else {
                continue
            }
            let key = try keypair.decrypt(wrapped)
            try store.saveKey(key, uid: uid)
            return key
        }
        return nil
    }

    private static func decodeSealedText(_ raw: Any?) -> CloudVaultSealedText? {
        guard let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return nil
        }
        return try? JSONDecoder().decode(CloudVaultSealedText.self, from: data)
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
