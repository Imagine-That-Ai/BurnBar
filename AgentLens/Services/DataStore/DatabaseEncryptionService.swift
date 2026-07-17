import CryptoKit
import Foundation
import GRDB
import Security
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

// MARK: - Database Encryption Service
//
// Manages the SQLCipher encryption key lifecycle in the macOS Keychain.
// When database encryption is enabled, the key is stored in the Keychain with
// kSecAttrAccessibleWhenUnlockedThisDeviceOnly so the app can open the database
// only when the device is unlocked and the key never leaves this device.
//
// The key is generated once using CryptoKit (SymmetricKey → 256-bit AES) and
// stored as a base64-encoded string. A UUID-based identifier is used as the
// Keychain account name to support future key rotation.
//
// SECURITY: The key is applied in SQLCipher *passphrase* mode through GRDB's
// `Database.usePassphrase(_:)` wrapper around SQLCipher's C API (NOT raw
// `x'<hex>'` mode). Passphrase mode runs the stored base64 string through
// SQLCipher's PBKDF2 key-derivation; raw mode would instead use the bytes as the
// AES key directly and derive a *different* key, so the two formats are not
// interchangeable for an existing database. Migration still has to pass the key
// through SQLCipher's ATTACH syntax, so the same base64 charset validation is
// retained before any SQL interpolation.
//
// RECOVERY: There is no automatic plaintext recovery file. Keychain loss means
// data loss. Users may explicitly export an encrypted recovery bundle protected
// by a user-chosen passphrase (PBKDF2 + AES-GCM). See exportRecoveryBundle
// and importRecoveryBundle.

/// Failures raised while configuring or opening an encrypted database.
enum DatabaseEncryptionError: Error, CustomStringConvertible {
    /// The build links a SQLite that is NOT SQLCipher (the `PRAGMA key` was a
    /// silent no-op, proven by `PRAGMA cipher_version` returning empty/nil), so
    /// the database would have been written in PLAINTEXT despite encryption being
    /// requested. We hard-fail instead of silently shipping plaintext.
    case cipherUnavailable

    /// A new encryption key was generated but could not be persisted to the
    /// Keychain. Using the key would create an unreadable database on next launch.
    case encryptionKeyUnavailable

    /// Keychain persistence returned an OSStatus failure while saving a newly
    /// generated database key. The caller must abort before opening SQLCipher.
    case keychainPersistenceFailed(status: OSStatus)

    /// SQLCipher was available and a plaintext database was eligible for first
    /// launch migration, but the export or atomic replacement failed.
    case plaintextMigrationFailed(path: String, detail: String)

    var description: String {
        switch self {
        case .cipherUnavailable:
            return "SQLCipher is not active in this build (PRAGMA cipher_version was empty); "
                + "the database would be written in plaintext. Refusing to open with encryption requested."
        case .encryptionKeyUnavailable:
            return "Failed to persist a new database encryption key to the Keychain. "
                + "Cannot create an encrypted database with an unpersisted key."
        case let .keychainPersistenceFailed(status):
            return "Failed to persist a new database encryption key to the Keychain (OSStatus \(status)). "
                + "Cannot create an encrypted database with an unpersisted key."
        case let .plaintextMigrationFailed(path, detail):
            return "Failed to migrate plaintext database at \(path) to SQLCipher: \(detail)"
        }
    }
}

// AUDIT(@unchecked Sendable): Security.framework Keychain calls require
// non-Sendable `[String: Any]` / `AnyObject` query payloads; access to the
// injectable client is serialized by DatabaseEncryptionKeychainClientBox.
// sendable-allowlist: foundation-sdk-shim
struct DatabaseEncryptionKeychainClient: @unchecked Sendable {
    var copyMatching: (_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?)
    var add: (_ query: [String: Any]) -> OSStatus
    var delete: (_ query: [String: Any]) -> OSStatus
}

