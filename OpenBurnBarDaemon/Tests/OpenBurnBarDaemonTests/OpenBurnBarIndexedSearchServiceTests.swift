import OpenBurnBarCore
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
