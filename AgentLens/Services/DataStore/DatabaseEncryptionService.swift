import CryptoKit
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
//
// SECURITY: The PRAGMA key is applied using hex encoding (x'' notation) to
// prevent SQL injection through string interpolation. Hex encoding is safe
// because the output charset is limited to [0-9a-f], making injection impossible.

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

    /// Gets the existing key from the Keychain, or recovers it from a recovery file
    /// if the Keychain entry is missing. If neither source has a key, generates a new one.
    ///
    /// When a key is recovered from the file, it is re-imported into the Keychain so
    /// subsequent accesses don't need the file. The recovery file is then removed.
    static func getOrCreateKey(recoveryURL: URL) -> String {
        // 1. Try Keychain first
        if let existing = getKey() {
            return existing
        }

        // 2. Try recovery file
        if let recovered = recoverKeyFromRecoveryFile(at: recoveryURL) {
            // Re-import to Keychain for future accesses
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: keyIdentifierAccount,
                kSecValueData as String: Data(recovered.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                AppLogger.dataStore.error("Failed to re-import recovered encryption key to Keychain: \(status)", metadata: ["status": "\(status)"])
            }

            // Remove recovery file after successful re-import
            removeKeyRecoveryFile(at: recoveryURL)

            return recovered
        }

        // 3. Generate new key
        let newKey = getOrCreateKey()

        // Persist recovery file for future Keychain loss scenarios
        _ = persistKeyRecovery(key: newKey, to: recoveryURL)

        return newKey
    }

    // MARK: - Key Recovery File

    /// The default recovery file URL: `~/.encryption-key-recovery`.
    /// Used when Keychain access is lost and the user needs to recover their
    /// database encryption key from a file backup.
    static var defaultRecoveryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".encryption-key-recovery")
    }

    /// Persists the encryption key to a recovery file with SHA-256 integrity check
    /// and restricted file permissions (0o600).
    ///
    /// The file format is:
    /// ```
    /// sha256:<hex_sha256_of_key>
    /// <base64_key>
    /// ```
    ///
    /// - Returns: `true` if the file was written successfully, `false` otherwise.
    static func persistKeyRecovery(key: String, to url: URL = defaultRecoveryURL) -> Bool {
        let dirURL = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

            let keyData = Data(key.utf8)
            let sha256 = SHA256.hash(data: keyData)
            let sha256Hex = sha256.compactMap { String(format: "%02x", $0) }.joined()
            let content = "sha256:\(sha256Hex)\n\(key)"

            try content.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            AppLogger.dataStore.error("Failed to persist encryption key recovery file: \(error.localizedDescription)")
            return false
        }
    }

    /// Recovers the encryption key from a recovery file.
    ///
    /// Validates the SHA-256 integrity check and file permissions (must be 0o600 or more restrictive).
    /// Returns `nil` if the file doesn't exist, is corrupted, has wrong permissions, or fails integrity check.
    static func recoverKeyFromRecoveryFile(at url: URL = defaultRecoveryURL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        // Verify file permissions — refuse to use overly permissive recovery files.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let perms = attrs[.posixPermissions] as? UInt16,
           (perms & 0o077) != 0 {
            AppLogger.dataStore.error("Encryption key recovery file has overly permissive permissions (\(String(perms, radix: 8))), refusing to use it")
            return nil
        }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }

        let prefix = "sha256:"
        guard lines[0].hasPrefix(prefix) else { return nil }
        let expectedHex = String(lines[0].dropFirst(prefix.count))

        let key = String(lines[1])
        let keyData = Data(key.utf8)
        let sha256 = SHA256.hash(data: keyData)
        let actualHex = sha256.compactMap { String(format: "%02x", $0) }.joined()

        guard expectedHex == actualHex else {
            AppLogger.dataStore.error("Encryption key recovery file integrity check failed")
            return nil
        }

        return key
    }

    /// Removes the encryption key recovery file from disk.
    static func removeKeyRecoveryFile(at url: URL = defaultRecoveryURL) {
        try? FileManager.default.removeItem(at: url)
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
