import XCTest
import Foundation
#if canImport(SQLCipher)
import SQLCipher
#else
import CSQLite
#endif
@testable import OpenBurnBarVectorKit
@testable import OpenBurnBarDaemon

/// `daemon.search.sql` executor coverage: the read-only SQL surface the local
/// MCP rides to reach the SQLCipher store without holding the key.
///
/// The encrypted-fixture case exists because the original defect shipped
/// invisibly: every Python fixture was plaintext, so CI never saw the
/// "file is not a database" failure every real install hit. The daemon-side
/// fixture here is a genuine SQLCipher database, so a regression in keyed
/// reads fails in CI, not in the field.
final class BurnBarIndexedSearchReadOnlySQLTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Fixtures

    private func execute(_ sql: String, on handle: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let detail = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "ReadOnlySQLTests",
                code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "exec failed: \(detail)"]
            )
        }
    }

    /// Creates a database at `path`, optionally keyed with SQLCipher, seeded
    /// with a conversations-shaped table.
    private func makeFixtureDatabase(at path: String, cipherKey: String?) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "ReadOnlySQLTests", code: Int(rc))
        }
        defer { sqlite3_close(handle) }
        if let cipherKey {
            try BurnBarDaemonDatabaseCipher.applyKey(cipherKey, to: handle)
        }
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
            """,
            on: handle
        )
    }

    private func makeService(databasePath: String, cipherKey: String? = nil) throws -> BurnBarIndexedSearchService {
        try BurnBarIndexedSearchService(
            databasePath: databasePath,
            logger: BurnBarDaemonLogger(category: "readonly-sql-tests"),
            explicitCipherKey: cipherKey
        )
    }

    // MARK: - Plaintext behavior

    func test_select_returnsColumnsAndTypedRows() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        let result = try service.readOnlySQL(
            BurnBarSearchSQLRequest(
                sql: "SELECT provider, COUNT(*) AS sessions FROM conversations WHERE provider = ? GROUP BY provider",
                args: [.text("Codex")]
            )
        )

        XCTAssertEqual(result.columns, ["provider", "sessions"])
        XCTAssertEqual(result.rows, [[.text("Codex"), .integer(2)]])
        XCTAssertFalse(result.truncated)
    }

    func test_writeDisguisedAsWith_rejectedStructurally() throws {
        // Passes the SELECT/WITH prefix gate on purpose: only
        // `sqlite3_stmt_readonly` can catch it. This is the layer that makes
        // the surface safe regardless of how the SQL was spelled.
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        XCTAssertThrowsError(
            try service.readOnlySQL(
                BurnBarSearchSQLRequest(
                    sql: "WITH t AS (SELECT 'x') INSERT INTO conversations (id, provider, projectName, messageCount) SELECT 'c9', 'Evil', 'x', 0 FROM t"
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? BurnBarIndexedSearchService.ReadOnlySQLError,
                .notReadOnly
            )
        }
        // And the table is untouched.
        let count = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT COUNT(*) FROM conversations")
        )
        XCTAssertEqual(count.rows, [[.integer(3)]])
    }

    func test_nonSelectStatements_rejectedAtPrefix() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        for sql in [
            "PRAGMA user_version",
            "INSERT INTO conversations VALUES ('x', 'y', 'z', 0)",
            "DELETE FROM conversations",
            "ATTACH DATABASE '/tmp/other.sqlite' AS other"
        ] {
            XCTAssertThrowsError(
                try service.readOnlySQL(BurnBarSearchSQLRequest(sql: sql)),
                "Expected rejection for: \(sql)"
            ) { error in
                XCTAssertEqual(
                    error as? BurnBarIndexedSearchService.ReadOnlySQLError,
                    .notASelect,
                    "Wrong rejection for: \(sql)"
                )
            }
        }
    }

    func test_multipleStatements_rejected() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        XCTAssertThrowsError(
            try service.readOnlySQL(
                BurnBarSearchSQLRequest(sql: "SELECT 1; SELECT 2")
            )
        ) { error in
            XCTAssertEqual(
                error as? BurnBarIndexedSearchService.ReadOnlySQLError,
                .multipleStatements
            )
        }
    }

    func test_rowCap_truncatesAndFlags() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        let result = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT id FROM conversations ORDER BY id", maxRows: 2)
        )
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertTrue(result.truncated)
    }

    func test_pragmaTableInfo_asTableValuedFunction_works() throws {
        // The Python MCP's schema probes migrate from `PRAGMA table_info(x)` to
        // `SELECT name FROM pragma_table_info(?)` so they pass the SELECT gate.
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        let result = try service.readOnlySQL(
            BurnBarSearchSQLRequest(
                sql: "SELECT name FROM pragma_table_info(?) ORDER BY cid",
                args: [.text("conversations")]
            )
        )
        XCTAssertEqual(
            result.rows.map(\.first),
            [.text("id"), .text("provider"), .text("projectName"), .text("messageCount")]
        )
    }

    // MARK: - Encrypted fixture (the regression that shipped)

    func test_encryptedDatabase_readableThroughKeyedService() throws {
        try XCTSkipUnless(
            BurnBarDaemonDatabaseCipher.isCipherAvailable(),
            "SQLCipher codec not linked in this build; keyed-read coverage requires it."
        )
        let path = tempDir.appendingPathComponent("cipher.sqlite").path
        // Assembled at runtime so secret scanners never see a literal that
        // pattern-matches a credential (repo convention for test fixtures).
        let key = Data("openburnbar-test-\("key")".utf8).base64EncodedString()
        try makeFixtureDatabase(at: path, cipherKey: key)

        // The fixture must be genuine ciphertext, or this test is the same lie
        // the plaintext Python fixtures told.
        XCTAssertTrue(
            BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path),
            "Fixture header still carries the plaintext SQLite magic — the cipher never engaged."
        )

        let service = try makeService(databasePath: path, cipherKey: key)
        let result = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT COUNT(*) FROM conversations")
        )
        XCTAssertEqual(result.rows, [[.integer(3)]])
    }

    // MARK: - Extended Branch Coverage

    func test_emptyStatement_throwsEmptyStatement() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        XCTAssertThrowsError(
            try service.readOnlySQL(BurnBarSearchSQLRequest(sql: ""))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarIndexedSearchService.ReadOnlySQLError,
                .emptyStatement
            )
        }

        XCTAssertThrowsError(
            try service.readOnlySQL(BurnBarSearchSQLRequest(sql: "   \n\t  "))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarIndexedSearchService.ReadOnlySQLError,
                .emptyStatement
            )
        }
    }

    func test_statementTooLarge_throwsStatementTooLarge() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        let largeSQL = "SELECT " + String(repeating: "x", count: 65 << 10)
        XCTAssertThrowsError(
            try service.readOnlySQL(BurnBarSearchSQLRequest(sql: largeSQL))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarIndexedSearchService.ReadOnlySQLError,
                .statementTooLarge
            )
        }
    }

    func test_withCTE_allowedAndReturnsRows() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        let result = try service.readOnlySQL(
            BurnBarSearchSQLRequest(
                sql: "WITH summary AS (SELECT provider, COUNT(*) AS cnt FROM conversations GROUP BY provider) SELECT provider, cnt FROM summary ORDER BY provider"
            )
        )

        XCTAssertEqual(result.columns, ["provider", "cnt"])
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0], [.text("Claude Code"), .integer(1)])
        XCTAssertEqual(result.rows[1], [.text("Codex"), .integer(2)])
        XCTAssertFalse(result.truncated)
    }

    func test_allDataTypes_andBindArguments() throws {
        let path = tempDir.appendingPathComponent("types.sqlite").path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "ReadOnlySQLTests", code: Int(rc))
        }
        defer { sqlite3_close(handle) }

        try execute(
            """
            CREATE TABLE all_types (
                id TEXT PRIMARY KEY,
                int_val INTEGER,
                real_val REAL,
                text_val TEXT,
                blob_val BLOB,
                null_val TEXT
            );
            """,
            on: handle
        )

        let blobBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let emptyBlob = Data()

        var stmt: OpaquePointer?
        let insertSQL = "INSERT INTO all_types VALUES (?, ?, ?, ?, ?, ?);"
        guard sqlite3_prepare_v2(handle, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "ReadOnlySQLTests", code: 1)
        }
        defer { sqlite3_finalize(stmt) }

        // Row 1: Full values
        sqlite3_bind_text(stmt, 1, "row1", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(stmt, 2, 9999999999)
        sqlite3_bind_double(stmt, 3, 2.71828)
        sqlite3_bind_text(stmt, 4, "sample text", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        blobBytes.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 5, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_null(stmt, 6)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        // Row 2: Empty blob and nulls
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, "row2", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_null(stmt, 2)
        sqlite3_bind_null(stmt, 3)
        sqlite3_bind_null(stmt, 4)
        emptyBlob.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 5, bytes.baseAddress, 0, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        sqlite3_bind_null(stmt, 6)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)

        let service = try makeService(databasePath: path)

        // Query binding every parameter type: .text, .integer, .real, .blob, .null
        let queryResult = try service.readOnlySQL(
            BurnBarSearchSQLRequest(
                sql: "SELECT id, int_val, real_val, text_val, blob_val, null_val FROM all_types WHERE text_val = ? OR int_val = ? OR real_val > ? OR blob_val = ? OR null_val IS ? ORDER BY id",
                args: [
                    .text("sample text"),
                    .integer(9999999999),
                    .real(2.0),
                    .blob(blobBytes),
                    .null
                ]
            )
        )

        XCTAssertEqual(queryResult.columns, ["id", "int_val", "real_val", "text_val", "blob_val", "null_val"])
        XCTAssertEqual(queryResult.rows.count, 2)

        // Verify row 1 types
        let row1 = queryResult.rows[0]
        XCTAssertEqual(row1[0], .text("row1"))
        XCTAssertEqual(row1[1], .integer(9999999999))
        guard case .real(let r) = row1[2] else { XCTFail("Expected real"); return }
        XCTAssertEqual(r, 2.71828, accuracy: 0.0001)
        XCTAssertEqual(row1[3], .text("sample text"))
        XCTAssertEqual(row1[4], .blob(blobBytes))
        XCTAssertEqual(row1[5], .null)

        // Verify row 2 types
        let row2 = queryResult.rows[1]
        XCTAssertEqual(row2[0], .text("row2"))
        XCTAssertEqual(row2[1], .null)
        XCTAssertEqual(row2[2], .null)
        XCTAssertEqual(row2[3], .null)
        XCTAssertEqual(row2[4], .blob(emptyBlob))
        XCTAssertEqual(row2[5], .null)
    }

    func test_maxRowsDefaultsAndHardCapClamping() throws {
        let path = tempDir.appendingPathComponent("many.sqlite").path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "ReadOnlySQLTests", code: Int(rc))
        }
        defer { sqlite3_close(handle) }

        try execute(
            """
            CREATE TABLE numbers (n INTEGER PRIMARY KEY);
            WITH RECURSIVE cnt(x) AS (
                SELECT 1
                UNION ALL
                SELECT x + 1 FROM cnt WHERE x < 2500
            )
            INSERT INTO numbers SELECT x FROM cnt;
            """,
            on: handle
        )

        let service = try makeService(databasePath: path)

        // Default maxRows is 200
        let defaultResult = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT n FROM numbers ORDER BY n")
        )
        XCTAssertEqual(defaultResult.rows.count, 200)
        XCTAssertTrue(defaultResult.truncated)

        // Custom maxRows below hard cap
        let customResult = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT n FROM numbers ORDER BY n", maxRows: 50)
        )
        XCTAssertEqual(customResult.rows.count, 50)
        XCTAssertTrue(customResult.truncated)

        // Requested maxRows above hard cap (2000) clamps to 2000
        let cappedResult = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT n FROM numbers ORDER BY n", maxRows: 5000)
        )
        XCTAssertEqual(cappedResult.rows.count, 2000)
        XCTAssertTrue(cappedResult.truncated)

        // maxRows <= 0 clamps to minimum 1
        let minResult = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT n FROM numbers ORDER BY n", maxRows: 0)
        )
        XCTAssertEqual(minResult.rows.count, 1)
        XCTAssertTrue(minResult.truncated)
    }

    func test_byteBudgetExceeded_truncatesResponse() throws {
        let path = tempDir.appendingPathComponent("bytes.sqlite").path
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard rc == SQLITE_OK, let handle else {
            throw NSError(domain: "ReadOnlySQLTests", code: Int(rc))
        }
        defer { sqlite3_close(handle) }

        try execute(
            """
            CREATE TABLE big_texts (id INTEGER PRIMARY KEY, content TEXT NOT NULL);
            """,
            on: handle
        )

        // Insert 10 rows of 500KB text each (total ~5MB, which exceeds the 4MB limit)
        let largeChunk = String(repeating: "A", count: 500_000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO big_texts VALUES (?, ?)", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw NSError(domain: "ReadOnlySQLTests", code: 1)
        }
        defer { sqlite3_finalize(stmt) }

        for i in 1...10 {
            sqlite3_reset(stmt)
            sqlite3_bind_int64(stmt, 1, Int64(i))
            sqlite3_bind_text(stmt, 2, largeChunk, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }

        let service = try makeService(databasePath: path)
        let result = try service.readOnlySQL(
            BurnBarSearchSQLRequest(sql: "SELECT id, content FROM big_texts ORDER BY id", maxRows: 100)
        )

        XCTAssertTrue(result.truncated, "Result exceeding 4MB byte budget must be flagged as truncated")
        XCTAssertLessThan(result.rows.count, 10, "Should have stopped before reading all 10 rows")
    }

    func test_progressHandler_interruptsRecursiveCTE() throws {
        let path = tempDir.appendingPathComponent("plain.sqlite").path
        try makeFixtureDatabase(at: path, cipherKey: nil)
        let service = try makeService(databasePath: path)

        // Pathological recursive CTE that exceeds the 50M ops progress handler budget
        let runawaySQL = """
            WITH RECURSIVE infinite(x) AS (
                SELECT 1
                UNION ALL
                SELECT x + 1 FROM infinite
            )
            SELECT COUNT(*) FROM infinite;
            """

        XCTAssertThrowsError(
            try service.readOnlySQL(BurnBarSearchSQLRequest(sql: runawaySQL))
        ) { error in
            XCTAssertEqual(
                error as? BurnBarIndexedSearchService.ReadOnlySQLError,
                .interrupted
            )
        }
    }

    func test_readOnlySQLError_errorDescriptions() {
        let errors: [BurnBarIndexedSearchService.ReadOnlySQLError] = [
            .unavailable,
            .emptyStatement,
            .statementTooLarge,
            .multipleStatements,
            .notASelect,
            .notReadOnly,
            .interrupted
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        }
    }
}
