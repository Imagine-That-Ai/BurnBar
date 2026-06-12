import FirebaseAuth
import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarSignalCore

private final class SessionLogSyncProcessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false

    func tryEnter() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return false }
        running = true
        return true
    }

    func leave() {
        lock.lock()
        running = false
        lock.unlock()
    }
}

/// Sync domain for uploading session-log manifests/search metadata to Firestore.
///
/// Firestore layout:
///   `users/{uid}/session_logs/{safeDeviceId}_{provider}_{recordHash}` (manifest)
///   `users/{uid}/cloud_search_chunks/{chunkId}` (server-written encrypted search metadata)
///
/// Gated separately on `sessionLogCloudBackupEnabled`.
/// Uses its own dirty flag (`logSyncedAt`) so it is independent of metadata sync.
final class SessionLogSyncService: CloudSyncDomain, @unchecked Sendable {
    private typealias FirestoreWrite = (data: [String: Any], document: CloudSyncDocumentGateway, merge: Bool)

    private static let processGate = SessionLogSyncProcessGate()

    private let context: CloudSyncContext
    private let encryptedCloudClient: SessionLogEncryptedCloudClient
    private let vaultKeyStore: SessionLogVaultKeyProviding
    private let vaultKeyPublisher: SessionLogVaultKeyPublishing
    private var archivedSessionMirror: SessionLogArchivedSessionMirroring?

    private(set) var isSyncing = false
    private(set) var lastSyncError: String?
    private(set) var lastSyncDate: Date?

    init(
        context: CloudSyncContext,
        encryptedCloudClient: SessionLogEncryptedCloudClient? = nil,
        vaultKeyStore: SessionLogVaultKeyProviding = CloudVaultKeyStore(),
        vaultKeyPublisher: SessionLogVaultKeyPublishing = FirebaseSessionLogVaultKeyPublisher(),
        archivedSessionMirror: SessionLogArchivedSessionMirroring? = nil
    ) {
        self.context = context
        self.encryptedCloudClient = encryptedCloudClient ?? FirebaseSessionLogEncryptedCloudClient()
        self.vaultKeyStore = vaultKeyStore
        self.vaultKeyPublisher = vaultKeyPublisher
        self.archivedSessionMirror = archivedSessionMirror
    }

    private func resolvedArchivedSessionMirror() async -> SessionLogArchivedSessionMirroring {
        if let archivedSessionMirror {
            return archivedSessionMirror
        }
        let shared = await MainActor.run { CLIAgentSessionMirror.shared }
        archivedSessionMirror = shared
        return shared
    }

    private func writableVaultKey(uid: String) async throws -> CloudVaultResolvedKey {
        if vaultKeyStore is CloudVaultKeyStore,
           vaultKeyPublisher is FirebaseSessionLogVaultKeyPublisher {
            let gate = await context.syncGate()
            return try await MacCloudVaultKeyAccess.keyForWriting(
                uid: uid,
                deviceId: gate.account.deviceId,
                firestore: Firestore.firestore()
            )
        }
        let key = try vaultKeyStore.getOrCreateKey(uid: uid)
        try await vaultKeyPublisher.publishCloudVaultKey(uid: uid, vaultKey: key, context: context)
        return CloudVaultResolvedKey(keyData: key, vaultKeyID: try CloudVaultCrypto.vaultKeyID(for: key))
    }

    private func readableVaultKey(uid: String) async throws -> CloudVaultResolvedKey? {
        if vaultKeyStore is CloudVaultKeyStore {
            let gate = await context.syncGate()
            return try await MacCloudVaultKeyAccess.keyForReading(
                uid: uid,
                deviceId: gate.account.deviceId,
                firestore: Firestore.firestore()
            )
        }
        guard let key = try vaultKeyStore.loadKey(uid: uid) else { return nil }
        return CloudVaultResolvedKey(keyData: key, vaultKeyID: try CloudVaultCrypto.vaultKeyID(for: key))
    }

    func sync() async {
        await sync(drainAll: false, progress: nil)
    }

