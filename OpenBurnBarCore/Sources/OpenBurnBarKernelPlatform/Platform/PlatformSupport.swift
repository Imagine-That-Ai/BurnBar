import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif

#if canImport(Security)
import Security
#endif

#if canImport(OSLog)
import OSLog
#endif

public typealias PlatformSymmetricKey = SymmetricKey
public typealias PlatformSharedSecret = SharedSecret
public typealias PlatformEd25519SigningMaterial =
    Curve25519.Signing.PrivateKey
public typealias PlatformEd25519PublicKey = Curve25519.Signing.PublicKey
public typealias PlatformP256SigningMaterial =
    P256.Signing.PrivateKey
public typealias PlatformP256SigningPublicKey = P256.Signing.PublicKey
public typealias PlatformP256SigningSignature = P256.Signing.ECDSASignature
public typealias PlatformP256KeyAgreementPrivateKey =
    P256.KeyAgreement.PrivateKey
public typealias PlatformP256KeyAgreementPublicKey = P256.KeyAgreement.PublicKey
public typealias PlatformCurve25519AgreementMaterial =
    Curve25519.KeyAgreement.PrivateKey
public typealias PlatformCurve25519KeyAgreementPublicKey = Curve25519.KeyAgreement.PublicKey

// Core-decomposition P-12 follow-up (docs/CORE_DECOMPOSITION_PROGRAM.md): the
// `FileManager` `Sendable` shim is homed in the Kernel — the common ancestor of
// every target that stores a `FileManager` in a `Sendable` type — so it is visible
// wherever the conformance is required WITHOUT depending on a sibling leaf. P-12
// moved the shim out of Core into `OpenBurnBarLogParsers/ParserDiskCache.swift`, so
// Core's `ProviderQuotaAdapterContext` (`public let fileManager: FileManager` in a
// `Sendable` struct) only saw the conformance transitively via Core's
// `@_exported import OpenBurnBarLogParsers` re-export — a split-brain that fails
// Swift-6 Sendable checking in build modes where the re-exported retroactive
// conformance is not propagated, and would break outright when P-13 moves the Quota
// adapters into `OpenBurnBarQuota` (which does not depend on LogParsers). Homing it
// in the Kernel resolves it for Core (via `@_exported import OpenBurnBarKernel`),
// LogParsers, and the future Quota target alike. Unlike the crypto shims below,
// `FileManager` is not `Sendable` on ANY platform, so this conformance is unguarded.
// AUDIT(@unchecked Sendable): Foundation documents `FileManager` as safe for
// concurrent use.
extension FileManager: @retroactive @unchecked Sendable {} // sendable-allowlist: foundation-sdk-shim

#if os(Linux) || os(Windows)
extension SymmetricKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension SharedSecret: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension Curve25519.Signing.PrivateKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension Curve25519.Signing.PublicKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension Curve25519.KeyAgreement.PrivateKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension Curve25519.KeyAgreement.PublicKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension P256.Signing.PrivateKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension P256.Signing.PublicKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension P256.KeyAgreement.PrivateKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
extension P256.KeyAgreement.PublicKey: @retroactive @unchecked Sendable {} // AUDIT sendable-allowlist: swift-crypto-key-material
#endif

internal enum PlatformCryptoError: Error {
    case randomGenerationFailed
    case invalidSigningKey
    case invalidVerifyingKey
    case canonicalEncodingFailed(String)
}

public typealias PlatformAESGCMSealedBox = (
    nonce: Data,
    ciphertext: Data,
    tag: Data,
    combined: Data
)

public struct PlatformHPKESealedBox: Sendable {
    public let encapsulatedKey: Data
    public let ciphertext: Data
}

public enum PlatformCrypto {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha256Hex(_ data: Data) -> String {
        hexString(sha256(data))
    }

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func symmetricKey(data: Data) throws -> SymmetricKey {
        SymmetricKey(data: data)
    }

