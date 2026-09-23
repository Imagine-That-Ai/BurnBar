import OpenBurnBarEngine
import Foundation
import SQLite3
@testable import OpenBurnBarDaemon
import XCTest

final class BurnBarIndexedSearchServiceTests: XCTestCase {
    func test_shouldPerformSemanticSearch_skipsLookupPrecisionQueries() {
        let request = BurnBarSearchQueryRequest(
            query: "Xiomara",
            resultLimit: 5,
            queryEmbedding: [0.1, 0.2, 0.3],
            embeddingDimension: 3,
            embeddingDistanceMetric: .cosine
        )
        let plan = BurnBarSearchPlan.plan(userText: request.query)

        XCTAssertFalse(
            BurnBarIndexedSearchService.shouldPerformSemanticSearch(
                plan: plan,
                query: request,
                semanticEnabled: true
            )
        )
    }

    func test_shouldPerformSemanticSearch_allowsBroaderQueriesWithEmbeddings() {
        let request = BurnBarSearchQueryRequest(
            query: "employee onboarding playbook",
            resultLimit: 5,
            queryEmbedding: [0.1, 0.2, 0.3],
            embeddingDimension: 3,
            embeddingDistanceMetric: .cosine
        )
        let plan = BurnBarSearchPlan.plan(userText: request.query)

        XCTAssertTrue(
            BurnBarIndexedSearchService.shouldPerformSemanticSearch(
                plan: plan,
                query: request,
                semanticEnabled: true
            )
        )
    }

    func test_searchCompletesWhenLexicalPathReentersDatabaseQueue() async throws {
        let harness = try IndexedSearchHarness()
        defer { harness.cleanup() }

        let result = try await withSearchTimeout {
            try harness.service.search(
                query: BurnBarSearchQueryRequest(query: "needle", resultLimit: 5)
            )
        }

        XCTAssertEqual(result.hits.map(\.chunkID), ["chunk-1"])
        XCTAssertNil(result.aggregateOccurrenceCount)
    }

    func test_searchCompletesWhenAggregatePathReentersDatabaseQueue() async throws {
        let harness = try IndexedSearchHarness()
        defer { harness.cleanup() }

        let result = try await withSearchTimeout {
            try harness.service.search(
                query: BurnBarSearchQueryRequest(query: "how many times did I say \"needle\"", resultLimit: 5)
            )
        }

        XCTAssertEqual(result.aggregateOccurrenceCount, 2)
        XCTAssertEqual(result.hits.map(\.chunkID), ["chunk-1"])
    }