    /// Upload session-log manifests and search metadata to Firestore.
    func sync(drainAll: Bool = false, progress: CloudBackupProgressTracker? = nil) async {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              gate.settings.sessionLogCloudBackupEnabled,
              !gate.syncSuppressed,
              !isSyncing,
              let uid = gate.account.uid else { return }
        guard Self.processGate.tryEnter() else { return }

        let deviceId = gate.account.deviceId

        isSyncing = true
        lastSyncError = nil

        defer {
            isSyncing = false
            Self.processGate.leave()
        }

        do {
            let backupUsage = try context.dataStore.backupUsageSnapshot(limits: context.backupPlanLimits)
            if let blockingReason = backupUsage.blockingReason {
                throw CloudBackupPreflightError.planLimitExceeded(blockingReason)
            }

            progress?.setPhase(.facetBackfill, operation: "Checking cockpit facet schema…")
            await runFacetBackfillIfNeeded()
            progress?.setPhase(.sessionLogs, operation: "Loading pending conversations…")

            let userRef = context.firestoreGateway.collection("users").document(uid)
            let logsRef = userRef.collection("session_logs")
            let sessionModelMap = (try? context.dataStore.sessionModelMap()) ?? [:]
            let sessionFacetsMap = (try? context.dataStore.sessionFacetsMap()) ?? [:]

            var processedAnyBatch = false
            repeat {
                let unsynced = try context.dataStore.fetchUnsyncedSessionLogs(limit: 50)
                guard !unsynced.isEmpty else {
                    if !processedAnyBatch {
                        lastSyncDate = Date()
                    }
                    break
                }
                processedAnyBatch = true

                for record in unsynced {
                    let label = Self.progressLabel(for: record)
                    progress?.setCurrentRecord(
                        label: label,
                        operation: "Reading local session log"
                    )

                    let markdown = SessionLogMarkdownFormatter.markdown(for: record)
                    // Project/path text is private. It is fed into keyed local
                    // search hashes, then stripped from every cloud document.
                    let privateProjectSearchText = Self.clampedPrivateSearchText(record.projectName)
                    let docId = Self.cloudDocumentID(deviceId: deviceId, record: record)
                    let manifestRef = logsRef.document(docId)
                    let resolvedVaultKey = try await writableVaultKey(uid: uid)
                    let vaultKey = resolvedVaultKey.keyData
                    let vaultKeyID = resolvedVaultKey.vaultKeyID
                    let bodyHash = try CloudVaultCrypto.sessionBodyHash(markdown, keyData: vaultKey)
                    let facetKey = Self.rootSessionKey(provider: record.provider, sessionId: record.sessionId)
                    let facets = sessionFacetsMap[facetKey]
                    let model = sessionModelMap["\(record.provider.rawValue):\(record.sessionId)"]
                        ?? facets?.model
                        ?? "unknown"
                    let facetFields = Self.facetFields(for: record, facets: facets, model: model)
                    let existingManifest = try await manifestRef.getData()
                    if let existing = existingManifest,
                       existing["bodyHash"] as? String == bodyHash,
                       existing["chunkMetadataVersion"] as? Int == Self.chunkMetadataVersion,
                       existing["cloudSearchIndexVersion"] as? Int == Self.cloudSearchIndexVersion,
                       existing["bodyStorage"] as? String == "firebase_storage_encrypted",
                       let existingStoragePath = existing["storagePath"] as? String,
                       !existingStoragePath.isEmpty {
                        let facetRefreshOnly = existing["facetSchemaVersion"] as? Int != Self.facetSchemaVersion
                        var writes: [FirestoreWrite] = []
                        if facetRefreshOnly {
                            progress?.setCurrentRecord(
                                label: label,
                                operation: "Refreshing cockpit facets"
                            )
                            var facetUpdate = facetFields
                            facetUpdate.merge(Self.legacyPlaintextFieldDeletes()) { _, new in new }
                            facetUpdate["updatedAt"] = FieldValue.serverTimestamp()
                            writes.append((facetUpdate, manifestRef, true))
                        }
                        let legacyChunkDocuments = (try await manifestRef.collection("chunks").getDocuments()).documents
                        if !legacyChunkDocuments.isEmpty {
                            progress?.setCurrentRecord(
                                label: label,
                                operation: "Scrubbing legacy search chunks"
                            )
                            let chunks = Self.chunkUTF8String(markdown, maxBytes: Self.cloudSearchChunkMaxBytes)
                            try Self.appendLegacySessionLogChunkScrubWrites(
                                to: &writes,
                                legacyChunkDocuments: legacyChunkDocuments,
                                manifestRef: manifestRef,
                                uid: uid,
                                deviceId: deviceId,
                                docId: docId,
                                record: record,
                                model: model,
                                privateProjectSearchText: privateProjectSearchText,
                                chunks: chunks,
                                bodyHash: bodyHash,
                                storagePath: existingStoragePath,
                                keyData: vaultKey
                            )
                        }
                        let firestoreBatchCommits = try await commitFirestoreWrites(
                            writes,
                            retryDomain: "sessionLog.legacyChunkScrub",
                            progress: progress,
                            label: label,
                            operation: { "Writing Firestore metadata (batch \($0))" }
                        )
                        await resolvedArchivedSessionMirror().mirrorArchivedLog(record, cloudLogDocumentID: docId)
                        try context.dataStore.markSessionLogsSynced(ids: [record.id])
                        progress?.recordSessionLogOutcome(
                            label: label,
                            uploaded: false,
                            facetRefreshOnly: facetRefreshOnly,
                            plaintextBytes: 0,
                            encryptedBytes: 0,
                            storageUploads: 0,
                            firestoreWrites: firestoreBatchCommits,
                            searchIndexCommits: 0
                        )
                        continue
                    }

                    progress?.setCurrentRecord(
                        label: label,
                        operation: "Encrypting session body"
                    )

                    let sealedBody = try CloudVaultCrypto.sealBlob(
                        Data(markdown.utf8),
                        keyData: vaultKey,
                        aadContext: CloudVaultAADContext(
                            uid: uid,
                            collection: "session_logs",
                            docID: docId,
                            field: "sealedBody"
                        )
                    )
                    let sealedBodyData = try Self.jsonData(sealedBody)
                    let uploadTicket = try await encryptedCloudClient.beginEncryptedSessionBlobUpload(
                        documentID: docId,
                        bodyHash: bodyHash,
                        byteCount: sealedBodyData.count
                    )

                    progress?.setCurrentRecord(
                        label: label,
                        operation: "Uploading encrypted blob (\(CloudBackupProgressSnapshot.formatBytes(Int64(sealedBodyData.count))))"
                    )
                    try await encryptedCloudClient.uploadEncryptedBody(data: sealedBodyData, ticket: uploadTicket)
                    let chunks = Self.chunkUTF8String(markdown, maxBytes: Self.cloudSearchChunkMaxBytes)
                    let titleText = record.summaryTitle ?? record.inferredTaskTitle
                    let sealedManifestTitle = try CloudVaultCrypto.sealText(
                        titleText,
                        keyData: vaultKey,
                        aadContext: CloudVaultAADContext(
                            uid: uid,
                            collection: "session_logs",
                            docID: docId,
                            field: "sealedTitle"
                        )
                    )
                    let previewText = String(markdown.prefix(500))
                    let sealedManifestPreview = try CloudVaultCrypto.sealText(
                        previewText,
                        keyData: vaultKey,
                        aadContext: CloudVaultAADContext(
                            uid: uid,
                            collection: "session_logs",
                            docID: docId,
                            field: "sealedBodyPreview"
                        )
                    )
                    let sealedSearchTitle = try CloudVaultCrypto.sealText(
                        titleText,
                        keyData: vaultKey,
                        aadContext: CloudVaultAADContext(
                            uid: uid,
                            collection: "cloud_search_documents",
                            docID: docId,
                            field: "sealedTitle"
                        )
                    )
                    let sealedSearchPreview = try CloudVaultCrypto.sealText(
                        previewText,
                        keyData: vaultKey,
                        aadContext: CloudVaultAADContext(
                            uid: uid,
                            collection: "cloud_search_documents",
                            docID: docId,
                            field: "sealedBodyPreview"
                        )
                    )

                    var manifest: [String: Any] = [
                        "id": record.id,
                        "deviceId": deviceId,
                        "provider": record.provider.rawValue,
                        "sessionId": record.sessionId,
                        "sourceType": record.sourceType.rawValue,
                        "inferredTaskTitle": "Encrypted session",
                        "bodyStorage": "firebase_storage_encrypted",
                        "storagePath": uploadTicket.storagePath,
                        "sealedTitle": try Self.dictionary(sealedManifestTitle),
                        "sealedBodyPreview": try Self.dictionary(sealedManifestPreview),
                        "encryption": [
                            "algorithm": CloudVaultCrypto.aesGCMAlgorithm,
                            "keyVersion": CloudVaultCrypto.currentKeyVersion,
                            "vaultKeyID": vaultKeyID,
                            "tokenHashVersion": CloudVaultCrypto.tokenHashVersion,
                            "semanticHashVersion": CloudVaultCrypto.semanticHashVersion
                        ],
                        "vaultKeyID": vaultKeyID,
                        "chunkCount": 0,
                        "searchChunkCount": chunks.count,
                        "byteCount": markdown.utf8.count,
                        "encryptedByteCount": sealedBodyData.count,
                        "bodyHash": bodyHash,
                        "bodyHashVersion": CloudVaultCrypto.sessionBodyHashVersion,
                        "chunkSize": 0,
                        "chunkHashes": try chunks.map { try CloudVaultCrypto.sessionChunkHash($0, keyData: vaultKey) },
                        "chunkHashVersion": CloudVaultCrypto.sessionChunkHashVersion,
                        "chunkMetadataVersion": Self.chunkMetadataVersion,
                        "cloudSearchIndexVersion": Self.cloudSearchIndexVersion,
                        "cloudSearchIndexedAt": FieldValue.serverTimestamp(),
                        "updatedAt": FieldValue.serverTimestamp()
                    ]
                    manifest.merge(facetFields) { _, new in new }
                    if let start = record.startTime { manifest["startTime"] = Timestamp(date: start) }
                    if let end = record.endTime { manifest["endTime"] = Timestamp(date: end) }

                    var writes: [FirestoreWrite] = [
                        (manifest, manifestRef, false)
                    ]

                    var cloudSearchChunks: [[String: Any]] = []
                    for (idx, chunk) in chunks.enumerated() {
                        let snippet = chunk
                            .replacingOccurrences(of: "\n", with: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let chunkHash = try CloudVaultCrypto.sessionChunkHash(chunk, keyData: vaultKey)
                        let chunkID = "\(docId)_\(idx)"
                        let sealedSnippet = try CloudVaultCrypto.sealText(
                            String(snippet.prefix(500)),
                            keyData: vaultKey,
                            aadContext: CloudVaultAADContext(
                                uid: uid,
                                collection: "cloud_search_chunks",
                                docID: chunkID,
                                field: "sealedSnippet"
                            )
                        )
                        let tokenHashes = try CloudVaultCrypto.searchIndexTokenHashes(
                            for: chunk + " " + record.inferredTaskTitle + " " + privateProjectSearchText + " " + model,
                            keyData: vaultKey,
                            limit: Self.cloudSearchChunkTokenHashLimit
                        )
                        let semanticHashes = try CloudVaultCrypto.semanticHashes(
                            for: chunk + " " + record.inferredTaskTitle + " " + privateProjectSearchText + " " + model,
                            keyData: vaultKey
                        )
                        cloudSearchChunks.append([
                            "chunkID": chunkID,
                            "documentID": docId,
                            "sourceKind": "conversation",
                            "sourceID": record.id,
                            "ordinal": idx,
                            "startOffset": 0,
                            "endOffset": chunk.utf8.count,
                            "contentHash": chunkHash,
                            "contentHashVersion": CloudVaultCrypto.sessionChunkHashVersion,
                            "bodyHash": bodyHash,
                            "bodyHashVersion": CloudVaultCrypto.sessionBodyHashVersion,
                            "storagePath": uploadTicket.storagePath,
                            "sealedSnippet": try Self.dictionary(sealedSnippet),
                            "tokenHashes": tokenHashes,
                            "semanticHashes": semanticHashes,
                            "semanticHashVersion": CloudVaultCrypto.semanticHashVersion,
                            "provider": record.provider.rawValue
                        ])
                    }
                    progress?.setCurrentRecord(
                        label: label,
                        operation: "Committing search index (\(chunks.count) chunks)"
                    )
                    try await encryptedCloudClient.commitEncryptedSearchIndex(
                        deviceId: deviceId,
                        indexVersion: Self.cloudSearchIndexVersion,
                        document: [
                            "documentID": docId,
                            "sourceKind": "conversation",
                            "sourceID": record.id,
                            "sourceVersionID": bodyHash,
                            "provider": record.provider.rawValue,
                            "bodyHash": bodyHash,
                            "bodyHashVersion": CloudVaultCrypto.sessionBodyHashVersion,
                            "storagePath": uploadTicket.storagePath,
                            "sealedTitle": try Self.dictionary(sealedSearchTitle),
                            "sealedBodyPreview": try Self.dictionary(sealedSearchPreview),
                            "byteCount": markdown.utf8.count,
                            "encryptedByteCount": sealedBodyData.count
                        ],
                        chunks: cloudSearchChunks
                    )

                    let legacyChunkDocuments = (try await manifestRef.collection("chunks").getDocuments()).documents
                    if !legacyChunkDocuments.isEmpty {
                        try Self.appendLegacySessionLogChunkScrubWrites(
                            to: &writes,
                            legacyChunkDocuments: legacyChunkDocuments,
                            manifestRef: manifestRef,
                            uid: uid,
                            deviceId: deviceId,
                            docId: docId,
                            record: record,
                            model: model,
                            privateProjectSearchText: privateProjectSearchText,
                            chunks: chunks,
                            bodyHash: bodyHash,
                            storagePath: uploadTicket.storagePath,
                            keyData: vaultKey
                        )
                    }
                    let firestoreBatchCommits = try await commitFirestoreWrites(
                        writes,
                        retryDomain: "sessionLog.batch",
                        progress: progress,
                        label: label,
                        operation: { "Writing Firestore metadata (batch \($0))" }
                    )
                    await resolvedArchivedSessionMirror().mirrorArchivedLog(record, cloudLogDocumentID: docId)
                    try context.dataStore.markSessionLogsSynced(ids: [record.id])
                    progress?.recordSessionLogOutcome(
                        label: label,
                        uploaded: true,
                        facetRefreshOnly: false,
                        plaintextBytes: markdown.utf8.count,
                        encryptedBytes: sealedBodyData.count,
                        storageUploads: 1,
                        firestoreWrites: firestoreBatchCommits,
                        searchIndexCommits: 1
                    )
                }
            } while drainAll

            lastSyncDate = Date()
            lastSyncError = nil
        } catch {
            progress?.fail(error.localizedDescription)
            await recordSyncError(error)
        }
    }

    /// Clears every conversation's encrypted-backup dirty flag exactly once when the cockpit
    /// facet schema advances, so existing manifests re-upload (or take the cheap facet-refresh
    /// path) carrying the new facet block. The bumped version is persisted so it never repeats.
    private func runFacetBackfillIfNeeded() async {
        let needsBackfill = await MainActor.run {
            context.settingsManager.conversationFacetBackfillVersion < Self.facetSchemaVersion
        }
        guard needsBackfill else { return }
        do {
            _ = try context.dataStore.markAllSessionLogsUnsynced()
            await MainActor.run {
                context.settingsManager.conversationFacetBackfillVersion = Self.facetSchemaVersion
            }
        } catch {
            // Leave the version unchanged so the backfill retries on the next sync cycle.
        }
    }

    private func recordSyncError(_ error: Error) async {
        lastSyncError = error.localizedDescription

        let nsError = error as NSError
        guard nsError.domain == FirestoreErrorDomain,
              let code = FirestoreErrorCode.Code(rawValue: nsError.code),
              code == .permissionDenied || code == .unauthenticated else {
            return
        }
        await context.suppressSync(for: CloudSyncBackoffPolicy.permissionDeniedCooldown)
    }

    /// Splits a UTF-8 string into chunks each fitting within `maxBytes` bytes.
    /// Maximum length (in UTF-16 code units) for project/path text before it is
    /// folded into keyed search hashes. The raw value is never uploaded.
    static let cloudFacetMaxLength = 512

    /// Trims and clamps private project/path search text before local keyed hashing.
    /// Truncates on a `Character` boundary so a multibyte grapheme is never split.
    static func clampedPrivateSearchText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count > cloudFacetMaxLength else { return trimmed }
        var clamped = ""
        for character in trimmed {
            if clamped.utf16.count + character.utf16.count > cloudFacetMaxLength { break }
            clamped.append(character)
        }
        return clamped
    }

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
    private static let cloudSearchChunkMaxBytes = 16_000
    private static let cloudSearchChunkTokenHashLimit = 1_024
    private static let cloudSearchIndexVersion = 5

