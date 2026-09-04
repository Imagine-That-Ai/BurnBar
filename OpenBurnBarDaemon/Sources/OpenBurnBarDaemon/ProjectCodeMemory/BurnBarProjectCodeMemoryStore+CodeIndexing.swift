import Foundation
import OpenBurnBarEngine

// Full project (re)index: file walk, secret / budget rejection, artifact +
// chunk + symbol + embedding persistence, manifest upkeep, diagnostics cache,
// checkpoint and post-commit compaction.
extension BurnBarProjectCodeMemoryStore {
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

    private func insertSearchDocument(
        documentID: String,
        artifactID: String,
        projectID: String,
        filePath: String,
        title: String,
        preview: String,
        contentHash: String,
        now: String
    ) throws {
        try execute(
            """
            INSERT INTO search_documents
                (id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, bodyPreview, indexedAt, contentHash, createdAt, updatedAt)
            VALUES (?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(documentID), .text(Self.codeSourceKind), .text(artifactID), .text(Self.codeProvider),
                .text(projectID), .text(title), .text(preview), .text(now), .text(contentHash), .text(now), .text(now)
            ]
        )
        _ = filePath
    }

    private func insertSearchChunk(
        chunkID: String,
        documentID: String,
        artifactID: String,
        projectID: String,
        filePath: String,
        ordinal: Int,
        startOffset: Int,
        endOffset: Int,
        text: String,
        contentHash: String,
        embeddingVector: [Float]?,
        now: String
    ) throws {
        // FTS row first so its rowid can be recorded on the chunk row: the FTS5
        // key columns (`chunkID`/`documentID`) are UNINDEXED, so any later
        // `DELETE ... WHERE documentID = ?` would full-scan the entire FTS
        // content table (GBs of chunk text on a mature index). Recording the
        // rowid keeps deletes O(log n). Mirrors the app-side
        // `v55_search_chunks_fts_rowid` contract on the shared schema.
        try execute(
            "INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(chunkID), .text(documentID), .text(filePath), .text(text), .text(projectID), .text(Self.codeProvider)]
        )
        if try searchChunksHasFtsRowidColumn() {
            let ftsRowid = try queryRows("SELECT last_insert_rowid()", []).first?.int64(0)
            try execute(
                """
                INSERT INTO search_chunks
                    (id, documentID, sourceKind, sourceID, sourceVersionID, ordinal, startOffset, endOffset, sectionPath, text, contentHash, ftsRowid, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(chunkID), .text(documentID), .text(Self.codeSourceKind), .text(artifactID),
                    .int(ordinal), .int(startOffset), .int(endOffset), .text(filePath),
                    .text(text), .text(contentHash), ftsRowid.map { SQLiteBind.int64($0) } ?? .null,
                    .text(now), .text(now)
                ]
            )
        } else {
            // Pre-v55 database (the app's migrator hasn't added `ftsRowid`
            // yet). Insert without the mapping; deletes fall back to the
            // legacy scan path for these rows.
            try execute(
                """
                INSERT INTO search_chunks
                    (id, documentID, sourceKind, sourceID, sourceVersionID, ordinal, startOffset, endOffset, sectionPath, text, contentHash, createdAt, updatedAt)
                VALUES (?, ?, ?, ?, '', ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(chunkID), .text(documentID), .text(Self.codeSourceKind), .text(artifactID),
                    .int(ordinal), .int(startOffset), .int(endOffset), .text(filePath),
                    .text(text), .text(contentHash), .text(now), .text(now)
                ]
            )
        }
        // Daemon-owned semantic vector for this chunk, tagged with the embedding version
        // so search never mixes generations. Stored base64 (TEXT) to ride the existing
        // string-based row machinery. Missing/declined embeddings degrade to lexical-only.
        if let vector = embeddingVector {
            try execute(
                """
                INSERT OR REPLACE INTO code_chunk_embeddings
                    (chunk_id, project_id, embedding_version, dimension, vector)
                VALUES (?, ?, ?, ?, ?)
                """,
                [
                    .text(chunkID), .text(projectID), .text(embeddingProvider.versionID),
                    .int(vector.count), .text(BurnBarCodeVectorCodec.encode(vector).base64EncodedString())
                ]
            )
        }
    }

    private func searchChunksHasFtsRowidColumn() throws -> Bool {
        if let cached = cachedSearchChunksHasFtsRowid { return cached }
        let has = try queryRows("PRAGMA table_info(search_chunks)", [])
            .contains { $0.string(1) == "ftsRowid" }
        cachedSearchChunksHasFtsRowid = has
        return has
    }

    private struct PreparedCodeChunk {
        let chunk: CodeChunk
        let embeddingVector: [Float]?
    }

    private func codeEmbeddingVector(for text: String) -> [Float]? {
        guard embeddingProvider.isAvailable else { return nil }
        return embeddingProvider.embed(text)
    }

    private static func codeEmbeddingVectorStorageByteCount(_ vector: [Float]?) -> Int {
        guard let vector else { return 0 }
        return BurnBarCodeVectorCodec.base64EncodedByteCount(vectorDimension: vector.count)
    }

    private func deleteCodeArtifact(artifactID: String) throws {
        var docIDs = Set(try queryRows(
            "SELECT id FROM search_documents WHERE sourceKind = ? AND sourceID = ?",
            [.text(Self.codeSourceKind), .text(artifactID)]
        ).map { $0.string(0) })
        for row in try queryRows(
            "SELECT DISTINCT documentID FROM search_chunks WHERE sourceKind = ? AND sourceID = ?",
            [.text(Self.codeSourceKind), .text(artifactID)]
        ) {
            docIDs.insert(row.string(0))
        }
        for docID in docIDs {
            let chunkIDs = try queryRows("SELECT id FROM search_chunks WHERE documentID = ?", [.text(docID)])
                .map { $0.string(0) }
            for chunkID in chunkIDs {
                try execute("DELETE FROM chunk_embeddings WHERE chunkID = ?", [.text(chunkID)])
                try execute("DELETE FROM code_chunk_embeddings WHERE chunk_id = ?", [.text(chunkID)])
            }
            // Rowid-targeted FTS delete via the `ftsRowid` mapping — matching
            // on the UNINDEXED `documentID` column scans the entire FTS
            // content table per document. Rows written before the mapping
            // existed carry NULL and take the scan path once, individually.
            if try searchChunksHasFtsRowidColumn() {
                try execute(
                    """
                    DELETE FROM search_chunks_fts WHERE rowid IN (
                        SELECT ftsRowid FROM search_chunks
                        WHERE documentID = ? AND ftsRowid IS NOT NULL
                    )
                    """,
                    [.text(docID)]
                )
                let legacyChunkIDs = try queryRows(
                    "SELECT id FROM search_chunks WHERE documentID = ? AND ftsRowid IS NULL",
                    [.text(docID)]
                ).map { $0.string(0) }
                for chunkID in legacyChunkIDs {
                    try execute("DELETE FROM search_chunks_fts WHERE chunkID = ?", [.text(chunkID)])
                }
            } else {
                try execute("DELETE FROM search_chunks_fts WHERE documentID = ?", [.text(docID)])
            }
            try execute("DELETE FROM search_chunks WHERE documentID = ?", [.text(docID)])
            try execute("DELETE FROM search_documents WHERE id = ?", [.text(docID)])
        }
        try execute(
            """
            DELETE FROM code_call_edges
            WHERE caller_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
               OR callee_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
            """,
            [.text(artifactID), .text(artifactID)]
        )
        try execute(
            """
            DELETE FROM code_references
            WHERE from_artifact_id = ?
               OR to_symbol_id IN (SELECT id FROM code_symbols WHERE artifact_id = ?)
            """,
            [.text(artifactID), .text(artifactID)]
        )
        try execute("DELETE FROM code_symbols WHERE artifact_id = ?", [.text(artifactID)])
        try execute(
            "DELETE FROM code_diagnostics_cache WHERE blob_sha IN (SELECT blob_sha FROM code_artifacts WHERE id = ?)",
            [.text(artifactID)]
        )
        try execute("DELETE FROM code_artifacts WHERE id = ?", [.text(artifactID)])
    }

    private func produceCodeDiagnostics(
        projectID: String,
        filePath: String,
        lang: String?,
        text: String,
        blobSHA: String,
        now: String
    ) throws {
        guard lang == "python" else { return }
        let script = """
        import json
        import sys
        source = sys.stdin.read()
        diagnostics = []
        try:
            compile(source, sys.argv[1], "exec")
        except SyntaxError as error:
            diagnostics.append({
                "severity": "error",
                "message": error.msg,
                "line": error.lineno,
                "column": error.offset,
                "endLine": error.end_lineno,
                "endColumn": error.end_offset,
            })
        print(json.dumps({
            "schema": "openburnbar.project_code_diagnostics.v1",
            "producer": "python.compile",
            "diagnostics": diagnostics,
        }, sort_keys=True, separators=(",", ":")))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", script, filePath]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        let payload = Data(text.utf8)
        guard Self.runHelperProcess(process, input: input, payload: payload),
              process.terminationStatus == 0,
              let outputData = Optional(output.fileHandleForReading.readDataToEndOfFile()),
              outputData.count <= Self.codeHelperMaxOutputBytes(),
              let firstLine = String(data: outputData, encoding: .utf8)?
                .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
                .first
        else {
            return
        }
        let diagnosticID = "diag_" + String(Self.sha256Hex("\(projectID):\(filePath):python.compile").prefix(32))
        try execute(
            """
            INSERT INTO code_diagnostics_cache
                (id, project_id, file_path, tool, payload_json, blob_sha, cached_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                payload_json = excluded.payload_json,
                blob_sha = excluded.blob_sha,
                cached_at = excluded.cached_at
            """,
            [
                .text(diagnosticID),
                .text(projectID),
                .text(filePath),
                .text("python.compile"),
                .text(String(firstLine)),
                .text(blobSHA),
                .text(now)
            ]
        )
    }

    private func upsertFileManifest(
        projectID: String,
        filePath: String,
        artifactID: String?,
        blobSHA: String?,
        contentHash: String?,
        byteCount: Int,
        mtime: Double,
        lang: String?,
        ignoredReason: String?,
        secretLabels: [String],
        parserTier: String?,
        now: String
    ) throws {
        let id = "manifest_" + String(Self.sha256Hex("\(projectID):\(filePath)").prefix(32))
        let labelsJSON = try encodeJSONString(secretLabels.sorted())
        try execute(
            """
            INSERT INTO pcm_file_manifest
                (id, project_id, file_path, artifact_id, blob_sha, content_hash, byte_count, mtime,
                 lang, ignored_reason, secret_labels_json, parser_tier, indexed_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(project_id, file_path) DO UPDATE SET
                artifact_id = excluded.artifact_id,
                blob_sha = excluded.blob_sha,
                content_hash = excluded.content_hash,
                byte_count = excluded.byte_count,
                mtime = excluded.mtime,
                lang = excluded.lang,
                ignored_reason = excluded.ignored_reason,
                secret_labels_json = excluded.secret_labels_json,
                parser_tier = excluded.parser_tier,
                indexed_at = excluded.indexed_at,
                last_seen_at = excluded.last_seen_at
            """,
            [
                .text(id), .text(projectID), .text(filePath),
                artifactID.map(SQLiteBind.text) ?? .null,
                blobSHA.map(SQLiteBind.text) ?? .null,
                contentHash.map(SQLiteBind.text) ?? .null,
                .int(byteCount), .double(mtime),
                lang.map(SQLiteBind.text) ?? .null,
                ignoredReason.map(SQLiteBind.text) ?? .null,
                .text(labelsJSON),
                parserTier.map(SQLiteBind.text) ?? .null,
                .text(now), .text(now)
            ]
        )
    }
}
