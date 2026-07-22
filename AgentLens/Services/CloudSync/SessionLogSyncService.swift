import FirebaseAuth
import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os
import CryptoKit
import OpenBurnBarCore
import OpenBurnBarSignalCore

private final class SessionLogSyncProcessGate: Sendable {
    private let running = Locked(false)

    func tryEnter() -> Bool {
        running.withLock { running in
            guard !running else { return false }
            running = true
            return true
        }
    }

    func leave() { running.write(false) }
}

/// Sync domain for uploading session-log manifests/search metadata to Firestore.
///
/// Firestore layout:
///   `users/{uid}/session_logs/{safeDeviceId}_{provider}_{recordHash}` (manifest)
///   `users/{uid}/cloud_search_chunks/{chunkId}` (server-written encrypted search metadata)
///
/// Gated separately on `sessionLogCloudBackupEnabled`.
/// Uses its own dirty flag (`logSyncedAt`) so it is independent of metadata sync.
final class SessionLogSyncService: CloudSyncDomain, Sendable {
    private typealias FirestoreWrite = (data: [String: Any], document: CloudSyncDocumentGateway, merge: Bool)
    private enum FirestoreBatchOperation {
        case set(FirestoreWrite)
        case delete(CloudSyncDocumentGateway)
    }

    private static let processGate = SessionLogSyncProcessGate()

    let context: CloudSyncContext
    let encryptedCloudClient: SessionLogEncryptedCloudClient
    private let vaultKeyStore: SessionLogVaultKeyProviding
    private let vaultKeyPublisher: SessionLogVaultKeyPublishing
    // SessionLogArchivedSessionMirroring is not Sendable; the lazily-resolved
    // singleton lives in an OSAllocatedUnfairLock so the service is plainly Sendable.
    private let archivedSessionMirrorBox: OSAllocatedUnfairLock<SessionLogArchivedSessionMirroring?>

    private let state = Locked(CloudSyncDomainState())