    /// Generation of the server-visible cockpit facet block stored on each manifest. Bumping this
    /// triggers a one-time backfill (`markAllSessionLogsUnsynced`) so existing manifests get the
    /// new facets. Facets are metadata only — token totals, cost, timing, model/provider, and
    /// generic tool tags. Project names and working directories are device-only.
    static let facetSchemaVersion = 2

    private static let legacyPlaintextFields = [
        "body",
        "payloadCiphertext",
        "ciphertext",
        "data",
        "text",
        "title",
        "snippet",
        "terms",
        "projectName",
        "workingDirectory"
    ]

    private static func legacyPlaintextFieldDeletes() -> [String: Any] {
        Dictionary(uniqueKeysWithValues: legacyPlaintextFields.map { ($0, FieldValue.delete()) })
    }

    private func commitFirestoreWrites(
        _ writes: [FirestoreWrite],
        retryDomain: String,
        progress: CloudBackupProgressTracker?,
        label: String,
        operation: (Int) -> String
    ) async throws -> Int {
        guard !writes.isEmpty else { return 0 }

        var firestoreBatchCommits = 0
        for start in stride(from: 0, to: writes.count, by: 450) {
            progress?.setCurrentRecord(
                label: label,
                operation: operation(firestoreBatchCommits + 1)
            )
            let batch = context.firestoreGateway.batch()
            for write in writes[start..<min(start + 450, writes.count)] {
                batch.setData(write.data, forDocument: write.document, merge: write.merge)
            }
            try await withCloudSyncRetry(
                policy: context.retryPolicy,
                circuitBreaker: context.circuitBreaker,
                domain: retryDomain
            ) {
                try await batch.commit()
            }
            firestoreBatchCommits += 1
        }
        return firestoreBatchCommits
    }

