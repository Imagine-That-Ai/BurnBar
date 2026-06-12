import GRDB
import XCTest

@testable import OpenBurnBar

/// Verifies the GRDB+SQLCipher SPM build applies `PRAGMA key` and reports `cipher_version`,
/// and validates the SOTA key recovery design (Keychain-only + explicit passphrase bundle).
final class DatabaseEncryptionServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Ensure a clean state for each test
        DatabaseEncryptionService.deleteKey()
    }

    override func tearDown() {
        DatabaseEncryptionService.deleteKey()
        super.tearDown()
    }

    /// Whether the current build links a real SQLCipher. Determined by opening a
    /// keyed in-memory database and reading `PRAGMA cipher_version`: non-empty means
    /// SQLCipher is active. Used to branch tests that can only assert encrypted
    /// behavior on a SQLCipher-linked build.
    private static func sqlCipherIsActive() -> Bool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA key = 'probe'")
        }
        guard let pool = try? DatabaseQueue(path: ":memory:", configuration: config) else { return false }
        let version = try? pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
        return (version ?? nil).map { $0.isEmpty == false } ?? false
    }

    /// (a) With a key applied, either `cipher_version` is non-empty (SQLCipher
    /// active) OR `makeConfiguration` throws `cipherUnavailable` when the cipher is
    /// genuinely unavailable. Both outcomes are correct; silently shipping plaintext
    /// is not — and that third outcome is exactly what the dead `#if canImport`
    /// guard used to produce.
    func testMakeConfigurationWithKey_eitherReportsCipherVersionOrHardFails() throws {
        let key = "k3y-" + String(repeating: "a", count: 32)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-enc-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: key)
            // Cipher reported available; opening must yield a non-empty cipher_version.
            let pool = try DatabasePool(path: path, configuration: config)
            let version = try pool.read { db in
                try String.fetchOne(db, sql: "PRAGMA cipher_version")
            }
            XCTAssertNotNil(version)
            XCTAssertFalse(version?.isEmpty ?? true, "cipher_version should be set when using SQLCipher")
            try pool.close()
        } catch DatabaseEncryptionError.cipherUnavailable {
            // Acceptable: this build has no SQLCipher and we hard-failed rather than
            // writing plaintext. This is the check that catches the dead-guard bug.
        }
    }

    /// (a) When the cipher is unavailable, opening a keyed pool throws
    /// `DatabaseEncryptionError.cipherUnavailable` (the `cipher_version` self-check
    /// runs in `prepareDatabase`, which GRDB evaluates lazily when the first
    /// connection opens — so the hard-fail surfaces at pool-open, never as a silent
    /// plaintext config). On a SQLCipher-linked build the open succeeds instead.
    /// Either way, a keyed open never silently produces plaintext.
    func testKeyedOpen_hardFailsWhenCipherUnavailable() throws {
        let key = "k3y-" + String(repeating: "a", count: 32)
        let config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: key)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-hardfail-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        if Self.sqlCipherIsActive() {
            XCTAssertNoThrow(try DatabasePool(path: path, configuration: config))
        } else {
            XCTAssertThrowsError(try DatabasePool(path: path, configuration: config)) { error in
                XCTAssertTrue(
                    error is DatabaseEncryptionError,
                    "A keyed open on a non-SQLCipher build must hard-fail with DatabaseEncryptionError, got \(error)"
                )
            }
        }
    }

    /// (c) A plaintext `DatabasePool` cannot open a file written with encryption on.
    /// Only meaningful when SQLCipher is active (otherwise there is no encrypted file
    /// to fail against); skipped on a plain-SQLite build.
    func testPlaintextPoolCannotOpenEncryptedFile() throws {
        try XCTSkipUnless(Self.sqlCipherIsActive(), "Requires a SQLCipher-linked build to produce an encrypted file.")
        let key = DatabaseEncryptionService.getOrCreateKey()
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-enc-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        let encConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: key)
        let encPool = try DatabasePool(path: path, configuration: encConfig)
        try encPool.write { db in
            try db.execute(sql: "CREATE TABLE secret (v INTEGER)")
            try db.execute(sql: "INSERT INTO secret (v) VALUES (42)")
        }
        try encPool.close()

        // The file must be detected as encrypted (no plaintext SQLite magic header).
        XCTAssertTrue(
            DatabaseEncryptionService.isEncryptedDatabaseFile(at: path),
            "File written with encryption on must be detected as encrypted"
        )

        // A plaintext pool (no key) must NOT be able to read the encrypted contents.
        let plainConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
        XCTAssertThrowsError(
            try {
                let plainPool = try DatabasePool(path: path, configuration: plainConfig)
                _ = try plainPool.read { db in
                    try Int.fetchOne(db, sql: "SELECT v FROM secret")
                }
            }(),
            "A plaintext pool must not open/read an encrypted database file"
        )
    }

    /// (d) An existing PLAINTEXT database still opens through the explicit
    /// encryption-disabled/tooling path. App startup with encryption enabled is
    /// covered separately below and must fail closed until migration is implemented.
    func testExistingPlaintextDatabaseStillOpensWithoutDataLoss() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-plain-existing-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        // Create a plaintext database with real data (simulating an existing install).
        let plainConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
        let original = try DatabasePool(path: path, configuration: plainConfig)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE usage (id INTEGER PRIMARY KEY, cost REAL)")
            try db.execute(sql: "INSERT INTO usage (cost) VALUES (1.5), (2.5)")
        }
        try original.close()

        // The file is plaintext, so it must be detected as NOT encrypted.
        XCTAssertFalse(
            DatabaseEncryptionService.isEncryptedDatabaseFile(at: path),
            "A plaintext SQLite file must be detected as not encrypted"
        )

        // Re-open via the explicit plaintext path and verify all rows survive.
        let reopened = try DatabasePool(path: path, configuration: plainConfig)
        let (count, total) = try reopened.read { db -> (Int, Double) in
            let c = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM usage") ?? -1
            let t = try Double.fetchOne(db, sql: "SELECT SUM(cost) FROM usage") ?? -1
            return (c, t)
        }
        XCTAssertEqual(count, 2, "Existing plaintext rows must survive re-open")
        XCTAssertEqual(total, 4.0, accuracy: 0.0001, "Existing plaintext data must be intact")
        try reopened.close()
    }

    @MainActor
    func testCoordinatorRefusesExistingPlaintextDatabaseWhenEncryptionEnabled() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-plain-refuse-\(UUID().uuidString).sqlite")
        let defaults = UserDefaults.standard
        let previousEncryptionDefault = defaults.object(forKey: "databaseEncryptionEnabled")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            if let previousEncryptionDefault {
                defaults.set(previousEncryptionDefault, forKey: "databaseEncryptionEnabled")
            } else {
                defaults.removeObject(forKey: "databaseEncryptionEnabled")
            }
        }

        let plainConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
        let plaintext = try DatabasePool(path: path, configuration: plainConfig)
        try plaintext.write { db in
            try db.execute(sql: "CREATE TABLE t (value TEXT)")
            try db.execute(sql: "INSERT INTO t (value) VALUES ('plain')")
        }
        try plaintext.close()

        defaults.set(true, forKey: "databaseEncryptionEnabled")
        do {
            let opened = try DataStoreCoordinator.makeDatabasePoolForTesting(path: path)
            try opened.close()
            XCTFail("Coordinator must refuse an existing plaintext database while encryption is enabled.")
        } catch DatabaseEncryptionError.plaintextDatabaseRequiresMigration(let refusedPath) {
            XCTAssertEqual(refusedPath, path)
        } catch {
            XCTFail("Expected plaintextDatabaseRequiresMigration, got \(error)")
        }
    }

    func testMakeConfigurationWithoutKey_allowsPlainDatabase() throws {
        let config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-plain-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pool = try DatabasePool(path: path, configuration: config)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE t (a INTEGER)")
        }
        let count = try pool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master")
        }
        XCTAssertEqual(count, 1)
    }

    // MARK: - Key Lifecycle Tests

    func testGetOrCreateKey_generatesNewKey() {
        let key1 = DatabaseEncryptionService.getOrCreateKey()
        XCTAssertFalse(key1.isEmpty)
        XCTAssertEqual(key1.count, 44, "Base64 encoding of 32 bytes should be 44 characters")

        let key2 = DatabaseEncryptionService.getOrCreateKey()
        XCTAssertEqual(key1, key2, "Second call should return the existing key")
    }

    func testDeleteKey_removesKey() {
        _ = DatabaseEncryptionService.getOrCreateKey()
        XCTAssertNotNil(DatabaseEncryptionService.getKey())

        DatabaseEncryptionService.deleteKey()
        XCTAssertNil(DatabaseEncryptionService.getKey())
    }

    func testGetKey_returnsNilAfterDeletion() {
        XCTAssertNil(DatabaseEncryptionService.getKey())
        let key = DatabaseEncryptionService.getOrCreateKey()
        XCTAssertEqual(DatabaseEncryptionService.getKey(), key)
        DatabaseEncryptionService.deleteKey()
        XCTAssertNil(DatabaseEncryptionService.getKey())
    }

    // MARK: - Recovery Bundle Tests

    func testExportRecoveryBundle_roundTripsKey() {
        let originalKey = DatabaseEncryptionService.getOrCreateKey()
        let password = "unit test recovery phrase 42"

        guard let bundle = DatabaseEncryptionService.exportRecoveryBundle(password: password) else {
            XCTFail("exportRecoveryBundle should return non-nil data")
            return
        }
        XCTAssertGreaterThan(bundle.count, 21, "Bundle must contain header + salt + iterations + ciphertext")

        // Simulate key loss
        DatabaseEncryptionService.deleteKey()
        XCTAssertNil(DatabaseEncryptionService.getKey())

        let recovered = DatabaseEncryptionService.importRecoveryBundle(data: bundle, password: password)
        XCTAssertEqual(recovered, originalKey, "Recovered key should match original")
        XCTAssertEqual(DatabaseEncryptionService.getKey(), originalKey, "Key should be re-imported into Keychain")
    }

    func testImportRecoveryBundle_wrongPasswordReturnsNil() {
        let originalKey = DatabaseEncryptionService.getOrCreateKey()
        let bundle = DatabaseEncryptionService.exportRecoveryBundle(password: "right-password")
        XCTAssertNotNil(bundle)

        DatabaseEncryptionService.deleteKey()
        let recovered = DatabaseEncryptionService.importRecoveryBundle(data: bundle!, password: "wrong-password")
        XCTAssertNil(recovered, "Wrong password should fail to decrypt")
    }

    func testImportRecoveryBundle_corruptedDataReturnsNil() {
        _ = DatabaseEncryptionService.getOrCreateKey()
        let bundle = DatabaseEncryptionService.exportRecoveryBundle(password: "any-password")
        XCTAssertNotNil(bundle)

        var corrupted = bundle!
        if corrupted.count > 22 {
            corrupted[22] = corrupted[22] ^ 0xFF // flip bits in ciphertext
        }

        let recovered = DatabaseEncryptionService.importRecoveryBundle(data: corrupted, password: "any-password")
        XCTAssertNil(recovered, "Corrupted bundle should fail authentication")
    }

    func testImportRecoveryBundle_unsupportedVersionReturnsNil() {
        var fakeBundle = Data([0xFF]) // unsupported version
        fakeBundle.append(contentsOf: [UInt8](repeating: 0, count: 20))
        fakeBundle.append(contentsOf: [UInt8](repeating: 0, count: 16)) // minimum ciphertext + tag

        let recovered = DatabaseEncryptionService.importRecoveryBundle(data: fakeBundle, password: "irrelevant")
        XCTAssertNil(recovered, "Unsupported version should be rejected")
    }

    func testExportRecoveryBundle_withoutKeyReturnsNil() {
        DatabaseEncryptionService.deleteKey()
        XCTAssertNil(DatabaseEncryptionService.exportRecoveryBundle(password: "password"))
    }

    func testRecoveryBundle_cannotBeRecoveredWithDifferentSalt() {
        let password = "shared-password"
        _ = DatabaseEncryptionService.getOrCreateKey()
        let bundle1 = DatabaseEncryptionService.exportRecoveryBundle(password: password)
        XCTAssertNotNil(bundle1)

        // Export again — should get a different salt and thus different bundle bytes
        let bundle2 = DatabaseEncryptionService.exportRecoveryBundle(password: password)
        XCTAssertNotNil(bundle2)
        XCTAssertNotEqual(bundle1, bundle2, "Each export should use a fresh random salt")

        // Both should still decrypt to the same key
        DatabaseEncryptionService.deleteKey()
        let recovered1 = DatabaseEncryptionService.importRecoveryBundle(data: bundle1!, password: password)
        DatabaseEncryptionService.deleteKey()
        let recovered2 = DatabaseEncryptionService.importRecoveryBundle(data: bundle2!, password: password)
        XCTAssertEqual(recovered1, recovered2)
    }

    func testDatabaseOpensAfterKeychainRecovery() throws {
        try XCTSkipUnless(Self.sqlCipherIsActive(), "Requires a SQLCipher-linked build to create + reopen an encrypted database.")
        let testKey = DatabaseEncryptionService.getOrCreateKey()
        let config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: testKey)
        let dbPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-recovery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        // Create an encrypted database
        let pool = try DatabasePool(path: dbPath, configuration: config)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE test_recovery (id INTEGER PRIMARY KEY)")
        }
        try pool.close()

        // Simulate Keychain loss: export bundle, delete key, then recover
        let password = "recovery-passphrase-99"
        guard let bundle = DatabaseEncryptionService.exportRecoveryBundle(password: password) else {
            XCTFail("Export should succeed")
            return
        }
        DatabaseEncryptionService.deleteKey()
        XCTAssertNil(DatabaseEncryptionService.getKey())

        let recoveredKey = DatabaseEncryptionService.importRecoveryBundle(data: bundle, password: password)
        XCTAssertEqual(recoveredKey, testKey)

        // Verify the database can be opened with the recovered key
        let recoveredConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: recoveredKey)
        let recoveredPool = try DatabasePool(path: dbPath, configuration: recoveredConfig)
        let count = try recoveredPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM test_recovery")
        }
        XCTAssertEqual(count, 0, "Database should be readable with recovered key")
        try recoveredPool.close()
    }
}
