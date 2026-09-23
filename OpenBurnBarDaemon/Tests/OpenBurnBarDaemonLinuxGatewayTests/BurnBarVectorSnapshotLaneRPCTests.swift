import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Wave 2.1c-ii: dispatch coverage for the vector-snapshot app lane. Storage
/// semantics live in `BurnBarIndexedSearchVectorSnapshotAppLaneTests`; these
/// pin the RPC surface — typed envelopes, the `invalidParams` mapping for
/// validation failures, and the unavailable store.
final class BurnBarVectorSnapshotLaneRPCTests: XCTestCase {
    func testVectorSnapshotUpsertRoundTripOverRPC() async throws {
        let server = try makeServer()
        let params = """
        {"embeddingVersionID":"version-1","backendID":"usearch-hnsw","state":"ready","fingerprint":"fp-9f2c","dimensions":1536,"distanceMetric":"dot_product","vectorCount":12000,"storageRelativePath":"snapshots/version-1/usearch-hnsw/gen-7","fileBytes":48234496,"backendVersion":"usearch-2.17",
        "createdAt":"2026-06-15T15:06:40Z","updatedAt":"2026-06-15T15:08:20Z","lastBuiltAt":"2026-06-15T15:08:20Z"}
        """
        let data = try await server.handleSearchRPC(
            method: .searchVectorSnapshotUpsert,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"vec-up-1","method":"daemon.search.vector_snapshot.upsert","params":\#(params)}"#.utf8
            )
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarVectorIndexSnapshotUpsertResponse>.self,
            from: data
        )
        XCTAssertNil(response.error)
        XCTAssertEqual(response.result?.embeddingVersionID, "version-1")
        XCTAssertEqual(response.result?.backendID, "usearch-hnsw")
        XCTAssertEqual(response.result?.updatedAt, "2026-06-15T15:08:20.000Z")
    }

    func testVectorSnapshotUpsertValidationFailureMapsToInvalidParams() async throws {
        let server = try makeServer()
        // Unknown state and a traversal path: validation must reject before storage.
        let params = """
        {"embeddingVersionID":"version-1","backendID":"usearch-hnsw","state":"archived","fingerprint":"fp-9f2c","dimensions":1536,"distanceMetric":"dot_product","vectorCount":12000,"storageRelativePath":"../escape/gen-7","fileBytes":48234496,
        "backendVersion":"usearch-2.17","createdAt":"2026-06-15T15:06:40Z","updatedAt":"2026-06-15T15:08:20Z"}
        """
        let data = try await server.handleSearchRPC(
            method: .searchVectorSnapshotUpsert,
            decoder: JSONDecoder(),
            requestData: Data(#"{"id":"vec-bad-1","method":"daemon.search.vector_snapshot.upsert","params":\#(params)}"#.utf8)
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarVectorIndexSnapshotUpsertResponse>.self,
            from: data
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.invalidParams)
    }

    func testVectorSnapshotUpsertReportsUnavailableWithoutIndexedSearch() async throws {
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )
        let params = """
        {"embeddingVersionID":"version-1","backendID":"usearch-hnsw","state":"ready","fingerprint":"fp-9f2c","dimensions":1536,"distanceMetric":"dot_product","vectorCount":12000,"fileBytes":0,"backendVersion":"usearch-2.17","createdAt":"2026-06-15T15:06:40Z","updatedAt":"2026-06-15T15:08:20Z"}
        """
        let data = try await server.handleSearchRPC(
            method: .searchVectorSnapshotUpsert,
            decoder: JSONDecoder(),
            requestData: Data(#"{"id":"vec-unavail","method":"daemon.search.vector_snapshot.upsert","params":\#(params)}"#.utf8)
        )
        let response = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarVectorIndexSnapshotUpsertResponse>.self,
            from: data
        )
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, BurnBarRPCErrorCode.internalError)
    }

    func testVectorSnapshotUpsertCarriesSearchWriteCapabilityInSearchDomain() {
        let method = BurnBarRPCMethod.searchVectorSnapshotUpsert
        XCTAssertEqual(BurnBarRPCCapability.capability(for: method), .searchWrite)
        XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), "search")
    }

    private func makeServer() throws -> BurnBarDaemonServer {
        let directory = try makeTemporaryDirectory()
        let dbPath = directory.appendingPathComponent("openburnbar.sqlite").path
        try createDatabase(at: dbPath)
        return BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                indexDatabasePath: dbPath,
                startsMissionControlBackgroundLoops: false
            )
        )
    }

    private func createDatabase(at path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "VectorSnapshotLaneRPCTests", code: 1)
        }
        defer { sqlite3_close(db) }
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
            throw NSError(domain: "VectorSnapshotLaneRPCTests", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VectorSnapshotLaneRPCTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