// AUDIT(@unchecked Sendable): mutable test injection state is guarded by
// `lock`; callers copy the current client while locked before invoking it.
// sendable-allowlist: foundation-sdk-shim
private final class DatabaseEncryptionKeychainClientBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: DatabaseEncryptionKeychainClient

    init(_ client: DatabaseEncryptionKeychainClient) {
        current = client
    }

    func copyMatching(_ query: [String: Any]) -> (status: OSStatus, result: AnyObject?) {
        let client = withLockedClient()
        return client.copyMatching(query)
    }

    func add(_ query: [String: Any]) -> OSStatus {
        let client = withLockedClient()
        return client.add(query)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let client = withLockedClient()
        return client.delete(query)
    }

    func withClient<T>(_ client: DatabaseEncryptionKeychainClient, _ body: () throws -> T) rethrows -> T {
        let previous = swapClient(client)
        defer { _ = swapClient(previous) }
        return try body()
    }

    private func withLockedClient() -> DatabaseEncryptionKeychainClient {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private func swapClient(_ client: DatabaseEncryptionKeychainClient) -> DatabaseEncryptionKeychainClient {
        lock.lock()
        defer { lock.unlock() }
        let previous = current
        current = client
        return previous
    }
}

#if DEBUG
// AUDIT(@unchecked Sendable): test injection state is guarded by `lock`;
// sendable-allowlist: foundation-sdk-shim
private final class OrphanSizeLookupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: DatabaseEncryptionService.OrphanSizeLookup

    init() {
        current = { fileManager, path in
            try fileManager.attributesOfItem(atPath: path)
        }
    }

    func lookup(_ fileManager: FileManager, _ path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        let fn = current
        lock.unlock()
        return try fn(fileManager, path)
    }

    func withLookup<T>(_ lookup: @escaping DatabaseEncryptionService.OrphanSizeLookup, _ body: () throws -> T) rethrows -> T {
        let previous = swap(lookup)
        defer { _ = swap(previous) }
        return try body()
    }

    private func swap(_ fn: @escaping DatabaseEncryptionService.OrphanSizeLookup) -> DatabaseEncryptionService.OrphanSizeLookup {
        lock.lock()
        defer { lock.unlock() }
        let previous = current
        current = fn
        return previous
    }
}
#endif

enum DatabaseEncryptionService {
    private static let service = "com.openburnbar.database-encryption"
    private static let keyIdentifierAccount = "database-encryption-key-v1"
    private static let allowedKeyCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=-"))

