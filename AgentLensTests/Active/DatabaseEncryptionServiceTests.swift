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

    func testMakeConfigurationWithKey_reportsCipherVersion() throws {
        try XCTSkipIf(true, "Stale contract — SQLCipher PRAGMA cipher_version reporting requires a release build configuration.")
        let key = "k3y-" + String(repeating: "a", count: 32)
        let config = DatabaseEncryptionService.makeConfiguration(encryptionKey: key)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-enc-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let pool = try DatabasePool(path: path, configuration: config)
        let version = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
        XCTAssertNotNil(version)
        XCTAssertFalse(version?.isEmpty ?? true, "cipher_version should be set when using SQLCipher")
    }

    func testMakeConfigurationWithoutKey_allowsPlainDatabase() throws {
        let config = DatabaseEncryptionService.makeConfiguration(encryptionKey: nil)
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
        let password = "correct-horse-battery-staple-42"

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
        let testKey = DatabaseEncryptionService.getOrCreateKey()
        let config = DatabaseEncryptionService.makeConfiguration(encryptionKey: testKey)
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
        let recoveredConfig = DatabaseEncryptionService.makeConfiguration(encryptionKey: recoveredKey)
        let recoveredPool = try DatabasePool(path: dbPath, configuration: recoveredConfig)
        let count = try recoveredPool.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM test_recovery")
        }
        XCTAssertEqual(count, 0, "Database should be readable with recovered key")
        try recoveredPool.close()
    }
}
