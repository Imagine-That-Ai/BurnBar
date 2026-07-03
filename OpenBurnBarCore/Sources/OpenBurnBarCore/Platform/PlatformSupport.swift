import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Security)
import Security
#endif

#if canImport(OSLog)
import OSLog
#endif

public typealias PlatformSymmetricKey = SymmetricKey
public typealias PlatformP256KeyAgreementPrivateKey = P256.KeyAgreement.PrivateKey
public typealias PlatformP256KeyAgreementPublicKey = P256.KeyAgreement.PublicKey
public typealias PlatformSharedSecret = SharedSecret

internal enum PlatformCryptoError: Error {
    case randomGenerationFailed
}

internal typealias PlatformAESGCMSealedBox = (
    nonce: Data,
    ciphertext: Data,
    tag: Data,
    combined: Data
)

internal struct PlatformHPKESealedBox: Sendable {
    let encapsulatedKey: Data
    let ciphertext: Data
}

internal enum PlatformCrypto {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func sha256Hex(_ data: Data) -> String {
        hexString(sha256(data))
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func symmetricKey(data: Data) throws -> SymmetricKey {
        SymmetricKey(data: data)
    }

    static func symmetricKeyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func secureRandomBytes(count: Int) throws -> Data {
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

    static func p256KeyAgreementPrivateKey() -> PlatformP256KeyAgreementPrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    static func p256KeyAgreementPrivateKey(
        rawRepresentation: Data
    ) throws -> PlatformP256KeyAgreementPrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    static func p256KeyAgreementPublicKey(
        x963Representation: Data
    ) throws -> PlatformP256KeyAgreementPublicKey {
        try P256.KeyAgreement.PublicKey(x963Representation: x963Representation)
    }

    static func p256KeyAgreementSharedSecret(
        privateKey: PlatformP256KeyAgreementPrivateKey,
        publicKey: PlatformP256KeyAgreementPublicKey
    ) throws -> SharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
    }

    static func deriveHKDFSHA256Key(
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

    static func deriveHKDFSHA256Key(
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

    static func deriveHKDFSHA256KeyData(
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

    static func hmacSHA256(_ data: Data, keyData: Data) throws -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: keyData)))
    }

    static func hmacSHA256Hex(_ data: Data, keyData: Data) throws -> String {
        hexString(try hmacSHA256(data, keyData: keyData))
    }

    static func sealAESGCMDetached(
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

    static func sealAESGCMDetached(
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

    static func sealAESGCM(
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

    static func sealAESGCM(
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

    static func openAESGCMDetached(
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

    static func openAESGCMDetached(
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

    static func openAESGCM(
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

    static func openAESGCM(
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

    static func hpkeSealP256SHA256AESGCM256(
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

    static func hpkeOpenP256SHA256AESGCM256(
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
internal struct PlatformLogger: Sendable {
    private let logger: Logger

    init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func notice(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    func fault(_ message: String) {
        logger.fault("\(message, privacy: .public)")
    }
}
#else
internal struct PlatformLogger: Sendable {
    init(subsystem: String, category: String) {}

    func debug(_ message: String) {}

    func info(_ message: String) {}

    func notice(_ message: String) {}

    func warning(_ message: String) {}

    func error(_ message: String) {}

    func fault(_ message: String) {}
}
#endif
