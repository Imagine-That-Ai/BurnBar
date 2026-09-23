import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

/// Wave 2.1c-iv search single-writer cutover: the app builds typed daemon
/// RPC requests instead of writing `search_documents` / `search_chunks` /
/// `search_chunks_fts` directly.
///
/// These tests pin the exact app→daemon mapping (verbatim field carry,
/// GRDB-text timestamps, explicit FTS context, delete-before-insert batch
/// order), prove the local test double round-trips records identically to
/// the old local path, and prove a failed write leaves no local rows behind.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class SearchIndexSingleWriterCutoverTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(writer: any SearchIndexWriter) throws -> DataStoreCoordinator {
        let queue = try DatabaseQueue()
        return try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            searchIndexWriter: writer
        )
    }

    private func makeDocument(now: Date) -> SearchDocumentRecord {
        SearchDocumentRecord(
            id: "doc-cutover-1",
            sourceKind: .conversation,
            sourceID: "conv-cutover-1",
            sourceVersionID: "v3",
            provider: "claudeCode",
            projectName: "OpenBurnBar",
            title: "Cutover mapping",
            subtitle: "claudeCode • OpenBurnBar",
            bodyPreview: "preview text",
            sourceUpdatedAt: now.addingTimeInterval(-3600),
            indexedAt: now,
            contentHash: "hash-doc-1",
            createdAt: now,
            updatedAt: now
        )
    }

    private func makeChunk(id: String, documentID: String, ordinal: Int, now: Date) -> SearchChunkRecord {
        SearchChunkRecord(
            id: id,
            documentID: documentID,
            sourceKind: .conversation,
            sourceID: "conv-cutover-1",
            sourceVersionID: "v3",
            ordinal: ordinal,
            startOffset: ordinal * 100,
            endOffset: ordinal * 100 + 50,
            messageStartOffset: ordinal * 100 + 5,
            messageEndOffset: ordinal * 100 + 45,
            sectionPath: "turn-\(ordinal)",
            text: "chunk body \(ordinal)",
            contentHash: "hash-chunk-\(ordinal)",
            createdAt: now,
            updatedAt: now
        )
    }

    // MARK: - Upsert mapping

    func testUpsertMapsRecordToDocumentUpsertRequest() async throws {
        let writer = RecordingSearchIndexWriter()
        let store = try makeStore(writer: writer)
        let now = Date(timeIntervalSince1970: 1_750_000_000.123)
        let document = makeDocument(now: now)

        try await store.upsertSearchDocument(document)

        XCTAssertEqual(writer.applies.count, 1, "upsert must issue exactly one apply")
        let request = try XCTUnwrap(writer.applies.first)
        XCTAssertNil(request.documentDelete)
        XCTAssertNil(request.chunkMutations)
        let row = try XCTUnwrap(request.documentUpsert)
        XCTAssertEqual(row.id, "doc-cutover-1")
        XCTAssertEqual(row.sourceKind, SearchSourceKind.conversation.rawValue, "sourceKind rides verbatim as the raw string")
        XCTAssertEqual(row.sourceID, "conv-cutover-1")
        XCTAssertEqual(row.sourceVersionID, "v3")
        XCTAssertEqual(row.provider, "claudeCode")
        XCTAssertEqual(row.projectName, "OpenBurnBar")
        XCTAssertEqual(row.title, "Cutover mapping")
        XCTAssertEqual(row.subtitle, "claudeCode • OpenBurnBar")
        XCTAssertEqual(row.bodyPreview, "preview text")
        XCTAssertEqual(row.contentHash, "hash-doc-1")
        // Timestamps ride as GRDB text via the canonical on-disk renderer —
        // the exact bytes the pre-cutover path stored — never ISO 8601.
        XCTAssertEqual(row.indexedAtText, OpenBurnBarDatabase.sqliteDateString(now))
        XCTAssertEqual(row.createdAtText, OpenBurnBarDatabase.sqliteDateString(now))
        XCTAssertEqual(row.updatedAtText, OpenBurnBarDatabase.sqliteDateString(now))
        XCTAssertEqual(row.sourceUpdatedAtText, OpenBurnBarDatabase.sqliteDateString(now.addingTimeInterval(-3600)))
        XCTAssertFalse(row.indexedAtText.contains("T"), "GRDB text must not be ISO 8601 (lexicographic columns would misorder)")
    }

    func testUpsertOmitsNilOptionals() async throws {
        let writer = RecordingSearchIndexWriter()
        let store = try makeStore(writer: writer)
        let now = Date(timeIntervalSince1970: 1_750_000_050)

        try await store.upsertSearchDocument(SearchDocumentRecord(
            id: "doc-sparse",
            sourceKind: .code,
            sourceID: "file-1",
            title: "Sparse",
            indexedAt: now,
            createdAt: now,
            updatedAt: now
        ))

        let row = try XCTUnwrap(writer.applies.first?.documentUpsert)
        XCTAssertNil(row.provider)
        XCTAssertNil(row.projectName)
        XCTAssertNil(row.subtitle)
        XCTAssertNil(row.bodyPreview)
        XCTAssertNil(row.sourceUpdatedAtText)
        XCTAssertNil(row.contentHash)
        XCTAssertEqual(row.sourceVersionID, "")
    }

    // MARK: - Delete mapping

    func testDeleteMapsToDocumentDeleteRequest() async throws {
        let writer = RecordingSearchIndexWriter()
        let store = try makeStore(writer: writer)

        try await store.deleteSearchDocuments(sourceKind: .sharedArtifact, sourceID: "artifact-9")

        XCTAssertEqual(writer.applies.count, 1)
        let request = try XCTUnwrap(writer.applies.first)
        XCTAssertNil(request.documentUpsert)
        XCTAssertNil(request.chunkMutations)
        let delete = try XCTUnwrap(request.documentDelete)
        XCTAssertEqual(delete.sourceKind, "shared_artifact")
        XCTAssertEqual(delete.sourceID, "artifact-9")
    }

    // MARK: - Chunk mapping

    func testReplaceMapsChunksToChunkMutationsRequest() async throws {
        let writer = RecordingSearchIndexWriter()
        let store = try makeStore(writer: writer)
        let now = Date(timeIntervalSince1970: 1_750_000_100.456)
        let chunks = [
            makeChunk(id: "chunk-b", documentID: "doc-cutover-1", ordinal: 1, now: now),
            makeChunk(id: "chunk-a", documentID: "doc-cutover-1", ordinal: 0, now: now)
        ]

        try await store.replaceSearchChunks(
            documentID: "doc-cutover-1",
            title: "Cutover mapping",
            projectName: "OpenBurnBar",
            provider: "claudeCode",
            chunks: chunks
        )

        // No existing chunks, so no delete batch — exactly one insert apply.
        XCTAssertEqual(writer.applies.count, 1)
        let request = try XCTUnwrap(writer.applies.first)
        XCTAssertNil(request.documentUpsert)
        XCTAssertNil(request.documentDelete)
        let mutations = try XCTUnwrap(request.chunkMutations)
        XCTAssertEqual(mutations.documentID, "doc-cutover-1")
        XCTAssertEqual(mutations.ftsTitle, "Cutover mapping")
        XCTAssertEqual(mutations.ftsProjectName, "OpenBurnBar")
        XCTAssertEqual(mutations.ftsProvider, "claudeCode")
        XCTAssertTrue(mutations.chunkIDsToDelete.isEmpty)
        // Inserts are sorted by (ordinal, id) regardless of input order.
        XCTAssertEqual(mutations.chunksToInsert.map(\.id), ["chunk-a", "chunk-b"])
        let first = try XCTUnwrap(mutations.chunksToInsert.first)
        XCTAssertEqual(first.documentID, "doc-cutover-1")
        XCTAssertEqual(first.sourceKind, SearchSourceKind.conversation.rawValue)
        XCTAssertEqual(first.sourceID, "conv-cutover-1")
        XCTAssertEqual(first.sourceVersionID, "v3")
        XCTAssertEqual(first.ordinal, 0)
        XCTAssertEqual(first.startOffset, 0)
        XCTAssertEqual(first.endOffset, 50)
        XCTAssertEqual(first.messageStartOffset, 5)
        XCTAssertEqual(first.messageEndOffset, 45)
        XCTAssertEqual(first.sectionPath, "turn-0")
        XCTAssertEqual(first.text, "chunk body 0")
        XCTAssertEqual(first.contentHash, "hash-chunk-0")
        XCTAssertEqual(first.createdAtText, OpenBurnBarDatabase.sqliteDateString(now))
        XCTAssertEqual(first.updatedAtText, OpenBurnBarDatabase.sqliteDateString(now))
    }

    func testReplaceBatchesLargeInsertSets() async throws {
        let writer = RecordingSearchIndexWriter()
        let store = try makeStore(writer: writer)
        let now = Date(timeIntervalSince1970: 1_750_000_200)
        let chunks = (0..<70).map { makeChunk(id: "chunk-\($0)", documentID: "doc-big", ordinal: $0, now: now) }

        try await store.replaceSearchChunks(
            documentID: "doc-big",
            title: "Big",
            projectName: "P",
            provider: "V",
            chunks: chunks
        )

        XCTAssertEqual(writer.applies.count, 2, "70 inserts must split into 64 + 6 (one RPC per batch)")
        let counts = writer.applies.map { $0.chunkMutations?.chunksToInsert.count ?? -1 }
        XCTAssertEqual(counts, [64, 6])
        // Every batch carries the FTS context — the daemon stamps each FTS row.
        for apply in writer.applies {
            let mutations = try XCTUnwrap(apply.chunkMutations)
            XCTAssertEqual(mutations.ftsTitle, "Big")
            XCTAssertEqual(mutations.ftsProjectName, "P")
            XCTAssertEqual(mutations.ftsProvider, "V")
        }
    }

    // MARK: - Local double equivalence

    func testLocalDoubleRoundTripsDocumentAndChunks() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            searchIndexWriter: LocalSearchIndexWriter(dbQueue: queue)
        )
        let now = Date(timeIntervalSince1970: 1_750_000_300.789)
        let document = makeDocument(now: now)

        try await store.upsertSearchDocument(document)
        try await store.replaceSearchChunks(
            documentID: document.id,
            title: document.title,
            projectName: document.projectName ?? "",
            provider: document.provider ?? "",
            chunks: [
                makeChunk(id: "chunk-rt-0", documentID: document.id, ordinal: 0, now: now),
                makeChunk(id: "chunk-rt-1", documentID: document.id, ordinal: 1, now: now)
            ]
        )
        // Re-upsert under the same ID (re-projection): ON CONFLICT updates.
        let evolved = SearchDocumentRecord(
            id: document.id,
            sourceKind: document.sourceKind,
            sourceID: document.sourceID,
            sourceVersionID: "v4",
            provider: document.provider,
            projectName: document.projectName,
            title: "Cutover mapping, revised",
            subtitle: document.subtitle,
            bodyPreview: document.bodyPreview,
            sourceUpdatedAt: document.sourceUpdatedAt,
            indexedAt: now,
            contentHash: "hash-doc-2",
            createdAt: document.createdAt,
            updatedAt: now.addingTimeInterval(60)
        )
        try await store.upsertSearchDocument(evolved)

        let fetchedDocuments = try await store.fetchSearchDocuments(limit: 10)
        XCTAssertEqual(fetchedDocuments.count, 1, "re-upsert under one ID must replace, not duplicate")
        let row = try XCTUnwrap(fetchedDocuments.first)
        XCTAssertEqual(row.title, "Cutover mapping, revised")
        XCTAssertEqual(row.sourceVersionID, "v4")
        XCTAssertEqual(row.contentHash, "hash-doc-2")
        XCTAssertEqual(row.indexedAt.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        let sourceUpdatedAt = try XCTUnwrap(row.sourceUpdatedAt)
        XCTAssertEqual(
            sourceUpdatedAt.timeIntervalSince1970,
            now.addingTimeInterval(-3600).timeIntervalSince1970,
            accuracy: 0.001
        )

        let fetchedChunks = try await store.fetchSearchChunks(documentID: document.id)
        XCTAssertEqual(fetchedChunks.count, 2)
        XCTAssertEqual(fetchedChunks.map(\.id), ["chunk-rt-0", "chunk-rt-1"])
        XCTAssertEqual(fetchedChunks.first?.text, "chunk body 0")
        XCTAssertEqual(fetchedChunks.first?.sectionPath, "turn-0")

        // FTS rows exist, carry the explicit context, and link via ftsRowid.
        let fts = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid, title, projectName, provider FROM search_chunks_fts ORDER BY rowid ASC")
        }
        XCTAssertEqual(fts.count, 2)
        XCTAssertEqual(fts.first?["title"] as? String, "Cutover mapping")
        XCTAssertEqual(fts.first?["projectName"] as? String, "OpenBurnBar")
        XCTAssertEqual(fts.first?["provider"] as? String, "claudeCode")
        let linkedRowids = try await queue.read { db in
            try Int64.fetchAll(db, sql: "SELECT ftsRowid FROM search_chunks WHERE ftsRowid IS NOT NULL")
        }
        XCTAssertEqual(linkedRowids.count, 2, "every chunk row must record its FTS rowid")

        // Lexical search finds the indexed text through the FTS table.
        let matches = try await store.searchLexicalChunks(ftsQuery: "chunk body", limit: 10)
        XCTAssertEqual(matches.count, 2)
    }

    func testLocalDoubleDeleteRemovesDocumentsChunksAndFTSRows() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            searchIndexWriter: LocalSearchIndexWriter(dbQueue: queue)
        )
        let now = Date(timeIntervalSince1970: 1_750_000_400)
        let document = makeDocument(now: now)
        try await store.upsertSearchDocument(document)
        try await store.replaceSearchChunks(
            documentID: document.id,
            title: document.title,
            projectName: document.projectName ?? "",
            provider: document.provider ?? "",
            chunks: [makeChunk(id: "chunk-del-0", documentID: document.id, ordinal: 0, now: now)]
        )

        try await store.deleteSearchDocuments(sourceKind: .conversation, sourceID: "conv-cutover-1")

        let counts = try await queue.read { db -> (Int, Int, Int) in
            let documents = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM search_documents") ?? -1
            let chunks = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM search_chunks") ?? -1
            let fts = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM search_chunks_fts") ?? -1
            return (documents, chunks, fts)
        }
        XCTAssertEqual(counts.0, 0, "delete must remove the document row")
        // Chunk rows cascade from the document delete (pre-cutover behavior).
        XCTAssertEqual(counts.1, 0, "delete must remove the chunk rows")
        XCTAssertEqual(counts.2, 0, "delete must remove the FTS rows")
    }

    // MARK: - Fail closed

    func testFailedWriteLeavesNoLocalRows() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            searchIndexWriter: ThrowingSearchIndexWriter()
        )
        let now = Date(timeIntervalSince1970: 1_750_000_500)

        do {
            try await store.upsertSearchDocument(makeDocument(now: now))
            XCTFail("a throwing writer must propagate the failure")
        } catch is ThrowingSearchIndexWriter.Boom {
        }
        do {
            try await store.replaceSearchChunks(
                documentID: "doc-x",
                title: "X",
                projectName: "",
                provider: "",
                chunks: [makeChunk(id: "chunk-x", documentID: "doc-x", ordinal: 0, now: now)]
            )
            XCTFail("a throwing writer must propagate the failure")
        } catch is ThrowingSearchIndexWriter.Boom {
        }
        do {
            try await store.deleteSearchDocuments(sourceKind: .conversation, sourceID: "conv-x")
            XCTFail("a throwing writer must propagate the failure")
        } catch is ThrowingSearchIndexWriter.Boom {
        }

        let counts = try await queue.read { db -> (Int, Int, Int) in
            let documents = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM search_documents") ?? -1
            let chunks = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM search_chunks") ?? -1
            let fts = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM search_chunks_fts") ?? -1
            return (documents, chunks, fts)
        }
        XCTAssertEqual(counts.0, 0, "no document row may land when the write fails")
        XCTAssertEqual(counts.1, 0, "no chunk row may land when the write fails")
        XCTAssertEqual(counts.2, 0, "no FTS row may land when the write fails")
    }
}