    var isSyncing: Bool { state.read().isSyncing }
    var lastSyncError: String? { state.read().lastSyncError }
    var lastSyncDate: Date? { state.read().lastSyncDate }

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
        self.archivedSessionMirrorBox = OSAllocatedUnfairLock(uncheckedState: archivedSessionMirror)
    }

    private func resolvedArchivedSessionMirror() async -> SessionLogArchivedSessionMirroring {
        if let existing = archivedSessionMirrorBox.withLockUnchecked({ $0 }) {
            return existing
        }
        let shared = await MainActor.run { CLIAgentSessionMirror.shared }
        archivedSessionMirrorBox.withLockUnchecked { $0 = shared }
        return shared
    }

    func writableVaultKey(uid: String) async throws -> CloudVaultResolvedKey {
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

    func readableVaultKey(uid: String) async throws -> CloudVaultResolvedKey? {
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
        let syncStartTime = Date()

        state.beginSyncing()

        defer {
            state.endSyncing()
            Self.processGate.leave()
        }

        do {
            let backupUsage = try await context.dataStore.backupUsageSnapshot(limits: context.backupPlanLimits)
            if let blockingReason = backupUsage.blockingReason {
                throw CloudBackupPreflightError.planLimitExceeded(blockingReason)
            }

            progress?.setPhase(.facetBackfill, operation: "Checking cockpit facet schema…")
            await runFacetBackfillIfNeeded()
            progress?.setPhase(.sessionLogs, operation: "Loading pending conversations…")

            let userRef = context.firestoreGateway.collection("users").document(uid)
            let logsRef = userRef.collection("session_logs")
            let sessionModelMap = (try? await context.dataStore.sessionModelMap()) ?? [:] // try?-ok(best-effort metadata read)
            let sessionFacetsMap = (try? await context.dataStore.sessionFacetsMap()) ?? [:] // try?-ok(best-effort metadata read)

            var processedAnyBatch = false
            var uploadedSessionLogCount = 0
            repeat {
                let unsynced = try await context.dataStore.fetchUnsyncedSessionLogs(limit: 50)
                guard !unsynced.isEmpty else {
                    if !processedAnyBatch {
                        state.withLock { $0.lastSyncDate = Date() }
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

                    let docId = Self.cloudDocumentID(deviceId: deviceId, record: record)
                    let manifestRef = logsRef.document(docId)
                    if let deletedAt = record.deletedAt {
                        let existingManifest = try await manifestRef.getData()
                        let operation = existingManifest == nil ? "Skipping absent session tombstone" : "Publishing session tombstone"
                        progress?.setCurrentRecord(label: label, operation: operation)
                        var firestoreWrites = 0
                        if existingManifest != nil {
                            let tombstone = Self.sessionLogTombstoneFields(for: record, deviceId: deviceId, deletedAt: deletedAt)
                            try await manifestRef.setData(tombstone, merge: true)
                            firestoreWrites = 1
                        }
                        try await context.dataStore.markSessionLogsSynced(ids: [record.id])
                        progress?.recordSessionLogOutcome(
                            label: label,
                            uploaded: false,
                            facetRefreshOnly: false,
                            plaintextBytes: 0,
                            encryptedBytes: 0,
                            storageUploads: 0,
                            firestoreWrites: firestoreWrites,
                            searchIndexCommits: 0
                        )
                        continue
                    }
                    let markdown = OpenBurnBarCore.SessionLogMarkdownFormatter.markdown(for: record)
                    // Project/path text is private. It is fed into keyed local
                    // search hashes, then stripped from every cloud document.
                    let privateProjectSearchText = Self.clampedPrivateSearchText(record.projectName)
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
                       existing["deletedAt"] == nil,
                       existing["bodyHash"] as? String == bodyHash,
                       existing["chunkMetadataVersion"] as? Int == Self.chunkMetadataVersion,
                       existing["cloudSearchIndexVersion"] as? Int == Self.cloudSearchIndexVersion,
                       existing["bodyStorage"] as? String == "firebase_storage_encrypted",
                       let existingStoragePath = existing["storagePath"] as? String,
                       !existingStoragePath.isEmpty {
                        let facetRefreshOnly = existing["facetSchemaVersion"] as? Int != Self.facetSchemaVersion
                        var writes: [FirestoreWrite] = []
                        var deletes: [CloudSyncDocumentGateway] = []
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
                                operation: "Deleting legacy search chunks"
                            )
                            Self.appendLegacySessionLogChunkDeletes(
                                to: &deletes,
                                legacyChunkDocuments: legacyChunkDocuments,
                                manifestRef: manifestRef
                            )
                        }
                        let firestoreBatchCommits = try await commitFirestoreWrites(
                            writes,
                            deletes: deletes,
                            retryDomain: "sessionLog.legacyChunkScrub",
                            progress: progress,
                            label: label,
                            operation: { "Writing Firestore metadata (batch \($0))" }
                        )
                        await resolvedArchivedSessionMirror().mirrorArchivedLog(record, cloudLogDocumentID: docId)
                        try await context.dataStore.markSessionLogsSynced(ids: [record.id])
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
                    let titleText = record.summaryTitle ?? record.inferredTaskTitle
                    let searchMetadata = record.inferredTaskTitle + " " + privateProjectSearchText + " " + model
                    let chunks = try CloudVaultCrypto.cloudSearchBodyChunks(
                        markdown,
                        metadata: searchMetadata,
                        maxBytes: Self.cloudSearchChunkMaxBytes
                    )
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

                    let writes: [FirestoreWrite] = [
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
                        let searchText = chunk + " " + searchMetadata
                        let tokenHashes = try CloudVaultCrypto.searchIndexTokenHashes(
                            for: searchText,
                            keyData: vaultKey,
                            limit: Self.cloudSearchChunkTokenHashLimit
                        )
                        let semanticHashes = try CloudVaultCrypto.semanticHashes(
                            for: searchText,
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
                    var deletes: [CloudSyncDocumentGateway] = []
                    if !legacyChunkDocuments.isEmpty {
                        Self.appendLegacySessionLogChunkDeletes(
                            to: &deletes,
                            legacyChunkDocuments: legacyChunkDocuments,
                            manifestRef: manifestRef
                        )
                    }
                    let firestoreBatchCommits = try await commitFirestoreWrites(
                        writes,
                        deletes: deletes,
                        retryDomain: "sessionLog.batch",
                        progress: progress,
                        label: label,
                        operation: { "Writing Firestore metadata (batch \($0))" }
                    )
                    await resolvedArchivedSessionMirror().mirrorArchivedLog(record, cloudLogDocumentID: docId)
                    try await context.dataStore.markSessionLogsSynced(ids: [record.id])
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
                    uploadedSessionLogCount += 1
                }
            } while drainAll

            state.withLock {
                $0.lastSyncDate = Date()
                $0.lastSyncError = nil
            }
            let durationBucket = AnalyticsBuckets.durationMs(Int(Date().timeIntervalSince(syncStartTime) * 1000))
            let itemCountBucket = AnalyticsBuckets.count(
                progress?.currentSnapshot().uploadedSessionLogs ?? uploadedSessionLogCount
            )
            Task { @MainActor in
                Analytics.shared.track(.cloudsyncCompleted, [
                    "domain": "session_logs",
                    "outcome": "success",
                    "duration_ms_bucket": .string(durationBucket),
                    "item_count_bucket": .string(itemCountBucket)
                ])
            }
        } catch {
            progress?.fail(error.localizedDescription)
            let errorType = String(describing: type(of: error))
            Task { @MainActor in
                Analytics.shared.track(.cloudsyncFailed, [
                    "domain": "session_logs",
                    "error_type": .string(errorType)
                ])
            }
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
            _ = try await context.dataStore.markAllSessionLogsUnsynced()
            await MainActor.run {
                context.settingsManager.conversationFacetBackfillVersion = Self.facetSchemaVersion
            }
        } catch {
            AppLogger.sync.silentFailure( // cov:ignore -- nonfatal-log
                "session_log_facet_backfill_failed", // cov:ignore -- nonfatal-log
                error: error, // cov:ignore -- nonfatal-log
                context: ["retry": "next_sync_cycle"] // cov:ignore -- nonfatal-log
            ) // cov:ignore -- nonfatal-log
        }
    }

    private static func sessionLogTombstoneFields(for record: OpenBurnBarCore.ConversationRecord, deviceId: String, deletedAt: Date) -> [String: Any] {
        var fields: [String: Any] = [
            "id": record.id,
            "deviceId": deviceId,
            "provider": record.provider.rawValue,
            "sessionId": record.sessionId,
            "sourceType": record.sourceType.rawValue,
            "deletedAt": Timestamp(date: deletedAt),
            "version": record.version,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        fields.merge(legacyPlaintextFieldDeletes()) { _, new in new }
        return fields
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

    private static let cloudPublicToolTagLimit = 12

    private static let cloudPublicToolTags: Set<String> = [
        "apply_patch",
        "bash",
        "edit",
        "exec_command",
        "find",
        "grep_search",
        "multi_edit",
        "other",
        "read",
        "rg",
        "search",
        "sed",
        "shell",
        "write"
    ]

    private static func normalizedPublicToolTag(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        let slug = String(
            trimmed.map { character in
                if character.isLetter || character.isNumber || character == "_" || character == "-" {
                    return character
                }
                return "_"
            }
        )
        .split(separator: "_")
        .joined(separator: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "_-"))

        guard !slug.isEmpty else { return nil }
        return cloudPublicToolTags.contains(slug) ? slug : "other"
    }

    static func publicToolTags(from values: [String]) -> [String] {
        let tags = Set(values.compactMap(normalizedPublicToolTag(_:)))
        let sortedTags = Array(tags).sorted()
        return Array(sortedTags[..<min(Self.cloudPublicToolTagLimit, sortedTags.count)])
    }

    private static let chunkMetadataVersion = 1
    private static let cloudSearchChunkMaxBytes = 16_000
    private static let cloudSearchChunkTokenHashLimit = 1_024
    private static let cloudSearchIndexVersion = 5

    /// Generation of the server-visible cockpit facet block stored on each manifest. Bumping this
    /// triggers a one-time backfill (`markAllSessionLogsUnsynced`) so existing manifests get the
    /// new facets. Facets are metadata only — token totals, cost, timing, model/provider, and
    /// generic tool tags. Project names and working directories are device-only.
    static let facetSchemaVersion = 3

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
        deletes: [CloudSyncDocumentGateway] = [],
        retryDomain: String,
        progress: CloudBackupProgressTracker?,
        label: String,
        operation: (Int) -> String
    ) async throws -> Int {
        let operations: [FirestoreBatchOperation] = writes.map(FirestoreBatchOperation.set)
            + deletes.map(FirestoreBatchOperation.delete)
        guard !operations.isEmpty else { return 0 }

        var firestoreBatchCommits = 0
        for start in stride(from: 0, to: operations.count, by: 450) {
            progress?.setCurrentRecord(
                label: label,
                operation: operation(firestoreBatchCommits + 1)
            )
            let batch = context.firestoreGateway.batch()
            for batchOperation in operations[start..<min(start + 450, operations.count)] {
                switch batchOperation {
                case .set(let write):
                    batch.setData(write.data, forDocument: write.document, merge: write.merge)
                case .delete(let document):
                    batch.deleteDocument(document)
                }
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

    private static func appendLegacySessionLogChunkDeletes(
        to deletes: inout [CloudSyncDocumentGateway],
        legacyChunkDocuments: [CloudSyncDocumentSnapshotGateway],
        manifestRef: CloudSyncDocumentGateway
    ) {
        guard !legacyChunkDocuments.isEmpty else { return }

        let chunksRef = manifestRef.collection("chunks")
        for legacyDocument in legacyChunkDocuments {
            deletes.append(chunksRef.document(legacyDocument.documentID))
        }
    }

    private static func progressLabel(for record: OpenBurnBarCore.ConversationRecord) -> String {
        let title = record.summaryTitle ?? record.inferredTaskTitle
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return record.provider.displayName
        }
        return "\(record.provider.displayName) · \(trimmed)"
    }

    /// Root session id used to align a `OpenBurnBarCore.ConversationRecord` with the aggregated usage facets,
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
        for record: OpenBurnBarCore.ConversationRecord,
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
        // Only coarse, allowlisted tool slugs are public cockpit facets. Unknown or noisy
        // tool names collapse to "other" so parser artifacts cannot become content sidecars.
        let toolTags = publicToolTags(from: record.keyTools)
        if !toolTags.isEmpty {
            fields["toolTags"] = toolTags
        }
        let start = facets?.startTime ?? record.startTime
        let end = facets?.endTime ?? record.endTime
        if let start, let end, end > start {
            fields["durationSeconds"] = Int(end.timeIntervalSince(start).rounded())
        }
        return fields
    }

}
