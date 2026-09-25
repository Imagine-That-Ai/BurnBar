#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

extension BurnBarProjectCodeMemoryStore {
    func remember(_ request: BurnBarProjectMemoryRememberRequest) throws -> BurnBarProjectMemoryRememberResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let body = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false else { throw BurnBarProjectCodeMemoryStoreError.emptyText }
        guard request.reviewStatus == .approved || request.reviewStatus == .quarantined else {
            throw BurnBarProjectCodeMemoryStoreError.invalidMemoryReviewStatus(request.reviewStatus.rawValue)
        }
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        let freeformFields = ([body, request.kind, request.scope] + request.tags + [request.sourcePath].compactMap { $0 })
            .joined(separator: "\n")
        let labels = Self.secretLabels(in: freeformFields)
        if labels.isEmpty == false {
            let hash = try databaseSync {
                try auditEvent(action: "memory.secret_rejected", domain: "memory", projectID: projectID, subjectID: nil, labels: labels)
            }
            logger.warning("project_memory_secret_rejected", metadata: ["project_id": projectID, "audit_hash": hash])
            throw BurnBarProjectCodeMemoryStoreError.secretRejected(labels: labels)
        }
        let injectionLabels = Self.memoryInjectionLabels(in: freeformFields)
        let reviewStatus: MemoryReviewStatus = injectionLabels.isEmpty ? request.reviewStatus : .quarantined
        // Keep semantic vectors body-only, matching the Python engine. Tags are
        // lexical evidence and must not distort the mirrored row's embedding.
        let memoryVector = embeddingProvider.isAvailable ? embeddingProvider.embed(body) : nil

