import GRDB
import XCTest

@testable import OpenBurnBar

private final class InMemoryDatabaseEncryptionKeychain {
    private let lock = NSLock()
    private var storedData: Data?

    lazy var client = DatabaseEncryptionKeychainClient(
        copyMatching: { [weak self] _ in
            guard let self else { return (errSecItemNotFound, nil) }
            return self.copyMatching()
        },
        add: { [weak self] query in
            guard let self else { return errSecNotAvailable }
            return self.add(query)
        },
        delete: { [weak self] _ in
            guard let self else { return errSecNotAvailable }
            return self.delete()
        }
    )

    private func copyMatching() -> (status: OSStatus, result: AnyObject?) {
        lock.lock()
        defer { lock.unlock() }
        guard let storedData else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, storedData as AnyObject)
    }

    private func add(_ query: [String: Any]) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard storedData == nil else { return errSecDuplicateItem }
        guard let data = query[kSecValueData as String] as? Data else { return errSecParam }
        storedData = data
        return errSecSuccess
    }

    private func delete() -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        storedData = nil
        return errSecSuccess
    }
}

/// Verifies the GRDB+SQLCipher SPM build applies the SQLCipher passphrase and reports `cipher_version`,
/// and validates the SOTA key recovery design (Keychain-only + explicit passphrase bundle).
final class DatabaseEncryptionServiceTests: XCTestCase {
    override func invokeTest() {
        let keychain = InMemoryDatabaseEncryptionKeychain()
        DatabaseEncryptionService.withKeychainClientForTesting(keychain.client) {
            super.invokeTest()
        }
    }

