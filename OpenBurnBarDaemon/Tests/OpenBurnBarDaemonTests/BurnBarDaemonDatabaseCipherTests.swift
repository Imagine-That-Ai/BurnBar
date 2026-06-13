import Foundation
import SQLite3
@testable import OpenBurnBarDaemon
import XCTest

/// RR-1 (daemon side): the daemon keys the shared SQLite with the app's Keychain
/// key WHEN a SQLCipher codec is linked, and migrates an existing plaintext file
/// once. On the current stock-SQLite build the codec is absent, so every keyed
/// path is a deliberate no-op (do-not-brick): these tests pin BOTH the
/// stock-build no-op contract AND, behind a codec-present flag, the real keyed
/// open + migration.
final class BurnBarDaemonDatabaseCipherTests: XCTestCase {
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Plaintext vs Encrypted File Detection (no key required)

    func test_plaintextDetection_onFreshSQLiteFile() throws {
        let path = try makePlaintextDatabase(rows: ["alpha", "beta"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path))
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path))
    }

    func test_detection_onMissingFile_isNeitherPlaintextNorEncrypted() {
        let path = NSTemporaryDirectory() + "obb-missing-\(UUID().uuidString).sqlite"
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path))
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path))
    }

    func test_encryptedDetection_onCiphertextHeader() throws {
        // A file whose first 16 bytes are NOT the SQLite magic looks "encrypted".
        let path = NSTemporaryDirectory() + "obb-cipher-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                  0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path))
        XCTAssertFalse(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path))
    }

    // MARK: - Stock-build do-not-brick contract

    func test_applyKeyIfAvailable_isNoOpOnStockSQLite() throws {
        // On a stock-SQLite build (no codec) applyKeyIfAvailable must NOT throw
        // and must leave a readable plaintext handle: the daemon keeps opening the
        // disclosed-plaintext file rather than bricking on a no-op PRAGMA key.
        try XCTSkipIf(BurnBarDaemonDatabaseCipher.isCipherAvailable(), "codec present; covered by the keyed-open test")

        let path = try makePlaintextDatabase(rows: ["row1"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertNoThrow(try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: handle!))
        XCTAssertEqual(try readAllRows(handle!), ["row1"], "stock plaintext DB must remain readable")
    }

    func test_migratePlaintextDatabaseIfNeeded_isNoOpOnStockSQLite() throws {
        try XCTSkipIf(BurnBarDaemonDatabaseCipher.isCipherAvailable(), "codec present; covered by the migration test")

        let path = try makePlaintextDatabase(rows: ["keep-me"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let logger = BurnBarDaemonLogger(category: "cipher-test")
        let migrated = try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(at: path, logger: logger)
        XCTAssertFalse(migrated, "no codec ⇒ no migration")
        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isPlaintextDatabaseFile(at: path), "file must stay plaintext and intact")
    }

    func test_applyKey_rejectsKeyWithUnsafeCharacters() {
        // Charset validation happens before any PRAGMA runs, so it is observable
        // even on a stock build: a key with a quote can never be interpolated.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        XCTAssertThrowsError(try BurnBarDaemonDatabaseCipher.applyKey("abc' OR '1'='1", to: handle!)) { error in
            guard case BurnBarDaemonDatabaseCipherError.keyApplicationFailed = error else {
                return XCTFail("expected keyApplicationFailed, got \(error)")
            }
        }
    }

    // MARK: - Real keyed open + migration (codec-present flag)
    //
    // Activates the moment a SQLCipher codec is linked into the daemon's SQLite.
    // Set DAEMON_SQLCIPHER_PRESENT=1 once such a build exists to demand the
    // assertions below pass; otherwise the test self-checks via isCipherAvailable.

    func test_keyedOpen_roundTripsThroughCodec_whenPresent() throws {
        try requireCodec()

        // A plaintext open of an encrypted DB must FAIL; a keyed open must succeed.
        let path = try makePlaintextDatabase(rows: ["secret-row"])
        defer { try? FileManager.default.removeItem(atPath: path) }

        let logger = BurnBarDaemonLogger(category: "cipher-test")
        XCTAssertTrue(try BurnBarDaemonDatabaseCipher.migratePlaintextDatabaseIfNeeded(at: path, logger: logger))
        XCTAssertTrue(BurnBarDaemonDatabaseCipher.isEncryptedDatabaseFile(at: path), "file must be encrypted after migration")

        // Keyed open reads the original rows back.
        var keyed: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &keyed, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(keyed) }
        try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: keyed!)
        XCTAssertEqual(try readAllRows(keyed!), ["secret-row"])

        // A keyless plaintext open must NOT be able to read the table.
        var keyless: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &keyless, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(keyless) }
        XCTAssertThrowsError(try readAllRows(keyless!), "keyless open must fail on an encrypted DB")
    }

    private func requireCodec() throws {
        if ProcessInfo.processInfo.environment["DAEMON_SQLCIPHER_PRESENT"] == "1" {
            XCTAssertTrue(
                BurnBarDaemonDatabaseCipher.isCipherAvailable(),
                "DAEMON_SQLCIPHER_PRESENT=1 but the linked SQLite has no codec"
            )
            return
        }
        try XCTSkipUnless(
            BurnBarDaemonDatabaseCipher.isCipherAvailable(),
            "SQLCipher codec not linked; set DAEMON_SQLCIPHER_PRESENT=1 once it is"
        )
    }

    // MARK: - Helpers

    private func makePlaintextDatabase(rows: [String]) throws -> String {
        let path = NSTemporaryDirectory() + "obb-plain-\(UUID().uuidString).sqlite"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TABLE t(v TEXT)", nil, nil, nil), SQLITE_OK)
        for row in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(handle, "INSERT INTO t(v) VALUES (?)", -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_text(stmt, 1, row, -1, transient)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        return path
    }

    private func readAllRows(_ handle: OpaquePointer) throws -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT v FROM t ORDER BY v", -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw POSIXError(.EIO)
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [String] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    rows.append(String(cString: cString))
                }
            } else if step == SQLITE_DONE {
                break
            } else {
                throw POSIXError(.EIO)
            }
        }
        return rows
    }
}