    private static func appendLegacySessionLogChunkScrubWrites(
        to writes: inout [FirestoreWrite],
        legacyChunkDocuments: [CloudSyncDocumentSnapshotGateway],
        manifestRef: CloudSyncDocumentGateway,
        uid: String,
        deviceId: String,
        docId: String,
        record: ConversationRecord,
        model: String,
        privateProjectSearchText: String,
        chunks: [String],
        bodyHash: String,
        storagePath: String,
        keyData: Data
    ) throws {
        guard !legacyChunkDocuments.isEmpty else { return }

        let chunksRef = manifestRef.collection("chunks")
        var repairedDocumentIDs = Set<String>()
        for (idx, chunk) in chunks.enumerated() {
            let matchingLegacyIDs = legacyChunkDocuments.compactMap { legacyDocument -> String? in
                if legacyDocument.documentID == "\(idx)" || legacyDocument.documentID == "\(docId)_\(idx)" {
                    return legacyDocument.documentID
                }
                let data = legacyDocument.data()
                let storedOrdinal = firestoreInt(data["ordinal"]) ?? firestoreInt(data["index"])
                return storedOrdinal == idx ? legacyDocument.documentID : nil
            }
            guard !matchingLegacyIDs.isEmpty else { continue }

            let snippet = chunk
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sealedSnippet = try CloudVaultCrypto.sealText(
                String(snippet.prefix(500)),
                keyData: keyData,
                aadContext: CloudVaultAADContext(
                    uid: uid,
                    collection: "session_log_chunks",
                    docID: "\(docId)_\(idx)",
                    field: "sealedSnippet"
                )
            )
            let tokenHashes = try CloudVaultCrypto.searchIndexTokenHashes(
                for: chunk + " " + record.inferredTaskTitle + " " + privateProjectSearchText + " " + model,
                keyData: keyData,
                limit: cloudSearchChunkTokenHashLimit
            )
            let semanticHashes = try CloudVaultCrypto.semanticHashes(
                for: chunk + " " + record.inferredTaskTitle + " " + privateProjectSearchText + " " + model,
                keyData: keyData
            )
            var data = try encryptedLegacyChunkData(
                uid: uid,
                deviceId: deviceId,
                docId: docId,
                record: record,
                ordinal: idx,
                chunk: chunk,
                bodyHash: bodyHash,
                storagePath: storagePath,
                sealedSnippet: try dictionary(sealedSnippet),
                tokenHashes: tokenHashes,
                semanticHashes: semanticHashes,
                keyData: keyData
            )
            data.merge(legacyPlaintextFieldDeletes()) { _, new in new }

            for documentID in matchingLegacyIDs {
                writes.append((data, chunksRef.document(documentID), true))
                repairedDocumentIDs.insert(documentID)
            }
        }

        for legacyDocument in legacyChunkDocuments where !repairedDocumentIDs.contains(legacyDocument.documentID) {
            var scrubData = orphanedLegacyChunkScrubData(
                uid: uid,
                deviceId: deviceId,
                docId: docId,
                record: record,
                legacyDocumentID: legacyDocument.documentID
            )
            scrubData.merge(legacyPlaintextFieldDeletes()) { _, new in new }
            writes.append((scrubData, chunksRef.document(legacyDocument.documentID), true))
        }
    }