        return try databaseSync {
            let bodyRef = Self.sha256Hex(body)
            let memoryID = "mem_" + String(Self.sha256Hex("\(projectID):\(request.scope):\(bodyRef)").prefix(32))
            let now = Self.isoNow()
            // Only the Memory MCP engine sends an id of its own, and it sends one
            // only for rows it wants mirrored as syncable. Its presence is therefore
            // the partition: callers that predate blind sync keep writing repository
            // knowledge, which never leaves the device.
            let engineMemoryID = request.engineMemoryID?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            let resolvedSourceKind = engineMemoryID == nil
                ? MemorySourceKind.code.rawValue
                : MemorySourceKind.agent.rawValue
            // The engine's taxonomy is richer than the app's `MemoryKind`, and the
            // app drops any row whose kind it cannot decode. A mirrored row is
            // therefore stored under the nearest app kind; the engine store keeps
            // the precise one, and it stays a tag here.
            let storedKind = engineMemoryID == nil
                ? request.kind
                : (MemoryKind(rawValue: request.kind)?.rawValue ?? MemoryKind.other.rawValue)
            // A normalised kind loses the engine's precise one, so keep it as a tag:
            // the mirrored row still says what it is, and nothing is lost locally.
            let storedTags = storedKind == request.kind ? request.tags : request.tags + ["engine-kind:\(request.kind)"]
            let tagsJSON = try encodeJSONString(storedTags)
            try execute("BEGIN IMMEDIATE", [])
            do {
                if reviewStatus == .approved {
                    try upsertProjectMemorySection(
                        projectID: projectID,
                        projectDisplayName: root.lastPathComponent,
                        memoryID: memoryID,
                        body: body,
                        kind: request.kind,
                        scope: request.scope,
                        tags: request.tags,
                        sourcePath: request.sourcePath,
                        now: now
                    )
                    try removeQuarantineMemoryBody(projectID: projectID, memoryID: memoryID)
                    // Blind sync: an approved memory the Memory MCP engine mirrored keeps
                    // its body in the shared encrypted database so the app's sync lane can
                    // seal and upload it. Nothing else writes here, so repository knowledge
                    // and quarantined input can never reach the cloud lane.
                    if let engineMemoryID {
                        try upsertAgentMemoryBody(
                            projectID: projectID,
                            memoryID: memoryID,
                            engineMemoryID: engineMemoryID,
                            body: body,
                            bodyHash: bodyRef,
                            now: now
                        )
                    } else {
                        try removeAgentMemoryBody(projectID: projectID, memoryID: memoryID)
                    }
                } else {
                    // Quarantined input remains reviewable in a dedicated
                    // encrypted-at-rest holding table, never in the default
                    // project-memory snapshot returned to agents.
                    try removeProjectMemorySection(
                        projectID: projectID,
                        projectDisplayName: root.lastPathComponent,
                        memoryID: memoryID,
                        now: now
                    )
                    try upsertQuarantineMemoryBody(projectID: projectID, memoryID: memoryID, body: body, now: now)
                    if let engineMemoryID {
                        // Quarantined-from-birth is the ordinary arrival for a mirrored
                        // row now that the wire defaults to review, so the engine id has
                        // to be recorded here: it is what the sealed cloud document keys
                        // on, and without it an approval later has nothing to address and
                        // the member's memory would silently never sync. The body stays
                        // out — `agent_memory_bodies` carries approved content only, and
                        // `setReviewStatus` refills it on approval. Writing an empty body
                        // over an existing row is also exactly the blanking an approved,
                        // already-uploaded memory needs when it is remirrored unapproved.
                        try upsertAgentMemoryBody(
                            projectID: projectID,
                            memoryID: memoryID,
                            engineMemoryID: engineMemoryID,
                            body: "",
                            bodyHash: "",
                            now: now
                        )
                    } else {
                        // Remirrored as unapproved after an upload: blank, never delete, so
                        // the sync lane can still address the sealed copy (see the helper).
                        try blankAgentMemoryBody(projectID: projectID, memoryID: memoryID, now: now)
                    }
                }
                let bodyReference = reviewStatus == .approved
                    ? Self.memoryBodyReference(memoryID: memoryID, projectID: projectID)
                    : Self.quarantineBodyReference(memoryID: memoryID, projectID: projectID)
                try execute(
                    """
                    INSERT INTO agent_memories
                        (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json, source_path, valid_from, review_status, source_kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        source_kind = excluded.source_kind,
                        kind = excluded.kind,
                        scope = excluded.scope,
                        confidence = excluded.confidence,
                        body_ref = excluded.body_ref,
                        body_redacted = excluded.body_redacted,
                        tags_json = excluded.tags_json,
                        source_path = excluded.source_path,
                        review_status = excluded.review_status,
                        updated_at = excluded.updated_at
                    """,
                    [
                        .text(memoryID), .text(projectID), .text(storedKind), .text(request.scope),
                        .double(request.confidence), .text(bodyRef), .text(bodyReference),
                        .text(tagsJSON), request.sourcePath.map(SQLiteBind.text) ?? .null, .text(now),
                        .text(reviewStatus.rawValue), .text(resolvedSourceKind), .text(now), .text(now)
                    ]
                )
                if let memoryVector, memoryVector.count == embeddingProvider.dimension {
                    let norm = memoryVector.reduce(0.0) { partial, value in
                        partial + Double(value * value)
                    }.squareRoot()
                    try execute(
                        """
                        INSERT INTO memory_embedding_refs
                            (memory_id, embedding_version_id, dimension, vector, norm, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(memory_id, embedding_version_id) DO UPDATE SET
                            dimension = excluded.dimension,
                            vector = excluded.vector,
                            norm = excluded.norm,
                            created_at = excluded.created_at
                        """,
                        [
                            .text(memoryID), .text(embeddingProvider.versionID), .int(memoryVector.count),
                            .blob(BurnBarCodeVectorCodec.encode(memoryVector)), .double(norm), .text(now)
                        ]
                    )
                }
                let salience = BurnBarMemoryRanking.salience(
                    kind: request.kind,
                    confidence: request.confidence,
                    accessCount: 0
                )
                try execute(
                    """
                    INSERT INTO memory_salience
                        (memory_id, salience, hit_count, last_reinforced_at, corroboration, source_trust, computed_at, updated_at)
                    VALUES (?, ?, 0, NULL, 1, ?, ?, ?)
                    ON CONFLICT(memory_id) DO UPDATE SET
                        salience = excluded.salience,
                        computed_at = excluded.computed_at,
                        updated_at = excluded.updated_at
                    """,
                    [.text(memoryID), .double(salience), .double(1.0), .text(now), .text(now)]
                )
                let auditHash = try auditEvent(
                    action: "memory.remember",
                    domain: "memory",
                    projectID: projectID,
                    subjectID: memoryID,
                    labels: ["review_status:\(reviewStatus.rawValue)"] + injectionLabels
                )
                try execute("COMMIT", [])
                return BurnBarProjectMemoryRememberResponse(
                    traceID: traceID,
                    projectID: projectID,
                    memoryID: memoryID,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }

    func indexProject(_ request: BurnBarProjectCodeIndexProjectRequest) throws -> BurnBarProjectCodeIndexProjectResponse {
        let traceID = TraceContextBridge.currentContext().traceID
        let root = try projectRoot(request.projectPath)
        let projectID = try resolveProjectIdentity(root: root).projectID
        let maxFiles = max(1, min(request.maxFiles, 25_000))
        let maxFileBytes = max(1_024, min(request.maxFileBytes, 10_000_000))
        let storageBudgetBytes = Self.normalizedStorageBudgetBytes(request.storageBudgetBytes)
        let commitSHA = Self.gitCommitSHA(root: root)
        let now = Self.isoNow()
        var indexedFiles = 0
        var chunkCount = 0
        var symbolCount = 0
        var storageByteCount = 0
        var rejectedFiles: [BurnBarProjectCodeRejectedFile] = []
        var artifactsForReferences: [IndexedArtifact] = []

        if let existing = codeHNSWSnapshot, existing.projectID == projectID {
            try? FileManager.default.removeItem(at: existing.directoryURL)
            codeHNSWSnapshot = nil
        }
        return try databaseSync {
            try execute("BEGIN IMMEDIATE", [])
            do {
                let existingRows = try queryRows(
                    """
                    SELECT id, file_path
                    FROM code_artifacts
                    WHERE project_id = ?
                    """,
                    [.text(projectID)]
                )
                var existingArtifactByPath: [String: String] = [:]
                for row in existingRows {
                    existingArtifactByPath[row.string(1)] = row.string(0)
                }

                try execute("DELETE FROM code_call_edges WHERE project_id = ?", [.text(projectID)])
                try execute("DELETE FROM code_references WHERE project_id = ?", [.text(projectID)])

                var seenArtifactIDs = Set<String>()
                // Age-aware budget eviction: index newest-first so a project larger than
                // its storage budget keeps the most-recently-modified (most relevant)
                // files and the over-budget rejections are the oldest — deterministic,
                // not whatever order the filesystem walk happened to yield.
                let rankedFiles = Self.enumerateIndexableFiles(root: root, maxFiles: maxFiles)
                    .map { url -> (url: URL, mtime: TimeInterval) in
                        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                        return (url, (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
                    }
                    .sorted { $0.mtime > $1.mtime }
                for ranked in rankedFiles {
                    let fileURL = ranked.url
                    guard let relativePath = Self.relativePath(fileURL, root: root) else { continue }
                    let artifactID = "code_" + String(Self.sha256Hex("\(projectID):\(relativePath)").prefix(32))
                    let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                    let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
                    guard fileSize <= maxFileBytes else {
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: nil,
                            contentHash: nil,
                            byteCount: fileSize,
                            mtime: mtime,
                            lang: Self.language(for: fileURL),
                            ignoredReason: "max_file_bytes",
                            secretLabels: [],
                            parserTier: nil,
                            now: now
                        )
                        continue
                    }
                    guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else {
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: nil,
                            contentHash: nil,
                            byteCount: fileSize,
                            mtime: mtime,
                            lang: Self.language(for: fileURL),
                            ignoredReason: "unreadable_or_non_utf8",
                            secretLabels: [],
                            parserTier: nil,
                            now: now
                        )
                        continue
                    }
                    let blobSHA = Self.gitBlobSHA(data)
                    let contentHash = Self.sha256Hex(data)
                    let lang = Self.language(for: fileURL)
                    let labels = Self.secretLabels(in: text)
                    if labels.isEmpty == false {
                        rejectedFiles.append(BurnBarProjectCodeRejectedFile(filePath: relativePath, labels: labels))
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: blobSHA,
                            contentHash: contentHash,
                            byteCount: data.count,
                            mtime: mtime,
                            lang: lang,
                            ignoredReason: "secret_rejected",
                            secretLabels: labels,
                            parserTier: nil,
                            now: now
                        )
                        _ = try auditEvent(action: "code.secret_rejected", domain: "code", projectID: projectID, subjectID: artifactID, labels: labels)
                        continue
                    }
                    let symbols = Self.extractSymbols(
                        text: text,
                        lang: lang,
                        relativePath: relativePath,
                        rootPath: root.path,
                        projectID: projectID,
                        artifactID: artifactID,
                        blobSHA: blobSHA
                    )
                    let chunks: [CodeChunk]
                    if let lang, ["swift", "typescript", "tsx", "python"].contains(lang) {
                        chunks = Self.astAwareChunks(text: text, symbols: symbols)
                    } else {
                        chunks = Self.chunk(text: text)
                    }
                    let preparedChunks = chunks.map {
                        PreparedCodeChunk(chunk: $0, embeddingVector: codeEmbeddingVector(for: $0.text))
                    }
                    let vectorBytes = preparedChunks.reduce(0) { partial, prepared in
                        partial + Self.codeEmbeddingVectorStorageByteCount(prepared.embeddingVector)
                    }
                    let candidateStorageByteCount = Self.estimatedCodeStorageByteCount(
                        sourceBytes: data.count,
                        chunks: chunks,
                        filePath: relativePath,
                        projectID: projectID,
                        provider: Self.codeProvider,
                        vectorBytes: vectorBytes
                    )
                    guard storageByteCount + candidateStorageByteCount <= storageBudgetBytes else {
                        rejectedFiles.append(
                            BurnBarProjectCodeRejectedFile(filePath: relativePath, labels: ["Storage budget cap reached"])
                        )
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: nil,
                            blobSHA: nil,
                            contentHash: nil,
                            byteCount: data.count,
                            mtime: mtime,
                            lang: lang,
                            ignoredReason: "storage_budget",
                            secretLabels: ["Storage budget cap reached"],
                            parserTier: nil,
                            now: now
                        )
                        _ = try auditEvent(
                            action: "code.storage_rejected",
                            domain: "code",
                            projectID: projectID,
                            subjectID: artifactID,
                            labels: ["storage budget cap reached"]
                        )
                        continue
                    }
                    let existingArtifact = try queryRows(
                        """
                        SELECT blob_sha, content_hash, byte_count
                        FROM code_artifacts
                        WHERE id = ?
                        LIMIT 1
                        """,
                        [.text(artifactID)]
                    ).first
                    if existingArtifact?.string(0) == blobSHA,
                       (existingArtifact?.optionalString(1) ?? contentHash) == contentHash {
                        artifactsForReferences.append(IndexedArtifact(id: artifactID, filePath: relativePath, blobSHA: blobSHA))
                        seenArtifactIDs.insert(artifactID)
                        indexedFiles += 1
                        storageByteCount += candidateStorageByteCount
                        chunkCount += try fetchInt("SELECT COUNT(*) FROM search_chunks WHERE sourceID = ?", [.text(artifactID)])
                        symbolCount += try fetchInt("SELECT COUNT(*) FROM code_symbols WHERE artifact_id = ?", [.text(artifactID)])
                        try upsertFileManifest(
                            projectID: projectID,
                            filePath: relativePath,
                            artifactID: artifactID,
                            blobSHA: blobSHA,
                            contentHash: contentHash,
                            byteCount: data.count,
                            mtime: mtime,
                            lang: lang,
                            ignoredReason: nil,
                            secretLabels: [],
                            parserTier: nil,
                            now: now
                        )
                        continue
                    }

                    try deleteCodeArtifact(artifactID: artifactID)
                    try execute(
                        """
                        INSERT INTO code_artifacts
                            (id, project_id, file_path, blob_sha, content_hash, commit_sha, lang, byte_count, mtime, indexed_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            .text(artifactID), .text(projectID), .text(relativePath), .text(blobSHA), .text(contentHash),
                            commitSHA.map(SQLiteBind.text) ?? .null, lang.map(SQLiteBind.text) ?? .null,
                            .int(data.count), .double(mtime), .text(now)
                        ]
                    )
                    try upsertFileManifest(
                        projectID: projectID,
                        filePath: relativePath,
                        artifactID: artifactID,
                        blobSHA: blobSHA,
                        contentHash: contentHash,
                        byteCount: data.count,
                        mtime: mtime,
                        lang: lang,
                        ignoredReason: nil,
                        secretLabels: [],
                        parserTier: nil,
                        now: now
                    )
                    artifactsForReferences.append(IndexedArtifact(id: artifactID, filePath: relativePath, blobSHA: blobSHA))
                    seenArtifactIDs.insert(artifactID)
                    indexedFiles += 1
                    storageByteCount += candidateStorageByteCount

                    let documentID = "doc_" + String(Self.sha256Hex("\(projectID):\(relativePath):\(blobSHA)").prefix(32))
                    try insertSearchDocument(
                        documentID: documentID,
                        artifactID: artifactID,
                        projectID: projectID,
                        filePath: relativePath,
                        title: relativePath,
                        preview: String(text.prefix(512)),
                        contentHash: blobSHA,
                        now: now
                    )
                    for (ordinal, prepared) in preparedChunks.enumerated() {
                        let chunk = prepared.chunk
                        let chunkID = "chunk_" + String(Self.sha256Hex("\(documentID):\(ordinal):\(chunk.contentHash)").prefix(32))
                        try insertSearchChunk(
                            chunkID: chunkID,
                            documentID: documentID,
                            artifactID: artifactID,
                            projectID: projectID,
                            filePath: relativePath,
                            ordinal: ordinal,
                            startOffset: chunk.startOffset,
                            endOffset: chunk.endOffset,
                            text: chunk.text,
                            contentHash: chunk.contentHash,
                            embeddingVector: prepared.embeddingVector,
                            now: now
                        )
                        chunkCount += 1
                    }
                    for symbol in symbols {
                        try insertSymbol(symbol, indexedAt: now)
                        symbolCount += 1
                    }
                    try produceCodeDiagnostics(
                        projectID: projectID,
                        filePath: relativePath,
                        lang: lang,
                        text: text,
                        blobSHA: blobSHA,
                        now: now
                    )
                }
                for artifactID in existingArtifactByPath.values where seenArtifactIDs.contains(artifactID) == false {
                    try deleteCodeArtifact(artifactID: artifactID)
                }
                try execute(
                    """
                    DELETE FROM pcm_file_manifest
                    WHERE project_id = ?
                      AND artifact_id IS NOT NULL
                      AND artifact_id NOT IN (SELECT id FROM code_artifacts WHERE project_id = ?)
                    """,
                    [.text(projectID), .text(projectID)]
                )
                try buildReferences(projectID: projectID, root: root, artifacts: artifactsForReferences, indexedAt: now)
                let previousVacuumedAt = try queryRows(
                    "SELECT vacuumed_at FROM code_index_checkpoints WHERE project_id = ? LIMIT 1",
                    [.text(projectID)]
                ).first?.optionalString(0)
                let compactionDecision = try sqliteCompactionDecision()
                try execute(
                    """
                    INSERT INTO code_index_checkpoints
                        (project_id, project_root, last_commit_sha, indexed_at, artifact_count, chunk_count, rejected_count, storage_byte_count, storage_budget_bytes, vacuumed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(project_id) DO UPDATE SET
                        project_root = excluded.project_root,
                        last_commit_sha = excluded.last_commit_sha,
                        indexed_at = excluded.indexed_at,
                        artifact_count = excluded.artifact_count,
                        chunk_count = excluded.chunk_count,
                        rejected_count = excluded.rejected_count,
                        storage_byte_count = excluded.storage_byte_count,
                        storage_budget_bytes = excluded.storage_budget_bytes,
                        vacuumed_at = excluded.vacuumed_at
                    """,
                    [
                        .text(projectID), .text(root.path), commitSHA.map(SQLiteBind.text) ?? .null,
                        .text(now), .int(indexedFiles), .int(chunkCount), .int(rejectedFiles.count),
                        .int(storageByteCount), .int(storageBudgetBytes), previousVacuumedAt.map(SQLiteBind.text) ?? .null
                    ]
                )
                let auditHash = try auditEvent(
                    action: "code.index",
                    domain: "code",
                    projectID: projectID,
                    subjectID: root.path,
                    labels: ["indexed:\(indexedFiles)", "rejected:\(rejectedFiles.count)"]
                )
                try execute("COMMIT", [])
                if compactionDecision.shouldCompact {
                    do {
                        try runIncrementalVacuum(maxPages: compactionDecision.freelistCount)
                        try execute(
                            "UPDATE code_index_checkpoints SET vacuumed_at = ? WHERE project_id = ?",
                            [.text(now), .text(projectID)]
                        )
                    } catch {
                        logger.warning(
                            "project_code_memory_compaction_failed",
                            metadata: [
                                "project_id": projectID,
                                "freelist_pages": String(compactionDecision.freelistCount),
                                "page_count": String(compactionDecision.pageCount),
                                "reclaimable_bytes": String(compactionDecision.reclaimableBytes),
                                "error": error.localizedDescription
                            ]
                        )
                    }
                }
                return BurnBarProjectCodeIndexProjectResponse(
                    traceID: traceID,
                    projectID: projectID,
                    projectRoot: root.path,
                    indexedFiles: indexedFiles,
                    chunkCount: chunkCount,
                    symbolCount: symbolCount,
                    rejectedFiles: rejectedFiles,
                    commitSHA: commitSHA,
                    auditHash: auditHash
                )
            } catch {
                try? execute("ROLLBACK", [])
                throw error
            }
        }
    }
}
