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
        let key = "b3BlbmJ1cm5iYXItdGVzdC1rZXk="
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
}
