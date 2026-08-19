import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Covers the `v55_search_chunks_fts_rowid` performance fix: chunk FTS rows are
/// deleted by recorded rowid instead of `WHERE chunkID = ?` (an UNINDEXED FTS5
/// column, i.e. a full scan of the entire FTS content table per chunk), and the
/// `search_documents_fts_au` trigger only fires when indexed content actually
/// changes instead of on every routine metadata upsert.
@MainActor
final class SearchIndexFTSRowidTests: XCTestCase {

    // MARK: - Insert records the FTS rowid; deletes target it

    func test_insertedChunks_recordFTSRowid_matchingTheFTSRow() async throws {
        let (store, queue) = try makeInMemoryStore()
        let now = Date()
        let document = makeDocument(id: "doc-1", now: now)
        try await store.upsertSearchDocument(document)
        try await store.replaceSearchChunks(
            documentID: document.id,
            title: document.title,
            chunks: [
                makeChunk(id: "chunk-1", document: document, ordinal: 0, text: "alpha bravo", now: now),
                makeChunk(id: "chunk-2", document: document, ordinal: 1, text: "charlie delta", now: now)
            ]
        )

        let mappings = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, ftsRowid FROM search_chunks ORDER BY id")
        }
        XCTAssertEqual(mappings.count, 2)
        for row in mappings {
            let ftsRowid: Int64? = row["ftsRowid"]
            XCTAssertNotNil(ftsRowid, "every inserted chunk must record its FTS rowid")
        }

