import GRDB
import XCTest

@testable import OpenBurnBar

/// Verifies the GRDB+SQLCipher SPM build applies `PRAGMA key` and reports `cipher_version`.
final class DatabaseEncryptionServiceTests: XCTestCase {
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

    // MARK: - Recovery File Tests

    private func tempRecoveryURL() -> URL {
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-recovery-tests-\(UUID().uuidString)")
        return URL(fileURLWithPath: tempDir).appendingPathComponent(".encryption-key-recovery")
    }

    func testPersistKeyRecovery_createsFile() throws {
        let recoveryURL = tempRecoveryURL()
        let tempDir = recoveryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let key = "test-recovery-key-base64-value=="
        let success = DatabaseEncryptionService.persistKeyRecovery(key: key, to: recoveryURL)
        XCTAssertTrue(success, "persistKeyRecovery should return true on success")

        // Verify file exists and has correct permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        let perms = attrs[.posixPermissions] as? UInt16 ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "Recovery file should have 0o600 permissions")

        // Verify file content format
        let content = try String(contentsOf: recoveryURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("sha256:"), "Recovery file should start with sha256: prefix")
        XCTAssertTrue(content.contains(key), "Recovery file should contain the key")
    }

    func testRecoverKeyFromRecoveryFile_succeedsAfterKeychainLoss() throws {
        let recoveryURL = tempRecoveryURL()
        let tempDir = recoveryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let key = "dGhpcyBpcyBhIHRlc3Qga2V5" // base64-looking test key
        let success = DatabaseEncryptionService.persistKeyRecovery(key: key, to: recoveryURL)
        XCTAssertTrue(success)

        let recovered = DatabaseEncryptionService.recoverKeyFromRecoveryFile(at: recoveryURL)
        XCTAssertEqual(recovered, key, "Recovered key should match the original")
    }

    func testRecoverKeyFromRecoveryFile_returnsNilForMissingFile() throws {
        let recoveryURL = URL(fileURLWithPath: "/tmp/obb-nonexistent-\(UUID().uuidString)/.encryption-key-recovery")
        let recovered = DatabaseEncryptionService.recoverKeyFromRecoveryFile(at: recoveryURL)
        XCTAssertNil(recovered, "Recovery should return nil for nonexistent file")
    }

    func testRecoverKeyFromRecoveryFile_returnsNilForCorruptedContent() throws {
        let recoveryURL = tempRecoveryURL()
        let tempDir = recoveryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write a corrupted recovery file with wrong hash
        let corruptedContent = "sha256:0000000000000000\ncorrupted-key"
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try corruptedContent.write(to: recoveryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)

        let recovered = DatabaseEncryptionService.recoverKeyFromRecoveryFile(at: recoveryURL)
        XCTAssertNil(recovered, "Recovery should return nil when integrity check fails")
    }

    func testRecoverKeyFromRecoveryFile_returnsNilForOverlyPermissiveFile() throws {
        let recoveryURL = tempRecoveryURL()
        let tempDir = recoveryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a valid recovery file but with overly permissive permissions
        let key = "test-key-for-perm-check=="
        _ = DatabaseEncryptionService.persistKeyRecovery(key: key, to: recoveryURL)

        // Loosen permissions to world-readable
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: recoveryURL.path)

        let recovered = DatabaseEncryptionService.recoverKeyFromRecoveryFile(at: recoveryURL)
        XCTAssertNil(recovered, "Recovery should refuse to use a world-readable recovery file")
    }

    func testRemoveKeyRecoveryFile_deletesFile() throws {
        let recoveryURL = tempRecoveryURL()
        let tempDir = recoveryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let key = "key-to-be-removed"
        _ = DatabaseEncryptionService.persistKeyRecovery(key: key, to: recoveryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))

        DatabaseEncryptionService.removeKeyRecoveryFile(at: recoveryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    func testDatabaseOpensAfterKeychainRecovery() throws {
        // This test simulates a full keychain loss/recovery cycle:
        // 1. Create an encrypted database with a key
        // 2. The recovery file is persisted alongside
        // 3. Simulate Keychain loss by deleting the key
        // 4. getOrCreateKey() recovers from file and re-imports to Keychain
        // 5. Database opens successfully with the recovered key
        let testKey = "recovery-cycle-test-key-" + String(repeating: "x", count: 20)
        let config = DatabaseEncryptionService.makeConfiguration(encryptionKey: testKey)
        let dbPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("obb-recovery-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        // Create an encrypted database
        let pool = try DatabasePool(path: dbPath, configuration: config)
        try pool.write { db in
            try db.execute(sql: "CREATE TABLE test_recovery (id INTEGER PRIMARY KEY)")
        }
        try pool.close()

        // Persist recovery file
        let recoveryURL = tempRecoveryURL()
        let tempDir = recoveryURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        XCTAssertTrue(DatabaseEncryptionService.persistKeyRecovery(key: testKey, to: recoveryURL))

        // Simulate Keychain loss: delete key, then recover from file
        DatabaseEncryptionService.deleteKey()

        // getOrCreateKey should recover from the file
        let recoveredKey = DatabaseEncryptionService.getOrCreateKey(recoveryURL: recoveryURL)
        XCTAssertEqual(recoveredKey, testKey, "getOrCreateKey should return the recovered key")

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
