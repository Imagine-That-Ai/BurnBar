import Foundation

/// Cross-platform implementation of the explicit database recovery bundle
/// format used by the macOS app's `DatabaseEncryptionService`.
///
/// Format (all binary, no JSON):
///   version (1 byte) || salt (16 bytes) || iterations (UInt32 BE) ||
///   AES-GCM combined (12-byte nonce || ciphertext || 16-byte tag)
///
/// The bundle contains only the SQLCipher passphrase. It never contains a
/// database file or the user's passphrase, and callers must keep the passphrase
/// in native memory only.
public enum BurnBarDatabaseRecoveryBundleCrypto {
    public static let version: UInt8 = 1
    public static let saltByteCount = 16
    public static let derivedKeyByteCount = 32
    public static let defaultIterations: UInt32 = 100_000
    public static let minimumIterations: UInt32 = 100_000
    public static let maximumIterations: UInt32 = 1_000_000
    public static let maximumBundleByteCount = 64 * 1024
    public static let minimumPassphraseByteCount = 1
    public static let maximumPassphraseByteCount = 4 * 1024

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyPassphrase
        case passphraseTooLong
        case randomGenerationFailed
        case unsupportedVersion(UInt8)
        case malformedBundle
        case bundleTooLarge(Int)
        case invalidIterationCount(UInt32)
        case authenticationFailed
        case invalidDatabaseKey
    }

    /// Wrap a SQLCipher passphrase using the exact macOS format.
    public static func export(databaseKey: String, passphrase: String) throws -> Data {
        try validatePassphrase(passphrase)
        guard isValidDatabaseKey(databaseKey) else { throw Error.invalidDatabaseKey }

        let salt: Data
        do {
            salt = try PlatformCrypto.secureRandomBytes(count: saltByteCount)
        } catch {
            throw Error.randomGenerationFailed
        }
        let derived = try deriveKey(
            passphrase: passphrase,
            salt: salt,
            iterations: defaultIterations
        )
        let combined: Data
        do {
            combined = try PlatformCrypto.sealAESGCM(
                plaintext: Data(databaseKey.utf8),
                keyData: derived
            )
        } catch {
            throw Error.authenticationFailed
        }

        var bundle = Data(capacity: 1 + saltByteCount + 4 + combined.count)
        bundle.append(version)
        bundle.append(salt)
        var iterations = defaultIterations.bigEndian
        withUnsafeBytes(of: &iterations) { bundle.append(contentsOf: $0) }
        bundle.append(combined)
        return bundle
    }

    /// Unwrap a macOS/Linux recovery bundle. Authentication failures are
    /// intentionally collapsed so wrong passphrases and tampering cannot be
    /// distinguished by callers or logs.
    public static func importDatabaseKey(bundle: Data, passphrase: String) throws -> String {
        try validatePassphrase(passphrase)
        guard bundle.count <= maximumBundleByteCount else {
            throw Error.bundleTooLarge(bundle.count)
        }
        // Match the macOS parser's ordering: a present version byte is
        // classified before payload-length validation, so an unsupported
        // future version is distinguishable from a truncated v1 bundle.
        guard let bundleVersion = bundle.first else { throw Error.malformedBundle }
        guard bundleVersion == version else { throw Error.unsupportedVersion(bundleVersion) }
        guard bundle.count >= 1 + saltByteCount + 4 + 12 + 16 else {
            throw Error.malformedBundle
        }

        let saltStart = 1
        let salt = bundle.subdata(in: saltStart..<(saltStart + saltByteCount))
        let iterationStart = saltStart + saltByteCount
        let iterations = bundle[iterationStart..<(iterationStart + 4)].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
        guard (minimumIterations...maximumIterations).contains(iterations) else {
            throw Error.invalidIterationCount(iterations)
        }
        let combined = bundle.subdata(in: (iterationStart + 4)..<bundle.count)
        guard combined.count >= 12 + 16 else { throw Error.malformedBundle }

        let derived = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let decrypted: Data
        do {
            decrypted = try PlatformCrypto.openAESGCM(combined: combined, keyData: derived)
        } catch {
            throw Error.authenticationFailed
        }
        guard let databaseKey = String(data: decrypted, encoding: .utf8),
              isValidDatabaseKey(databaseKey) else {
            throw Error.invalidDatabaseKey
        }
        return databaseKey
    }

    public static func isValidDatabaseKey(_ key: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+/=-"))
        guard key.isEmpty == false,
              key.utf8.count <= 512,
              key.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return false
        }
        guard let decoded = Data(base64Encoded: key), decoded.count == 32 else {
            return false
        }
        return true
    }

    private static func validatePassphrase(_ passphrase: String) throws {
        let length = passphrase.utf8.count
        guard length >= minimumPassphraseByteCount else { throw Error.emptyPassphrase }
        guard length <= maximumPassphraseByteCount else { throw Error.passphraseTooLong }
        guard passphrase.utf8.contains(0) == false else { throw Error.emptyPassphrase }
    }

    /// PBKDF2-HMAC-SHA256, RFC 8018 section 5.2, one 32-byte block.
    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: UInt32
    ) throws -> Data {
        let password = Data(passphrase.utf8)
        var blockInput = Data(capacity: salt.count + 4)
        blockInput.append(salt)
        var blockIndex = UInt32(1).bigEndian
        withUnsafeBytes(of: &blockIndex) { blockInput.append(contentsOf: $0) }

        var u = try PlatformCrypto.hmacSHA256(blockInput, keyData: password)
        var result = u
        if iterations > 1 {
            for _ in 1..<iterations {
                u = try PlatformCrypto.hmacSHA256(u, keyData: password)
                for index in result.indices {
                    result[index] ^= u[index]
                }
            }
        }
        return result
    }
}