    private static let keychainClient = DatabaseEncryptionKeychainClientBox(DatabaseEncryptionKeychainClient(
        copyMatching: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        },
        add: { query in
            SecItemAdd(query as CFDictionary, nil)
        },
        delete: { query in
            SecItemDelete(query as CFDictionary)
        }
    ))

    /// The 16-byte magic header every *plaintext* SQLite 3 file begins with.
    /// A SQLCipher-encrypted file's first page is ciphertext and does NOT carry
    /// this header, so its presence/absence cheaply distinguishes the two without
    /// needing the key. Reference: <https://www.sqlite.org/fileformat2.html#the_database_header>.
    private static let plaintextSQLiteMagic = Data("SQLite format 3\u{0}".utf8)

    // MARK: - Key Management

    /// UI-test builds derive the SQLCipher key from the environment so test runs
    /// never touch the login Keychain. Ad-hoc re-signed builds are treated as a
    /// new code identity by the Keychain, which prompts for the login password on
    /// every launch and makes unattended UI automation impossible. In UI-test
    /// mode we use a deterministic ephemeral key instead — the store still opens
    /// encrypted, but no Keychain access (and no prompt) occurs.
    static func uiTestDatabaseKey() -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENBURNBAR_UITEST"] == "1" else { return nil }
        if let provided = environment["OPENBURNBAR_UITEST_DB_KEY"], !provided.isEmpty {
            return provided
        }
        return Data("openburnbar-uitest-db-key-v1".utf8).base64EncodedString()
    }

    /// Returns the stored encryption key if one exists, nil otherwise.
    static func getKey() -> String? {
        if let testKey = uiTestDatabaseKey() {
            return testKey
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyIdentifierAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let lookup = keychainClient.copyMatching(query)
        let status = lookup.status
        let result = lookup.result
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Generates a new 256-bit AES key, stores it in the Keychain, and returns it.
    /// If a key already exists, returns the existing key without generating a new one.
    ///
    /// The Keychain item uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
    /// so the key is unavailable when the device is locked and cannot migrate
    /// to other devices via iCloud Keychain.
    ///
    /// Legacy optional wrapper for UI/recovery callers. SQLCipher setup must use
    /// `getOrCreatePersistedKey()` so Keychain failures stay typed and fail closed.
    static func getOrCreateKey() -> String? {
        do {
            return try getOrCreatePersistedKey()
        } catch {
            AppLogger.dataStore.error(
                "database_encryption_key_create_failed",
                metadata: ["error": "\(error)"]
            )
            return nil
        }
    }

    /// Generates a new 256-bit AES key, persists it to the Keychain, and returns
    /// it. Throws `DatabaseEncryptionError.keychainPersistenceFailed` if
    /// `SecItemAdd` fails. A generated-but-unpersisted key would encrypt a DB that
    /// cannot be reopened on next launch, so callers must abort.
    /// Closes FINDING-008.
    static func getOrCreatePersistedKey() throws -> String {
        if let existing = getKey() {
            return existing
        }
        // Generate a 256-bit random key encoded as base64.
        // Using 32 bytes = 256 bits of entropy.
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let key = Data(bytes).base64EncodedString()

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyIdentifierAccount,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = keychainClient.add(addQuery)
        guard status == errSecSuccess else {
            // Fail closed: if we cannot persist the key, returning it would
            // create a database encrypted with an unpersisted key that the
            // next launch cannot recover, causing silent data loss.
            AppLogger.dataStore.error("Failed to store database encryption key in Keychain (aborting key creation): \(status)", metadata: ["status": "\(status)"])
            throw DatabaseEncryptionError.keychainPersistenceFailed(status: status)
        }
        return key
    }

    /// Deletes the encryption key from the Keychain.
    /// WARNING: This will make any existing encrypted database unreadable.
    static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyIdentifierAccount
        ]
        _ = keychainClient.delete(query)
    }

    /// Legacy overload. Recovery file support has been removed; this now
    /// delegates to `getOrCreateKey()` and ignores the URL parameter.
    ///
    /// If you need recovery, use `exportRecoveryBundle(password:)` to create
    /// an explicit passphrase-protected backup, or `importRecoveryBundle(data:password:)`
    /// to restore from one.
    @available(*, deprecated, message: "Recovery file support removed. Use getOrCreateKey() or exportRecoveryBundle(password:).")
    static func getOrCreateKey(recoveryURL: URL) -> String? {
        _ = recoveryURL
        return getOrCreateKey()
    }

    // MARK: - Explicit Recovery Bundle

    /// Recovery bundle format version (1 byte at head of exported data).
    private static let recoveryBundleVersion: UInt8 = 1

    /// Minimum PBKDF2 iterations for recovery-bundle key derivation.
    private static let recoveryBundleIterations: UInt32 = 100_000

    /// Exports the current database encryption key as a passphrase-wrapped
    /// recovery bundle. The user must provide and remember the passphrase;
    /// without it the bundle cannot be decrypted.
    ///
    /// The bundle uses PBKDF2-HMAC-SHA256 (100k iterations, random 16-byte salt)
    /// to derive a 256-bit AES key from the passphrase, then encrypts the
    /// database key with AES-GCM. The returned data is safe to write to disk or
    /// transfer because it cannot be decrypted without the passphrase.
    ///
    /// - Returns: The wrapped recovery bundle as opaque data, or `nil` if the
    ///   key cannot be retrieved or wrapping fails.
    static func exportRecoveryBundle(password: String) -> Data? {
        guard let key = getKey() else { return nil }
        #if canImport(CommonCrypto)
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var derivedKeyData = Data(count: 32)
        let passwordData = Data(password.utf8)
        let iterations = recoveryBundleIterations

        let result = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derivedKeyData.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard result == kCCSuccess else { return nil }
        let symmetricKey = SymmetricKey(data: derivedKeyData)
        let keyData = Data(key.utf8)
        do {
            let sealedBox = try AES.GCM.seal(keyData, using: symmetricKey)
            guard let combined = sealedBox.combined else { return nil }
            var bundle = Data()
            bundle.append(contentsOf: [recoveryBundleVersion])
            bundle.append(salt)
            bundle.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian, Array.init))
            bundle.append(combined)
            return bundle
        } catch {
            AppLogger.dataStore.error("Failed to seal recovery bundle: \(error.localizedDescription)")
            return nil
        }
        #else
        AppLogger.dataStore.error("Recovery bundle export requires CommonCrypto (PBKDF2)")
        return nil
        #endif
    }

    /// Imports a database encryption key from a passphrase-wrapped recovery bundle.
    ///
    /// - Parameters:
    ///   - data: The recovery bundle produced by `exportRecoveryBundle(password:)`.
    ///   - password: The passphrase the user chose when exporting.
    /// - Returns: The unwrapped database key string, or `nil` if decryption fails
    ///   (wrong passphrase, corrupted bundle, or unsupported version).
    @discardableResult
    static func importRecoveryBundle(data: Data, password: String) -> String? {
        #if canImport(CommonCrypto)
        guard data.count > 21 else { return nil }
        let version = data[0]
        guard version == recoveryBundleVersion else { return nil }

        let salt = data.subdata(in: 1..<17)
        let iterations = data.subdata(in: 17..<21).withUnsafeBytes { ptr in
            ptr.load(as: UInt32.self).bigEndian
        }
        let combined = data.subdata(in: 21..<data.count)

        var derivedKeyData = Data(count: 32)
        let passwordData = Data(password.utf8)
        let result = passwordData.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                derivedKeyData.withUnsafeMutableBytes { keyBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }
        guard result == kCCSuccess else { return nil }
        let symmetricKey = SymmetricKey(data: derivedKeyData)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let decrypted = try AES.GCM.open(sealedBox, using: symmetricKey)
            guard let key = String(data: decrypted, encoding: .utf8) else { return nil }
            // Re-import the recovered key into the Keychain for future use.
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: keyIdentifierAccount,
                kSecValueData as String: Data(key.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            _ = keychainClient.delete(addQuery) // overwrite if present
            let addStatus = keychainClient.add(addQuery)
            if addStatus != errSecSuccess {
                AppLogger.dataStore.error("Failed to re-import recovered key to Keychain: \(addStatus)", metadata: ["status": "\(addStatus)"])
            }
            return key
        } catch {
            AppLogger.dataStore.error("Failed to open recovery bundle: \(error.localizedDescription)")
            return nil
        }
        #else
        AppLogger.dataStore.error("Recovery bundle import requires CommonCrypto (PBKDF2)")
        return nil
        #endif
    }

    #if DEBUG
    typealias OrphanSizeLookup = (_ fileManager: FileManager, _ path: String) throws -> [FileAttributeKey: Any]

    private static let orphanSizeLookupBox = OrphanSizeLookupBox()

    private static func orphanSizeLookup(_ fileManager: FileManager, _ path: String) throws -> [FileAttributeKey: Any] {
        try orphanSizeLookupBox.lookup(fileManager, path)
    }

    /// Swaps the orphan size-lookup closure for the duration of `body`,
    /// restoring the previous closure on exit. Mirrors
    /// `withKeychainClientForTesting`. Used to exercise the fail-open catch
    /// branch in `removeOrphanedMigrationArtifacts` deterministically.
    static func withOrphanSizeLookupForTesting<T>(
        _ lookup: @escaping OrphanSizeLookup,
        _ body: () throws -> T
    ) rethrows -> T {
        try orphanSizeLookupBox.withLookup(lookup, body)
    }