    private func withSearchTimeout<T: Sendable>(
        seconds: UInt64 = 2,
        operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                throw NSError(
                    domain: "BurnBarIndexedSearchServiceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Indexed search did not complete within \(seconds)s; possible SQLite queue self-deadlock."]
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Wave 2.1c-ii: the vector-snapshot app lane stores app-finalized rows
/// verbatim and rejects malformed rows before storage.
final class BurnBarIndexedSearchVectorSnapshotAppLaneTests: XCTestCase {
    func testVectorSnapshotUpsertAppLaneStoresRowVerbatim() throws {
        let harness = try VectorSnapshotAppLaneHarness()
        defer { harness.cleanup() }

        let response = try harness.service.vectorSnapshotUpsertAppLane(harness.validRequest())
        XCTAssertEqual(response.embeddingVersionID, "version-1")
        XCTAssertEqual(response.backendID, "usearch-hnsw")

        let row = try XCTUnwrap(
            harness.fetchRow(versionID: "version-1", backendID: "usearch-hnsw"),
            "upsert must persist exactly one readable row"
        )
        XCTAssertEqual(row["state"], "ready")
        XCTAssertEqual(row["fingerprint"], "fp-9f2c")
        XCTAssertEqual(row["dimensions"], "1536")
        XCTAssertEqual(
            row["distanceMetric"],
            "dot_product",
            "the app spelling is stored verbatim, never reinterpreted as the daemon enum's `dotProduct`"
        )
        XCTAssertEqual(row["vectorCount"], "12000")
        XCTAssertEqual(row["storageRelativePath"], "snapshots/version-1/usearch-hnsw/gen-7")
        XCTAssertEqual(row["fileBytes"], "48234496")
        XCTAssertEqual(row["backendVersion"], "usearch-2.17")
        XCTAssertNil(row["errorCode"])
        XCTAssertNil(row["errorMessage"])
        XCTAssertEqual(row["createdAt"], "2026-06-15 15:06:40.000")
        XCTAssertEqual(row["updatedAt"], "2026-06-15 15:08:20.000")
        XCTAssertEqual(row["lastBuiltAt"], "2026-06-15 15:08:20.000")
    }

    func testVectorSnapshotUpsertAppLaneOverwritesExistingRow() throws {
        let harness = try VectorSnapshotAppLaneHarness()
        defer { harness.cleanup() }

        _ = try harness.service.vectorSnapshotUpsertAppLane(harness.validRequest())
        var evolved = harness.validRequest()
        evolved = BurnBarVectorIndexSnapshotUpsertRequest(
            embeddingVersionID: evolved.embeddingVersionID,
            backendID: evolved.backendID,
            state: "stale",
            fingerprint: "fp-evolved",
            dimensions: evolved.dimensions,
            distanceMetric: evolved.distanceMetric,
            vectorCount: 500,
            storageRelativePath: evolved.storageRelativePath,
            fileBytes: 1024,
            backendVersion: evolved.backendVersion,
            createdAt: evolved.createdAt,
            updatedAt: "2026-06-16T10:00:00Z"
        )
        _ = try harness.service.vectorSnapshotUpsertAppLane(evolved)

        XCTAssertEqual(harness.rowCount(), 1, "re-upsert must overwrite, not duplicate")
        let row = try XCTUnwrap(harness.fetchRow(versionID: "version-1", backendID: "usearch-hnsw"))
        XCTAssertEqual(row["state"], "stale")
        XCTAssertEqual(row["fingerprint"], "fp-evolved")
        XCTAssertEqual(row["vectorCount"], "500")
        XCTAssertEqual(row["updatedAt"], "2026-06-16 10:00:00.000")
    }

    func testVectorSnapshotUpsertAppLaneRejectsInvalidRequests() throws {
        let harness = try VectorSnapshotAppLaneHarness()
        defer { harness.cleanup() }
        let base = harness.validRequest()

        let cases: [(String, BurnBarVectorIndexSnapshotUpsertRequest)] = [
            ("blank version", harness.mutating(base) {
                BurnBarVectorIndexSnapshotUpsertRequest(
                    embeddingVersionID: "  ",
                    backendID: $0.backendID,
                    state: $0.state,
                    fingerprint: $0.fingerprint,
                    dimensions: $0.dimensions,
                    distanceMetric: $0.distanceMetric,
                    vectorCount: $0.vectorCount,
                    fileBytes: $0.fileBytes,
                    backendVersion: $0.backendVersion,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt
                )
            }),
            ("unknown state", harness.mutating(base, state: "archived")),
            ("blank metric", harness.mutating(base, distanceMetric: "")),
            ("traversal path", harness.mutating(base, storageRelativePath: "../escape/gen-1")),
            ("absolute path", harness.mutating(base, storageRelativePath: "/tmp/evil")),
            ("zero dimensions", harness.mutating(base, dimensions: 0)),
            ("negative count", harness.mutating(base, vectorCount: -1)),
            ("bad timestamp", harness.mutating(base, updatedAt: "not-a-date"))
        ]
        for (name, request) in cases {
            XCTAssertThrowsError(
                try harness.service.vectorSnapshotUpsertAppLane(request),
                name,
                { error in
                    guard case BurnBarIndexedSearchService.VectorSnapshotAppLaneError.invalidRequest = error else {
                        XCTFail("\(name) must throw invalidRequest, got \(error)")
                        return
                    }
                }
            )
        }
        XCTAssertEqual(harness.rowCount(), 0, "rejected rows must never reach storage")
    }
}

private final class VectorSnapshotAppLaneHarness: @unchecked Sendable {
    let tempDir: URL
    let dbPath: String
    let service: BurnBarIndexedSearchService

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-vector-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("openburnbar.sqlite", isDirectory: false)
        dbPath = dbURL.path
        try Self.createDatabase(at: dbURL)
        service = try BurnBarIndexedSearchService(
            databasePath: dbURL.path,
            logger: BurnBarDaemonLogger(category: "vector-snapshot-test")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func validRequest() -> BurnBarVectorIndexSnapshotUpsertRequest {
        BurnBarVectorIndexSnapshotUpsertRequest(
            embeddingVersionID: "version-1",
            backendID: "usearch-hnsw",
            state: "ready",
            fingerprint: "fp-9f2c",
            dimensions: 1536,
            distanceMetric: "dot_product",
            vectorCount: 12_000,
            storageRelativePath: "snapshots/version-1/usearch-hnsw/gen-7",
            fileBytes: 48_234_496,
            backendVersion: "usearch-2.17",
            createdAt: "2026-06-15T15:06:40Z",
            updatedAt: "2026-06-15T15:08:20Z",
            lastBuiltAt: "2026-06-15T15:08:20Z"
        )
    }

    func mutating(
        _ base: BurnBarVectorIndexSnapshotUpsertRequest,
        state: String? = nil,
        distanceMetric: String? = nil,
        storageRelativePath: String? = nil,
        dimensions: Int? = nil,
        vectorCount: Int? = nil,
        updatedAt: String? = nil
    ) -> BurnBarVectorIndexSnapshotUpsertRequest {
        BurnBarVectorIndexSnapshotUpsertRequest(
            embeddingVersionID: base.embeddingVersionID,
            backendID: base.backendID,
            state: state ?? base.state,
            fingerprint: base.fingerprint,
            dimensions: dimensions ?? base.dimensions,
            distanceMetric: distanceMetric ?? base.distanceMetric,
            vectorCount: vectorCount ?? base.vectorCount,
            storageRelativePath: storageRelativePath ?? base.storageRelativePath,
            fileBytes: base.fileBytes,
            backendVersion: base.backendVersion,
            errorCode: base.errorCode,
            errorMessage: base.errorMessage,
            createdAt: base.createdAt,
            updatedAt: updatedAt ?? base.updatedAt,
            lastBuiltAt: base.lastBuiltAt
        )
    }

    func mutating(
        _ base: BurnBarVectorIndexSnapshotUpsertRequest,
        _ rebuild: (BurnBarVectorIndexSnapshotUpsertRequest) -> BurnBarVectorIndexSnapshotUpsertRequest
    ) -> BurnBarVectorIndexSnapshotUpsertRequest {
        rebuild(base)
    }

    func rowCount() -> Int {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM vector_index_snapshots", -1, &stmt, nil) == SQLITE_OK else {
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// Raw column readback. NULL columns are absent from the dictionary, so
    /// `row["errorCode"]` is a plain `String?` and `XCTAssertNil` pins NULL —
    /// the qualified-optional form would compare `String??` and never compile.
    func fetchRow(versionID: String, backendID: String) -> [String: String]? {
        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT state, fingerprint, dimensions, distanceMetric, vectorCount,
               storageRelativePath, fileBytes, backendVersion, errorCode, errorMessage,
               createdAt, updatedAt, lastBuiltAt
        FROM vector_index_snapshots
        WHERE embeddingVersionID = ? AND backendID = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, versionID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(stmt, 2, backendID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
                  let bytes = sqlite3_column_text(stmt, index) else { return nil }
            return String(cString: bytes)
        }
        var row: [String: String] = [
            "dimensions": String(sqlite3_column_int64(stmt, 2)),
            "vectorCount": String(sqlite3_column_int64(stmt, 4)),
            "fileBytes": String(sqlite3_column_int64(stmt, 6))
        ]
        let names = [
            "state", "fingerprint", nil, "distanceMetric", nil,
            "storageRelativePath", nil, "backendVersion", "errorCode", "errorMessage",
            "createdAt", "updatedAt", "lastBuiltAt"
        ]
        for (index, name) in names.enumerated() {
            guard let name, let value = text(Int32(index)) else { continue }
            row[name] = value
        }
        return row
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "VectorSnapshotAppLaneHarness", code: 1)
        }
        defer { sqlite3_close(db) }
        // Mirrors the migrator's v34 `vector_index_snapshots` shape (column
        // names and nullability); the lane upsert names every column, so the
        // test pins names, not ordinal positions.
        var error: UnsafeMutablePointer<CChar>?
        let sql = """
        CREATE TABLE vector_index_snapshots (
            embeddingVersionID TEXT NOT NULL,
            backendID TEXT NOT NULL,
            state TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            distanceMetric TEXT NOT NULL,
            vectorCount INTEGER NOT NULL DEFAULT 0,
            storageRelativePath TEXT,
            fileBytes INTEGER NOT NULL DEFAULT 0,
            backendVersion TEXT NOT NULL,
            errorCode TEXT,
            errorMessage TEXT,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            lastBuiltAt TEXT,
            PRIMARY KEY (embeddingVersionID, backendID)
        );
        """
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            if let error {
                sqlite3_free(error)
            }
            throw NSError(domain: "VectorSnapshotAppLaneHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

private final class IndexedSearchHarness: @unchecked Sendable {
    let tempDir: URL
    let service: BurnBarIndexedSearchService

    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-indexed-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("openburnbar.sqlite", isDirectory: false)
        try Self.createDatabase(at: dbURL)
        service = try BurnBarIndexedSearchService(
            databasePath: dbURL.path,
            logger: BurnBarDaemonLogger(category: "indexed-search-test")
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "IndexedSearchHarness", code: 1)
        }
        defer { sqlite3_close(db) }

        try exec(db, """
        CREATE TABLE search_documents (
            id TEXT PRIMARY KEY,
            sourceKind TEXT NOT NULL,
            sourceID TEXT NOT NULL,
            title TEXT NOT NULL,
            provider TEXT,
            projectName TEXT,
            indexedAt TEXT NOT NULL,
            sourceUpdatedAt TEXT
        );
        CREATE TABLE search_chunks (
            id TEXT PRIMARY KEY,
            documentID TEXT NOT NULL,
            ordinal INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE search_chunks_fts USING fts5(
            chunkID UNINDEXED,
            documentID UNINDEXED,
            text,
            fullText
        );
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            provider TEXT,
            projectName TEXT,
            fullText TEXT NOT NULL,
            startTime TEXT,
            endTime TEXT,
            fileModifiedAt TEXT,
            indexedAt TEXT
        );
        INSERT INTO search_documents (
            id, sourceKind, sourceID, title, provider, projectName, indexedAt, sourceUpdatedAt
        ) VALUES (
            'doc-1', 'conversation', 'conv-1', 'Needle Debugging', 'codex', 'BurnBar',
            '2026-04-30T12:00:00Z', '2026-04-30T12:00:00Z'
        );
        INSERT INTO search_chunks (id, documentID, ordinal) VALUES ('chunk-1', 'doc-1', 0);
        INSERT INTO search_chunks_fts (chunkID, documentID, text, fullText)
        VALUES ('chunk-1', 'doc-1', 'needle search content', 'needle search content');
        INSERT INTO conversations (
            id, provider, projectName, fullText, startTime, endTime, fileModifiedAt, indexedAt
        ) VALUES (
            'conv-1', 'codex', 'BurnBar', 'needle first needle second',
            '2026-04-30T12:00:00Z', '2026-04-30T12:00:00Z',
            '2026-04-30T12:00:00Z', '2026-04-30T12:00:00Z'
        );
        """)
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            if let error {
                sqlite3_free(error)
            }
            throw NSError(domain: "IndexedSearchHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
