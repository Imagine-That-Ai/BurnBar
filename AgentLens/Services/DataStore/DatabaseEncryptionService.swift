import CryptoKit
import Foundation
import GRDB
import Security
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
// SECURITY: The key is applied in SQLCipher *passphrase* mode via
// `PRAGMA key = '<key>'` (NOT raw `x'<hex>'` mode). Passphrase mode runs the
// stored base64 string through SQLCipher's PBKDF2 key-derivation; raw mode would
// instead use the bytes as the AES key directly and derive a *different* key, so
// the two formats are not interchangeable for an existing database. Before
// interpolation the key is validated to contain only base64 characters
// (A-Z, a-z, 0-9, +, /, =) plus '-', none of which can escape a single-quoted
// SQL string literal, so string injection is impossible. See `makeConfiguration`.
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

    var description: String {
        switch self {
        case .cipherUnavailable:
            return "SQLCipher is not active in this build (PRAGMA cipher_version was empty); "
                + "the database would be written in plaintext. Refusing to open with encryption requested."
        }
    }
}

enum DatabaseEncryptionService {
    private static let service = "com.openburnbar.database-encryption"
    private static let keyIdentifierAccount = "database-encryption-key-v1"

    /// The 16-byte magic header every *plaintext* SQLite 3 file begins with.
    /// A SQLCipher-encrypted file's first page is ciphertext and does NOT carry
    /// this header, so its presence/absence cheaply distinguishes the two without
    /// needing the key. Reference: <https://www.sqlite.org/fileformat2.html#the_database_header>.
    private static let plaintextSQLiteMagic = Data("SQLite format 3\u{0}".utf8)

    // MARK: - Key Management

    /// Returns the stored encryption key if one exists, nil otherwise.
    static func getKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyIdentifierAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
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
    static func getOrCreateKey() -> String {
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
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.dataStore.error("Failed to store database encryption key in Keychain: \(status)", metadata: ["status": "\(status)"])
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
        SecItemDelete(query as CFDictionary)
    }

    /// Legacy overload. Recovery file support has been removed; this now
    /// delegates to `getOrCreateKey()` and ignores the URL parameter.
    ///
    /// If you need recovery, use `exportRecoveryBundle(password:)` to create
    /// an explicit passphrase-protected backup, or `importRecoveryBundle(data:password:)`
    /// to restore from one.
    @available(*, deprecated, message: "Recovery file support removed. Use getOrCreateKey() or exportRecoveryBundle(password:).")
    static func getOrCreateKey(recoveryURL: URL) -> String {
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
            SecItemDelete(addQuery as CFDictionary) // overwrite if present
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
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
}

// MARK: - Database Configuration with Encryption

extension DatabaseEncryptionService {
    /// Builds a GRDB `Configuration`. When `encryptionKey` is non-nil the
    /// configuration applies the SQLCipher passphrase on every connection AND
    /// self-checks that SQLCipher is genuinely active, throwing
    /// `DatabaseEncryptionError.cipherUnavailable` if it is not.
    ///
    /// **Why this is now the only path (the dead-guard bug):**
    /// The linked package `SahebRoy92/GRDB-SQLCipher` exposes its module as
    /// `GRDB` — there is NO `GRDBCipher` product or target. The previous
    /// `#if canImport(GRDBCipher)` gate was therefore DEAD CODE: the `PRAGMA key`
    /// block never compiled in, so the database was written in PLAINTEXT for
    /// everyone regardless of the `databaseEncryptionEnabled` setting. The key is
    /// now applied through the real `import GRDB` build.
    ///
    /// **Key application (passphrase mode):**
    /// The key is base64 (A-Z, a-z, 0-9, +, /, =) plus '-'. It is validated to
    /// contain only those characters before interpolation into
    /// `PRAGMA key = '<key>'`; none of them can escape a single-quoted SQL string
    /// literal (only `'` and `\` can), so string injection is impossible. We use
    /// passphrase mode (PBKDF2 derivation) — NOT raw `x'<hex>'` mode — because the
    /// two derive different AES keys and are not interchangeable for an existing
    /// encrypted database.
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
    /// (`DataStoreCoordinator.makeDatabasePool`) catches that error and falls back
    /// to the acknowledged-plaintext escape hatch instead of crashing.
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
        guard let key = encryptionKey else { return config }

        // Validate that the key contains only safe characters before interpolation.
        // Allowed: base64 alphabet (A-Z, a-z, 0-9, +, /, =) plus hyphens for
        // backward compatibility with test keys. None of these characters can
        // escape a single-quoted SQL string literal (only ' and \ can do that).
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=-"))
        guard key.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            AppLogger.dataStore.error(
                "encryption_key_validation_failed",
                metadata: ["reason": "Key contains characters outside the allowed set"]
            )
            throw DatabaseEncryptionError.cipherUnavailable
        }

        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA key = '\(key)'")
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
        }

        return config
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
}