    /// Opens the app target's GRDB module and reads `PRAGMA cipher_version`.
    /// A non-empty value proves GRDB is backed by SQLCipher rather than stock
    /// SQLite. This must stay hard-required now that SQLCipher is vendored.
    private static func readGRDBCipherVersion() throws -> String? {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase("probe")
        }
        let pool = try DatabaseQueue(path: ":memory:", configuration: config)
        defer { try? pool.close() }
        return try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
    }

    private static func sqlCipherIsActive() -> Bool {
        do {
            guard let version = try readGRDBCipherVersion() else { return false }
            return version.isEmpty == false
        } catch {
            return false
        }
    }

    func testGRDBRuntimeReportsSQLCipherVersion() throws {
        let version = try XCTUnwrap(
            try Self.readGRDBCipherVersion(),
            "The app target's GRDB module must report SQLCipher through PRAGMA cipher_version."
        )
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(
            version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression),
            "Unexpected SQLCipher version format: \(version)"
        )
    }

    /// (a) With a key applied, `cipher_version` must be non-empty. Vendoring the
    /// SQLCipher-backed GRDB package means a missing codec is no longer an
    /// acceptable local or release-build outcome.
    func testMakeConfigurationWithKey_reportsCipherVersion() throws {
        let key = "k3y-" + String(repeating: "a", count: 32)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-enc-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: key)
        let pool = try DatabasePool(path: path, configuration: config)
        defer { try? pool.close() }
        let version = try pool.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
        XCTAssertNotNil(version)
        XCTAssertFalse(version?.isEmpty ?? true, "cipher_version should be set when using SQLCipher")
    }

    /// (a) A keyed open must succeed through SQLCipher and write an encrypted file.
    /// Stock-SQLite fallback would either make this test fail at open time or leave
    /// the SQLite magic header on disk.
    func testKeyedOpen_writesEncryptedDatabase() throws {
        let key = "k3y-" + String(repeating: "a", count: 32)
        let config = try DatabaseEncryptionService.makeConfiguration(encryptionKey: key)
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-hardfail-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        let pool = try DatabasePool(path: path, configuration: config)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE keyed (value INTEGER)")
            try db.execute(sql: "INSERT INTO keyed (value) VALUES (7)")
        }
        try pool.close()
        XCTAssertTrue(
            DatabaseEncryptionService.isEncryptedDatabaseFile(at: path),
            "A keyed open must produce a SQLCipher-encrypted file, not plaintext SQLite."
        )
    }

    /// (c) A plaintext `DatabasePool` cannot open a file written with encryption on.
    /// Only meaningful when SQLCipher is active (otherwise there is no encrypted file
    /// to fail against); skipped on a plain-SQLite build.
    func testPlaintextPoolCannotOpenEncryptedFile() throws {
        try XCTSkipUnless(Self.sqlCipherIsActive(), "Requires a SQLCipher-linked build to produce an encrypted file.")
        let key = try XCTUnwrap(
            DatabaseEncryptionService.getOrCreateKey(),
            "Keychain-backed encryption key creation must succeed before writing an encrypted test database."
        )
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
    /// migration/test tooling path. Production startup is covered separately
    /// below and must migrate the file before opening it.
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

    #if DEBUG
    /// A legacy persisted encryption opt-out must never reopen the production
    /// database plaintext. Startup normalizes the retired preference, migrates
    /// an existing plaintext file to SQLCipher, and preserves its data.
    @MainActor
    func testCoordinatorMigratesLegacyPlaintextDatabaseWhenEncryptionPreferenceIsFalse() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-plain-refuse-\(UUID().uuidString).sqlite")
        let defaults = UserDefaults.standard
        let previousEncryptionDefault = defaults.object(forKey: "databaseEncryptionEnabled")
        let previousFallbackFlag = defaults.object(forKey: DataStoreCoordinator.plaintextFallbackAcknowledgedDefaultsKey)
        let previousLegacyAcknowledgement = defaults.object(forKey: "plaintextDatabaseAcknowledged")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
            if let previousEncryptionDefault {
                defaults.set(previousEncryptionDefault, forKey: "databaseEncryptionEnabled")
            } else {
                defaults.removeObject(forKey: "databaseEncryptionEnabled")
            }
            if let previousFallbackFlag {
                defaults.set(previousFallbackFlag, forKey: DataStoreCoordinator.plaintextFallbackAcknowledgedDefaultsKey)
            } else {
                defaults.removeObject(forKey: DataStoreCoordinator.plaintextFallbackAcknowledgedDefaultsKey)
            }
            if let previousLegacyAcknowledgement {
                defaults.set(previousLegacyAcknowledgement, forKey: "plaintextDatabaseAcknowledged")
            } else {
                defaults.removeObject(forKey: "plaintextDatabaseAcknowledged")
            }
        }

        var plainConfig = Configuration()
        plainConfig.busyMode = .timeout(5)
        let plaintext = try DatabaseQueue(path: path, configuration: plainConfig)
        try plaintext.write { db in
            try db.execute(sql: "CREATE TABLE t (value TEXT)")
            try db.execute(sql: "INSERT INTO t (value) VALUES ('plain')")
        }
        try? plaintext.close()

        defaults.set(false, forKey: "databaseEncryptionEnabled")
        defaults.set(true, forKey: DataStoreCoordinator.plaintextFallbackAcknowledgedDefaultsKey)
        defaults.set(true, forKey: "plaintextDatabaseAcknowledged")

        let testKey = String(repeating: "a", count: 64)
        let keychain = DatabaseEncryptionKeychainClient(
            copyMatching: { _ in (errSecSuccess, Data(testKey.utf8) as AnyObject) },
            add: { _ in errSecSuccess },
            delete: { _ in errSecSuccess }
        )

        XCTAssertTrue(DatabaseEncryptionService.isCipherAvailable())
        let opened = try DatabaseEncryptionService.withKeychainClientForTesting(keychain) {
            try DataStoreCoordinator.makeDatabasePoolForTesting(path: path)
        }
        defer { try? opened.close() }
        let value = try opened.read { db in try String.fetchOne(db, sql: "SELECT value FROM t") }
        XCTAssertEqual(value, "plain", "First-launch SQLCipher migration must preserve existing plaintext data.")
        XCTAssertTrue(
            DatabaseEncryptionService.isEncryptedDatabaseFile(at: path),
            "First-launch migration must replace the plaintext file with an encrypted SQLCipher file."
        )
        XCTAssertFalse(
            defaults.bool(forKey: DataStoreCoordinator.plaintextFallbackAcknowledgedDefaultsKey),
            "Encryption-requested startup must not set or rely on the retired plaintext fallback disclosure flag."
        )
        XCTAssertTrue(
            defaults.bool(forKey: "databaseEncryptionEnabled"),
            "Production startup must normalize the retired encryption opt-out to enabled."
        )
        XCTAssertFalse(
            defaults.bool(forKey: "plaintextDatabaseAcknowledged"),
            "Production startup must clear the retired plaintext acknowledgement."
        )
    }
    #endif

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

    func testGetOrCreateKey_generatesNewKey() throws {
        let key1 = try XCTUnwrap(
            DatabaseEncryptionService.getOrCreateKey(),
            "getOrCreateKey must return a persisted key."
        )
        XCTAssertFalse(key1.isEmpty)
        XCTAssertEqual(key1.count, 44, "Base64 encoding of 32 bytes should be 44 characters")

        let key2 = try XCTUnwrap(
            DatabaseEncryptionService.getOrCreateKey(),
            "A second getOrCreateKey call must return the existing persisted key."
        )
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

    func testExportRecoveryBundle_roundTripsKey() throws {
        let originalKey = try XCTUnwrap(
            DatabaseEncryptionService.getOrCreateKey(),
            "Recovery bundle tests require a persisted source key."
        )
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
        XCTAssertNotNil(DatabaseEncryptionService.getOrCreateKey())
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

    /// A generated key must be persisted to the Keychain so subsequent calls
    /// return the same key. If persistence silently failed, the next launch would
    /// generate a different key and brick the encrypted database.
    func testGetOrCreateKey_isIdempotentAfterPersistence() {
        let first = DatabaseEncryptionService.getOrCreateKey()
        XCTAssertNotNil(first, "getOrCreateKey must return a key when Keychain persistence succeeds")
        let second = DatabaseEncryptionService.getOrCreateKey()
        XCTAssertEqual(first, second, "Repeated calls must return the same persisted key")
    }

    func testXCTestKeychainAccountIsIsolatedFromProduction() {
        let productionAccount = DatabaseEncryptionService.resolvedKeyIdentifierAccount(
            environment: [:],
            processIdentifier: 42
        )
        let testAccount = DatabaseEncryptionService.resolvedKeyIdentifierAccount(
            environment: ["XCTestConfigurationFilePath": "/tmp/OpenBurnBarTests.xctestconfiguration"],
            processIdentifier: 42
        )

        XCTAssertEqual(productionAccount, "database-encryption-key-v1")
        XCTAssertEqual(testAccount, "database-encryption-key-v1.xctest.42")
        XCTAssertNotEqual(testAccount, productionAccount)

        let runningTestAccount = DatabaseEncryptionService.resolvedKeyIdentifierAccount(
            environment: ProcessInfo.processInfo.environment,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        XCTAssertEqual(
            runningTestAccount,
            "database-encryption-key-v1.xctest.\(ProcessInfo.processInfo.processIdentifier)",
            "The real XCTest host must never resolve the production database-key account."
        )
    }

    func testExistingEncryptedDatabaseKeyFailuresProduceActionableRecoveryCopy() {
        let path = "/tmp/preserved-openburnbar.sqlite"
        let missing = DatabaseEncryptionError.existingEncryptedDatabaseKeyMissing(path: path)
        let rejected = DatabaseEncryptionError.existingEncryptedDatabaseKeyRejected(path: path)

        XCTAssertEqual(
            missing.localizedDescription,
            "The encryption key for this database is missing. OpenBurnBar preserved the database."
        )
        XCTAssertEqual(
            rejected.localizedDescription,
            "The stored encryption key cannot open this database. OpenBurnBar preserved the database."
        )
        XCTAssertEqual(
            missing.recoverySuggestion,
            "Restore the original key from a recovery bundle, or archive and reset to rebuild local data."
        )

        let failure = DataStoreStartupFailure.make(error: missing)
        XCTAssertEqual(failure.errorSummary, missing.localizedDescription)
        XCTAssertTrue(failure.technicalDetails.contains(path))
    }

    #if DEBUG
    func testGetOrCreatePersistedKey_throwsTypedErrorWhenKeychainAddFails() {
        let failingKeychain = DatabaseEncryptionKeychainClient(
            copyMatching: { _ in (errSecItemNotFound, nil) },
            add: { _ in errSecAuthFailed },
            delete: { _ in errSecSuccess }
        )

        XCTAssertThrowsError(
            try DatabaseEncryptionService.withKeychainClientForTesting(failingKeychain) {
                try DatabaseEncryptionService.getOrCreatePersistedKey()
            }
        ) { error in
            guard case DatabaseEncryptionError.keychainPersistenceFailed(let status) = error else {
                return XCTFail("Expected keychainPersistenceFailed, got \(error)")
            }
            XCTAssertEqual(status, errSecAuthFailed)
        }
    }

    @MainActor
    func testCoordinatorSetupAbortsWhenKeychainPersistenceFails() throws {
        XCTAssertTrue(
            DatabaseEncryptionService.isCipherAvailable(),
            "This setup-abort regression requires the vendored SQLCipher codec to reach the Keychain path."
        )

        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-keychain-abort-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        }

        let defaults = UserDefaults.standard
        let previousEncryptionDefault = defaults.object(forKey: "databaseEncryptionEnabled")
        defer {
            if let previousEncryptionDefault {
                defaults.set(previousEncryptionDefault, forKey: "databaseEncryptionEnabled")
            } else {
                defaults.removeObject(forKey: "databaseEncryptionEnabled")
            }
        }
        defaults.set(true, forKey: "databaseEncryptionEnabled")

        let failingKeychain = DatabaseEncryptionKeychainClient(
            copyMatching: { _ in (errSecItemNotFound, nil) },
            add: { _ in errSecAuthFailed },
            delete: { _ in errSecSuccess }
        )

        XCTAssertThrowsError(
            try DatabaseEncryptionService.withKeychainClientForTesting(failingKeychain) {
                try DataStoreCoordinator.makeDatabasePoolForTesting(path: path)
            }
        ) { error in
            guard case DatabaseEncryptionError.keychainPersistenceFailed(let status) = error else {
                return XCTFail("Expected coordinator setup to abort with keychainPersistenceFailed, got \(error)")
            }
            XCTAssertEqual(status, errSecAuthFailed)
        }

        for suffix in ["", "-wal", "-shm"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path + suffix),
                "Coordinator must not create a database file when the generated SQLCipher key was not persisted."
            )
        }
    }

    @MainActor
    func testCoordinatorDoesNotCreateReplacementKeyForEncryptedDatabaseWhenKeyIsMissing() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("obb-encrypted-missing-key-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let originalKey = Data("missing-key-regression".utf8).base64EncodedString()
        let originalConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: originalKey)
        let original = try DatabasePool(path: path, configuration: originalConfig)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE protected_value (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO protected_value (value) VALUES ('preserved')")
        }
        try original.close()
        let bytesBeforeOpen = try Data(contentsOf: URL(fileURLWithPath: path))

        var addCalls = 0
        let missingKeychain = DatabaseEncryptionKeychainClient(
            copyMatching: { _ in (errSecItemNotFound, nil) },
            add: { _ in
                addCalls += 1
                return errSecSuccess
            },
            delete: { _ in errSecSuccess }
        )

        XCTAssertThrowsError(
            try DatabaseEncryptionService.withKeychainClientForTesting(missingKeychain) {
                try DataStoreCoordinator.makeDatabasePoolForTesting(path: path)
            }
        ) { error in
            guard case DatabaseEncryptionError.existingEncryptedDatabaseKeyMissing(let failedPath) = error else {
                return XCTFail("Expected existingEncryptedDatabaseKeyMissing, got \(error)")
            }
            XCTAssertEqual(failedPath, path)
        }

        XCTAssertEqual(addCalls, 0, "Startup must not create a replacement key for an encrypted database.")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)),
            bytesBeforeOpen,
            "A missing-key startup attempt must leave the encrypted database byte-for-byte unchanged."
        )
    }

    @MainActor
    func testCoordinatorRejectsWrongKeyWithoutChangingEncryptedDatabase() throws {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("obb-encrypted-wrong-key-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let originalKey = Data("correct-key-regression".utf8).base64EncodedString()
        let wrongKey = Data("incorrect-key-regression".utf8).base64EncodedString()
        let originalConfig = try DatabaseEncryptionService.makeConfiguration(encryptionKey: originalKey)
        let original = try DatabasePool(path: path, configuration: originalConfig)
        try original.write { db in
            try db.execute(sql: "CREATE TABLE protected_value (value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO protected_value (value) VALUES ('preserved')")
        }
        try original.close()
        let bytesBeforeOpen = try Data(contentsOf: URL(fileURLWithPath: path))

        var addCalls = 0
        let wrongKeychain = DatabaseEncryptionKeychainClient(
            copyMatching: { _ in (errSecSuccess, Data(wrongKey.utf8) as AnyObject) },
            add: { _ in
                addCalls += 1
                return errSecSuccess
            },
            delete: { _ in errSecSuccess }
        )

        XCTAssertThrowsError(
            try DatabaseEncryptionService.withKeychainClientForTesting(wrongKeychain) {
                try DataStoreCoordinator.makeDatabasePoolForTesting(path: path)
            }
        ) { error in
            guard case DatabaseEncryptionError.existingEncryptedDatabaseKeyRejected(let failedPath) = error else {
                return XCTFail("Expected existingEncryptedDatabaseKeyRejected, got \(error)")
            }
            XCTAssertEqual(failedPath, path)
        }

        XCTAssertEqual(addCalls, 0)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)),
            bytesBeforeOpen,
            "A wrong-key startup attempt must leave the encrypted database byte-for-byte unchanged."
        )

        let reopened = try DatabasePool(path: path, configuration: originalConfig)
        let value = try reopened.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM protected_value")
        }
        XCTAssertEqual(value, "preserved")
        try reopened.close()
    }
    #endif

    func testReleaseGateRequiresActiveSQLCipherWhenEnabled() throws {
        let version = try DatabaseEncryptionService.requireLinkedSQLCipherForRelease()
        XCTAssertFalse(version.isEmpty)
    }

    func testDatabaseOpensAfterKeychainRecovery() throws {
        try XCTSkipUnless(Self.sqlCipherIsActive(), "Requires a SQLCipher-linked build to create + reopen an encrypted database.")
        let testKey = try XCTUnwrap(
            DatabaseEncryptionService.getOrCreateKey(),
            "Database recovery tests require a persisted SQLCipher key."
        )
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

    // MARK: - Orphaned Migration Artifact Sweep

    /// A migration process that dies mid-export (SIGKILL, force quit, shutdown)
    /// strands its `<db>.sqlcipher-migrating-<UUID>` temp database (plus
    /// `-wal`/`-shm`/`-journal` sidecars) forever — one real machine accumulated
    /// 9.4 GB of them. The sweep must delete every artifact matching the prefix.
    func testOrphanSweep_deletesOrphanTempDatabasesAndSidecars() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = (directory as NSString).appendingPathComponent("openburnbar.sqlite")

        let orphanA = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        let orphanB = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        let orphanPaths = [orphanA, orphanA + "-journal", orphanA + "-wal", orphanA + "-shm", orphanB]
        for orphanPath in orphanPaths {
            try Data("orphaned migration payload".utf8).write(to: URL(fileURLWithPath: orphanPath))
        }

        DatabaseEncryptionService.removeOrphanedMigrationArtifacts(forDatabaseAt: dbPath)

        for orphanPath in orphanPaths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: orphanPath),
                "Sweep must delete orphaned migration artifact at \(orphanPath)"
            )
        }
    }

    /// The sweep must be strictly name-scoped: the live database, its own
    /// `-wal`/`-shm` sidecars, another database's migration temp files, and
    /// near-miss names must all survive untouched.
    func testOrphanSweep_leavesLiveDatabaseAndUnrelatedFilesUntouched() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = (directory as NSString).appendingPathComponent("openburnbar.sqlite")

        let liveDatabaseContent = Data("live database bytes".utf8)
        try liveDatabaseContent.write(to: URL(fileURLWithPath: dbPath))
        let keeperPaths = [
            dbPath + "-wal",
            dbPath + "-shm",
            // Another database's orphan: prefix must match THIS db's file name only.
            (directory as NSString).appendingPathComponent("other.sqlite.sqlcipher-migrating-\(UUID().uuidString)"),
            // Near-misses: wrong leading character / missing trailing dash.
            (directory as NSString).appendingPathComponent("xopenburnbar.sqlite.sqlcipher-migrating-\(UUID().uuidString)"),
            dbPath + ".sqlcipher-migratingNOT",
            dbPath + ".backup"
        ]
        for keeperPath in keeperPaths {
            try Data("keep me".utf8).write(to: URL(fileURLWithPath: keeperPath))
        }
        let orphanPath = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        try Data("orphaned migration payload".utf8).write(to: URL(fileURLWithPath: orphanPath))

        DatabaseEncryptionService.removeOrphanedMigrationArtifacts(forDatabaseAt: dbPath)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPath), "Sweep must delete the orphan")
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: dbPath)),
            liveDatabaseContent,
            "Sweep must never touch the live database"
        )
        for keeperPath in keeperPaths {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: keeperPath),
                "Sweep must not delete unrelated file at \(keeperPath)"
            )
        }
    }

    /// A database path whose parent directory does not exist (first launch before
    /// the app-support directory is provisioned) must be a silent no-op.
    func testOrphanSweep_toleratesMissingDirectory() {
        let missingPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("obb-sweep-missing-\(UUID().uuidString)/nested/openburnbar.sqlite")
        DatabaseEncryptionService.removeOrphanedMigrationArtifacts(forDatabaseAt: missingPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingPath))
    }

    func testOrphanSweep_toleratesDirectoryEnumerationFailure() throws {
        let directoryPlaceholder = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-orphan-scan-file-\(UUID().uuidString)")
        try Data("not a directory".utf8).write(to: directoryPlaceholder)
        defer { try? FileManager.default.removeItem(at: directoryPlaceholder) }

        let databasePath = directoryPlaceholder
            .appendingPathComponent("openburnbar.sqlite")
            .path

        DatabaseEncryptionService.removeOrphanedMigrationArtifacts(forDatabaseAt: databasePath)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directoryPlaceholder.path),
            "A failed best-effort scan must not alter the path that could not be enumerated"
        )
    }

    func testOrphanSweep_removesArtifactWhenSizeLookupFails() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = (directory as NSString).appendingPathComponent("openburnbar.sqlite")
        let orphanPath = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        try Data("orphan".utf8).write(to: URL(fileURLWithPath: orphanPath))

        let fileManager = AttributeFaultFileManager(faultingPath: orphanPath)
        DatabaseEncryptionService.removeOrphanedMigrationArtifacts(
            forDatabaseAt: dbPath,
            fileManager: fileManager
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanPath),
            "Size telemetry is best-effort; cleanup must continue when attributes cannot be read"
        )
    }

    /// Entering the migration check must reclaim orphans even when no migration
    /// runs (here: the primary database file does not exist yet).
    func testMigratePlaintextDatabaseIfNeeded_sweepsOrphansAtEntry() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = (directory as NSString).appendingPathComponent("openburnbar.sqlite")
        let orphanPath = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        try Data("orphaned migration payload".utf8).write(to: URL(fileURLWithPath: orphanPath))

        let migrated = try DatabaseEncryptionService.migratePlaintextDatabaseIfNeeded(
            at: dbPath,
            encryptionKey: String(repeating: "a", count: 64)
        )

        XCTAssertFalse(migrated, "No primary database file exists, so no migration should run")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanPath),
            "Checking migration must sweep orphaned temp databases from prior crashed migrations"
        )
    }

    /// The orphan sweep's size lookup (`attributesOfItem`) can fail when a
    /// stranded migration temp file is removed between the directory enumeration
    /// and the per-entry stat (a TOCTOU race against another reaper, or a
    /// filesystem that declines to report size). Cleanup must fail OPEN: a
    /// size-lookup failure must NOT abort removal of the orphan — the strand is
    /// reclaimed exactly as it would be when the size is known, and no error is
    /// propagated. Exercises the `do { attributes… } catch` branch in
    /// `removeOrphanedMigrationArtifacts`.
    func testOrphanSweep_removesOrphanEvenWhenSizeLookupFails() throws {
        let directory = try makeOrphanSweepDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let dbPath = (directory as NSString).appendingPathComponent("openburnbar.sqlite")

        // A real orphan matching the prefix so the sweep reaches the size-lookup.
        let orphanPath = dbPath + ".sqlcipher-migrating-" + UUID().uuidString
        try Data("orphaned migration payload".utf8).write(to: URL(fileURLWithPath: orphanPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanPath), "Precondition: orphan must exist")

        // Inject a size lookup that always fails, simulating the TOCTOU/stat-failure
        // branch deterministically (the real path is only reachable via a
        // non-deterministic race). The default lookup is restored on exit.
        var sizeLookupWasCalled = false
        try DatabaseEncryptionService.withOrphanSizeLookupForTesting(
            { _, _ in
                sizeLookupWasCalled = true
                throw CocoaError(.fileReadNoSuchFile)
            },
            {
                DatabaseEncryptionService.removeOrphanedMigrationArtifacts(forDatabaseAt: dbPath)
            }
        )

        // The failing size lookup must have been consulted (proves the branch ran)
        // and — the real contract — the orphan must STILL be removed despite it.
        XCTAssertTrue(sizeLookupWasCalled, "Sweep must consult the size lookup for a matching orphan")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: orphanPath),
            "Sweep must delete the orphan even when its size lookup fails (fail-open cleanup)"
        )
    }

    private func makeOrphanSweepDirectory() throws -> String {
        let directory = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("obb-orphan-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class AttributeFaultFileManager: FileManager {
    private let faultingPath: String

    init(faultingPath: String) {
        self.faultingPath = faultingPath
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path == faultingPath {
            throw CocoaError(.fileReadUnknown)
        }
        return try super.attributesOfItem(atPath: path)
    }
}