    private static func encryptedLegacyChunkData(
        uid: String,
        deviceId: String,
        docId: String,
        record: ConversationRecord,
        ordinal: Int,
        chunk: String,
        bodyHash: String,
        storagePath: String,
        sealedSnippet: [String: Any],
        tokenHashes: [String],
        semanticHashes: [String],
        keyData: Data
    ) throws -> [String: Any] {
        [
            "uid": uid,
            "sessionId": record.sessionId,
            "deviceId": deviceId,
            "docId": docId,
            "documentID": docId,
            "chunkID": "\(docId)_\(ordinal)",
            "sourceKind": "conversation",
            "sourceID": record.id,
            "provider": record.provider.rawValue,
            "ordinal": ordinal,
            "index": ordinal,
            "startOffset": 0,
            "endOffset": chunk.utf8.count,
            "contentHash": try CloudVaultCrypto.sessionChunkHash(chunk, keyData: keyData),
            "contentHashVersion": CloudVaultCrypto.sessionChunkHashVersion,
            "bodyHash": bodyHash,
            "bodyHashVersion": CloudVaultCrypto.sessionBodyHashVersion,
            "bodyStorage": "firebase_storage_encrypted",
            "storagePath": storagePath,
            "sealedSnippet": sealedSnippet,
            "tokenHashes": tokenHashes,
            "semanticHashes": semanticHashes,
            "tokenHashVersion": CloudVaultCrypto.tokenHashVersion,
            "semanticHashVersion": CloudVaultCrypto.semanticHashVersion,
            "indexVersion": cloudSearchIndexVersion,
            "schemaVersion": chunkMetadataVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    private static func orphanedLegacyChunkScrubData(
        uid: String,
        deviceId: String,
        docId: String,
        record: ConversationRecord,
        legacyDocumentID: String
    ) -> [String: Any] {
        [
            "uid": uid,
            "sessionId": record.sessionId,
            "deviceId": deviceId,
            "docId": docId,
            "documentID": docId,
            "chunkID": "\(docId)_\(legacyDocumentID)",
            "sourceKind": "conversation",
            "sourceID": record.id,
            "provider": record.provider.rawValue,
            "bodyStorage": "firebase_storage_encrypted",
            "tokenHashes": [],
            "semanticHashes": [],
            "indexVersion": cloudSearchIndexVersion,
            "schemaVersion": chunkMetadataVersion,
            "orphanedByEncryptedReindex": true,
            "updatedAt": FieldValue.serverTimestamp()
        ]
    }

    private static func firestoreInt(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func progressLabel(for record: ConversationRecord) -> String {
        let title = record.summaryTitle ?? record.inferredTaskTitle
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return record.provider.displayName
        }
        return "\(record.provider.displayName) · \(trimmed)"
    }

    /// Root session id used to align a `ConversationRecord` with the aggregated usage facets,
    /// which group `token_usage` rows under the portion before the first `/` sub-path.
    private static func rootSessionKey(provider: AgentProvider, sessionId: String) -> String {
        let root: Substring
        if let slash = sessionId.firstIndex(of: "/") {
            root = sessionId[..<slash]
        } else {
            root = Substring(sessionId)
        }
        return "\(provider.rawValue):\(root)"
    }

    /// Builds the server-visible cockpit facet block merged onto a session-log manifest. Pure metadata:
    /// no message text or path/project text, only counters, cost, timing, model/provider, and generic tool tags.
    static func facetFields(
        for record: ConversationRecord,
        facets: SessionUsageFacets?,
        model: String
    ) -> [String: Any] {
        var fields: [String: Any] = [
            "facetSchemaVersion": facetSchemaVersion,
            "model": model,
            "messageCount": record.messageCount,
            "userWordCount": record.userWordCount,
            "assistantWordCount": record.assistantWordCount,
            "inputTokens": facets?.inputTokens ?? 0,
            "outputTokens": facets?.outputTokens ?? 0,
            "cacheCreationTokens": facets?.cacheCreationTokens ?? 0,
            "cacheReadTokens": facets?.cacheReadTokens ?? 0,
            "totalTokens": facets?.totalTokens ?? 0,
            "costUSD": facets?.costUSD ?? 0
        ]
        // Generic tool names (e.g. "bash", "edit") are non-identifying, unlike key files/commands
        // which can reveal content, so only tools become queryable cockpit tags.
        let toolTags = Array(Set(record.keyTools.map { $0.lowercased() }))
            .filter { !$0.isEmpty }
            .sorted()
            .prefix(24)
        if !toolTags.isEmpty {
            fields["toolTags"] = Array(toolTags)
        }
        let start = facets?.startTime ?? record.startTime
        let end = facets?.endTime ?? record.endTime
        if let start, let end, end > start {
            fields["durationSeconds"] = Int(end.timeIntervalSince(start).rounded())
        }
        return fields
    }

    func uploadProjectMemorySnapshot(_ snapshot: ProjectMemorySnapshot) async throws {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              gate.settings.sessionLogCloudBackupEnabled,
              !gate.syncSuppressed,
              let uid = gate.account.uid else { return }

        let resolvedVaultKey = try await writableVaultKey(uid: uid)
        let vaultKey = resolvedVaultKey.keyData

        let payload = try Self.jsonData(snapshot)
        let cloudContentHash = try CloudVaultCrypto.projectMemoryContentHash(payload, keyData: vaultKey)
        let visualKinds = Array(Set(snapshot.visuals.map(\.kind.rawValue))).sorted()

        // Opaque, deterministic, vault-key-keyed doc id so the server (and anyone
        // with raw Firestore read) never sees the project name — it lives only
        // inside `sealedSnapshot`. Same slug + key → same id, so upsert stays
        // idempotent. The plaintext `projectSlug`/`projectDisplayName` callable
        // fields are dropped (they were pure denormalization of the ciphertext).
        let docID = try CloudVaultCrypto.projectMemoryDocID(forSlug: snapshot.projectSlug, keyData: vaultKey)
        let sealedSnapshot = try CloudVaultCrypto.sealBlob(
            payload,
            keyData: vaultKey,
            aadContext: CloudVaultAADContext(
                uid: uid,
                collection: "project_memory_snapshots",
                docID: docID,
                field: "sealedSnapshot"
            )
        )

        var commitPayload: [String: Any] = [
            "docID": docID,
            "contentHash": cloudContentHash,
            "contentHashVersion": CloudVaultCrypto.projectMemoryContentHashVersion,
            "sourceSessionCount": snapshot.sourceSessionCount,
            "sourceConversationCount": snapshot.sourceConversationCount,
            "generatedAt": Self.iso8601.string(from: snapshot.generatedAt),
            "freshness": snapshot.freshness.rawValue,
            "visualKinds": visualKinds,
            "vaultKeyID": resolvedVaultKey.vaultKeyID,
            "sealedSnapshot": try Self.dictionary(sealedSnapshot)
        ]
        // Client-side migration: if this snapshot was previously stored under the
        // plaintext-slug doc id, tell the server to delete that legacy doc in the
        // same authed commit so the cleartext name/slug stops surviving. The
        // server cannot re-key on its own (it lacks the vault key).
        if snapshot.projectSlug != docID {
            commitPayload["legacyDocID"] = snapshot.projectSlug
        }

        do {
            try await encryptedCloudClient.commitEncryptedProjectMemorySnapshot(commitPayload)
        } catch {
            if Self.isPermissionDeniedFunctionsError(error) { return }
            throw error
        }
    }

    func fetchCloudProjectMemorySnapshot(projectSlug: String) async throws -> ProjectMemorySnapshot? {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              gate.account.isCloudSyncEnabled,
              gate.settings.sessionLogCloudBackupEnabled,
              !gate.syncSuppressed,
              let uid = gate.account.uid else { return nil }

        guard let vaultKey = try await readableVaultKey(uid: uid)?.keyData else { return nil }

        // Look the snapshot up by the opaque vault-keyed doc id derived from the
        // candidate slug. LEGACY FALLBACK: a doc written before this change is keyed
        // by the plaintext slug, so if the opaque lookup misses, retry by slug so
        // in-flight/legacy docs still render during migration (the next upload
        // re-keys + deletes the legacy doc).
        let docID = try CloudVaultCrypto.projectMemoryDocID(forSlug: projectSlug, keyData: vaultKey)
        let payload: [String: Any]
        do {
            payload = try await encryptedCloudClient.getEncryptedProjectMemorySnapshot([
                "docID": docID
            ])
        } catch {
            if Self.isPermissionDeniedFunctionsError(error) { return nil }
            throw error
        }
        var snapshotPayload = payload["snapshot"] as? [String: Any]
        if snapshotPayload?["sealedSnapshot"] == nil {
            let legacyPayload: [String: Any]
            do {
                legacyPayload = try await encryptedCloudClient.getEncryptedProjectMemorySnapshot([
                    "projectSlug": projectSlug
                ])
            } catch {
                if Self.isPermissionDeniedFunctionsError(error) { return nil }
                throw error
            }
            snapshotPayload = legacyPayload["snapshot"] as? [String: Any]
        }
        guard let snapshotPayload,
              let sealedSnapshot = snapshotPayload["sealedSnapshot"] else {
            return nil
        }
        let sealedData = try JSONSerialization.data(withJSONObject: sealedSnapshot)
        let envelope = try JSONDecoder().decode(CloudVaultBlobEnvelope.self, from: sealedData)
        let snapshotDocID = snapshotPayload["docID"] as? String ?? docID
        let plaintext = try CloudVaultCrypto.openBlob(
            envelope,
            keyData: vaultKey,
            aadContext: CloudVaultAADContext(
                uid: uid,
                collection: "project_memory_snapshots",
                docID: snapshotDocID,
                field: "sealedSnapshot"
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectMemorySnapshot.self, from: plaintext)
    }

    /// Fetches session log manifests from Firestore for the signed-in user.
    /// Returns ConversationRecords with empty fullText; body is fetched lazily via DownloadSyncService.
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [ConversationRecord] {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              let uid = gate.account.uid else { return [] }
        let vaultKey: Data?
        do {
            vaultKey = try await readableVaultKey(uid: uid)?.keyData
        } catch {
            vaultKey = nil
        }

        let snapshot = try await context.firestoreGateway
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
                do {
                    return try CloudVaultCrypto.openText(
                        envelope,
                        keyData: key,
                        aadContext: CloudVaultAADContext(
                            uid: uid,
                            collection: "session_logs",
                            docID: doc.documentID,
                            field: "sealedTitle"
                        )
                    )
                } catch {
                    return nil
                }
            }
            let title = decryptedTitle ?? data["inferredTaskTitle"] as? String ?? ""

            return ConversationRecord(
                id: id,
                provider: provider,
                sessionId: doc.documentID,
                projectName: "",
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

    /// Fetches and decrypts a session-log body from encrypted Cloud Storage.
    /// Legacy Firestore chunk bodies are intentionally ignored; they are
    /// scrub-only data under the hardened cloud privacy boundary.
    func fetchCloudSessionLogBody(docId: String) async throws -> String {
        let gate = await context.syncGate()
        guard gate.account.isFirebaseAvailable,
              gate.account.isSignedIn,
              let uid = gate.account.uid else { return "" }
        guard let vaultKey = try await readableVaultKey(uid: uid)?.keyData else { return "" }

        let manifestData = try await context.firestoreGateway
            .collection("users")
            .document(uid)
            .collection("session_logs")
            .document(docId)
            .getData() ?? [:]
        guard manifestData["bodyStorage"] as? String == "firebase_storage_encrypted",
              let storagePath = manifestData["storagePath"] as? String else {
            return ""
        }

        let data = try await encryptedCloudClient.downloadEncryptedBody(storagePath: storagePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(CloudVaultBlobEnvelope.self, from: data)
        let plaintext = try CloudVaultCrypto.openBlob(
            envelope,
            keyData: vaultKey,
            aadContext: CloudVaultAADContext(
                uid: uid,
                collection: "session_logs",
                docID: docId,
                field: "sealedBody"
            )
        )
        return String(data: plaintext, encoding: .utf8) ?? ""
    }

}

protocol SessionLogVaultKeyProviding {
    func loadKey(uid: String) throws -> Data?
    func getOrCreateKey(uid: String) throws -> Data
}

extension CloudVaultKeyStore: SessionLogVaultKeyProviding {}

protocol SessionLogArchivedSessionMirroring {
    func mirrorArchivedLog(_ conversation: ConversationRecord, cloudLogDocumentID: String?) async
}

extension CLIAgentSessionMirror: SessionLogArchivedSessionMirroring {}

@MainActor
protocol SessionLogVaultKeyPublishing {
    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws
}

enum CloudSyncEscrowPublicKeyPublisher {
    static func publishIfNeeded(
        userRef: CloudSyncDocumentGateway,
        deviceId: String,
        publicKeyData: Data,
        publicKeyFingerprint: String,
        keyVersion: Int
    ) async throws {
        let publicKeyBase64 = publicKeyData.base64EncodedString()
        let documentRef = userRef.collection("escrow_public_keys").document("\(deviceId)_\(keyVersion)")

        if let data = try await documentRef.getData() {
            guard EscrowPublicKeyPublisher.matchesExistingPublicKey(
                data,
                deviceId: deviceId,
                publicKeyBase64: publicKeyBase64,
                publicKeyFingerprint: publicKeyFingerprint,
                keyVersion: keyVersion
            ) else {
                throw EscrowPublicKeyPublishError.immutablePublicKeyConflict(
                    deviceId: deviceId,
                    keyVersion: keyVersion
                )
            }
            return
        }

        try await documentRef.setData([
            "deviceId": deviceId,
            "publicKeyData": publicKeyBase64,
            "publicKeyFingerprint": publicKeyFingerprint,
            "keyVersion": keyVersion,
            "algorithm": "ECIES-P256-AESGCM",
            "createdAt": FieldValue.serverTimestamp()
        ], merge: false)
    }
}

enum CloudSyncSignalIdentityPublicKeyPublisher {
    static func publishIfNeeded(
        userRef: CloudSyncDocumentGateway,
        deviceId: String,
        platform: String,
        identity: OpenBurnBarSignalIdentityKeypair
    ) async throws {
        let documentRef = userRef.collection("signal_identity_public_keys").document(identity.identityKeyId)
        if let data = try await documentRef.getData() {
            guard data["deviceId"] as? String == deviceId,
                  data["platform"] as? String == platform,
                  data["identityKeyId"] as? String == identity.identityKeyId,
                  data["publicKeyData"] as? String == identity.publicKeyBase64,
                  data["publicKeyFingerprint"] as? String == identity.publicKeyFingerprint,
                  data["keyVersion"] as? Int == identity.keyVersion,
                  data["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption else {
                throw SignalIdentityPublicKeyPublishError.immutablePublicKeyConflict(
                    deviceId: deviceId,
                    keyVersion: identity.keyVersion
                )
            }
            return
        }
        try await documentRef.setData([
            "deviceId": deviceId,
            "platform": platform,
            "identityKeyId": identity.identityKeyId,
            "publicKeyData": identity.publicKeyBase64,
            "publicKeyFingerprint": identity.publicKeyFingerprint,
            "keyVersion": identity.keyVersion,
            "algorithm": CloudVaultCrypto.signalAtRestEncryption,
            "createdAt": FieldValue.serverTimestamp()
        ], merge: false)
    }
}

enum CloudSyncTrustedDeviceChainVerifier {
    static func verifiedTrustedDevice(
        uid: String,
        userRef: CloudSyncDocumentGateway,
        deviceDocument: CloudSyncDocumentSnapshotGateway,
        localIdentity: OpenBurnBarSignalIdentityKeypair
    ) async throws -> CloudVaultVerifiedTrustedDevice {
        let data = deviceDocument.data()
        let deviceId = ((data["deviceId"] as? String) ?? deviceDocument.documentID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: deviceId,
            localIdentity: localIdentity,
            visited: []
        )
    }

    private static func verifiedTrustedDevice(
        uid: String,
        userRef: CloudSyncDocumentGateway,
        deviceId: String,
        localIdentity: OpenBurnBarSignalIdentityKeypair,
        visited: Set<String>
    ) async throws -> CloudVaultVerifiedTrustedDevice {
        guard !deviceId.isEmpty, !visited.contains(deviceId) else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        guard let deviceData = try await userRef.collection("escrow_devices").document(deviceId).getData(),
              deviceData["trustState"] as? String == EscrowDeviceTrustState.trusted.rawValue,
              let keyVersion = deviceData["keyVersion"] as? Int,
              let escrowFingerprint = deviceData["publicKeyFingerprint"] as? String else {
            throw CloudVaultTrustChainVerificationError.invalidTrustedDevice(deviceId: deviceId)
        }
        guard let publicKeyData = try await userRef.collection("escrow_public_keys")
            .document("\(deviceId)_\(keyVersion)")
            .getData(),
              publicKeyData["deviceId"] as? String == deviceId,
              publicKeyData["keyVersion"] as? Int == keyVersion,
              publicKeyData["publicKeyFingerprint"] as? String == escrowFingerprint,
              let escrowPublicKeyBase64 = publicKeyData["publicKeyData"] as? String,
              let escrowPublicKey = Data(base64Encoded: escrowPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.missingEscrowPublicKey(deviceId: deviceId, keyVersion: keyVersion)
        }
        // H1: bind the server fingerprint to the actual escrow key bytes — the
        // trust-chain signature only covers the fingerprint string, so a backend
        // byte-swap would otherwise be invisible. Recompute and reject on mismatch.
        guard EscrowDeviceSafetyCode.isFingerprint(escrowFingerprint, boundTo: escrowPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        let signalIdentityKeyId = OpenBurnBarSignalIdentityKeyStore.identityKeyId(deviceId: deviceId, keyVersion: keyVersion)
        guard let signalData = try await userRef.collection("signal_identity_public_keys")
            .document(signalIdentityKeyId)
            .getData(),
              signalData["deviceId"] as? String == deviceId,
              signalData["identityKeyId"] as? String == signalIdentityKeyId,
              signalData["keyVersion"] as? Int == keyVersion,
              signalData["algorithm"] as? String == CloudVaultCrypto.signalAtRestEncryption,
              let signalFingerprint = signalData["publicKeyFingerprint"] as? String,
              let signalPublicKeyBase64 = signalData["publicKeyData"] as? String,
              let signalPublicKey = Data(base64Encoded: signalPublicKeyBase64) else {
            throw CloudVaultTrustChainVerificationError.missingSignalIdentity(deviceId: deviceId, keyVersion: keyVersion)
        }
        // H1: bind the Signal identity fingerprint to its actual key bytes.
        guard Data(SHA256.hash(data: signalPublicKey)).base64EncodedString() == signalFingerprint else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        let verified = CloudVaultVerifiedTrustedDevice(
            deviceId: deviceId,
            keyVersion: keyVersion,
            escrowPublicKeyFingerprint: escrowFingerprint,
            escrowPublicKeyData: escrowPublicKey,
            signalIdentityKeyId: signalIdentityKeyId,
            signalIdentityPublicKeyFingerprint: signalFingerprint,
            signalIdentityPublicKeyData: signalPublicKey
        )
        if signalIdentityKeyId == localIdentity.identityKeyId {
            guard signalPublicKey == localIdentity.publicKeyData else {
                throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
            }
            return verified
        }
        guard deviceData["trustChainVersion"] as? Int == CloudVaultDeviceTrustChain.version,
              deviceData["trustChainAlgorithm"] as? String == CloudVaultDeviceTrustChain.algorithm,
              deviceData["targetSignalIdentityKeyId"] as? String == signalIdentityKeyId,
              deviceData["targetSignalIdentityPublicKeyFingerprint"] as? String == signalFingerprint,
              let approvedByDeviceId = deviceData["approvedByDeviceId"] as? String,
              let approvedBySignalIdentityKeyId = deviceData["approvedBySignalIdentityKeyId"] as? String,
              let approvedBySignalFingerprint = deviceData["approvedBySignalIdentityPublicKeyFingerprint"] as? String,
              let signature = deviceData["trustChainSignature"] as? String else {
            throw CloudVaultTrustChainVerificationError.missingTrustChain(deviceId: deviceId)
        }
        let approver = try await verifiedTrustedDevice(
            uid: uid,
            userRef: userRef,
            deviceId: approvedByDeviceId,
            localIdentity: localIdentity,
            visited: visited.union([deviceId])
        )
        guard approver.signalIdentityKeyId == approvedBySignalIdentityKeyId,
              approver.signalIdentityPublicKeyFingerprint == approvedBySignalFingerprint else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        let payload = CloudVaultDeviceTrustChainPayload(
            uid: uid,
            targetDeviceId: deviceId,
            targetEscrowPublicKeyFingerprint: escrowFingerprint,
            targetKeyVersion: keyVersion,
            targetSignalIdentityKeyId: signalIdentityKeyId,
            targetSignalIdentityPublicKeyFingerprint: signalFingerprint,
            approverDeviceId: approver.deviceId,
            approverSignalIdentityKeyId: approver.signalIdentityKeyId,
            approverSignalIdentityPublicKeyFingerprint: approver.signalIdentityPublicKeyFingerprint
        )
        guard CloudVaultDeviceTrustChain.verify(
            payload,
            signatureBase64: signature,
            approverPublicKeyData: approver.signalIdentityPublicKeyData
        ) else {
            throw CloudVaultTrustChainVerificationError.invalidTrustChain(deviceId: deviceId)
        }
        return verified
    }
}

@MainActor
struct FirebaseSessionLogVaultKeyPublisher: SessionLogVaultKeyPublishing {
    func publishCloudVaultKey(uid: String, vaultKey: Data, context: CloudSyncContext) async throws {
        let vaultKeyID = try CloudVaultCrypto.vaultKeyID(for: vaultKey)
        let keypair = try CloudVaultDeviceKeypair(account: "cloud-vault-device:\(context.deviceId)")
        let userRef = context.firestoreGateway.collection("users").document(uid)
        let deviceRef = userRef.collection("escrow_devices").document(context.deviceId)
        let existingDevice: [String: Any]?
        do {
            existingDevice = try await deviceRef.getData()
        } catch {
            existingDevice = nil
        }
        let existingTrustState = existingDevice?["trustState"] as? String
        let sourceIsTrusted = existingTrustState == EscrowDeviceTrustState.trusted.rawValue
        var devicePayload: [String: Any] = [
            "deviceId": context.deviceId,
            "deviceName": Host.current().localizedName ?? "Mac",
            "platform": "macOS",
            "publicKeyFingerprint": keypair.publicKeyFingerprint,
            "keyVersion": keypair.keyVersion,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if existingDevice == nil {
            devicePayload["trustState"] = EscrowDeviceTrustState.pending.rawValue
        }
        try await deviceRef.setData(devicePayload, merge: true)
        try await CloudSyncEscrowPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: context.deviceId,
            publicKeyData: keypair.publicKeyData,
            publicKeyFingerprint: keypair.publicKeyFingerprint,
            keyVersion: keypair.keyVersion
        )
        let signalIdentity = try OpenBurnBarSignalIdentityKeyStore().loadOrCreate(uid: uid, deviceId: context.deviceId)
        try await CloudSyncSignalIdentityPublicKeyPublisher.publishIfNeeded(
            userRef: userRef,
            deviceId: context.deviceId,
            platform: "macOS",
            identity: signalIdentity
        )
        guard sourceIsTrusted else {
            return
        }

        let trusted = try await userRef.collection("escrow_devices")
            .whereField("trustState", isEqualTo: EscrowDeviceTrustState.trusted.rawValue)
            .getDocuments()
        for doc in trusted.documents {
            let target = try await CloudSyncTrustedDeviceChainVerifier.verifiedTrustedDevice(
                uid: uid,
                userRef: userRef,
                deviceDocument: doc,
                localIdentity: signalIdentity
            )
            let wrapped = try CloudVaultCrypto.wrapVaultKey(
                vaultKey,
                recipientPublicKey: target.escrowPublicKeyData
            )
            try await userRef.collection("cloud_vault_key_wrappers")
                .document("\(target.deviceId)_\(target.keyVersion)")
                .setData([
                    "uid": uid,
                    "vaultKeyID": vaultKeyID,
                    "targetDeviceId": target.deviceId,
                    "sourceDeviceId": context.deviceId,
                    "publicKeyFingerprint": target.escrowPublicKeyFingerprint,
                    "keyVersion": target.keyVersion,
                    "wrappedVaultKey": wrapped.base64EncodedString(),
                    "algorithm": "ECIES-P256-AESGCM",
                    "status": "active",
                    "createdAt": FieldValue.serverTimestamp(),
                    "updatedAt": FieldValue.serverTimestamp(),
                    "schemaVersion": 2
                ], merge: true)
        }
    }
}

extension SessionLogSyncService {
    static func cloudDocumentID(deviceId: String, record: ConversationRecord) -> String {
        let safeDevice = cloudDocumentComponent(deviceId, fallback: "device", maxLength: 48)
        let safeProvider = cloudDocumentComponent(record.provider.rawValue, fallback: "provider", maxLength: 32)
        let digest = sha256Hex("\(record.provider.rawValue)\n\(record.sessionId)\n\(record.id)")
        return "\(safeDevice)_\(safeProvider)_\(digest.prefix(32))"
    }

    private static func cloudDocumentComponent(_ raw: String, fallback: String, maxLength: Int) -> String {
        var result = ""
        result.reserveCapacity(min(raw.count, maxLength))
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95:
                result.unicodeScalars.append(scalar)
            default:
                result.append("_")
            }
        }
        while result.contains("__") {
            result = result.replacingOccurrences(of: "__", with: "_")
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        let safe = trimmed.isEmpty ? fallback : trimmed
        return String(safe.prefix(maxLength))
    }
}

private extension SessionLogSyncService {

    static func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudSessionLogUploadError.encodingFailed
        }
        return dictionary
    }

    static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isPermissionDeniedFunctionsError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == FunctionsErrorDomain,
              let code = FunctionsErrorCode(rawValue: nsError.code) else {
            return false
        }
        return code == .permissionDenied || code == .unauthenticated || code == .failedPrecondition
    }

    static func normalizedTerms(from text: String) -> [String] {
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

    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func decodeSealedText(_ raw: Any?) -> CloudVaultSealedText? {
        guard let dict = raw as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: dict) else {
            return nil
        }
        return try? JSONDecoder().decode(CloudVaultSealedText.self, from: data)
    }
}

struct EncryptedSessionBlobUploadTicket {
    let storagePath: String
    let uploadURL: URL
}

protocol SessionLogEncryptedCloudClient {
    func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedSessionBlobUploadTicket
    func uploadEncryptedBody(data: Data, ticket: EncryptedSessionBlobUploadTicket) async throws
    func commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: [String: Any],
        chunks: [[String: Any]]
    ) async throws
    func commitEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws
    func getEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any]
    func downloadEncryptedBody(storagePath: String) async throws -> Data
    /// Deletes the encrypted session body blob from Cloud Storage for a single
    /// session-log document. Used by tombstone GC after the retention window so
    /// the GCS object does not outlive the conversation it backed (B-DATA-2).
    func deleteEncryptedSessionBlob(documentID: String, storagePath: String) async throws
}

