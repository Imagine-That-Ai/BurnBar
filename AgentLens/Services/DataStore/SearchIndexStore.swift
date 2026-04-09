import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - SearchIndexStore

/// Search documents, chunks, FTS-based lexical search, and document-level deletion.
final class SearchIndexStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Documents

    func upsertDocument(_ document: SearchDocumentRecord) throws {
        try dbQueue.write { db in
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

    func fetchDocuments(limit: Int) throws -> [SearchDocumentRecord] {
        try dbQueue.read { db in
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
    func fetchDocuments(limit: Int, offset: Int) throws -> [SearchDocumentRecord] {
        try dbQueue.read { db in
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
    ) throws -> [SearchDocumentRecord] {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
        var queryArgs = args
        queryArgs.append(max(1, limit))

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                \(whereSQL)
                ORDER BY COALESCE(sourceUpdatedAt, indexedAt) DESC, indexedAt DESC, createdAt DESC
                LIMIT ?
                """,
                arguments: StatementArguments(queryArgs)
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
    ) throws -> [SearchDocumentRecord] {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )
        var queryArgs = args
        queryArgs.append(max(1, limit))
        queryArgs.append(max(0, offset))

        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM search_documents
                \(whereSQL)
                ORDER BY COALESCE(sourceUpdatedAt, indexedAt) DESC, indexedAt DESC, createdAt DESC, id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: StatementArguments(queryArgs)
            )
            return rows.compactMap(Self.document(from:))
        }
    }

    func fetchDocuments(ids: [String]) throws -> [SearchDocumentRecord] {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard uniqueIDs.isEmpty == false else { return [] }

        return try dbQueue.read { db in
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

    func fetchDocument(id: String) throws -> SearchDocumentRecord? {
        try fetchDocuments(ids: [id]).first
    }

    func fetchDocuments(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchDocumentRecord] {
        try dbQueue.read { db in
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
    ) throws -> Int {
        let (whereSQL, args) = Self.filteredDocumentClause(
            provider: provider,
            projectName: projectName,
            sourceKinds: sourceKinds,
            dateRange: dateRange
        )

        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_documents
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func deleteDocuments(sourceKind: SearchSourceKind, sourceID: String) throws {
        try dbQueue.write { db in
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
                try db.execute(
                    sql: "DELETE FROM search_chunks_fts WHERE documentID = ?",
                    arguments: [documentID]
                )
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
    ) throws -> Int {
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
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM search_chunks AS c
                JOIN search_documents AS d ON d.id = c.documentID
                \(whereSQL)
                """,
                arguments: StatementArguments(args)
            ) ?? 0
        }
    }

    func countChunks(documentID: String) throws -> Int {
        try dbQueue.read { db in
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
    ) throws -> ChunkDiffResult {
        // Fetch existing chunks for this document
        let existingChunks = try fetchChunks(documentID: documentID)

        // If no existing chunks, just insert all (first projection)
        if existingChunks.isEmpty {
            guard newChunks.isEmpty == false else {
                return ChunkDiffResult(unchanged: 0, rekeyed: 0, added: newChunks.count, deleted: 0, existingTotal: 0, newTotal: newChunks.count)
            }
            try replaceChunks(documentID: documentID, title: title, chunks: newChunks)
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
            let oldIDs = Set(existingByHash[hash]!.map(\.id))
            let newIDs = Set(newByHash[hash]!.map(\.id))
            if oldIDs != newIDs {
                rekeyedCount += max(oldIDs.count, newIDs.count)
            }
        }

        // Count truly unchanged chunks.
        // A chunk is truly unchanged only when contentHash AND chunkID match.
        // A chunk is rekeyed when contentHash matches but chunkID differs.
        var unchangedCount = 0
        for hash in unchangedHashes {
            let oldIDs = Set(existingByHash[hash]!.map(\.id))
            let newIDs = Set(newByHash[hash]!.map(\.id))
            if oldIDs == newIDs {
                // Identical chunkIDs: truly unchanged — no writes needed
                unchangedCount += oldIDs.count
            }
            // Note: When oldIDs != newIDs (rekeyed), we don't add to unchangedCount.
            // These chunks will be reconciled via delete+insert in the diff block.
        }

        // With our fix, rekeyed chunks don't cause writes. So the only writes
        // are for truly added or deleted contentHashes.
        let effectiveWriteCount = deletedHashes.reduce(0) { $0 + (existingByHash[$1]?.count ?? 0) }
            + addedHashes.reduce(0) { $0 + (newByHash[$1]?.count ?? 0) }

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

        // Apply the diff
        var actualAdded = 0
        var actualDeleted = 0
        try dbQueue.write { db in
            let documentRow = try Row.fetchOne(
                db,
                sql: "SELECT projectName, provider FROM search_documents WHERE id = ?",
                arguments: [documentID]
            )
            let projectName = documentRow?["projectName"] as? String ?? ""
            let provider = documentRow?["provider"] as? String ?? ""

            // Delete old chunks whose contentHash is no longer present
            var oldIDsToDelete: [String] = deletedHashes.flatMap { existingByHash[$0]!.map(\.id) }

            // Delete old chunks for rekeyed hashes where IDs differ.
            // These chunks have the same contentHash but different chunk IDs (boundary shift).
            // We delete the old chunks and insert the new chunks so the persisted
            // chunk set matches the projected chunk set exactly.
            for hash in unchangedHashes {
                let oldIDs = Set(existingByHash[hash]!.map(\.id))
                let newIDs = Set(newByHash[hash]!.map(\.id))
                if oldIDs != newIDs {
                    // New chunk IDs not in old set: these new chunks will be inserted below
                    // Old chunk IDs not in new set: these old chunks need to be deleted
                    let idsOnlyInOld = oldIDs.subtracting(newIDs)
                    oldIDsToDelete.append(contentsOf: idsOnlyInOld)
                }
            }

            // Perform deletes (only for truly deleted contentHashes and old rekeyed IDs)
            for chunkID in oldIDsToDelete {
                try db.execute(sql: "DELETE FROM search_chunks_fts WHERE chunkID = ?", arguments: [chunkID])
                try db.execute(sql: "DELETE FROM search_chunks WHERE id = ?", arguments: [chunkID])
            }
            actualDeleted = oldIDsToDelete.count

            // Insert added chunks (new content hashes)
            for hash in addedHashes {
                for chunk in newByHash[hash]! {
                    try Self.insertChunk(chunk, documentID: documentID, title: title, projectName: projectName, provider: provider, db: db)
                    actualAdded += 1
                }
            }

            // Insert new chunks for rekeyed hashes (same contentHash, different chunk IDs).
            // This ensures the persisted chunk set matches the projected chunk set when
            // boundary shifts cause chunk IDs to differ for the same content.
            for hash in unchangedHashes {
                let oldIDs = Set(existingByHash[hash]!.map(\.id))
                let newIDs = Set(newByHash[hash]!.map(\.id))
                if oldIDs != newIDs {
                    // New IDs not in old set: insert these new chunks
                    let idsOnlyInNew = newIDs.subtracting(oldIDs)
                    for chunk in newByHash[hash]! {
                        if idsOnlyInNew.contains(chunk.id) {
                            try Self.insertChunk(chunk, documentID: documentID, title: title, projectName: projectName, provider: provider, db: db)
                            actualAdded += 1
                        }
                    }
                }
            }
        }

        return ChunkDiffResult(
            unchanged: unchangedCount,
            rekeyed: rekeyedCount,
            added: actualAdded,
            deleted: actualDeleted,
            existingTotal: existingChunks.count,
            newTotal: newChunks.count
        )
    }

    func replaceChunks(documentID: String, title: String, chunks: [SearchChunkRecord]) throws {
        try dbQueue.write { db in
            let documentRow = try Row.fetchOne(
                db,
                sql: "SELECT projectName, provider FROM search_documents WHERE id = ?",
                arguments: [documentID]
            )
            let projectName = documentRow?["projectName"] as? String ?? ""
            let provider = documentRow?["provider"] as? String ?? ""

            try db.execute(
                sql: "DELETE FROM search_chunks_fts WHERE documentID = ?",
                arguments: [documentID]
            )
            try db.execute(
                sql: "DELETE FROM search_chunks WHERE documentID = ?",
                arguments: [documentID]
            )

            for chunk in chunks.sorted(by: { $0.ordinal < $1.ordinal }) {
                try Self.insertChunk(chunk, documentID: documentID, title: title, projectName: projectName, provider: provider, db: db)
            }
        }
    }

    /// Fetches existing embeddings keyed by contentHash for a document.
    /// Returns a mapping of contentHash -> (chunkID, vectorBlob) for chunks
    /// that have embeddings for the given version. Used for embedding reuse:
    /// when a new chunk has the same contentHash, the existing embedding
    /// can be copied to the new chunk ID instead of regenerating it.
    func fetchEmbeddingByContentHash(documentID: String, embeddingVersionID: String) throws -> [String: (chunkID: String, vectorBlob: Data)] {
        try dbQueue.read { db in
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

    private static func insertChunk(
        _ chunk: SearchChunkRecord,
        documentID: String,
        title: String,
        projectName: String,
        provider: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO search_chunks (
                id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                startOffset, endOffset, messageStartOffset, messageEndOffset,
                sectionPath, text, contentHash, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                chunk.createdAt,
                chunk.updatedAt
            ]
        )

        try db.execute(
            sql: """
            INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [chunk.id, chunk.documentID, title, chunk.text, projectName, provider]
        )
    }

    func fetchChunks(documentID: String) throws -> [SearchChunkRecord] {
        try dbQueue.read { db in
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

    func fetchChunks(ids: [String]) throws -> [SearchChunkRecord] {
        let uniqueIDs = Array(Set(ids)).sorted()
        guard uniqueIDs.isEmpty == false else { return [] }

        return try dbQueue.read { db in
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

    func fetchChunks(sourceKind: SearchSourceKind, sourceID: String) throws -> [SearchChunkRecord] {
        try dbQueue.read { db in
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
    ) throws -> [SearchChunkLexicalMatch] {
        guard ftsQuery.isEmpty == false, limit > 0 else { return [] }

        let normalizedSourceKinds = Array(Set(sourceKinds ?? [])).sorted { $0.rawValue < $1.rawValue }
        let normalizedSourceIDs = Array(Set((sourceIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let normalizedProject = projectName?.trimmingCharacters(in: .whitespacesAndNewlines)

        var clauses: [String] = ["search_chunks_fts MATCH ?"]
        var args: [any DatabaseValueConvertible] = [ftsQuery]

        if let provider, provider.isEmpty == false {
            clauses.append("d.provider = ?")
            args.append(provider)
        }

        if let normalizedProject, normalizedProject.isEmpty == false {
            clauses.append("d.projectName = ?")
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

        return try dbQueue.read { db in
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
                arguments: StatementArguments(args)
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

        let ordinal = (row["ordinal"] as? Int) ?? Int(row["ordinal"] as? Int64 ?? 0)
        let startOffset = (row["startOffset"] as? Int) ?? Int(row["startOffset"] as? Int64 ?? 0)
        let endOffset = (row["endOffset"] as? Int) ?? Int(row["endOffset"] as? Int64 ?? 0)
        let messageStartOffset = (row["messageStartOffset"] as? Int) ?? Int(row["messageStartOffset"] as? Int64 ?? -1)
        let messageEndOffset = (row["messageEndOffset"] as? Int) ?? Int(row["messageEndOffset"] as? Int64 ?? -1)
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

        let lexicalRankRaw = (row["lexicalRank"] as? Double) ?? Double(row["lexicalRank"] as? Int64 ?? 0)
        let chunkOrdinal = (row["chunkOrdinal"] as? Int) ?? Int(row["chunkOrdinal"] as? Int64 ?? 0)
        let startOffset = (row["startOffset"] as? Int) ?? Int(row["startOffset"] as? Int64 ?? 0)
        let endOffset = (row["endOffset"] as? Int) ?? Int(row["endOffset"] as? Int64 ?? 0)

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
            clauses.append("projectName = ?")
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
