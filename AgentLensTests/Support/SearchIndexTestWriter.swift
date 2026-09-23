import Foundation
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - Local search index writer (test double)
//
// Wave 2.1c-iv: production search-index writes go through the daemon
// (single writer, ADR-005). Tests that need a working search store
// without a live daemon inject this double, which performs the exact
// pre-cutover local semantics — the same statements, in the same order —
// against the test queue. Test files are exempt from the dual-writer
// grep, so the legacy SQL lives here and only here.
//
// Wire timestamps are GRDB text; the double binds them verbatim, exactly
// as the daemon lane does (same bytes the pre-cutover GRDB `Date`
// arguments rendered, via the same canonical renderer).

final class LocalSearchIndexWriter: SearchIndexWriter {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func apply(_ request: BurnBarSearchIndexApplyRequest) async throws -> BurnBarSearchIndexApplyResponse {
        try await dbQueue.write { db in
            var documentsDeleted = 0
            var documentsUpserted = 0
            var chunksAdded = 0
            var chunksDeleted = 0
            if let documentDelete = request.documentDelete {
                documentsDeleted = try Self.applyDocumentDelete(db: db, delete: documentDelete)
            }
            if let documentUpsert = request.documentUpsert {
                try Self.applyDocumentUpsert(db: db, document: documentUpsert)
                documentsUpserted = 1
            }
            if let chunkMutations = request.chunkMutations {
                let counts = try Self.applyChunkMutations(db: db, mutations: chunkMutations)
                chunksAdded = counts.added
                chunksDeleted = counts.deleted
            }
            return BurnBarSearchIndexApplyResponse(
                documentsUpserted: documentsUpserted,
                documentsDeleted: documentsDeleted,
                chunksAdded: chunksAdded,
                chunksDeleted: chunksDeleted
            )
        }
    }

    private static func applyDocumentUpsert(db: Database, document: BurnBarSearchIndexDocumentRow) throws {
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
                document.sourceKind,
                document.sourceID,
                document.sourceVersionID,
                document.provider,
                document.projectName,
                document.title,
                document.subtitle,
                document.bodyPreview,
                document.sourceUpdatedAtText,
                document.indexedAtText,
                document.contentHash,
                document.createdAtText,
                document.updatedAtText
            ]
        )
    }

    private static func applyDocumentDelete(db: Database, delete: BurnBarSearchIndexDeleteDocuments) throws -> Int {
        let documentIDs = try String.fetchAll(
            db,
            sql: "SELECT id FROM search_documents WHERE sourceKind = ? AND sourceID = ?",
            arguments: [delete.sourceKind, delete.sourceID]
        )
        for documentID in documentIDs {
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
                try db.execute(sql: "DELETE FROM search_chunks_fts WHERE chunkID = ?", arguments: [chunkID])
            }
        }
        try db.execute(
            sql: "DELETE FROM search_documents WHERE sourceKind = ? AND sourceID = ?",
            arguments: [delete.sourceKind, delete.sourceID]
        )
        return db.changesCount
    }

    private static func applyChunkMutations(
        db: Database,
        mutations: BurnBarSearchIndexChunkMutations
    ) throws -> (added: Int, deleted: Int) {
        for chunkID in mutations.chunkIDsToDelete {
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
            try db.execute(sql: "DELETE FROM search_chunks WHERE id = ?", arguments: [chunkID])
        }
        for chunk in mutations.chunksToInsert {
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [chunk.id, chunk.documentID, mutations.ftsTitle, chunk.text, mutations.ftsProjectName, mutations.ftsProvider]
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
                    chunk.sourceKind,
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
                    chunk.createdAtText,
                    chunk.updatedAtText
                ]
            )
        }
        return (added: mutations.chunksToInsert.count, deleted: mutations.chunkIDsToDelete.count)
    }
}

/// Stands in for a daemon that is unreachable: every write throws, proving the
/// store fails closed (no local write, no silent success).
struct ThrowingSearchIndexWriter: SearchIndexWriter {
    struct Boom: Error {}

    func apply(_ request: BurnBarSearchIndexApplyRequest) async throws -> BurnBarSearchIndexApplyResponse {
        throw Boom()
    }
}

/// Records the RPC requests the store issues, so cutover tests can assert the
/// exact app→daemon mapping without a live socket.
final class RecordingSearchIndexWriter: SearchIndexWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _applies: [BurnBarSearchIndexApplyRequest] = []

    var applies: [BurnBarSearchIndexApplyRequest] {
        lock.withLock { _applies }
    }

    func apply(_ request: BurnBarSearchIndexApplyRequest) async throws -> BurnBarSearchIndexApplyResponse {
        lock.withLock { _applies.append(request) }
        return BurnBarSearchIndexApplyResponse(
            documentsUpserted: request.documentUpsert == nil ? 0 : 1,
            documentsDeleted: request.documentDelete == nil ? 0 : 1,
            chunksAdded: request.chunkMutations?.chunksToInsert.count ?? 0,
            chunksDeleted: request.chunkMutations?.chunkIDsToDelete.count ?? 0
        )
    }
}