#else
    private static func orphanSizeLookup(
        _ fileManager: FileManager,
        _ path: String
    ) throws -> [FileAttributeKey: Any] {
        try fileManager.attributesOfItem(atPath: path)
    }
    #endif

    #if DEBUG
    static func withKeychainClientForTesting<T>(
        _ client: DatabaseEncryptionKeychainClient,
        _ body: () throws -> T
    ) rethrows -> T {
        try keychainClient.withClient(client, body)
    }
    #endif
}

// MARK: - Database Configuration with Encryption

extension DatabaseEncryptionService {
    /// Builds a GRDB `Configuration`. When `encryptionKey` is non-nil the
    /// configuration applies the SQLCipher passphrase on every connection AND
    /// self-checks that SQLCipher is genuinely active, throwing
    /// `DatabaseEncryptionError.cipherUnavailable` if it is not.
    ///
    /// **Why this is now the only path (the dead-guard bug):**
    /// GRDB's SQLCipher surface is still the `GRDB` module; there is no separate
    /// `GRDBCipher` product to import. The previous `#if canImport(GRDBCipher)`
    /// gate was therefore DEAD CODE: the keying block never compiled in, so the
    /// database could be written in PLAINTEXT even when encryption was requested.
    /// OpenBurnBar now vendors a GRDB package patched to import the pinned
    /// SQLCipher XCFramework instead of system SQLite, and applies the key
    /// through that real `import GRDB` build.
    ///
    /// **Key application (passphrase mode):**
    /// The key is base64 (A-Z, a-z, 0-9, +, /, =) plus '-'. It is validated for
    /// consistency with the first-launch migration path, where SQLCipher's ATTACH
    /// statement requires the key as a SQL string literal. For normal opens we use
    /// `Database.usePassphrase(_:)`, so the passphrase is handed to SQLCipher's C
    /// API without SQL interpolation.
    ///
    /// **`cipher_version` self-check:**
    /// Immediately after applying the key, inside `prepareDatabase`, we read
    /// `PRAGMA cipher_version`. On a SQLCipher build this returns the SQLCipher
    /// version string; on a plain SQLite build (where `PRAGMA key` was silently
    /// ignored) it returns nil/empty, and we throw
    /// `DatabaseEncryptionError.cipherUnavailable`. This is exactly the check that
    /// would have caught the dead-guard bug above. Because GRDB evaluates
    /// `prepareDatabase` lazily for each connection, this self-check fires when the
    /// pool actually opens a connection — so a keyed `DatabasePool(...)` open
    /// HARD-FAILS rather than ever silently shipping plaintext. The caller
    /// (`DataStoreCoordinator.makeDatabasePool`) surfaces that startup failure
    /// instead of downgrading to plaintext.
    ///
    /// - Throws: `DatabaseEncryptionError.cipherUnavailable` synchronously when the
    ///   key fails charset validation; and via `prepareDatabase` (at connection
    ///   open) when a key was requested but SQLCipher is not active in this build.
    static func makeConfiguration(encryptionKey: String?) throws -> Configuration {
        var config = Configuration()
        // The daemon writes to the same SQLite file (switcher profiles, indexed search).
        // Without a busy timeout, any cross-process write contention immediately raises
        // SQLITE_BUSY (error 5: "database is locked"). 5s matches GRDB's recommended default.
        config.busyMode = .timeout(5)
        guard let key = encryptionKey else {
            config.prepareDatabase { db in
                try installPersistentWALIfNeeded(on: db)
            }
            return config
        }

        // Validate that the key contains only safe characters before interpolation.
        // Allowed: base64 alphabet (A-Z, a-z, 0-9, +, /, =) plus hyphens for
        // backward compatibility with test keys. None of these characters can
        // escape a single-quoted SQL string literal (only ' and \ can do that).
        try validateEncryptionKey(key)

        config.prepareDatabase { db in
            try db.usePassphrase(key)
            // SQLCipher activity self-check. On a plain (non-SQLCipher) SQLite the
            // PRAGMA above is an ignored no-op and this returns empty/nil; we refuse
            // to proceed because the data would be plaintext.
            let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version")
            guard let version = cipherVersion, version.isEmpty == false else {
                AppLogger.dataStore.error(
                    "cipher_self_check_failed",
                    metadata: ["reason": "PRAGMA cipher_version empty; SQLCipher not active in this build"]
                )
                throw DatabaseEncryptionError.cipherUnavailable
            }
            try installPersistentWALIfNeeded(on: db)
        }

        return config
    }

