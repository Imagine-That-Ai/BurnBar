import Foundation

/// Passphrase-wrapped payload format for Linux local privacy exports.
///
/// The binary envelope is:
/// `magic (7) || version (1) || salt (16) || iterations (4 BE) ||
/// AES-GCM combined (nonce || ciphertext || tag)`.
///
/// The header is authenticated as AES-GCM AAD, so changing the format,
/// iteration count, or salt cannot produce an apparently valid export.
public enum BurnBarLinuxPrivacyExportCrypto {
    public static let formatVersion: UInt8 = 1
    public static let magic = Data("OBBPRIV".utf8)
    public static let saltByteCount = 16
    public static let defaultIterations: UInt32 = 100_000
    public static let minimumIterations: UInt32 = 100_000
    public static let maximumIterations: UInt32 = 1_000_000
    public static let minimumPassphraseByteCount = 8
    public static let maximumPassphraseByteCount = 4 * 1024
    public static let maximumPayloadByteCount = 48 * 1024 * 1024
    public static let maximumBundleByteCount = 64 * 1024 * 1024

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyPassphrase
        case passphraseTooShort
        case passphraseTooLong
        case malformedBundle
        case bundleTooLarge(Int)
        case unsupportedVersion(UInt8)
        case invalidIterationCount(UInt32)
        case payloadTooLarge(Int)
        case randomGenerationFailed
        case authenticationFailed
    }

    public static func seal(payload: Data, passphrase: String) throws -> Data {
        try validatePassphrase(passphrase)
        guard payload.count <= maximumPayloadByteCount else {
            throw Error.payloadTooLarge(payload.count)
        }
        let salt: Data
        do {
            salt = try PlatformCrypto.secureRandomBytes(count: saltByteCount)
        } catch {
            throw Error.randomGenerationFailed
        }

        var header = magic
        header.append(formatVersion)
        header.append(salt)
        var iterations = defaultIterations.bigEndian
        withUnsafeBytes(of: &iterations) { header.append(contentsOf: $0) }
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: defaultIterations)
        let combined: Data
        do {
            combined = try PlatformCrypto.sealAESGCM(
                plaintext: payload,
                keyData: key,
                authenticating: header
            )
        } catch {
            throw Error.authenticationFailed
        }
        guard header.count + combined.count <= maximumBundleByteCount else {
            throw Error.bundleTooLarge(header.count + combined.count)
        }
        var bundle = header
        bundle.append(combined)
        return bundle
    }

    /// Test/import-side parser. Production export currently has no import
    /// mutation path; keeping this parser here makes the format independently
    /// verifiable without exposing local store paths or secrets.
    public static func open(bundle: Data, passphrase: String) throws -> Data {
        try validatePassphrase(passphrase)
        guard bundle.count <= maximumBundleByteCount else {
            throw Error.bundleTooLarge(bundle.count)
        }
        let minimumHeader = magic.count + 1 + saltByteCount + 4
        guard bundle.count >= minimumHeader + 12 + 16,
              bundle.prefix(magic.count) == magic else {
            throw Error.malformedBundle
        }
        let versionOffset = magic.count
        let version = bundle[versionOffset]
        guard version == formatVersion else { throw Error.unsupportedVersion(version) }
        let saltStart = versionOffset + 1
        let salt = bundle.subdata(in: saltStart..<(saltStart + saltByteCount))
        let iterationStart = saltStart + saltByteCount
        let iterations = bundle[iterationStart..<(iterationStart + 4)].reduce(UInt32(0)) { value, byte in
            (value << 8) | UInt32(byte)
        }
        guard (minimumIterations...maximumIterations).contains(iterations) else {
            throw Error.invalidIterationCount(iterations)
        }
        let header = bundle.prefix(minimumHeader)
        let combined = bundle.subdata(in: minimumHeader..<bundle.count)
        let key = try deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        do {
            let payload = try PlatformCrypto.openAESGCM(
                combined: combined,
                keyData: key,
                authenticating: Data(header)
            )
            guard payload.count <= maximumPayloadByteCount else {
                throw Error.payloadTooLarge(payload.count)
            }
            return payload
        } catch let error as Error {
            throw error
        } catch {
            throw Error.authenticationFailed
        }
    }

    private static func validatePassphrase(_ passphrase: String) throws {
        let length = passphrase.utf8.count
        guard length > 0 else { throw Error.emptyPassphrase }
        guard length >= minimumPassphraseByteCount else { throw Error.passphraseTooShort }
        guard length <= maximumPassphraseByteCount else { throw Error.passphraseTooLong }
        guard passphrase.utf8.contains(0) == false else { throw Error.emptyPassphrase }
    }

    private static func deriveKey(
        passphrase: String,
        salt: Data,
        iterations: UInt32
    ) throws -> Data {
        var blockInput = Data(capacity: salt.count + 4)
        blockInput.append(salt)
        var blockIndex = UInt32(1).bigEndian
        withUnsafeBytes(of: &blockIndex) { blockInput.append(contentsOf: $0) }
        let password = Data(passphrase.utf8)
        var u = try PlatformCrypto.hmacSHA256(blockInput, keyData: password)
        var result = u
        if iterations > 1 {
            for _ in 1..<iterations {
                u = try PlatformCrypto.hmacSHA256(u, keyData: password)
                for index in result.indices { result[index] ^= u[index] }
            }
        }
        return result
    }
}
