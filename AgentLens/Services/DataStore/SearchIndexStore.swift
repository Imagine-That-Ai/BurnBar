import Foundation
@preconcurrency import GRDB
import OpenBurnBarCore

// MARK: - SearchIndexStore

struct SearchChunkEmbeddingInput: Identifiable, Equatable, Sendable {
    let id: String
    let text: String
}

/// Search documents, chunks, FTS-based lexical search, and document-level deletion.
final class SearchIndexStore: Sendable {
    private struct ChunkDiffMetadata {
        let id: String
        let contentHash: String?
    }

    private enum WriteTuning {
        static let chunkMutationBatchSize = 64
        static let interChunkMutationPauseNanoseconds: UInt64 = 10_000_000
    }

    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Documents

    func upsertDocument(_ document: SearchDocumentRecord) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, subtitle,
                    bodyPreview, sourceUpdatedAt, indexedAt, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    sourceKind = excluded.sourceKind,
                    sourceID = excluded.sourceID,
                    sourceVersionID = excluded.sourceVersionID,
                    provider = excluded.provider,
                    projectName = excluded.projectName,
                    title = excluded.title,
                    subtitle = excluded.subtitle,
                    bodyPreview = excluded.bodyPreview,
                    sourceUpdatedAt = excluded.sourceUpdatedAt,
                    indexedAt = excluded.indexedAt,
                    contentHash = excluded.contentHash,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    document.id,
                    document.sourceKind.rawValue,
                    document.sourceID,
                    document.sourceVersionID,
                    document.provider,
                    document.projectName,
                    document.title,
                    document.subtitle,
                    document.bodyPreview,
                    document.sourceUpdatedAt,
                    document.indexedAt,
                    document.contentHash,
                    document.createdAt,
                    document.updatedAt
                ]
            )
        }
    }

    func fetchDocuments(limit: Int) async throws -> [SearchDocumentRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                ORDER BY indexedAt DESC, createdAt DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    /// Paginated document fetch using offset-based cursor.
    func fetchDocuments(limit: Int, offset: Int) async throws -> [SearchDocumentRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                ORDER BY indexedAt DESC, createdAt DESC, id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func fetchDocuments(
        limit: Int,
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) async throws -> [SearchDocumentRecord] {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
        var queryArgs = args
        queryArgs.append(max(1, limit))

        let capturedArgs = queryArgs

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                \(whereSQL)
                ORDER BY COALESCE(sourceUpdatedAt, indexedAt) DESC, indexedAt DESC, createdAt DESC
                LIMIT ?
                """,
                arguments: StatementArguments(capturedArgs)
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    /// Paginated document fetch with filtering using offset-based cursor.
    /// Order is deterministic: COALESCE(sourceUpdatedAt, indexedAt) DESC, indexedAt DESC, createdAt DESC.
    func fetchDocuments(
        limit: Int,
        offset: Int,
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) async throws -> [SearchDocumentRecord] {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
        var queryArgs = args
        queryArgs.append(max(1, limit))
        queryArgs.append(max(0, offset))

        let capturedArgs = queryArgs

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                \(whereSQL)
                ORDER BY COALESCE(sourceUpdatedAt, indexedAt) DESC, indexedAt DESC, createdAt DESC, id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: StatementArguments(capturedArgs)
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func fetchDocuments(ids: [String]) async throws -> [SearchDocumentRecord] {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard uniqueIDs.isEmpty == false else { return [] }

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                WHERE id IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: uniqueIDs.count)))
                ORDER BY indexedAt DESC, createdAt DESC
                """,
                arguments: StatementArguments(uniqueIDs)
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func fetchDocument(id: String) async throws -> SearchDocumentRecord? {
        try await fetchDocuments(ids: [id]).first
    }

    func fetchDocuments(sourceKind: SearchSourceKind, sourceID: String) async throws -> [SearchDocumentRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                WHERE sourceKind = ? AND sourceID = ?
                ORDER BY indexedAt DESC, createdAt DESC
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func countDocuments(
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) async throws -> Int {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
        let capturedArgs = args

        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_documents
                \(whereSQL)
                """,
                arguments: StatementArguments(capturedArgs)
            ) ?? 0
        }
    }

    func deleteDocuments(sourceKind: SearchSourceKind, sourceID: String) async throws {
        try await dbQueue.write { db in
            let documentIDs = try String.fetchAll(
                db,
                sql: """
                SELECT id
                FROM search_documents
                WHERE sourceKind = ? AND sourceID = ?
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )

            for documentID in documentIDs {
                // Rowid-targeted delete via the ftsRowid mapping (documentID is
                // an UNINDEXED FTS5 column; matching on it scans the whole FTS
                // table). Legacy chunks with NULL ftsRowid predate v55 and take
                // the scan path once, individually.
                try db.execute(
                    sql: """
                    DELETE FROM search_chunks_fts WHERE rowid IN (
                        SELECT ftsRowid FROM search_chunks
                        WHERE documentID = ? AND ftsRowid IS NOT NULL
                    )
                    """,
                    arguments: [documentID]
                )
                let legacyChunkIDs = try String.fetchAll(
                    db,
                    sql: "SELECT id FROM search_chunks WHERE documentID = ? AND ftsRowid IS NULL",
                    arguments: [documentID]
                )
                for chunkID in legacyChunkIDs {
                    try db.execute(
                        sql: "DELETE FROM search_chunks_fts WHERE chunkID = ?",
                        arguments: [chunkID]
                    )
                }
            }

            try db.execute(
                sql: """
                DELETE FROM search_documents
                WHERE sourceKind = ? AND sourceID = ?
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )
        }
    }

    // MARK: - Chunks

    func countChunks(
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) async throws -> Int {
        let normalizedSourceKinds = Array(Set(sourceKinds ?? [])).sorted { $0.rawValue < $1.rawValue }
        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if normalizedSourceKinds.isEmpty == false {
            clauses.append("d.sourceKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: normalizedSourceKinds.count)))")
            args.append(contentsOf: normalizedSourceKinds.map(\.rawValue))
        }

        if let dateRange {
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) >= ?")
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) <= ?")
            args.append(dateRange.lowerBound)
            args.append(dateRange.upperBound)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let capturedArgs = args
        return try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_chunks AS c
                JOIN search_documents AS d ON d.id = c.documentID
                \(whereSQL)
                """,
                arguments: StatementArguments(capturedArgs)
            ) ?? 0
        }
    }

    func countChunks(documentID: String) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_chunks
                WHERE documentID = ?
                """,
                arguments: [documentID]
            ) ?? 0
        }
    }

    /// Incrementally applies a chunk diff for a document.
    /// Compares new chunks against existing chunks by contentHash to determine:
    /// - **Unchanged** (same contentHash, same ID): skipped entirely — no writes.
    /// - **Rekeyed** (same contentHash, different ID): old row deleted, new row inserted.
    ///   Embeddings can be copied by contentHash in the caller.
    /// - **Added** (new contentHash): inserted as new chunk.
    /// - **Deleted** (existing contentHash not in new set): removed.
    ///
    /// Returns a `ChunkDiffResult` with counts for each operation category,
    /// enabling callers to verify write-amplification behavior.
    ///
    /// Falls back to replace-all when content hashes are unavailable
    /// (e.g., first projection with empty existing set).
    func applyChunkDiff(
        documentID: String,
        title: String,
        newChunks: [SearchChunkRecord]
    ) async throws -> ChunkDiffResult {
        // Diffing needs only stable identity and content hash. Reading full rows
        // here decrypts chunk text and parses timestamps for data that the diff
        // never uses.
        let existingChunks = try await fetchChunkDiffMetadata(documentID: documentID)

        // If no existing chunks, just insert all (first projection)
        if existingChunks.isEmpty {
            guard newChunks.isEmpty == false else {
                return ChunkDiffResult(unchanged: 0, rekeyed: 0, added: newChunks.count, deleted: 0, existingTotal: 0, newTotal: newChunks.count)
            }
            try await replaceChunks(documentID: documentID, title: title, chunks: newChunks)
            return ChunkDiffResult(unchanged: 0, rekeyed: 0, added: newChunks.count, deleted: 0, existingTotal: 0, newTotal: newChunks.count)
        }

        // Build contentHash -> chunk mappings
        let existingByHash = Dictionary(grouping: existingChunks, by: { $0.contentHash ?? "" })
        let newByHash = Dictionary(grouping: newChunks, by: { $0.contentHash ?? "" })

        let existingHashes = Set(existingByHash.keys)
        let newHashes = Set(newByHash.keys)

        let unchangedHashes = existingHashes.intersection(newHashes)
        let addedHashes = newHashes.subtracting(existingHashes)
        let deletedHashes = existingHashes.subtracting(newHashes)

        // Count rekeyed chunks (same hash but different chunk ID)
        var rekeyedCount = 0
        for hash in unchangedHashes {
            let oldIDs = Set(existingByHash[hash, default: []].map(\.id))
            let newIDs = Set(newByHash[hash, default: []].map(\.id))
            if oldIDs != newIDs {
                rekeyedCount += max(oldIDs.count, newIDs.count)
            }
        }

        // Count truly unchanged chunks.
        // A chunk is truly unchanged only when contentHash AND chunkID match.
        // A chunk is rekeyed when contentHash matches but chunkID differs.
        var unchangedCount = 0
        for hash in unchangedHashes {
            let oldIDs = Set(existingByHash[hash, default: []].map(\.id))
            let newIDs = Set(newByHash[hash, default: []].map(\.id))
            if oldIDs == newIDs {
                // Identical chunkIDs: truly unchanged — no writes needed
                unchangedCount += oldIDs.count
            }
            // Note: When oldIDs != newIDs (rekeyed), we don't add to unchangedCount.
            // These chunks will be reconciled via delete+insert in the diff block.
        }

        // With our fix, rekeyed chunks don't cause writes. So the only writes
        // are for truly added or deleted contentHashes.
        let deletedWriteCount = deletedHashes.reduce(0) { count, hash in
            count + (existingByHash[hash]?.count ?? 0)
        }
        let addedWriteCount = addedHashes.reduce(0) { count, hash in
            count + (newByHash[hash]?.count ?? 0)
        }
        let effectiveWriteCount = deletedWriteCount + addedWriteCount

        // If no new content hashes added, no content hashes removed, no effective writes,
        // AND no rekeyed chunks (IDs differ), this is a true no-op — skip all writes entirely.
        // Note: Hash-set equality alone does not trigger no-op when per-hash chunk
        // multiplicity or chunk IDs require reconciliation (rekeyedCount > 0).
        if deletedHashes.isEmpty && addedHashes.isEmpty && effectiveWriteCount == 0 && rekeyedCount == 0 {
            return ChunkDiffResult(
                unchanged: unchangedCount,
                rekeyed: 0,
                added: 0,
                deleted: 0,
                existingTotal: existingChunks.count,
                newTotal: newChunks.count
            )
        }

        var oldIDsToDelete: [String] = deletedHashes.flatMap { existingByHash[$0, default: []].map(\.id) }
        var chunksToInsert: [SearchChunkRecord] = []

        for hash in addedHashes {
            chunksToInsert.append(contentsOf: newByHash[hash, default: []])
        }

        for hash in unchangedHashes {
            let oldIDs = Set(existingByHash[hash, default: []].map(\.id))
            let newIDs = Set(newByHash[hash, default: []].map(\.id))
            guard oldIDs != newIDs else { continue }
            oldIDsToDelete.append(contentsOf: oldIDs.subtracting(newIDs))
            let idsOnlyInNew = newIDs.subtracting(oldIDs)
            chunksToInsert.append(contentsOf: newByHash[hash, default: []].filter { idsOnlyInNew.contains($0.id) })
        }

        let (projectName, provider) = try await fetchDocumentIndexContext(documentID: documentID)
        let (actualAdded, actualDeleted) = try await applyChunkMutationsInBatches(
            documentID: documentID,
            title: title,
            projectName: projectName,
            provider: provider,
            chunkIDsToDelete: oldIDsToDelete.sorted(),
            chunksToInsert: chunksToInsert.sorted { lhs, rhs in
                lhs.ordinal == rhs.ordinal ? lhs.id < rhs.id : lhs.ordinal < rhs.ordinal
            }
        )

        return ChunkDiffResult(
            unchanged: unchangedCount,
            rekeyed: rekeyedCount,
            added: actualAdded,
            deleted: actualDeleted,
            existingTotal: existingChunks.count,
            newTotal: newChunks.count
        )
    }

    private func fetchChunkDiffMetadata(documentID: String) async throws -> [ChunkDiffMetadata] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, contentHash
                FROM search_chunks
                WHERE documentID = ?
                ORDER BY ordinal ASC
                """,
                arguments: [documentID]
            )
            return rows.compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return ChunkDiffMetadata(
                    id: id,
                    contentHash: row["contentHash"] as? String
                )
            }
        }
    }

    func replaceChunks(documentID: String, title: String, chunks: [SearchChunkRecord]) async throws {
        let existingChunkIDs = try await dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM search_chunks WHERE documentID = ? ORDER BY ordinal ASC, id ASC",
                arguments: [documentID]
            )
        }
        let (projectName, provider) = try await fetchDocumentIndexContext(documentID: documentID)
        _ = try await applyChunkMutationsInBatches(
            documentID: documentID,
            title: title,
            projectName: projectName,
            provider: provider,
            chunkIDsToDelete: existingChunkIDs,
            chunksToInsert: chunks.sorted { lhs, rhs in
                lhs.ordinal == rhs.ordinal ? lhs.id < rhs.id : lhs.ordinal < rhs.ordinal
            }
        )
    }

    private func fetchDocumentIndexContext(documentID: String) async throws -> (projectName: String, provider: String) {
        try await dbQueue.read { db in
            let documentRow = try Row.fetchOne(
                db,
                sql: "SELECT projectName, provider FROM search_documents WHERE id = ?",
                arguments: [documentID]
            )
            let projectName = documentRow?["projectName"] as? String ?? ""
            let provider = documentRow?["provider"] as? String ?? ""
            return (projectName, provider)
        }
    }

    private func applyChunkMutationsInBatches(
        documentID: String,
        title: String,
        projectName: String,
        provider: String,
        chunkIDsToDelete: [String],
        chunksToInsert: [SearchChunkRecord]
    ) async throws -> (added: Int, deleted: Int) {
        let batchSize = max(1, WriteTuning.chunkMutationBatchSize)
        var deleted = 0
        var added = 0

        for start in stride(from: 0, to: chunkIDsToDelete.count, by: batchSize) {
            let end = min(chunkIDsToDelete.count, start + batchSize)
            let batch = Array(chunkIDsToDelete[start..<end])
            try await dbQueue.write { db in
                for chunkID in batch {
                    try Self.deleteChunkFTSRow(chunkID: chunkID, db: db)
                    try db.execute(sql: "DELETE FROM search_chunks WHERE id = ?", arguments: [chunkID])
                }
            }
            deleted += batch.count
            if end < chunkIDsToDelete.count || chunksToInsert.isEmpty == false {
                try await Task.sleep(nanoseconds: WriteTuning.interChunkMutationPauseNanoseconds)
            }
        }

        for start in stride(from: 0, to: chunksToInsert.count, by: batchSize) {
            let end = min(chunksToInsert.count, start + batchSize)
            let batch = Array(chunksToInsert[start..<end])
            try await dbQueue.write { db in
                for chunk in batch {
                    try Self.insertChunk(chunk, documentID: documentID, title: title, projectName: projectName, provider: provider, db: db)
                }
            }
            added += batch.count
            if end < chunksToInsert.count {
                try await Task.sleep(nanoseconds: WriteTuning.interChunkMutationPauseNanoseconds)
            }
        }

        return (added, deleted)
    }

    /// Fetches existing embeddings keyed by contentHash for a document.
    /// Returns a mapping of contentHash -> (chunkID, vectorBlob) for chunks
    /// that have embeddings for the given version. Used for embedding reuse:
    /// when a new chunk has the same contentHash, the existing embedding
    /// can be copied to the new chunk ID instead of regenerating it.
    func fetchEmbeddingByContentHash(documentID: String, embeddingVersionID: String) async throws -> [String: (chunkID: String, vectorBlob: Data)] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT c.contentHash, e.chunkID, e.vectorBlob
                FROM search_chunks AS c
                JOIN chunk_embeddings AS e ON e.chunkID = c.id AND e.embeddingVersionID = ?
                WHERE c.documentID = ? AND c.contentHash IS NOT NULL AND c.contentHash != ''
                """,
                arguments: [embeddingVersionID, documentID]
            )
            var result: [String: (chunkID: String, vectorBlob: Data)] = [:]
            for row in rows {
                guard let hash = row["contentHash"] as? String,
                      let chunkID = row["chunkID"] as? String,
                      let blob = row["vectorBlob"] as? Data else { continue }
                result[hash] = (chunkID: chunkID, vectorBlob: blob)
            }
            return result
        }
    }

    /// Deletes a chunk's FTS row by its recorded rowid (O(log n)). `chunkID` /
    /// `documentID` are UNINDEXED FTS5 columns, so a plain
    /// `DELETE ... WHERE chunkID = ?` full-scans the entire FTS content table —
    /// on a mature index that is a multi-GB read per chunk. Rows written by a
    /// pre-`v55_search_chunks_fts_rowid` binary can carry a NULL `ftsRowid`;
    /// only those take the legacy scan path.
    static func deleteChunkFTSRow(chunkID: String, db: Database) throws {
        let ftsRowid = try Int64.fetchOne(
            db,
            sql: "SELECT ftsRowid FROM search_chunks WHERE id = ? AND ftsRowid IS NOT NULL",
            arguments: [chunkID]
        )
        if let ftsRowid {
            try db.execute(sql: "DELETE FROM search_chunks_fts WHERE rowid = ?", arguments: [ftsRowid])
        } else {
            try db.execute(sql: "DELETE FROM search_chunks_fts WHERE chunkID = ?", arguments: [chunkID])
        }
    }

    private static func insertChunk(
        _ chunk: SearchChunkRecord,
        documentID: String,
        title: String,
        projectName: String,
        provider: String,
        db: Database
    ) throws {
        // FTS row first so its rowid can be recorded on the chunk row —
        // deletes then target the FTS rowid instead of scanning the table.
        try db.execute(
            sql: """
            INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [chunk.id, chunk.documentID, title, chunk.text, projectName, provider]
        )
        let ftsRowid = db.lastInsertedRowID

        try db.execute(
            sql: """
            INSERT INTO search_chunks (
                id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                startOffset, endOffset, messageStartOffset, messageEndOffset,
                sectionPath, text, contentHash, ftsRowid, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                chunk.id,
                chunk.documentID,
                chunk.sourceKind.rawValue,
                chunk.sourceID,
                chunk.sourceVersionID,
                chunk.ordinal,
                chunk.startOffset,
                chunk.endOffset,
                chunk.messageStartOffset,
                chunk.messageEndOffset,
                chunk.sectionPath,
                chunk.text,
                chunk.contentHash,
                ftsRowid,
                chunk.createdAt,
                chunk.updatedAt
            ]
        )
    }

    func fetchChunks(documentID: String) async throws -> [SearchChunkRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_chunks
                WHERE documentID = ?
                ORDER BY ordinal ASC
                """,
                arguments: [documentID]
            )
            return rows.compactMap(Self.chunk(from:))
        }
    }

    /// Reads the minimum row shape required by semantic re-embedding.
    ///
    /// Keyset pagination keeps each SQLCipher read bounded and stable while the
    /// caller embeds and releases one page at a time. Code chunks stay local-only.
    func fetchChunkEmbeddingInputs(
        afterID: String?,
        limit: Int,
        embeddingVersionID: String,
        sourceKind: SearchSourceKind?,
        sourceID: String?
    ) async throws -> [SearchChunkEmbeddingInput] {
        if sourceKind == .code {
            return []
        }

        var clauses = [
            """
            NOT EXISTS (
                SELECT 1
                FROM chunk_embeddings AS existing_embedding
                WHERE existing_embedding.chunkID = search_chunks.id
                  AND existing_embedding.embeddingVersionID = ?
            )
            """
        ]
        var arguments: [any DatabaseValueConvertible] = [embeddingVersionID]

        if let sourceKind, let sourceID {
            clauses.append("sourceKind = ?")
            arguments.append(sourceKind.rawValue)
            clauses.append("sourceID = ?")
            arguments.append(sourceID)
        } else {
            clauses.append("sourceKind <> ?")
            arguments.append(SearchSourceKind.code.rawValue)
        }

        if let afterID {
            clauses.append("id > ?")
            arguments.append(afterID)
        }

        arguments.append(max(1, limit))
        let whereSQL = clauses.joined(separator: " AND ")
        let capturedArguments = arguments

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, text
                FROM search_chunks
                WHERE \(whereSQL)
                ORDER BY id ASC
                LIMIT ?
                """,
                arguments: StatementArguments(capturedArguments)
            )
            return rows.compactMap { row in
                guard
                    let id = row["id"] as? String,
                    let text = row["text"] as? String
                else {
                    return nil
                }
                return SearchChunkEmbeddingInput(id: id, text: text)
            }
        }
    }

    func fetchChunks(ids: [String]) async throws -> [SearchChunkRecord] {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard uniqueIDs.isEmpty == false else { return [] }

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_chunks
                WHERE id IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: uniqueIDs.count)))
                ORDER BY documentID ASC, ordinal ASC
                """,
                arguments: StatementArguments(uniqueIDs)
            )
            return rows.compactMap(Self.chunk(from:))
        }
    }

    /// Round-4 perf sweep: combined chunk + document fetch via a single JOIN.
    /// Eliminates one DB round-trip in the SearchService hydration path: the
    /// old flow fetched missing chunks, then fetched their parent documents in
    /// a second query. This JOIN returns both in one pass. The caller still
    /// merges results with the lexical-provided maps; documents that were
    /// already in `lexicalDocumentMap` are simply overwritten (same content).
    func fetchChunksWithDocuments(ids: [String]) async throws -> [(chunk: SearchChunkRecord, document: SearchDocumentRecord)] {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard uniqueIDs.isEmpty == false else { return [] }

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    c.id AS chunkID,
                    c.documentID AS chunkDocumentID,
                    c.sourceKind AS chunkSourceKind,
                    c.sourceID AS chunkSourceID,
                    c.sourceVersionID AS chunkSourceVersionID,
                    c.ordinal AS chunkOrdinal,
                    c.startOffset AS chunkStartOffset,
                    c.endOffset AS chunkEndOffset,
                    c.messageStartOffset AS chunkMessageStartOffset,
                    c.messageEndOffset AS chunkMessageEndOffset,
                    c.sectionPath AS chunkSectionPath,
                    c.text AS chunkText,
                    c.contentHash AS chunkContentHash,
                    c.createdAt AS chunkCreatedAt,
                    c.updatedAt AS chunkUpdatedAt,
                    d.id AS docID,
                    d.sourceKind AS docSourceKind,
                    d.sourceID AS docSourceID,
                    d.sourceVersionID AS docSourceVersionID,
                    d.provider AS docProvider,
                    d.projectName AS docProjectName,
                    d.title AS docTitle,
                    d.subtitle AS docSubtitle,
                    d.bodyPreview AS docBodyPreview,
                    d.sourceUpdatedAt AS docSourceUpdatedAt,
                    d.indexedAt AS docIndexedAt,
                    d.contentHash AS docContentHash,
                    d.createdAt AS docCreatedAt,
                    d.updatedAt AS docUpdatedAt
                FROM search_chunks AS c
                JOIN search_documents AS d ON d.id = c.documentID
                WHERE c.id IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: uniqueIDs.count)))
                ORDER BY c.documentID ASC, c.ordinal ASC
                """,
                arguments: StatementArguments(uniqueIDs)
            )
            return rows.compactMap(Self.chunkWithDocument(from:))
        }
    }

    static func chunkWithDocument(from row: Row) -> (chunk: SearchChunkRecord, document: SearchDocumentRecord)? {
        guard
            let chunkID = row["chunkID"] as? String,
            let chunkDocumentID = row["chunkDocumentID"] as? String,
            let chunkSourceKindRaw = row["chunkSourceKind"] as? String,
            let chunkSourceKind = SearchSourceKind(rawValue: chunkSourceKindRaw),
            let chunkSourceID = row["chunkSourceID"] as? String,
            let docID = row["docID"] as? String,
            let docSourceKindRaw = row["docSourceKind"] as? String,
            let docSourceKind = SearchSourceKind(rawValue: docSourceKindRaw),
            let docSourceID = row["docSourceID"] as? String,
            let docTitle = row["docTitle"] as? String
        else {
            return nil
        }

        let chunkOrdinal: Int = row["chunkOrdinal"] ?? 0
        let chunkStartOffset: Int = row["chunkStartOffset"] ?? 0
        let chunkEndOffset: Int = row["chunkEndOffset"] ?? 0
        let chunkMessageStartOffset: Int = row["chunkMessageStartOffset"] ?? -1
        let chunkMessageEndOffset: Int = row["chunkMessageEndOffset"] ?? -1
        let chunkCreatedAt = OpenBurnBarDatabase.parseDateValue(row["chunkCreatedAt"]) ?? Date.distantPast
        let chunkUpdatedAt = OpenBurnBarDatabase.parseDateValue(row["chunkUpdatedAt"]) ?? chunkCreatedAt

        let chunk = SearchChunkRecord(
            id: chunkID,
            documentID: chunkDocumentID,
            sourceKind: chunkSourceKind,
            sourceID: chunkSourceID,
            sourceVersionID: (row["chunkSourceVersionID"] as? String) ?? "",
            ordinal: chunkOrdinal,
            startOffset: chunkStartOffset,
            endOffset: chunkEndOffset,
            messageStartOffset: chunkMessageStartOffset >= 0 ? chunkMessageStartOffset : nil,
            messageEndOffset: chunkMessageEndOffset >= 0 ? chunkMessageEndOffset : nil,
            sectionPath: row["chunkSectionPath"] as? String,
            text: (row["chunkText"] as? String) ?? "",
            contentHash: row["chunkContentHash"] as? String,
            createdAt: chunkCreatedAt,
            updatedAt: chunkUpdatedAt
        )

        let docIndexedAt = OpenBurnBarDatabase.parseDateValue(row["docIndexedAt"]) ?? Date()
        let docCreatedAt = OpenBurnBarDatabase.parseDateValue(row["docCreatedAt"]) ?? docIndexedAt
        let docUpdatedAt = OpenBurnBarDatabase.parseDateValue(row["docUpdatedAt"]) ?? docCreatedAt
        let document = SearchDocumentRecord(
            id: docID,
            sourceKind: docSourceKind,
            sourceID: docSourceID,
            sourceVersionID: (row["docSourceVersionID"] as? String) ?? "",
            provider: row["docProvider"] as? String,
            projectName: row["docProjectName"] as? String,
            title: docTitle,
            subtitle: row["docSubtitle"] as? String,
            bodyPreview: row["docBodyPreview"] as? String,
            sourceUpdatedAt: OpenBurnBarDatabase.parseDateValue(row["docSourceUpdatedAt"]),
            indexedAt: docIndexedAt,
            contentHash: row["docContentHash"] as? String,
            createdAt: docCreatedAt,
            updatedAt: docUpdatedAt
        )

        return (chunk: chunk, document: document)
    }

    func fetchChunks(sourceKind: SearchSourceKind, sourceID: String) async throws -> [SearchChunkRecord] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_chunks
                WHERE sourceKind = ? AND sourceID = ?
                ORDER BY documentID ASC, ordinal ASC
                """,
                arguments: [sourceKind.rawValue, sourceID]
            )
            return rows.compactMap(Self.chunk(from:))
        }
    }

    // MARK: - Lexical Search

    func searchLexicalChunks(
        ftsQuery: String,
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?,
        visibility: SearchVisibilityScope,
        sharedArtifactAccessContext: SharedArtifactAccessContext?,
        sourceIDs: [String]?,
        limit: Int
    ) async throws -> [SearchChunkLexicalMatch] {
        guard ftsQuery.isEmpty == false, limit > 0 else { return [] }

        let normalizedSourceKinds = Array(Set(sourceKinds ?? [])).sorted { $0.rawValue < $1.rawValue }
        let trimmedSourceIDs = (sourceIDs ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        let normalizedSourceIDs = Array(Set(trimmedSourceIDs)).sorted()
        let normalizedProject = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)

        var clauses: [String] = ["search_chunks_fts MATCH ?"]
        var args: [any DatabaseValueConvertible] = [ftsQuery]

        if let provider, provider.isEmpty == false {
            clauses.append("d.provider = ?")
            args.append(provider)
        }

        if let normalizedProject, normalizedProject.isEmpty == false {
            clauses.append("LOWER(COALESCE(d.projectName, '')) = LOWER(?)")
            args.append(normalizedProject)
        }

        if normalizedSourceKinds.isEmpty == false {
            clauses.append("d.sourceKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: normalizedSourceKinds.count)))")
            args.append(contentsOf: normalizedSourceKinds.map(\.rawValue))
        }

        if normalizedSourceIDs.isEmpty == false {
            clauses.append("d.sourceID IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: normalizedSourceIDs.count)))")
            args.append(contentsOf: normalizedSourceIDs)
        }

        if let dateRange {
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) >= ?")
            clauses.append("COALESCE(d.sourceUpdatedAt, d.indexedAt) <= ?")
            args.append(dateRange.lowerBound)
            args.append(dateRange.upperBound)
        }

        switch visibility {
        case .all:
            break
        case .personalOnly:
            clauses.append("d.sourceKind != ?")
            args.append(SearchSourceKind.sharedArtifact.rawValue)
        case .sharedOnly:
            clauses.append("d.sourceKind = ?")
            args.append(SearchSourceKind.sharedArtifact.rawValue)
        }

        if visibility != .personalOnly {
            if let access = sharedArtifactAccessContext {
                clauses.append(
                    """
                    (
                        d.sourceKind != ?
                        OR EXISTS (
                            SELECT 1
                            FROM artifact_permissions AS ap
                            WHERE ap.sourceArtifactID = d.sourceID
                              AND ap.canRead = 1
                              AND ap.workspaceID = ?
                              AND (
                                  (ap.principalType = ? AND ap.principalID = ?)
                                  OR (ap.principalType = ? AND ap.principalID = ? AND ap.teamID = ?)
                                  OR (ap.principalType = ? AND ap.principalID = ?)
                              )
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM shared_artifact_sync_state AS sas
                            WHERE sas.sourceArtifactID = d.sourceID
                              AND sas.workspaceID = ?
                              AND sas.teamID = ?
                              AND sas.ownerUserID = ?
                        )
                    )
                    """
                )
                args.append(SearchSourceKind.sharedArtifact.rawValue)
                args.append(access.workspaceID)
                args.append(SharedArtifactPrincipalType.user.rawValue)
                args.append(access.userID)
                args.append(SharedArtifactPrincipalType.team.rawValue)
                args.append(access.teamID)
                args.append(access.teamID)
                args.append(SharedArtifactPrincipalType.workspace.rawValue)
                args.append(access.workspaceID)
                args.append(access.workspaceID)
                args.append(access.teamID)
                args.append(access.userID)
            } else {
                clauses.append("d.sourceKind != ?")
                args.append(SearchSourceKind.sharedArtifact.rawValue)
            }
        }

        let whereSQL = clauses.joined(separator: " AND ")
        args.append(limit)
        let capturedArgs = args

        return try await dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    search_chunks_fts.chunkID AS chunkID,
                    search_chunks_fts.documentID AS documentID,
                    bm25(search_chunks_fts) AS lexicalRank,
                    snippet(search_chunks_fts, 3, '<b>', '</b>', '…', 16) AS snippet,
                    d.sourceKind AS sourceKind,
                    d.sourceID AS sourceID,
                    d.sourceVersionID AS sourceVersionID,
                    d.provider AS provider,
                    d.projectName AS projectName,
                    d.title AS title,
                    d.subtitle AS subtitle,
                    d.bodyPreview AS bodyPreview,
                    d.sourceUpdatedAt AS sourceUpdatedAt,
                    d.indexedAt AS indexedAt,
                    c.ordinal AS chunkOrdinal,
                    c.startOffset AS startOffset,
                    c.endOffset AS endOffset,
                    c.sectionPath AS sectionPath,
                    c.text AS chunkText
                FROM search_chunks_fts
                JOIN search_chunks AS c ON c.id = search_chunks_fts.chunkID
                JOIN search_documents AS d ON d.id = search_chunks_fts.documentID
                WHERE \(whereSQL)
                ORDER BY lexicalRank ASC, d.indexedAt DESC, c.ordinal ASC
                LIMIT ?
                """,
                arguments: StatementArguments(capturedArgs)
            )
            return rows.compactMap(Self.lexicalMatch(from:))
        }
    }

    // MARK: - Row Decoding

    static func document(from row: Row) -> SearchDocumentRecord? {
        guard
            let id = row["id"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let sourceID = row["sourceID"] as? String,
            let title = row["title"] as? String
        else {
            return nil
        }
        let indexedAt = OpenBurnBarDatabase.parseDateValue(row["indexedAt"]) ?? Date()
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? indexedAt
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        return SearchDocumentRecord(
            id: id,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            provider: row["provider"] as? String,
            projectName: row["projectName"] as? String,
            title: title,
            subtitle: row["subtitle"] as? String,
            bodyPreview: row["bodyPreview"] as? String,
            sourceUpdatedAt: OpenBurnBarDatabase.parseDateValue(row["sourceUpdatedAt"]),
            indexedAt: indexedAt,
            contentHash: row["contentHash"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func chunk(from row: Row) -> SearchChunkRecord? {
        guard
            let id = row["id"] as? String,
            let documentID = row["documentID"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let sourceID = row["sourceID"] as? String
        else {
            return nil
        }

        let ordinal: Int = row["ordinal"] ?? 0
        let startOffset: Int = row["startOffset"] ?? 0
        let endOffset: Int = row["endOffset"] ?? 0
        let messageStartOffset: Int = row["messageStartOffset"] ?? -1
        let messageEndOffset: Int = row["messageEndOffset"] ?? -1
        let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date.distantPast
        let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? createdAt
        let text = (row["text"] as? String) ?? ""
        let contentHash = row["contentHash"] as? String
        return SearchChunkRecord(
            id: id,
            documentID: documentID,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            ordinal: ordinal,
            startOffset: startOffset,
            endOffset: endOffset,
            messageStartOffset: messageStartOffset >= 0 ? messageStartOffset : nil,
            messageEndOffset: messageEndOffset >= 0 ? messageEndOffset : nil,
            sectionPath: row["sectionPath"] as? String,
            text: text,
            contentHash: contentHash,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func lexicalMatch(from row: Row) -> SearchChunkLexicalMatch? {
        guard
            let chunkID = row["chunkID"] as? String,
            let documentID = row["documentID"] as? String,
            let sourceKindRaw = row["sourceKind"] as? String,
            let sourceKind = SearchSourceKind(rawValue: sourceKindRaw),
            let sourceID = row["sourceID"] as? String,
            let title = row["title"] as? String
        else {
            return nil
        }

        let lexicalRankRaw: Double = row["lexicalRank"] ?? 0
        let chunkOrdinal: Int = row["chunkOrdinal"] ?? 0
        let startOffset: Int = row["startOffset"] ?? 0
        let endOffset: Int = row["endOffset"] ?? 0

        return SearchChunkLexicalMatch(
            chunkID: chunkID,
            documentID: documentID,
            sourceKind: sourceKind,
            sourceID: sourceID,
            sourceVersionID: (row["sourceVersionID"] as? String) ?? "",
            provider: row["provider"] as? String,
            projectName: row["projectName"] as? String,
            title: title,
            subtitle: row["subtitle"] as? String,
            bodyPreview: row["bodyPreview"] as? String,
            sourceUpdatedAt: OpenBurnBarDatabase.parseDateValue(row["sourceUpdatedAt"]),
            indexedAt: OpenBurnBarDatabase.parseDateValue(row["indexedAt"]) ?? Date.distantPast,
            chunkOrdinal: chunkOrdinal,
            startOffset: startOffset,
            endOffset: endOffset,
            sectionPath: row["sectionPath"] as? String,
            chunkText: (row["chunkText"] as? String) ?? "",
            snippet: (row["snippet"] as? String) ?? "",
            lexicalRank: lexicalRankRaw
        )
    }

    // MARK: - Private Helpers

    private static func filteredDocumentClause(
        provider: String?,
        projectName: String?,
        sourceKinds: [SearchSourceKind]?,
        dateRange: ClosedRange<Date>?
    ) -> (String, [any DatabaseValueConvertible]) {
        let trimmedProjectName = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProjectName = (trimmedProjectName?.isEmpty == false) ? trimmedProjectName : nil
        let normalizedSourceKinds = Array(Set(sourceKinds ?? []))
            .sorted { $0.rawValue < $1.rawValue }

        var clauses: [String] = []
        var args: [any DatabaseValueConvertible] = []

        if let provider, provider.isEmpty == false {
            clauses.append("provider = ?")
            args.append(provider)
        }

        if let normalizedProjectName {
            clauses.append("LOWER(COALESCE(projectName, '')) = LOWER(?)")
            args.append(normalizedProjectName)
        }

        if normalizedSourceKinds.isEmpty == false {
            clauses.append("sourceKind IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: normalizedSourceKinds.count)))")
            args.append(contentsOf: normalizedSourceKinds.map(\.rawValue))
        }

        if let dateRange {
            clauses.append("COALESCE(sourceUpdatedAt, indexedAt) >= ?")
            clauses.append("COALESCE(sourceUpdatedAt, indexedAt) <= ?")
            args.append(dateRange.lowerBound)
            args.append(dateRange.upperBound)
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        return (whereSQL, args)
    }
}
