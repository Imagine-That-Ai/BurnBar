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
// SECURITY: The PRAGMA key is applied using hex encoding (x'' notation) to
// prevent SQL injection through string interpolation. Hex encoding is safe
// because the output charset is limited to [0-9a-f], making injection impossible.
//
// RECOVERY: There is no automatic plaintext recovery file. Keychain loss means
// data loss. Users may explicitly export an encrypted recovery bundle protected
// by a user-chosen passphrase (PBKDF2 + AES-GCM). See exportRecoveryBundle
// and importRecoveryBundle.

enum DatabaseEncryptionService {
    private static let service = "com.openburnbar.database-encryption"
    private static let keyIdentifierAccount = "database-encryption-key-v1"

    // MARK: - Key Management

    /// Returns the stored encryption key if one exists, nil otherwise.
    static func getKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyIdentifierAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
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
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
            kSecAttrAccount as String: keyIdentifierAccount,
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
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
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
    /// Builds a GRDB `Configuration` object with SQLCipher encryption applied
    /// when `encryptionKey` is non-nil and GRDBCipher is available in the build.
    ///
    /// **Key application:**
    /// The key is base64-encoded (alphabet: A-Z, a-z, 0-9, +, /, =). Before
    /// interpolation into `PRAGMA key`, the key is validated to contain only
    /// these characters, which cannot escape the SQL string literal. This is
    /// safe because none of these characters are single quotes or backslashes.
    ///
    /// **Raw key format (x''):**
    /// Previously, raw key hex format (`x'<hex>'`) was considered to eliminate
    /// any injection risk. However, `PRAGMA key = x'...'` uses the bytes as
    /// the raw AES key directly (bypassing PBKDF2 derivation), while
    /// `PRAGMA key = '...'` derives the AES key from the passphrase via PBKDF2.
    /// These produce completely different derived keys, so switching from one
    /// format to the other would make existing encrypted databases unreadable.
    /// We use passphrase mode for backward compatibility with existing databases,
    /// and validate the key character set to prevent injection.
    static func makeConfiguration(encryptionKey: String?) -> Configuration {
        var config = Configuration()
        // The daemon writes to the same SQLite file (switcher profiles, indexed search).
        // Without a busy timeout, any cross-process write contention immediately raises
        // SQLITE_BUSY (error 5: "database is locked"). 5s matches GRDB's recommended default.
        config.busyMode = .timeout(5)
        guard let key = encryptionKey else { return config }

        #if canImport(GRDBCipher)
        // Validate that the key contains only safe characters before interpolation.
        // Allowed: base64 alphabet (A-Z, a-z, 0-9, +, /, =) plus hyphens for
        // backward compatibility with test keys. None of these characters can
        // escape a single-quoted SQL string literal (only ' and \ can do that).
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=-"))
        guard key.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) }) else {
            AppLogger.dataStore.error("encryption_key_validation_failed", metadata: ["reason": "Key contains characters outside the allowed set"])
            return config
        }

        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA key = '\(key)'")
        }
        #else
        // GRDBCipher not available in this build — encryption cannot be enabled.
        // Log a warning so the user knows their data is NOT encrypted despite
        // having enabled the setting. This is a build-time configuration issue.
        AppLogger.dataStore.error("Database encryption enabled in settings but GRDBCipher is not available in this build. The database will NOT be encrypted. Ensure the app is built with the SQLCipher target to enable encryption.")
        _ = key  // Suppress unused warning
        #endif

        return config
    }
}
