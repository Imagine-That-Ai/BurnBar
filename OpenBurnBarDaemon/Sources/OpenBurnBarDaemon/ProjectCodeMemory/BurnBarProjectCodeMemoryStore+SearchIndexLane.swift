import Foundation
import OpenBurnBarEngine
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

// MARK: - Search Index App Lane (Wave 2.1c-iv)

/// The daemon-owned write path for the app lane of the search tables
/// (ADR-005): `search_documents`, `search_chunks`, `search_chunks_fts`.
///
/// The app finalizes every write set locally — diffs are computed against
/// its local reads — and this lane stores the set verbatim inside one
/// transaction per apply. The only values the daemon assigns are the FTS
/// `rowid`s recorded in `search_chunks.ftsRowid`, exactly as the app's
/// pre-cutover GRDB writes did: FTS row first, `last_insert_rowid()` onto
/// the chunk row, deletes targeted at the recorded rowid with the legacy
/// `WHERE chunkID = ?` scan path for pre-v55 rows.
///
/// Not to be confused with the daemon's own code-indexing path
/// (`insertSearchDocument`/`insertSearchChunk`): that lane mints
/// daemon-side rows with daemon-side embeddings, while this lane carries
/// rows the app already finalized, including the app's GRDB timestamp
/// text. The two lanes share the v55 `ftsRowid` contract and nothing else.
extension BurnBarProjectCodeMemoryStore {
    enum SearchIndexAppLaneError: Error, LocalizedError {
        case invalidRequest(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest(let detail):
                return "Invalid search index request: \(detail)"
            }
        }
    }

    /// The app's `SearchSourceKind` raw values. The wire carries the
    /// spelling as a string; an unknown value fails validation loudly
    /// instead of being reinterpreted or crashing a decode.
    static let searchIndexAppLaneKnownSourceKinds: Set<String> = [
        "conversation",
        "skill_doc",
        "agent_doc",
        "shared_artifact",
        "code"
    ]

    /// Fail-closed bound on one apply: the app sends 64-row batches, so a
    /// request past this is a runaway caller, not an index. Rejected
    /// before the transaction opens, so no partial apply is possible.
    static let searchIndexAppLaneMaxChunksPerApply = 1024

    func searchIndexApplyAppLane(_ request: BurnBarSearchIndexApplyRequest) throws -> BurnBarSearchIndexApplyResponse {
        try Self.validateSearchIndexApply(request)
        try execute("BEGIN IMMEDIATE", [])
        do {
            var documentsDeleted = 0
            var documentsUpserted = 0
            var chunksAdded = 0
            var chunksDeleted = 0
            // Fixed order: document deletes, document upsert, chunk
            // mutations (deletes before inserts). The app never combines
            // operation kinds in one call today; the contract pins the
            // order so any future combined caller can reason about it.
            if let documentDelete = request.documentDelete {
                documentsDeleted = try applySearchIndexDocumentDelete(documentDelete)
            }
            if let documentUpsert = request.documentUpsert {
                try applySearchIndexDocumentUpsert(documentUpsert)
                documentsUpserted = 1
            }
            if let chunkMutations = request.chunkMutations {
                let counts = try applySearchIndexChunkMutations(chunkMutations)
                chunksAdded = counts.added
                chunksDeleted = counts.deleted
            }
            try execute("COMMIT", [])
            return BurnBarSearchIndexApplyResponse(
                documentsUpserted: documentsUpserted,
                documentsDeleted: documentsDeleted,
                chunksAdded: chunksAdded,
                chunksDeleted: chunksDeleted
            )
        } catch {
            try? execute("ROLLBACK", [])
            throw error
        }
    }

    // MARK: - Validation

    private static func validateSearchIndexApply(_ request: BurnBarSearchIndexApplyRequest) throws {
        guard request.documentUpsert != nil || request.documentDelete != nil || request.chunkMutations != nil else {
            throw SearchIndexAppLaneError.invalidRequest("apply carries no operations")
        }
        if let document = request.documentUpsert {
            try validateSearchIndexDocument(document)
        }
        if let documentDelete = request.documentDelete {
            try validateSearchIndexSourceKind(documentDelete.sourceKind, field: "documentDelete.sourceKind")
            guard documentDelete.sourceID.isEmpty == false else {
                throw SearchIndexAppLaneError.invalidRequest("documentDelete.sourceID is empty")
            }
        }
        if let mutations = request.chunkMutations {
            try validateSearchIndexChunkMutations(mutations)
        }
    }

    private static func validateSearchIndexDocument(_ document: BurnBarSearchIndexDocumentRow) throws {
        guard document.id.isEmpty == false else {
            throw SearchIndexAppLaneError.invalidRequest("document.id is empty")
        }
        try validateSearchIndexSourceKind(document.sourceKind, field: "document.sourceKind")
        guard document.sourceID.isEmpty == false else {
            throw SearchIndexAppLaneError.invalidRequest("document.sourceID is empty")
        }
        if let sourceUpdatedAt = document.sourceUpdatedAtText {
            try validateSearchIndexTimestamp(sourceUpdatedAt, field: "document.sourceUpdatedAtText")
        }
        try validateSearchIndexTimestamp(document.indexedAtText, field: "document.indexedAtText")
        try validateSearchIndexTimestamp(document.createdAtText, field: "document.createdAtText")
        try validateSearchIndexTimestamp(document.updatedAtText, field: "document.updatedAtText")
    }

    private static func validateSearchIndexChunkMutations(_ mutations: BurnBarSearchIndexChunkMutations) throws {
        guard mutations.documentID.isEmpty == false else {
            throw SearchIndexAppLaneError.invalidRequest("chunkMutations.documentID is empty")
        }
        guard mutations.chunkIDsToDelete.isEmpty == false || mutations.chunksToInsert.isEmpty == false else {
            throw SearchIndexAppLaneError.invalidRequest("chunkMutations carries no deletes or inserts")
        }
        guard mutations.chunksToInsert.count <= searchIndexAppLaneMaxChunksPerApply else {
            throw SearchIndexAppLaneError.invalidRequest(
                "chunksToInsert count \(mutations.chunksToInsert.count) exceeds \(searchIndexAppLaneMaxChunksPerApply)"
            )
        }
        for chunkID in mutations.chunkIDsToDelete where chunkID.isEmpty {
            throw SearchIndexAppLaneError.invalidRequest("chunkIDsToDelete contains an empty id")
        }
        for chunk in mutations.chunksToInsert {
            try validateSearchIndexChunk(chunk, documentID: mutations.documentID)
        }
    }

    private static func validateSearchIndexChunk(_ chunk: BurnBarSearchIndexChunkRow, documentID: String) throws {
        guard chunk.id.isEmpty == false else {
            throw SearchIndexAppLaneError.invalidRequest("chunk.id is empty")
        }
        guard chunk.documentID == documentID else {
            throw SearchIndexAppLaneError.invalidRequest("chunk \(chunk.id) belongs to \(chunk.documentID), not \(documentID)")
        }
        try validateSearchIndexSourceKind(chunk.sourceKind, field: "chunk.sourceKind")
        guard chunk.sourceID.isEmpty == false else {
            throw SearchIndexAppLaneError.invalidRequest("chunk.sourceID is empty")
        }
        guard chunk.ordinal >= 0, chunk.startOffset >= 0, chunk.endOffset >= chunk.startOffset else {
            throw SearchIndexAppLaneError.invalidRequest("chunk \(chunk.id) has an invalid ordinal/offset range")
        }
        for messageOffset in [chunk.messageStartOffset, chunk.messageEndOffset] {
            guard messageOffset == nil || messageOffset ?? 0 >= 0 else {
                throw SearchIndexAppLaneError.invalidRequest("chunk \(chunk.id) has a negative message offset")
            }
        }
        try validateSearchIndexTimestamp(chunk.createdAtText, field: "chunk.createdAtText")
        try validateSearchIndexTimestamp(chunk.updatedAtText, field: "chunk.updatedAtText")
    }

    /// Strict GRDB timestamp text (`yyyy-MM-dd HH:mm:ss.SSS`, UTC) and
    /// nothing else. The columns order lexicographically, so a second
    /// format on the wire (notably ISO 8601) would silently misorder
    /// mixed rows; validated stamps bind verbatim.
    private static func validateSearchIndexTimestamp(_ raw: String, field: String) throws {
        guard raw.count == 23, parseSearchIndexTimestamp(raw) != nil else {
            throw SearchIndexAppLaneError.invalidRequest("\(field) must be GRDB timestamp text (yyyy-MM-dd HH:mm:ss.SSS)")
        }
    }

    private static func parseSearchIndexTimestamp(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.date(from: raw)
    }

    private static func validateSearchIndexSourceKind(_ sourceKind: String, field: String) throws {
        guard searchIndexAppLaneKnownSourceKinds.contains(sourceKind) else {
            throw SearchIndexAppLaneError.invalidRequest("\(field) has unknown sourceKind '\(sourceKind)'")
        }
    }

    // MARK: - Document operations

    private func applySearchIndexDocumentUpsert(_ document: BurnBarSearchIndexDocumentRow) throws {
        // Byte-identical to the app's pre-cutover upsert: same columns,
        // same `ON CONFLICT` target, same trigger behavior on
        // `search_documents_fts`. Validated GRDB timestamp text binds
        // verbatim — the storage class GRDB's own `Date` writer used.
        try execute(
            """
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
            [
                .text(document.id),
                .text(document.sourceKind),
                .text(document.sourceID),
                .text(document.sourceVersionID),
                document.provider.map(SQLiteBind.text) ?? .null,
                document.projectName.map(SQLiteBind.text) ?? .null,
                .text(document.title),
                document.subtitle.map(SQLiteBind.text) ?? .null,
                document.bodyPreview.map(SQLiteBind.text) ?? .null,
                document.sourceUpdatedAtText.map(SQLiteBind.text) ?? .null,
                .text(document.indexedAtText),
                document.contentHash.map(SQLiteBind.text) ?? .null,
                .text(document.createdAtText),
                .text(document.updatedAtText)
            ]
        )
    }

    private func applySearchIndexDocumentDelete(_ delete: BurnBarSearchIndexDeleteDocuments) throws -> Int {
        // Mirrors the app's pre-cutover delete: rowid-targeted FTS
        // cleanup per document (documentID is UNINDEXED, matching on it
        // scans the whole FTS table), the legacy per-chunk scan for
        // pre-v55 rows, then the document rows themselves.
        let documentIDs = try queryRows(
            "SELECT id FROM search_documents WHERE sourceKind = ? AND sourceID = ?",
            [.text(delete.sourceKind), .text(delete.sourceID)]
        ).map { $0.string(0) }
        for documentID in documentIDs {
            try execute(
                """
                DELETE FROM search_chunks_fts WHERE rowid IN (
                    SELECT ftsRowid FROM search_chunks
                    WHERE documentID = ? AND ftsRowid IS NOT NULL
                )
                """,
                [.text(documentID)]
            )
            let legacyChunkIDs = try queryRows(
                "SELECT id FROM search_chunks WHERE documentID = ? AND ftsRowid IS NULL",
                [.text(documentID)]
            ).map { $0.string(0) }
            for chunkID in legacyChunkIDs {
                try execute("DELETE FROM search_chunks_fts WHERE chunkID = ?", [.text(chunkID)])
            }
        }
        try execute(
            "DELETE FROM search_documents WHERE sourceKind = ? AND sourceID = ?",
            [.text(delete.sourceKind), .text(delete.sourceID)]
        )
        return Int(try queryRows("SELECT changes()", []).first?.int64(0) ?? 0)
    }

    // MARK: - Chunk operations

    private func applySearchIndexChunkMutations(
        _ mutations: BurnBarSearchIndexChunkMutations
    ) throws -> (added: Int, deleted: Int) {
        for chunkID in mutations.chunkIDsToDelete {
            try deleteSearchIndexChunk(chunkID: chunkID)
        }
        for chunk in mutations.chunksToInsert {
            try insertSearchIndexChunk(
                chunk,
                title: mutations.ftsTitle,
                projectName: mutations.ftsProjectName,
                provider: mutations.ftsProvider
            )
        }
        // Requested counts, matching the app's pre-cutover batch
        // reporter (`ChunkDiffResult.added/deleted` counted the batch,
        // not matched rows).
        return (added: mutations.chunksToInsert.count, deleted: mutations.chunkIDsToDelete.count)
    }

    private func deleteSearchIndexChunk(chunkID: String) throws {
        // Rowid-targeted delete via the ftsRowid mapping (O(log n));
        // pre-v55 rows with NULL ftsRowid take the legacy scan path.
        let ftsRowid = try queryRows(
            "SELECT ftsRowid FROM search_chunks WHERE id = ? AND ftsRowid IS NOT NULL",
            [.text(chunkID)]
        ).first?.int64(0)
        if let ftsRowid {
            try execute("DELETE FROM search_chunks_fts WHERE rowid = ?", [.int64(ftsRowid)])
        } else {
            try execute("DELETE FROM search_chunks_fts WHERE chunkID = ?", [.text(chunkID)])
        }
        try execute("DELETE FROM search_chunks WHERE id = ?", [.text(chunkID)])
    }

    private func insertSearchIndexChunk(
        _ chunk: BurnBarSearchIndexChunkRow,
        title: String,
        projectName: String,
        provider: String
    ) throws {
        // FTS row first so its rowid can be recorded on the chunk row —
        // deletes then target the FTS rowid instead of scanning the
        // table. Mirrors the app's pre-cutover `insertChunk`.
        try execute(
            """
            INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            [.text(chunk.id), .text(chunk.documentID), .text(title), .text(chunk.text), .text(projectName), .text(provider)]
        )
        let ftsRowid = try queryRows("SELECT last_insert_rowid()", []).first?.int64(0)
        // No pre-v55 fallback: the migrator owns `ftsRowid` (v55, far
        // below the current schema version) and the daemon bootstrap
        // self-heals it via `ensureColumn`, so the column is guaranteed
        // at lane time. A database without it is a schema violation and
        // fails loudly here (rolled back) instead of silently writing
        // rows the rowid-targeted deletes can never reach.
        try execute(
            """
            INSERT INTO search_chunks (
                id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                startOffset, endOffset, messageStartOffset, messageEndOffset,
                sectionPath, text, contentHash, ftsRowid, createdAt, updatedAt
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            [
                .text(chunk.id),
                .text(chunk.documentID),
                .text(chunk.sourceKind),
                .text(chunk.sourceID),
                .text(chunk.sourceVersionID),
                .int(chunk.ordinal),
                .int(chunk.startOffset),
                .int(chunk.endOffset),
                chunk.messageStartOffset.map(SQLiteBind.int) ?? .null,
                chunk.messageEndOffset.map(SQLiteBind.int) ?? .null,
                chunk.sectionPath.map(SQLiteBind.text) ?? .null,
                .text(chunk.text),
                chunk.contentHash.map(SQLiteBind.text) ?? .null,
                ftsRowid.map(SQLiteBind.int64) ?? .null,
                .text(chunk.createdAtText),
                .text(chunk.updatedAtText)
            ]
        )
    }
}