        let ftsRows = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid AS ftsRowid, chunkID FROM search_chunks_fts ORDER BY chunkID")
        }
        XCTAssertEqual(ftsRows.count, 2)
        for (mapping, ftsRow) in zip(mappings, ftsRows) {
            XCTAssertEqual(mapping["id"] as? String, ftsRow["chunkID"] as? String)
            let mappedRowid: Int64? = mapping["ftsRowid"]
            let indexedRowid: Int64? = ftsRow["ftsRowid"]
            XCTAssertEqual(mappedRowid, indexedRowid)
        }
    }

    func test_chunkDiffDelete_removesFTSRow_byRowid() async throws {
        let (store, queue) = try makeInMemoryStore()
        let now = Date()
        let document = makeDocument(id: "doc-1", now: now)
        try await store.upsertSearchDocument(document)
        try await store.replaceSearchChunks(
            documentID: document.id,
            title: document.title,
            chunks: [
                makeChunk(id: "chunk-1", document: document, ordinal: 0, text: "keepable text", now: now),
                makeChunk(id: "chunk-2", document: document, ordinal: 1, text: "deletable text", now: now)
            ]
        )

        _ = try await store.applySearchChunkDiff(
            documentID: document.id,
            title: document.title,
            chunks: [
                makeChunk(id: "chunk-1", document: document, ordinal: 0, text: "keepable text", now: now)
            ]
        )

        let remaining = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT chunkID FROM search_chunks_fts ORDER BY chunkID")
        }
        XCTAssertEqual(remaining, ["chunk-1"], "the removed chunk's FTS row must be deleted")
        let chunkIDs = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM search_chunks ORDER BY id")
        }
        XCTAssertEqual(chunkIDs, ["chunk-1"])
    }

    func test_legacyChunkWithNullFtsRowid_stillDeletesItsFTSRow() async throws {
        let (store, queue) = try makeInMemoryStore()
        let now = Date()
        let document = makeDocument(id: "doc-1", now: now)
        try await store.upsertSearchDocument(document)

        // Simulate a row written by a pre-v55 binary: chunk with NULL ftsRowid
        // plus its FTS row.
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_chunks (
                    id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                    startOffset, endOffset, sectionPath, text, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["legacy-chunk", "doc-1", "conversation", "source-1", "", 0, 0, 11, nil, "legacy text", "legacy-hash", now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["legacy-chunk", "doc-1", "Title", "legacy text", "", ""]
            )
        }

        try await store.replaceSearchChunks(documentID: document.id, title: document.title, chunks: [])

        let ftsCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_chunks_fts") ?? -1
        }
        XCTAssertEqual(ftsCount, 0, "legacy NULL-ftsRowid chunks must fall back to the chunkID delete path")
    }

    // MARK: - v55 migration backfill

    func test_v55Migration_backfillsFtsRowid_andSweepsOrphanFTSRows() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        var migrator = OpenBurnBarDatabase.migrator
        migrator.eraseDatabaseOnSchemaChange = false
        try migrator.migrate(queue, upTo: "v53_memory_forget_outbox")

        let now = Date()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO search_documents (
                    id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, subtitle,
                    bodyPreview, sourceUpdatedAt, indexedAt, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["doc-1", "conversation", "source-1", "", "Codex", "Proj", "Title", nil, nil, nil, now, nil, now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO search_chunks (
                    id, documentID, sourceKind, sourceID, sourceVersionID, ordinal,
                    startOffset, endOffset, sectionPath, text, contentHash, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["chunk-1", "doc-1", "conversation", "source-1", "", 0, 0, 10, nil, "hello world", "h1", now, now]
            )
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["chunk-1", "doc-1", "Title", "hello world", "Proj", "Codex"]
            )
            // Stale duplicate FTS row: same chunkID, older text. The migration
            // must preserve the row whose FTS text still matches the source chunk.
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["chunk-1", "doc-1", "Title", "stale world", "Proj", "Codex"]
            )
            // Orphan FTS row: no matching chunk. The migration sweeps it.
            try db.execute(
                sql: """
                INSERT INTO search_chunks_fts (chunkID, documentID, title, chunkText, projectName, provider)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["orphan-chunk", "doc-gone", "Old", "stranded text", "Proj", "Codex"]
            )
        }

        try migrator.migrate(queue)

        let mapping = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT ftsRowid FROM search_chunks WHERE id = 'chunk-1'")
        }
        let backfilledRowid: Int64? = mapping?["ftsRowid"]
        XCTAssertNotNil(backfilledRowid, "v55 must backfill ftsRowid for pre-existing chunks")

        let ftsRows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid AS ftsRowid, chunkID, chunkText FROM search_chunks_fts")
        }
        XCTAssertEqual(ftsRows.count, 1, "the orphan and stale duplicate FTS rows must be swept by the migration")
        XCTAssertEqual(ftsRows.first?["chunkID"] as? String, "chunk-1")
        XCTAssertEqual(ftsRows.first?["chunkText"] as? String, "hello world")
        let survivingRowid: Int64? = ftsRows.first?["ftsRowid"]
        XCTAssertEqual(survivingRowid, backfilledRowid)
    }

    // MARK: - Documents FTS trigger only fires on content change

    func test_documentMetadataOnlyUpsert_doesNotRewriteDocumentsFTSRow() async throws {
        let (store, queue) = try makeInMemoryStore()
        let now = Date()
        try await store.upsertSearchDocument(makeDocument(id: "doc-1", now: now))

        let originalRowid = try await queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM search_documents_fts WHERE documentID = 'doc-1'")
        }
        XCTAssertNotNil(originalRowid)

        // Routine reindex: only timestamps/hash change. The v55 trigger must
        // skip the delete+reinsert churn entirely.
        try await store.upsertSearchDocument(makeDocument(
            id: "doc-1",
            now: now,
            indexedAt: now.addingTimeInterval(60),
            contentHash: "different-hash"
        ))

        let rowidAfterMetadataUpsert = try await queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT rowid FROM search_documents_fts WHERE documentID = 'doc-1'")
        }
        XCTAssertEqual(rowidAfterMetadataUpsert, originalRowid, "metadata-only upserts must not rewrite the documents FTS row")

        // A genuine content change must still refresh the FTS row.
        try await store.upsertSearchDocument(makeDocument(
            id: "doc-1",
            now: now,
            title: "A Brand New Title",
            indexedAt: now.addingTimeInterval(120),
            contentHash: "different-hash"
        ))

        let refreshed = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT rowid, title FROM search_documents_fts WHERE documentID = 'doc-1'")
        }
        XCTAssertEqual(refreshed?["title"] as? String, "A Brand New Title")
        let refreshedCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM search_documents_fts WHERE documentID = 'doc-1'") ?? -1
        }
        XCTAssertEqual(refreshedCount, 1, "the content-change path must replace, not duplicate, the FTS row")
    }

    // MARK: - Conversations FTS trigger only fires on content change

    func test_conversationMetadataOnlyUpdate_doesNotRewriteConversationsFTS() async throws {
        let (_, queue) = try makeInMemoryStore()
        let now = Date()
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO conversations (id, provider, sessionId, projectName, inferredTaskTitle, fullText, indexedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: ["conv-1", "Codex", "s-1", "Proj", "Title", "full text body", now]
            )
            // Canary: remove the FTS row the insert trigger created. The gated
            // update trigger must NOT resurrect it on a metadata-only update —
            // if it does, the update re-tokenized the whole fullText.
            try db.execute(
                sql: "DELETE FROM conversations_fts WHERE rowid = (SELECT rowid FROM conversations WHERE id = 'conv-1')"
            )
            try db.execute(sql: "UPDATE conversations SET messageCount = 5 WHERE id = 'conv-1'")
        }

        let countAfterMetadataUpdate = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations_fts") ?? -1
        }
        XCTAssertEqual(countAfterMetadataUpdate, 0, "metadata-only conversation updates must not re-tokenize fullText")

        try await queue.write { db in
            try db.execute(sql: "UPDATE conversations SET fullText = 'brand new body' WHERE id = 'conv-1'")
        }
        let ftsText = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT fullText FROM conversations_fts")
        }
        XCTAssertEqual(ftsText, "brand new body", "content changes must still refresh the conversations FTS row")
    }

    // MARK: - Helpers

    private func makeInMemoryStore() throws -> (DataStore, DatabaseQueue) {
        let queue = try DatabaseQueue(path: ":memory:")
        let store = try DataStore(databaseQueue: queue, runMigrations: true)
        return (store, queue)
    }

    private func makeDocument(
        id: String,
        now: Date,
        title: String = "Title",
        indexedAt: Date? = nil,
        contentHash: String = "hash-1"
    ) -> SearchDocumentRecord {
        SearchDocumentRecord(
            id: id,
            sourceKind: .conversation,
            sourceID: "source-1",
            sourceVersionID: "",
            provider: "Codex",
            projectName: "Proj",
            title: title,
            subtitle: nil,
            bodyPreview: "preview",
            sourceUpdatedAt: nil,
            indexedAt: indexedAt ?? now,
            contentHash: contentHash,
            createdAt: now,
            updatedAt: indexedAt ?? now
        )
    }

    private func makeChunk(
        id: String,
        document: SearchDocumentRecord,
        ordinal: Int,
        text: String,
        now: Date
    ) -> SearchChunkRecord {
        SearchChunkRecord(
            id: id,
            documentID: document.id,
            sourceKind: document.sourceKind,
            sourceID: document.sourceID,
            sourceVersionID: document.sourceVersionID,
            ordinal: ordinal,
            startOffset: ordinal * 100,
            endOffset: ordinal * 100 + text.count,
            text: text,
            contentHash: "hash-\(id)",
            createdAt: now,
            updatedAt: now
        )
    }
}