    private static func installPersistentWALIfNeeded(on db: Database) throws {
        guard db.configuration.readonly == false else { return }
        var flag: CInt = 1
        let code = withUnsafeMutablePointer(to: &flag) { flagPointer in
            sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagPointer)
        }
        guard code != SQLITE_NOTFOUND else { return }
        guard code == SQLITE_OK else {
            throw DatabaseError(resultCode: ResultCode(rawValue: code))
        }
    }

    private static func validateEncryptionKey(_ key: String) throws {
        guard key.unicodeScalars.allSatisfy({ allowedKeyCharacters.contains($0) }) else {
            AppLogger.dataStore.error(
                "encryption_key_validation_failed",
                metadata: ["reason": "Key contains characters outside the allowed set"]
            )
            throw DatabaseEncryptionError.cipherUnavailable
        }
    }

    /// Migrates a legacy plaintext SQLite database to SQLCipher on first launch.
    /// Uses SQLCipher's `sqlcipher_export` so schema, indexes, and data move
    /// through the codec in one transaction. The original file is left untouched
    /// unless the encrypted replacement is complete.
    @discardableResult
    static func migratePlaintextDatabaseIfNeeded(at path: String, encryptionKey: String) throws -> Bool {
        removeOrphanedMigrationArtifacts(forDatabaseAt: path)
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard isEncryptedDatabaseFile(at: path) == false else { return false }
        guard isCipherAvailable() else { throw DatabaseEncryptionError.cipherUnavailable }
        try validateEncryptionKey(encryptionKey)

        let encryptedPath = path + ".sqlcipher-migrating-\(UUID().uuidString)"
        removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)

        do {
            let config = makePlaintextMigrationConfiguration()
            let source = try DatabaseQueue(path: path, configuration: config)
            do {
                try source.writeWithoutTransaction { db in
                    let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version")
                    guard let version = cipherVersion, version.isEmpty == false else {
                        throw DatabaseEncryptionError.cipherUnavailable
                    }
                    do {
                        _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                    } catch {
                        guard isMissingSQLiteSidecarRemoval(error) else { throw error }
                        AppLogger.dataStore.debug(
                            "database_migration_checkpoint_ignored_missing_sidecar",
                            metadata: ["path": path, "error": "\(error)"]
                        )
                    }
                    let escapedPath = encryptedPath.replacingOccurrences(of: "'", with: "''")
                    try db.execute(sql: "ATTACH DATABASE '\(escapedPath)' AS encrypted KEY '\(encryptionKey)'")
                    _ = try Row.fetchAll(db, sql: "SELECT sqlcipher_export('encrypted')")
                    try db.execute(sql: "DETACH DATABASE encrypted")
                }
            } catch {
                guard isEncryptedDatabaseFile(at: encryptedPath),
                      canOpenEncryptedDatabase(at: encryptedPath, encryptionKey: encryptionKey)
                else {
                    throw error
                }
                AppLogger.dataStore.debug(
                    "database_migration_write_error_ignored_after_verified_export",
                    metadata: ["path": path, "error": "\(error)"]
                )
            }
            do {
                try source.close()
            } catch {
                AppLogger.dataStore.debug(
                    "database_migration_source_close_ignored_after_export",
                    metadata: ["path": path, "error": "\(error)"]
                )
            }

            guard isEncryptedDatabaseFile(at: encryptedPath),
                  canOpenEncryptedDatabase(at: encryptedPath, encryptionKey: encryptionKey)
            else {
                throw DatabaseEncryptionError.plaintextMigrationFailed(
                    path: path,
                    detail: "export completed but encrypted replacement failed SQLCipher verification"
                )
            }

            removeDatabaseFilesIfPresent(at: path, includePrimary: false)
            removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: false)
            let replaceResult = encryptedPath.withCString { sourcePath in
                path.withCString { destinationPath in
                    rename(sourcePath, destinationPath)
                }
            }
            guard replaceResult == 0 else {
                let errorNumber = errno
                throw DatabaseEncryptionError.plaintextMigrationFailed(
                    path: path,
                    detail: "atomic replace failed with errno \(errorNumber): \(String(cString: strerror(errorNumber)))"
                )
            }
            return true
        } catch let error as DatabaseEncryptionError {
            removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)
            throw error
        } catch {
            removeDatabaseFilesIfPresent(at: encryptedPath, includePrimary: true)
            throw DatabaseEncryptionError.plaintextMigrationFailed(path: path, detail: "\(error)")
        }
    }

    /// Deletes orphaned `<dbFileName>.sqlcipher-migrating-<UUID>` temp databases
    /// (and their `-wal`/`-shm`/`-journal` sidecars, which share that prefix)
    /// from the database's parent directory. The temp file is only valid DURING a
    /// live `migratePlaintextDatabaseIfNeeded` call; when the process dies
    /// mid-export (SIGKILL, force quit, shutdown) the catch-path cleanup never
    /// runs and a multi-gigabyte orphan is stranded forever — a real machine
    /// accumulated 9.4 GB of them. Anything matching the prefix at entry is
    /// therefore dead and safe to remove; the live database and its own
    /// `-wal`/`-shm` never match. Best-effort by design: failures are logged and
    /// never interrupt startup or migration.
    static func removeOrphanedMigrationArtifacts(forDatabaseAt path: String) {
        let fileManager = FileManager.default
        let databaseURL = URL(fileURLWithPath: path)
        let databaseFileName = databaseURL.lastPathComponent
        guard databaseFileName.isEmpty == false else { return }
        let orphanPrefix = databaseFileName + ".sqlcipher-migrating-"
        let directoryURL = databaseURL.deletingLastPathComponent()
        let entries: [String]
        do {
            entries = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
        } catch {
            AppLogger.dataStore.error(
                "database_migration_orphan_enumeration_failed",
                metadata: ["path": directoryURL.path, "error": "\(error)"]
            )
            return
        }
        for entry in entries where entry.hasPrefix(orphanPrefix) {
            let orphanPath = directoryURL.appendingPathComponent(entry).path
            let orphanBytes: Int64
            do {
                let attributes = try orphanSizeLookup(fileManager, orphanPath)
                orphanBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                AppLogger.dataStore.debug(
                    "database_migration_orphan_size_unavailable",
                    metadata: ["path": orphanPath, "error": "\(error)"]
                )
                orphanBytes = 0
            }
            do {
                try fileManager.removeItem(atPath: orphanPath)
                AppLogger.dataStore.notice(
                    "database_migration_orphan_removed",
                    metadata: ["path": orphanPath, "reclaimedBytes": "\(orphanBytes)"]
                )
            } catch {
                AppLogger.dataStore.error(
                    "database_migration_orphan_cleanup_failed",
                    metadata: ["path": orphanPath, "error": "\(error)"]
                )
            }
        }
    }

    private static func removeDatabaseFilesIfPresent(at path: String, includePrimary: Bool) {
        let suffixes = includePrimary ? ["", "-wal", "-shm"] : ["-wal", "-shm"]
        for suffix in suffixes {
            removeFileIfPresent(at: path + suffix)
        }
    }

    private static func makePlaintextMigrationConfiguration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        return config
    }

    private static func removeFileIfPresent(at path: String) {
        #if canImport(Darwin)
        let result = path.withCString { unlink($0) }
        if result != 0, errno != ENOENT {
            AppLogger.dataStore.debug(
                "database_file_cleanup_failed",
                metadata: ["path": path, "errno": "\(errno)"]
            )
        }
        #else
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            AppLogger.dataStore.debug(
                "database_file_cleanup_failed",
                metadata: ["path": path, "error": "\(error)"]
            )
        }
        #endif
    }

    static func removeSQLiteSidecarsIfPresent(at path: String) {
        removeDatabaseFilesIfPresent(at: path, includePrimary: false)
    }

    private static func canOpenEncryptedDatabase(at path: String, encryptionKey: String) -> Bool {
        do {
            var config = Configuration()
            config.busyMode = .timeout(5)
            config.prepareDatabase { db in
                try db.usePassphrase(encryptionKey)
            }
            let queue = try DatabaseQueue(path: path, configuration: config)
            defer { closeQuietly(queue, context: "database_migration_verification_close_failed") }
            return try queue.read { db in
                let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version")
                guard cipherVersion?.isEmpty == false else { return false }
                return try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok"
            }
        } catch {
            AppLogger.dataStore.error(
                "database_migration_encrypted_verification_failed",
                metadata: ["path": path, "error": "\(error)"]
            )
            return false
        }
    }

    static func isMissingSQLiteSidecarRemoval(_ error: Error) -> Bool {
        let nsError = error as NSError
        return isMissingSQLiteSidecarRemoval(nsError)
    }

    private static func isMissingSQLiteSidecarRemoval(_ error: NSError) -> Bool {
        if let path = sqliteSidecarPath(from: error),
           isSQLiteSidecarPath(path),
           isNoSuchFileError(error) {
            return true
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isMissingSQLiteSidecarRemoval(underlying)
        }

        let diagnosticParts = [error.localizedDescription, error.description]
            + error.userInfo.map { "\($0.key)=\($0.value)" }
        let diagnostic = diagnosticParts.joined(separator: " ")
        return (diagnostic.contains("-wal") || diagnostic.contains("-shm"))
            && (diagnostic.contains("No such file")
                || (diagnostic.contains("couldn") && diagnostic.contains("removed")))
    }

    private static func sqliteSidecarPath(from error: NSError) -> String? {
        if let path = error.userInfo[NSFilePathErrorKey] as? String {
            return path
        }
        if let url = error.userInfo[NSURLErrorKey] as? URL {
            return url.path
        }
        return nil
    }

    private static func isSQLiteSidecarPath(_ path: String) -> Bool {
        path.hasSuffix("-wal") || path.hasSuffix("-shm")
    }

    private static func isNoSuchFileError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }
        #if canImport(Darwin)
        if error.domain == NSPOSIXErrorDomain, error.code == ENOENT {
            return true
        }
        #endif
        return false
    }

    /// Release-gate helper: opens a keyed in-memory database and returns the
    /// linked SQLCipher version. Empty means stock SQLite is still linked.
    static func linkedCipherVersion() -> String? {
        do {
            return try probeLinkedCipherVersion()
        } catch {
            return nil
        }
    }

    /// Verifies that the current build links active SQLCipher. Intended for
    /// release CI and focused tests, where plaintext fallback is not acceptable.
    static func requireLinkedSQLCipherForRelease() throws -> String {
        guard let version = linkedCipherVersion() else {
            AppLogger.dataStore.error(
                "release_sqlcipher_codec_missing",
                metadata: ["reason": "PRAGMA cipher_version empty in release codec gate"]
            )
            throw DatabaseEncryptionError.cipherUnavailable
        }
        return version
    }

    /// Probes whether the linked SQLite actually provides the SQLCipher codec, i.e.
    /// `PRAGMA cipher_version` is non-empty after `Database.usePassphrase(_:)`. On a build that
    /// links stock SQLite this returns `false`; encryption-requested startup then
    /// aborts instead of falling back to plaintext. The probe opens a throwaway
    /// in-memory database; the result is cached for the process lifetime.
    static func isCipherAvailable() -> Bool { cipherAvailabilityProbe }

    private static let cipherAvailabilityProbe: Bool = {
        do {
            _ = try probeLinkedCipherVersion()
            return true
        } catch {
            return false
        }
    }()

    private static func probeLinkedCipherVersion() throws -> String {
        let probeKey = String(repeating: "a", count: 64)
        try validateEncryptionKey(probeKey)
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.usePassphrase(probeKey)
        }
        let queue = try DatabaseQueue(path: ":memory:", configuration: config)
        defer { closeQuietly(queue, context: "database_cipher_probe_close_failed") }
        let version = try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA cipher_version")
        }
        guard let version, version.isEmpty == false else {
            throw DatabaseEncryptionError.cipherUnavailable
        }
        return version
    }

    // MARK: - Plaintext vs Encrypted File Detection

    /// Reports whether the file at `path` is an *encrypted* SQLCipher database, by
    /// inspecting only the first 16 bytes (no key required).
    ///
    /// A plaintext SQLite 3 file always begins with the magic header
    /// `"SQLite format 3\0"`. A SQLCipher-encrypted file's first page is
    /// ciphertext and does not carry that header. A brand-new / missing / empty
    /// file is treated as "not encrypted" so the caller can create it fresh.
    ///
    /// - Returns: `true` if the file exists, is non-trivial, and does NOT start
    ///   with the plaintext SQLite magic (i.e. it is encrypted); `false` for a
    ///   missing, empty, or plaintext file.
    static func isEncryptedDatabaseFile(at path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer {
            do {
                try handle.close()
            } catch {
                AppLogger.dataStore.debug("Failed to close database header probe handle: \(error.localizedDescription)")
            }
        }
        let header: Data
        do {
            guard let data = try handle.read(upToCount: plaintextSQLiteMagic.count),
                  data.count == plaintextSQLiteMagic.count else {
                // Missing or shorter-than-header file: nothing encrypted to protect.
                return false
            }
            header = data
        } catch {
            // Missing or shorter-than-header file: nothing encrypted to protect.
            return false
        }
        return header != plaintextSQLiteMagic
    }

    private static func closeQuietly(_ queue: DatabaseQueue, context: String) {
        do {
            try queue.close()
        } catch {
            AppLogger.dataStore.debug(
                "\(context)",
                metadata: ["error": "\(error)"]
            )
        }
    }
}