final class FirebaseSessionLogEncryptedCloudClient: SessionLogEncryptedCloudClient, @unchecked Sendable {
    private let injectedFunctions: Functions?
    private let urlSession: URLSession

    init(
        functions: Functions? = nil,
        urlSession: URLSession = .shared
    ) {
        self.injectedFunctions = functions
        self.urlSession = urlSession
    }

    private var functions: Functions {
        injectedFunctions ?? Functions.functions(region: "us-central1")
    }

    func beginEncryptedSessionBlobUpload(
        documentID: String,
        bodyHash: String,
        byteCount: Int
    ) async throws -> EncryptedSessionBlobUploadTicket {
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
        return EncryptedSessionBlobUploadTicket(storagePath: storagePath, uploadURL: uploadURL)
    }

    func uploadEncryptedBody(data: Data, ticket: EncryptedSessionBlobUploadTicket) async throws {
        var request = URLRequest(url: ticket.uploadURL)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await urlSession.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw CloudSessionLogUploadError.storageUploadFailed
        }
    }

    func commitEncryptedSearchIndex(
        deviceId: String,
        indexVersion: Int,
        document: [String: Any],
        chunks: [[String: Any]]
    ) async throws {
        _ = try await functions.httpsCallable("commitEncryptedSearchIndexBatch").call([
            "deviceId": deviceId,
            "indexVersion": indexVersion,
            "documents": [document],
            "chunks": chunks
        ])
    }

    func commitEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws {
        _ = try await functions.httpsCallable("commitEncryptedProjectMemorySnapshot").call(payload as NSDictionary)
    }

    func getEncryptedProjectMemorySnapshot(_ payload: [String: Any]) async throws -> [String: Any] {
        let result = try await functions.httpsCallable("getEncryptedProjectMemorySnapshot").call(payload as NSDictionary)
        return result.data as? [String: Any] ?? [:]
    }

    func downloadEncryptedBody(storagePath: String) async throws -> Data {
        let result = try await functions.httpsCallable("getEncryptedSessionBlobDownloadUrl").call([
            "storagePath": storagePath
        ])
        guard let dict = result.data as? [String: Any],
              let raw = dict["downloadURL"] as? String,
              let url = URL(string: raw) else {
            throw URLError(.badServerResponse)
        }
        let (data, response) = try await urlSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func deleteEncryptedSessionBlob(documentID: String, storagePath: String) async throws {
        // The body lives behind a signed-URL / IAM boundary, so deletion is
        // server-mediated (same posture as `beginEncryptedSessionBlobUpload`).
        _ = try await functions.httpsCallable("deleteEncryptedSessionBlob").call([
            "documentID": documentID,
            "storagePath": storagePath
        ])
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
    func fetchCloudSessionLogs(limit: Int = 200) async throws -> [ConversationRecord] {
        let context = CloudSyncContext(
            dataStore: dataStore,
            accountManager: accountManager,
            settingsManager: settingsManager
        )
        return try await SessionLogSyncService(context: context).fetchCloudSessionLogs(limit: limit)
    }

    func searchCloudSessionLogs(query: String, limit: Int = 50) async throws -> [ConversationRecord] {
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
