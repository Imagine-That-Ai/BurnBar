import Foundation
import GRDB
import Security

// MARK: - Database Encryption Service
//
// Manages the SQLCipher encryption key lifecycle in the macOS Keychain.
// When database encryption is enabled, the key is stored in the Keychain with
// kSecAttrAccessibleAfterFirstUnlock so the app can open the database on launch.
//
// The key is generated once using CryptoKit (SymmetricKey → 256-bit AES) and
// stored as a base64-encoded string. A UUID-based identifier is used as the
// Keychain account name to support future key rotation.

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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
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
}

// MARK: - Database Configuration with Encryption

extension DatabaseEncryptionService {
    /// Builds a GRDB `Configuration` object with SQLCipher encryption applied
    /// when `encryptionKey` is non-nil and GRDBCipher is available in the build.
    ///
    /// The key is applied via `PRAGMA key` on every new database connection.
    /// This approach works with both GRDB 6.x (via prepareDatabase) and GRDB 7+
    /// (via GRDBPassword passed to the configuration).
    static func makeConfiguration(encryptionKey: String?) -> Configuration {
        var config = Configuration()
        guard let key = encryptionKey else { return config }

        #if canImport(GRDBCipher)
        // GRDBCipher is available — apply the key via PRAGMA on each new connection.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA key = '\(key)'")
        }
        #else
        // GRDBCipher not available in this build — log and continue without encryption.
        // The build must use CocoaPods with GRDB.swift/SQLCipher to enable encryption.
        AppLogger.dataStore.info("Database encryption key present but GRDBCipher not available in build — encryption inactive")
        _ = key  // Suppress unused warning
        #endif

        return config
    }
}
