import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore

extension CloudSyncService {
    // MARK: - Session Log Upload (manifest + search metadata)

    /// Uploads session-log manifests and encrypted search metadata to Firestore.
    /// Layout: `users/{uid}/session_logs/{deviceId}_{escapedId}` (manifest)
    ///         `users/{uid}/cloud_search_chunks/{chunkId}` (server-written search metadata)
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
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [OpenBurnBarCore.ConversationRecord] {
        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        return try await SessionLogSyncService(context: context).fetchCloudSessionLogs(limit: limit)
    }

    func searchCloudSessionLogs(query: String, limit: Int = 50) async throws -> [OpenBurnBarCore.ConversationRecord] {
        let accountReady = await MainActor.run {
            (accountManager.isFirebaseAvailable, accountManager.isSignedIn)
        }
        guard accountReady.0,
              accountReady.1,
              let uid = Auth.auth().currentUser?.uid else { return [] }
        guard let vaultKey = try await cloudVaultKey(uid: uid) else { return [] }
        let tokenHashes = try CloudVaultCrypto.searchQueryTokenHashes(for: query, keyData: vaultKey, limit: 10)
        let semanticHashes = try CloudVaultCrypto.semanticHashes(for: query, keyData: vaultKey, limit: 12)
        guard tokenHashes.isEmpty == false || semanticHashes.isEmpty == false else { return [] }

        let result = try await Functions.functions(region: "us-central1")
            .httpsCallable("searchEncryptedConversationIndex")
            .call([
                "tokenHashes": tokenHashes,
                "semanticHashes": semanticHashes,
                "limit": max(1, min(limit, 50))
            ])
        guard let dict = result.data as? [String: Any],
              let hits = dict["hits"] as? [[String: Any]] else { return [] }

        return hits.compactMap { Self.decodeEncryptedSearchHit($0, vaultKey: vaultKey, uid: uid) }
    }

    /// Outcome of decrypting one server-relayed encrypted-search field (title/snippet).
    enum EncryptedSearchFieldDecode: Equatable {
        /// No sealed field was present on the hit (legitimately absent → safe placeholder).
        case absent
        /// The sealed field authenticated and decrypted to this plaintext.
        case decrypted(String)
        /// A sealed field was present but failed AES-GCM authentication/decryption.
        /// In an E2EE search index this means the server returned a forged, tampered,
        /// or mis-keyed entry — the hit must be rejected, never shown with a placeholder.
        case tampered
    }

    /// Decrypts one sealed search field with its bound AAD context, failing CLOSED.
    ///
    /// The seal side (and the Cloud Function relay) bind every sealed search field to a
    /// `CloudVaultAADContext`, so opening WITHOUT the matching AAD always fails. A failure
    /// here is a trust/verification signal (forgery / tamper / wrong key), not a recoverable
    /// read — so the caller rejects the whole hit rather than surfacing a placeholder entry.
    ///
    /// `nonisolated`: a pure AAD-bound decrypt with no `@MainActor` state, so it is
    /// callable off the main actor (the enclosing `CloudSyncService` is `@MainActor`,
    /// which would otherwise isolate this `static` helper).
    nonisolated static func decryptEncryptedSearchField(
        _ raw: Any?,
        vaultKey: Data,
        uid: String,
        collection: String,
        docID: String,
        field: String
    ) -> EncryptedSearchFieldDecode {
        guard let envelope = CloudVaultCrypto.decodeSealedText(from: raw) else {
            // Distinguish a genuinely-absent field from a PRESENT-but-undecodable
            // one. A present sealed field that cannot be parsed into a
            // CloudVaultSealedText (missing required tag/nonce, wrong types, or a
            // non-dict value) is a forgery/tamper signal from the untrusted
            // server — reject the hit (.tampered) rather than surfacing it as a
            // safe placeholder (.absent). Absence (no value / explicit null) is
            // legitimate and stays .absent.
            if Self.sealedFieldIsPresent(raw) {
                AppLogger.search.error(
                    "encryptedSearchHit.fieldMalformed",
                    metadata: ["field": field, "collection": collection]
                )
                return .tampered
            }
            return .absent
        }
        do {
            let aadContext = try CloudVaultAADContext(
                uid: uid,
                collection: collection,
                docID: docID,
                field: field
            )
            return .decrypted(try CloudVaultCrypto.openText(envelope, keyData: vaultKey, aadContext: aadContext))
        } catch {
            AppLogger.search.error(
                "encryptedSearchHit.fieldAuthFailed",
                metadata: [
                    "field": field,
                    "collection": collection,
                    "errorClass": "\(String(describing: type(of: error)))"
                ]
            )
            return .tampered
        }
    }

    /// Builds a `OpenBurnBarCore.ConversationRecord` from one encrypted-search hit, returning `nil`
    /// (skipping the hit) whenever the hit is malformed or any present sealed field
    /// fails authentication. Never returns a record carrying an unauthenticated
    /// title/snippet, so a cloud-side forgery cannot masquerade as a real result.
    ///
    /// `nonisolated`: pure decode (delegates to `decryptEncryptedSearchField`), no
    /// `@MainActor` state — callable off the main actor despite the `@MainActor`
    /// `CloudSyncService` extension scope.
    nonisolated static func decodeEncryptedSearchHit(
        _ hit: [String: Any],
        vaultKey: Data,
        uid: String
    ) -> OpenBurnBarCore.ConversationRecord? {
        guard let rawProvider = hit["provider"] as? String,
              let provider = AgentProvider(rawValue: rawProvider),
              let documentID = hit["documentID"] as? String else { return nil }

        let titleDecode = decryptEncryptedSearchField(
            hit["sealedTitle"],
            vaultKey: vaultKey,
            uid: uid,
            collection: "cloud_search_documents",
            docID: documentID,
            field: "sealedTitle"
        )
        let chunkID = hit["chunkID"] as? String ?? documentID
        let snippetDecode = decryptEncryptedSearchField(
            hit["sealedSnippet"],
            vaultKey: vaultKey,
            uid: uid,
            collection: "cloud_search_chunks",
            docID: chunkID,
            field: "sealedSnippet"
        )

        // Fail closed: a present-but-unauthenticated field means the hit is forged/tampered.
        if titleDecode == .tampered || snippetDecode == .tampered {
            AppLogger.search.error(
                "encryptedSearchHit.rejectedUnauthenticated",
                metadata: ["documentID": documentID]
            )
            return nil
        }

        let title: String
        switch titleDecode {
        case .decrypted(let plaintext): title = plaintext
        case .absent: title = "Encrypted session"
        case .tampered: return nil
        }
        let snippet: String
        switch snippetDecode {
        case .decrypted(let plaintext): snippet = plaintext
        case .absent: snippet = ""
        case .tampered: return nil
        }

        return OpenBurnBarCore.ConversationRecord(
            id: hit["sourceID"] as? String ?? documentID,
            provider: provider,
            sessionId: documentID,
            projectName: "",
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

    /// Fetches and decrypts a session-log body from encrypted Cloud Storage.
    /// Legacy Firestore chunk bodies are intentionally ignored.
    /// - Parameter docId: The Firestore document ID (stored in `record.sessionId` for cloud-sourced records).
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        return try await SessionLogSyncService(context: context).fetchCloudSessionLogBody(docId: docId)
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

    /// Whether the (untrusted, server-supplied) sealed field carries an actual
    /// value. A missing key or explicit null is a legitimate absence; any other
    /// present value that fails to decode is treated as tamper by the caller.
    private nonisolated static func sealedFieldIsPresent(_ raw: Any?) -> Bool {
        guard let raw else { return false }
        return !(raw is NSNull)
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
