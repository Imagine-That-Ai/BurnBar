import Foundation
import OpenBurnBarKernel
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Wave 2.1c-iv: storage semantics for the search-index app lane. Every
/// test pins the same promise — the daemon stores the app-finalized write
/// set verbatim inside one transaction and assigns only the FTS `rowid`
/// mapping — against the migrator's exact DDL, not the daemon bootstrap's
/// TEXT-date approximation.
final class BurnBarSearchIndexLaneTests: XCTestCase {
    // MARK: - Harness

    private func makeStore() throws -> BurnBarProjectCodeMemoryStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIndexLaneTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let store = try BurnBarProjectCodeMemoryStore(
            databasePath: root.appendingPathComponent("openburnbar.sqlite").path,
            logger: BurnBarDaemonLogger(category: "search-index-lane-test")
        )
        try store.searchIndexTestCompleteSchema()
        return store
    }

    private func fetchStrings(
        _ store: BurnBarProjectCodeMemoryStore,
        _ sql: String,
        _ binds: [BurnBarProjectCodeMemoryStore.SQLiteBind] = []
    ) throws -> [[String?]] {
        try store.queryRows(sql, binds).map { $0.values }
    }

    private func fetchCount(
        _ store: BurnBarProjectCodeMemoryStore,
        _ sql: String,
        _ binds: [BurnBarProjectCodeMemoryStore.SQLiteBind] = []
    ) throws -> Int {
        Int(try store.queryRows(sql, binds).first?.int64(0) ?? -1)
    }

    private func assertInvalidRequest(
        _ store: BurnBarProjectCodeMemoryStore,
        _ request: BurnBarSearchIndexApplyRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try store.searchIndexApplyAppLane(request)
            XCTFail("expected invalidRequest", file: file, line: line)
        } catch let error as BurnBarProjectCodeMemoryStore.SearchIndexAppLaneError {
            guard case .invalidRequest = error else {
                XCTFail("unexpected lane error \(error)", file: file, line: line)
                return
            }
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private static func document(id: String = "doc-1") -> BurnBarSearchIndexDocumentRow {
        BurnBarSearchIndexDocumentRow(
            id: id,
            sourceKind: "conversation",
            sourceID: "source-1",
            sourceVersionID: "v1",
            provider: "test-provider",
            projectName: "test-project",
            title: "Test title",
            subtitle: "Test subtitle",
            bodyPreview: "preview",
            sourceUpdatedAtText: "2026-09-23 04:00:00.000",
            indexedAtText: "2026-09-23 05:00:00.000",
            contentHash: "hash-1",
            createdAtText: "2026-09-23 05:00:00.000",
            updatedAtText: "2026-09-23 06:00:00.000"
        )
    }

    private static func chunk(
        id: String = "chunk-1",
        documentID: String = "doc-1",
        ordinal: Int = 0
    ) -> BurnBarSearchIndexChunkRow {
        BurnBarSearchIndexChunkRow(
            id: id,
            documentID: documentID,
            sourceKind: "conversation",
            sourceID: "source-1",
            ordinal: ordinal,
            startOffset: 0,
            endOffset: 11,
            messageStartOffset: 0,
            messageEndOffset: 11,
            sectionPath: "root",
            text: "hello world",
            contentHash: "chunk-hash-1",
            createdAtText: "2026-09-23 05:00:00.000",
            updatedAtText: "2026-09-23 06:00:00.000"
        )
    }

    private static func mutations(
        documentID: String = "doc-1",
        deletes: [String] = [],
        inserts: [BurnBarSearchIndexChunkRow] = []
    ) -> BurnBarSearchIndexChunkMutations {
        BurnBarSearchIndexChunkMutations(
            documentID: documentID,
            ftsTitle: "Test title",
            ftsProjectName: "test-project",
            ftsProvider: "test-provider",
            chunkIDsToDelete: deletes,
            chunksToInsert: inserts
        )
    }

    // MARK: - Document upsert

    func testDocumentUpsertStoresRowVerbatim() throws {
        let store = try makeStore()
        let response = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: Self.document()))
        XCTAssertEqual(response.documentsUpserted, 1)
        XCTAssertEqual(response.documentsDeleted, 0)
        XCTAssertEqual(response.chunksAdded, 0)
        XCTAssertEqual(response.chunksDeleted, 0)

        let rows = try fetchStrings(
            store,
            "SELECT id, sourceKind, sourceID, sourceVersionID, provider, projectName, title, subtitle, bodyPreview, sourceUpdatedAt, indexedAt, contentHash, createdAt, updatedAt FROM search_documents",
            []
        )
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row[0], "doc-1")
        XCTAssertEqual(row[1], "conversation")
        XCTAssertEqual(row[2], "source-1")
        XCTAssertEqual(row[3], "v1")
        XCTAssertEqual(row[4], "test-provider")
        XCTAssertEqual(row[5], "test-project")
        XCTAssertEqual(row[6], "Test title")
        XCTAssertEqual(row[7], "Test subtitle")
        XCTAssertEqual(row[8], "preview")
        XCTAssertEqual(row[9], "2026-09-23 04:00:00.000")
        XCTAssertEqual(row[10], "2026-09-23 05:00:00.000")
        XCTAssertEqual(row[11], "hash-1")
        XCTAssertEqual(row[12], "2026-09-23 05:00:00.000")
        XCTAssertEqual(row[13], "2026-09-23 06:00:00.000")

        // GRDB `Date` storage is TEXT (`yyyy-MM-dd HH:mm:ss.SSS`): the
        // daemon binds the validated stamps verbatim, so RPC-written
        // rows share the storage class — and the lexicographic order —
        // of every legacy row.
        let storageClass = try fetchStrings(store, "SELECT typeof(indexedAt), typeof(createdAt) FROM search_documents", [])
        XCTAssertEqual(storageClass.first, ["text", "text"])

        // The migrator's document-FTS trigger fires for daemon writes
        // exactly as it did for the app's pre-cutover writes.
        let mirror = try fetchStrings(
            store,
            "SELECT documentID, title, subtitle, bodyPreview, projectName, provider FROM search_documents_fts",
            []
        )
        XCTAssertEqual(mirror, [["doc-1", "Test title", "Test subtitle", "preview", "test-project", "test-provider"]])
    }

    func testDocumentUpsertOnConflictUpdatesRowButKeepsCreatedAt() throws {
        let store = try makeStore()
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: Self.document()))
        var updated = Self.document()
        updated = BurnBarSearchIndexDocumentRow(
            id: updated.id,
            sourceKind: updated.sourceKind,
            sourceID: updated.sourceID,
            sourceVersionID: "v2",
            provider: updated.provider,
            projectName: updated.projectName,
            title: "Retitled",
            subtitle: updated.subtitle,
            bodyPreview: "preview-2",
            sourceUpdatedAtText: updated.sourceUpdatedAtText,
            indexedAtText: "2026-09-23 05:30:00.000",
            contentHash: "hash-2",
            createdAtText: "2026-09-23 09:00:00.000",
            updatedAtText: "2026-09-23 07:00:00.000"
        )
        let response = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: updated))
        XCTAssertEqual(response.documentsUpserted, 1)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_documents", []), 1)

        let rows = try fetchStrings(
            store,
            "SELECT title, sourceVersionID, bodyPreview, indexedAt, contentHash, createdAt, updatedAt FROM search_documents WHERE id = 'doc-1'",
            []
        )
        // `createdAt` is not in the ON CONFLICT SET list: the first
        // write wins, matching the app's pre-cutover upsert.
        XCTAssertEqual(rows.first, [
            "Retitled",
            "v2",
            "preview-2",
            "2026-09-23 05:30:00.000",
            "hash-2",
            "2026-09-23 05:00:00.000",
            "2026-09-23 07:00:00.000"
        ])

        // The content-gated update trigger re-mirrors on title change.
        let mirror = try fetchStrings(store, "SELECT COUNT(*), MAX(title) FROM search_documents_fts", [])
        XCTAssertEqual(mirror.first, ["1", "Retitled"])
    }

    // MARK: - Chunk mutations

    func testChunkMutationsRecordFTSRowidMapping() throws {
        let store = try makeStore()
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: Self.document()))
        let response = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            chunkMutations: Self.mutations(inserts: [Self.chunk(), Self.chunk(id: "chunk-2", ordinal: 1)])
        ))
        XCTAssertEqual(response.chunksAdded, 2)
        XCTAssertEqual(response.chunksDeleted, 0)

        // Every chunk row records the rowid of its own FTS row, and the
        // FTS row carries the batch context — never the chunk text twice
        // under a different column.
        let joined = try fetchStrings(
            store,
            """
            SELECT c.id, c.ordinal, c.messageStartOffset, c.sectionPath, c.contentHash, f.title, f.chunkText, f.projectName, f.provider
            FROM search_chunks AS c JOIN search_chunks_fts AS f ON f.rowid = c.ftsRowid
            ORDER BY c.ordinal ASC
            """,
            []
        )
        XCTAssertEqual(joined.count, 2)
        XCTAssertEqual(
            joined[0],
            ["chunk-1", "0", "0", "root", "chunk-hash-1", "Test title", "hello world", "test-project", "test-provider"]
        )
        XCTAssertEqual(joined[1][0], "chunk-2")
        XCTAssertEqual(joined[1][1], "1")
    }

    func testChunkDeletesRemoveChunkAndFTSRow() throws {
        let store = try makeStore()
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: Self.document()))
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            chunkMutations: Self.mutations(inserts: [Self.chunk(), Self.chunk(id: "chunk-2", ordinal: 1)])
        ))
        let response = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            chunkMutations: Self.mutations(deletes: ["chunk-1"])
        ))
        XCTAssertEqual(response.chunksDeleted, 1)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks", []), 1)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks_fts", []), 1)
        let remaining = try fetchStrings(store, "SELECT chunkID FROM search_chunks_fts", [])
        XCTAssertEqual(remaining, [["chunk-2"]])
    }

    func testChunkDeleteFallsBackToScanForLegacyNullMapping() throws {
        let store = try makeStore()
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: Self.document()))
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            chunkMutations: Self.mutations(inserts: [Self.chunk()])
        ))
        // A pre-v55 row the backfill never mapped: NULL ftsRowid with a
        // live FTS row. The delete must still reach the FTS row.
        try store.execute("UPDATE search_chunks SET ftsRowid = NULL WHERE id = 'chunk-1'", [])
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            chunkMutations: Self.mutations(deletes: ["chunk-1"])
        ))
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks", []), 0)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks_fts", []), 0)
    }

    // MARK: - Document delete

    func testDeleteDocumentsRemovesDocumentsChunksAndFTS() throws {
        let store = try makeStore()
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: Self.document()))
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            chunkMutations: Self.mutations(inserts: [Self.chunk()])
        ))
        var other = Self.document(id: "doc-2")
        other = BurnBarSearchIndexDocumentRow(
            id: other.id,
            sourceKind: other.sourceKind,
            sourceID: "source-2",
            sourceVersionID: other.sourceVersionID,
            provider: other.provider,
            projectName: other.projectName,
            title: other.title,
            subtitle: other.subtitle,
            bodyPreview: other.bodyPreview,
            sourceUpdatedAtText: other.sourceUpdatedAtText,
            indexedAtText: other.indexedAtText,
            contentHash: other.contentHash,
            createdAtText: other.createdAtText,
            updatedAtText: other.updatedAtText
        )
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: other))
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            chunkMutations: Self.mutations(
                documentID: "doc-2",
                inserts: [Self.chunk(id: "chunk-other", documentID: "doc-2")]
            )
        ))

        let response = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            documentDelete: BurnBarSearchIndexDeleteDocuments(sourceKind: "conversation", sourceID: "source-1")
        ))
        XCTAssertEqual(response.documentsDeleted, 1)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_documents", []), 1)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks", []), 1)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks_fts", []), 1)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_documents_fts", []), 1)
        let remainingDoc = try fetchStrings(store, "SELECT id FROM search_documents", [])
        XCTAssertEqual(remainingDoc, [["doc-2"]])
        let remainingChunk = try fetchStrings(store, "SELECT chunkID FROM search_chunks_fts", [])
        XCTAssertEqual(remainingChunk, [["chunk-other"]])
    }

    // MARK: - Validation

    func testValidationRejectsMalformedAppliesBeforeAnyWrite() throws {
        let store = try makeStore()
        // Fully empty.
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest())
        // Empty mutations block alongside no other operation.
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest(chunkMutations: Self.mutations()))
        // Unknown source kinds fail loudly instead of being stored.
        assertInvalidRequest(
            store,
            BurnBarSearchIndexApplyRequest(documentDelete: BurnBarSearchIndexDeleteDocuments(
                sourceKind: "carrier_pigeon",
                sourceID: "source-1"
            ))
        )
        // Empty identities.
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest(chunkMutations: Self.mutations(
            documentID: "",
            deletes: ["chunk-1"]
        )))
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest(chunkMutations: Self.mutations(
            deletes: ["", "chunk-1"]
        )))
        // Chunk rows must belong to the batch document.
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest(chunkMutations: Self.mutations(
            inserts: [Self.chunk(documentID: "doc-other")]
        )))
        // Offsets must be a valid range.
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest(chunkMutations: Self.mutations(
            inserts: [BurnBarSearchIndexChunkRow(
                id: "chunk-bad",
                documentID: "doc-1",
                sourceKind: "conversation",
                sourceID: "source-1",
                ordinal: 0,
                startOffset: 12,
                endOffset: 4,
                text: "inverted",
                createdAtText: "2026-09-23 05:00:00.000",
                updatedAtText: "2026-09-23 06:00:00.000"
            )]
        )))
        // ISO 8601 is a valid instant but the wrong wire format: the
        // columns order lexicographically, so only GRDB text is stored.
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest(documentUpsert: BurnBarSearchIndexDocumentRow(
            id: "doc-iso",
            sourceKind: "conversation",
            sourceID: "source-1",
            sourceVersionID: "v1",
            title: "ISO",
            indexedAtText: "2026-09-23T05:00:00.000Z",
            createdAtText: "2026-09-23 05:00:00.000",
            updatedAtText: "2026-09-23 06:00:00.000"
        )))
        // Runaway batches are rejected before the transaction opens.
        var oversized: [BurnBarSearchIndexChunkRow] = []
        oversized.reserveCapacity(BurnBarProjectCodeMemoryStore.searchIndexAppLaneMaxChunksPerApply + 1)
        for ordinal in 0...BurnBarProjectCodeMemoryStore.searchIndexAppLaneMaxChunksPerApply {
            oversized.append(Self.chunk(id: "chunk-\(ordinal)", ordinal: ordinal))
        }
        assertInvalidRequest(store, BurnBarSearchIndexApplyRequest(chunkMutations: Self.mutations(inserts: oversized)))

        // Validation precedes the transaction: every rejection above
        // left the tables untouched.
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_documents", []), 0)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks", []), 0)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks_fts", []), 0)
    }

    // MARK: - Atomicity and ordering

    func testApplyIsAtomicAcrossOperations() throws {
        let store = try makeStore()
        // Two chunks sharing (documentID, ordinal) violate the
        // migrator's unique index mid-transaction: the document upsert
        // in the same apply must roll back with them.
        do {
            _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
                documentUpsert: Self.document(),
                chunkMutations: Self.mutations(inserts: [
                    Self.chunk(),
                    Self.chunk(id: "chunk-clash", ordinal: 0)
                ])
            ))
            XCTFail("expected a unique violation")
        } catch {
            XCTAssertFalse(error is BurnBarProjectCodeMemoryStore.SearchIndexAppLaneError)
        }
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_documents", []), 0)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks", []), 0)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_chunks_fts", []), 0)
        XCTAssertEqual(try fetchCount(store, "SELECT COUNT(*) FROM search_documents_fts", []), 0)
    }

    func testCombinedApplyDeletesBeforeItUpserts() throws {
        let store = try makeStore()
        _ = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(documentUpsert: Self.document()))
        var replacement = Self.document()
        replacement = BurnBarSearchIndexDocumentRow(
            id: replacement.id,
            sourceKind: replacement.sourceKind,
            sourceID: replacement.sourceID,
            sourceVersionID: "v2",
            provider: replacement.provider,
            projectName: replacement.projectName,
            title: "Replaced",
            subtitle: replacement.subtitle,
            bodyPreview: replacement.bodyPreview,
            sourceUpdatedAtText: replacement.sourceUpdatedAtText,
            indexedAtText: replacement.indexedAtText,
            contentHash: replacement.contentHash,
            createdAtText: replacement.createdAtText,
            updatedAtText: "2026-09-23 09:00:00.000"
        )
        let response = try store.searchIndexApplyAppLane(BurnBarSearchIndexApplyRequest(
            documentUpsert: replacement,
            documentDelete: BurnBarSearchIndexDeleteDocuments(sourceKind: "conversation", sourceID: "source-1")
        ))
        XCTAssertEqual(response.documentsDeleted, 1)
        XCTAssertEqual(response.documentsUpserted, 1)
        let rows = try fetchStrings(store, "SELECT COUNT(*), MAX(title) FROM search_documents", [])
        XCTAssertEqual(rows.first, ["1", "Replaced"])
    }
}
