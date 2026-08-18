import Darwin
import Foundation
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
@testable import OpenBurnBarVectorKit
import XCTest
#if canImport(SQLCipher)
import SQLCipher
#else
import CSQLite
#endif

/// Search RPCs exercised end-to-end through the daemon server socket dispatch:
/// Unix domain socket, `handleSearchRPC`, `daemon.search.sql` and `daemon.search.query`.
final class BurnBarDaemonServerRPCSearchTests: XCTestCase {
    private let authToken = "search-rpc-test-token"

    // MARK: - Database Fixture Helpers

    private func execute(_ sql: String, on handle: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "BurnBarDaemonServerRPCSearchTests",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "exec failed: \(detail)"]
            )
        }
    }

    private func makeSeededDatabase(at path: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "BurnBarDaemonServerRPCSearchTests", code: Int(rc))
        }
        defer { sqlite3_close(handle) }
        try execute(
            """
            CREATE TABLE conversations (
                id TEXT PRIMARY KEY,
                provider TEXT NOT NULL,
                projectName TEXT NOT NULL,
                messageCount INTEGER NOT NULL
            );
            INSERT INTO conversations VALUES
                ('c1', 'Claude Code', 'burnbar', 12),
                ('c2', 'Codex', 'burnbar', 7),
                ('c3', 'Codex', 'website', 3);

            CREATE TABLE search_documents (
                id TEXT PRIMARY KEY,
                sourceKind TEXT NOT NULL,
                sourceID TEXT NOT NULL,
                title TEXT NOT NULL,
                provider TEXT,
                projectName TEXT,
                sourceUpdatedAt TEXT,
                indexedAt TEXT NOT NULL
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

            INSERT INTO search_documents VALUES (
                'doc1', 'conversation', 'c1', 'Fixing compile error', 'Claude Code', 'burnbar',
                '2026-05-12 14:30:00.000', '2026-05-12 14:30:00.000'
            );

            INSERT INTO search_chunks VALUES (
                'chunk1', 'doc1', 0
            );

            INSERT INTO search_chunks_fts VALUES (
                'chunk1', 'doc1', 'Fixed the swift compiler issue in daemon', 'Fixed the swift compiler issue in daemon'
            );
            """,
            on: handle
        )
    }

    // MARK: - daemon.search.sql Tests

    func test_searchSQL_againstSeededDatabase_returnsColumnsAndRows() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-sql-seeded")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        try makeSeededDatabase(at: databasePath)

        let socketPath = makeSocketPath(name: "search-sql-seeded")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "req-sql-1",
            method: .searchSQL,
            authToken: authToken,
            params: BurnBarSearchSQLRequest(
                sql: "SELECT provider, SUM(messageCount) AS total FROM conversations GROUP BY provider ORDER BY provider",
                args: [],
                maxRows: 10
            )
        )

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchSQLResult> = try sendEnvelope(
            request,
            socketPath: socketPath
        )

        XCTAssertNil(response.error)
        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result.columns, ["provider", "total"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], [.text("Claude Code"), .integer(12)])
        XCTAssertEqual(result.rows[1], [.text("Codex"), .integer(10)])
        XCTAssertFalse(result.truncated)
    }

    func test_searchSQL_whenNoIndexDatabaseConfigured_returnsInternalErrorWithEnvVarHelp() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-sql-nil-db")
        let socketPath = makeSocketPath(name: "search-sql-nil-db")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "req-sql-nil",
            method: .searchSQL,
            authToken: authToken,
            params: BurnBarSearchSQLRequest(sql: "SELECT 1")
        )

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchSQLResult> = try sendEnvelope(
            request,
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, BurnBarRPCErrorCode.internalError)
        XCTAssertTrue(
            error.message.contains("OPENBURNBAR_INDEX_DATABASE_PATH"),
            "Error message must instruct the operator: \(error.message)"
        )
    }

    func test_searchSQL_writeStatement_rejectedWithInvalidParams() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-sql-write")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        try makeSeededDatabase(at: databasePath)

        let socketPath = makeSocketPath(name: "search-sql-write")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        for writeSQL in [
            "DELETE FROM conversations WHERE id = 'c1'",
            "INSERT INTO conversations VALUES ('c99', 'Test', 'proj', 1)",
            "UPDATE conversations SET messageCount = 0",
            "WITH t AS (SELECT 1) INSERT INTO conversations (id, provider, projectName, messageCount) SELECT 'c99', 'x', 'y', 0 FROM t"
        ] {
            let request = BurnBarRPCRequestEnvelopeWithParams(
                id: "req-write",
                method: .searchSQL,
                authToken: authToken,
                params: BurnBarSearchSQLRequest(sql: writeSQL)
            )

            let response: BurnBarRPCResponseEnvelope<BurnBarSearchSQLResult> = try sendEnvelope(
                request,
                socketPath: socketPath
            )

            XCTAssertNil(response.result, "Write statement '\(writeSQL)' should produce no result")
            let error = try XCTUnwrap(response.error, "Write statement '\(writeSQL)' should produce an error")
            XCTAssertEqual(
                error.code,
                BurnBarRPCErrorCode.invalidParams,
                "Expected invalidParams error code for write attempt '\(writeSQL)', got: \(error.code)"
            )
        }
    }

    func test_searchSQL_multipleStatements_rejectedWithInvalidParams() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-sql-multi")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        try makeSeededDatabase(at: databasePath)

        let socketPath = makeSocketPath(name: "search-sql-multi")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "req-multi",
            method: .searchSQL,
            authToken: authToken,
            params: BurnBarSearchSQLRequest(sql: "SELECT 1; SELECT 2")
        )

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchSQLResult> = try sendEnvelope(
            request,
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, BurnBarRPCErrorCode.invalidParams)
    }

    func test_searchSQL_emptyStatement_rejectedWithInvalidParams() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-sql-empty")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        try makeSeededDatabase(at: databasePath)

        let socketPath = makeSocketPath(name: "search-sql-empty")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "req-empty",
            method: .searchSQL,
            authToken: authToken,
            params: BurnBarSearchSQLRequest(sql: "   ")
        )

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchSQLResult> = try sendEnvelope(
            request,
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, BurnBarRPCErrorCode.invalidParams)
    }

    // MARK: - daemon.search.query Tests

    func test_searchQuery_againstSeededDatabase_returnsHits() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-query-seeded")
        let databasePath = rootURL.appendingPathComponent("openburnbar.sqlite").path
        try makeSeededDatabase(at: databasePath)

        let socketPath = makeSocketPath(name: "search-query-seeded")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: databasePath)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "req-query-1",
            method: .searchQuery,
            authToken: authToken,
            params: BurnBarSearchQueryRequest(
                query: "compiler",
                resultLimit: 10
            )
        )

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchQueryResult> = try sendEnvelope(
            request,
            socketPath: socketPath
        )

        XCTAssertNil(response.error)
        let result = try XCTUnwrap(response.result)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertEqual(result.hits.first?.chunkID, "chunk1")
        XCTAssertEqual(result.hits.first?.title, "Fixing compile error")
    }

    func test_searchQuery_whenNoIndexDatabaseConfigured_returnsInternalErrorWithEnvVarHelp() async throws {
        let rootURL = try makeTemporaryRoot(name: "search-query-nil-db")
        let socketPath = makeSocketPath(name: "search-query-nil-db")
        let server = makeServer(rootURL: rootURL, socketPath: socketPath, indexDatabasePath: nil)
        try await server.start()
        addTeardownBlock { await server.stop() }

        let request = BurnBarRPCRequestEnvelopeWithParams(
            id: "req-query-nil",
            method: .searchQuery,
            authToken: authToken,
            params: BurnBarSearchQueryRequest(query: "compiler")
        )

        let response: BurnBarRPCResponseEnvelope<BurnBarSearchQueryResult> = try sendEnvelope(
            request,
            socketPath: socketPath
        )

        XCTAssertNil(response.result)
        let error = try XCTUnwrap(response.error)
        XCTAssertEqual(error.code, BurnBarRPCErrorCode.internalError)
        XCTAssertTrue(
            error.message.contains("OPENBURNBAR_INDEX_DATABASE_PATH"),
            "Error message must instruct the operator: \(error.message)"
        )
    }

    // MARK: - Server construction

    private func makeServer(
        rootURL: URL,
        socketPath: String,
        indexDatabasePath: String?
    ) -> BurnBarDaemonServer {
        BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketPath: socketPath,
                socketAuthToken: authToken,
                indexDatabasePath: indexDatabasePath,
                startsMissionControlBackgroundLoops: false
            ),
            logger: BurnBarDaemonLogger(category: "search-rpc-tests"),
            configStore: BurnBarConfigStore(
                fileURL: rootURL.appendingPathComponent("provider-config.json"),
                secretStore: BurnBarInMemorySecretStore(),
                logger: BurnBarDaemonLogger(category: "search-rpc-tests")
            ),
            usageRecorder: BurnBarUsageRecorder(
                fileURL: rootURL.appendingPathComponent("usage-events.jsonl")
            )
        )
    }

    private func makeTemporaryRoot(name: String) throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootURL) }
        return rootURL
    }

    private func makeSocketPath(name: String) -> String {
        "/tmp/obb-search-\(name)-\(String(UUID().uuidString.prefix(8))).sock"
    }

    // MARK: - Socket transport

    private func sendEnvelope<Envelope: Encodable, Response: Decodable>(
        _ envelope: Envelope,
        socketPath: String
    ) throws -> BurnBarRPCResponseEnvelope<Response> {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertNotEqual(fileDescriptor, -1)

        var noSigPipe: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = try socketAddress(for: socketPath)
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { reboundPointer in
                connect(fileDescriptor, reboundPointer, socklen_t(MemoryLayout<sockaddr_un>.stride))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(fileDescriptor)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        let payload = try JSONEncoder().encode(envelope) + Data([0x0A])
        payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let bytesWritten = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                XCTAssertGreaterThan(bytesWritten, 0)
                bytesRemaining -= bytesWritten
                offset += bytesWritten
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            if bytesRead == 0 { break }
            XCTAssertGreaterThan(bytesRead, 0)
            response.append(contentsOf: buffer.prefix(bytesRead))
            if response.last == 0x0A { break }
        }
        while response.last == 0x0A || response.last == 0x0D { response.removeLast() }

        return try JSONDecoder().decode(BurnBarRPCResponseEnvelope<Response>.self, from: response)
    }

    private func socketAddress(for socketPath: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.stride)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() { rawBuffer[index] = byte }
        }
        return address
    }
}