    public static func symmetricKeyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    public static func secureRandomBytes(count: Int) throws -> Data {
        precondition(count >= 0)
        guard count > 0 else { return Data() }

        #if canImport(Security)
        var bytes = Data(repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let baseAddress = raw.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlatformCryptoError.randomGenerationFailed
        }
        return bytes
        #else
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        #endif
    }

    public static func p256KeyAgreementPrivateKey() -> PlatformP256KeyAgreementPrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    public static func p256KeyAgreementPrivateKey(
        rawRepresentation: Data
    ) throws -> PlatformP256KeyAgreementPrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public static func p256KeyAgreementPublicKey(
        x963Representation: Data
    ) throws -> PlatformP256KeyAgreementPublicKey {
        try P256.KeyAgreement.PublicKey(x963Representation: x963Representation)
    }

    public static func p256KeyAgreementSharedSecret(
        privateKey: PlatformP256KeyAgreementPrivateKey,
        publicKey: PlatformP256KeyAgreementPublicKey
    ) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    }

    public static func deriveHKDFSHA256Key(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int
    ) throws -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
    }

    public static func deriveHKDFSHA256Key(
        sharedSecret: SharedSecret,
        salt: Data,
        info: Data,
        outputByteCount: Int
    ) throws -> SymmetricKey {
        try deriveHKDFSHA256Key(
            inputKeyMaterial: sharedSecret.withUnsafeBytes { Data($0) },
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
    }

    public static func deriveHKDFSHA256KeyData(
        inputKeyMaterial: Data,
        salt: Data,
        info: Data,
        outputByteCount: Int
    ) throws -> Data {
        try deriveHKDFSHA256Key(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        ).withUnsafeBytes { Data($0) }
    }

    public static func hmacSHA256(_ data: Data, keyData: Data) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
    }

    public static func hmacSHA256Hex(_ data: Data, keyData: Data) throws -> String {
        hexString(try hmacSHA256(data, keyData: keyData))
    }

    public static func sealAESGCMDetached(
        plaintext: Data,
        keyData: Data,
        authenticating: Data? = nil
    ) throws -> PlatformAESGCMSealedBox {
        try sealAESGCMDetached(
            plaintext: plaintext,
            key: SymmetricKey(data: keyData),
            authenticating: authenticating
        )
    }

    public static func sealAESGCMDetached(
        plaintext: Data,
        keyData: Data,
        nonce: Data,
        authenticating: Data
    ) throws -> PlatformAESGCMSealedBox {
        let key = SymmetricKey(data: keyData)
        let aesNonce = try AES.GCM.Nonce(data: nonce)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: aesNonce,
            authenticating: authenticating
        )
        return (
            nonce: Data(sealed.nonce),
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            combined: Data(sealed.nonce) + sealed.ciphertext + sealed.tag
        )
    }

    public static func sealAESGCMDetached(
        plaintext: Data,
        key: SymmetricKey,
        authenticating: Data? = nil
    ) throws -> PlatformAESGCMSealedBox {
        let sealed: AES.GCM.SealedBox
        if let authenticating {
            sealed = try AES.GCM.seal(plaintext, using: key, authenticating: authenticating)
        } else {
            sealed = try AES.GCM.seal(plaintext, using: key)
        }

        let nonce = Data(sealed.nonce)
        let combined = nonce + sealed.ciphertext + sealed.tag
        return (
            nonce: nonce,
            ciphertext: sealed.ciphertext,
            tag: sealed.tag,
            combined: combined
        )
    }

    public static func sealAESGCM(
        plaintext: Data,
        keyData: Data,
        authenticating: Data? = nil
    ) throws -> Data {
        try sealAESGCMDetached(
            plaintext: plaintext,
            keyData: keyData,
            authenticating: authenticating
        ).combined
    }

    public static func sealAESGCM(
        plaintext: Data,
        key: SymmetricKey,
        authenticating: Data? = nil
    ) throws -> Data {
        try sealAESGCMDetached(
            plaintext: plaintext,
            key: key,
            authenticating: authenticating
        ).combined
    }

    public static func openAESGCMDetached(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        keyData: Data,
        authenticating: Data? = nil
    ) throws -> Data {
        try openAESGCMDetached(
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            key: SymmetricKey(data: keyData),
            authenticating: authenticating
        )
    }

    public static func openAESGCMDetached(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        key: SymmetricKey,
        authenticating: Data? = nil
    ) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonce),
            ciphertext: ciphertext,
            tag: tag
        )
        if let authenticating {
            return try AES.GCM.open(sealedBox, using: key, authenticating: authenticating)
        }
        return try AES.GCM.open(sealedBox, using: key)
    }

    public static func openAESGCM(
        combined: Data,
        keyData: Data,
        authenticating: Data? = nil
    ) throws -> Data {
        try openAESGCM(
            combined: combined,
            key: SymmetricKey(data: keyData),
            authenticating: authenticating
        )
    }

    public static func openAESGCM(
        combined: Data,
        key: SymmetricKey,
        authenticating: Data? = nil
    ) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: combined)
        if let authenticating {
            return try AES.GCM.open(sealedBox, using: key, authenticating: authenticating)
        }
        return try AES.GCM.open(sealedBox, using: key)
    }

    public static func ed25519PrivateKey(rawRepresentation: Data) throws -> PlatformEd25519SigningMaterial {
        guard rawRepresentation.count == 32 else { throw PlatformCryptoError.invalidSigningKey }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw PlatformCryptoError.invalidSigningKey
        }
    }

    public static func ed25519PrivateKey() -> PlatformEd25519SigningMaterial {
        Curve25519.Signing.PrivateKey()
    }

    public static func ed25519PublicKey(rawRepresentation: Data) throws -> PlatformEd25519PublicKey {
        guard rawRepresentation.count == 32 else { throw PlatformCryptoError.invalidVerifyingKey }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: rawRepresentation)
        } catch {
            throw PlatformCryptoError.invalidVerifyingKey
        }
    }

    public static func ed25519PublicKeyRaw(privateKeyRaw: Data) throws -> Data {
        try ed25519PrivateKey(rawRepresentation: privateKeyRaw)
            .publicKey
            .rawRepresentation
    }

    public static func ed25519Signature(message: Data, privateKeyRaw: Data) throws -> Data {
        try ed25519Signature(
            message: message,
            privateKey: try ed25519PrivateKey(rawRepresentation: privateKeyRaw)
        )
    }

    public static func ed25519Signature(
        message: Data,
        privateKey: PlatformEd25519SigningMaterial
    ) throws -> Data {
        do {
            return try privateKey.signature(for: message)
        } catch {
            throw PlatformCryptoError.invalidSigningKey
        }
    }

    public static func verifyEd25519Signature(
        _ signature: Data,
        message: Data,
        publicKeyRaw: Data
    ) throws -> Bool {
        guard publicKeyRaw.count == 32 else { throw PlatformCryptoError.invalidVerifyingKey }
        return try verifyEd25519Signature(
            signature,
            message: message,
            publicKey: try ed25519PublicKey(rawRepresentation: publicKeyRaw)
        )
    }

    public static func verifyEd25519Signature(
        _ signature: Data,
        message: Data,
        publicKey: PlatformEd25519PublicKey
    ) throws -> Bool {
        publicKey.isValidSignature(signature, for: message)
    }

    public static func p256SigningPublicKey(from representation: Data) throws -> PlatformP256SigningPublicKey {
        switch representation.count {
        case 65:
            return try P256.Signing.PublicKey(x963Representation: representation)
        case 64:
            return try P256.Signing.PublicKey(rawRepresentation: representation)
        default:
            return try P256.Signing.PublicKey(derRepresentation: representation)
        }
    }

    public static func p256SigningRawSignature(
        message: Data,
        privateKey: PlatformP256SigningMaterial
    ) throws -> Data {
        try privateKey.signature(for: message).rawRepresentation
    }

    public static func verifyP256SigningSignature(
        _ signature: Data,
        message: Data,
        publicKey: PlatformP256SigningPublicKey
    ) -> Bool {
        if let raw = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
           publicKey.isValidSignature(raw, for: message) {
            return true
        }
        if let der = try? P256.Signing.ECDSASignature(derRepresentation: signature),
           publicKey.isValidSignature(der, for: message) {
            return true
        }
        return false
    }

    public static func curve25519KeyAgreementPublicKey(rawRepresentation: Data) throws -> PlatformCurve25519KeyAgreementPublicKey {
        try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawRepresentation)
    }

    public static func hpkeSealCurve25519SHA256ChaChaPoly(
        plaintext: Data,
        recipientPublicKey: PlatformCurve25519KeyAgreementPublicKey,
        info: Data
    ) throws -> (encapsulatedKey: Data, ciphertext: Data) {
        var sender = try HPKE.Sender(
            recipientKey: recipientPublicKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info
        )
        let ciphertext = try sender.seal(plaintext)
        return (sender.encapsulatedKey, ciphertext)
    }

    public static func hpkeOpenCurve25519SHA256ChaPoly(
        ciphertext: Data,
        recipientPrivateKey: PlatformCurve25519AgreementMaterial,
        info: Data,
        encapsulatedKey: Data
    ) throws -> Data {
        var recipient = try HPKE.Recipient(
            privateKey: recipientPrivateKey,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info,
            encapsulatedKey: encapsulatedKey
        )
        return try recipient.open(ciphertext)
    }

    public static func hpkeOpenCurve25519SHA256ChaChaPoly(
        ciphertext: Data,
        recipientPrivateKey: PlatformCurve25519AgreementMaterial,
        info: Data,
        encapsulatedKey: Data
    ) throws -> Data {
        try hpkeOpenCurve25519SHA256ChaPoly(
            ciphertext: ciphertext,
            recipientPrivateKey: recipientPrivateKey,
            info: info,
            encapsulatedKey: encapsulatedKey
        )
    }

    public static func canonicalJSONData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            return try encoder.encode(value)
        } catch {
            throw PlatformCryptoError.canonicalEncodingFailed(String(describing: error))
        }
    }

    public static func hpkeSealP256SHA256AESGCM256(
        plaintext: Data,
        recipientPublicKey: PlatformP256KeyAgreementPublicKey,
        info: Data,
        aad: Data,
        authenticatedBy senderPrivateKey: PlatformP256KeyAgreementPrivateKey
    ) throws -> PlatformHPKESealedBox {
        var sender = try HPKE.Sender(
            recipientKey: recipientPublicKey,
            ciphersuite: .P256_SHA256_AES_GCM_256,
            info: info,
            authenticatedBy: senderPrivateKey
        )
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        return PlatformHPKESealedBox(
            encapsulatedKey: sender.encapsulatedKey,
            ciphertext: ciphertext
        )
    }

    public static func hpkeOpenP256SHA256AESGCM256(
        ciphertext: Data,
        recipientPrivateKey: PlatformP256KeyAgreementPrivateKey,
        info: Data,
        encapsulatedKey: Data,
        authenticatedBy senderPublicKey: PlatformP256KeyAgreementPublicKey,
        aad: Data
    ) throws -> Data {
        var recipient = try HPKE.Recipient(
            privateKey: recipientPrivateKey,
            ciphersuite: .P256_SHA256_AES_GCM_256,
            info: info,
            encapsulatedKey: encapsulatedKey,
            authenticatedBy: senderPublicKey
        )
        return try recipient.open(ciphertext, authenticating: aad)
    }
}

#if canImport(OSLog)
public struct PlatformLogger: Sendable {
    private let logger: Logger

    public init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    public func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
    }
}
#else
public struct PlatformLogger: Sendable {
    public init(subsystem: String, category: String) {}

    public func debug(_ message: String) {}

    public func info(_ message: String) {}

    public func notice(_ message: String) {}

    public func warning(_ message: String) {}

    public func error(_ message: String) {}

    public func fault(_ message: String) {}
}
#endif
