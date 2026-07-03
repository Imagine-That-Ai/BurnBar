import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
@preconcurrency import Crypto
#endif
#if canImport(Security)
import Security
#endif

public typealias PlatformSymmetricKey = SymmetricKey
public typealias PlatformSharedSecret = SharedSecret
public typealias PlatformEd25519PrivateKey = Curve25519.Signing.PrivateKey
public typealias PlatformEd25519PublicKey = Curve25519.Signing.PublicKey
public typealias PlatformP256SigningPrivateKey = P256.Signing.PrivateKey
public typealias PlatformP256SigningPublicKey = P256.Signing.PublicKey
public typealias PlatformP256SigningSignature = P256.Signing.ECDSASignature
public typealias PlatformP256KeyAgreementPrivateKey = P256.KeyAgreement.PrivateKey
public typealias PlatformP256KeyAgreementPublicKey = P256.KeyAgreement.PublicKey
public typealias PlatformCurve25519KeyAgreementPrivateKey = Curve25519.KeyAgreement.PrivateKey
public typealias PlatformCurve25519KeyAgreementPublicKey = Curve25519.KeyAgreement.PublicKey

#if os(Linux)
extension SymmetricKey: @unchecked Sendable {}
extension SharedSecret: @unchecked Sendable {}
extension Curve25519.Signing.PrivateKey: @unchecked Sendable {}
extension Curve25519.Signing.PublicKey: @unchecked Sendable {}
extension Curve25519.KeyAgreement.PrivateKey: @unchecked Sendable {}
extension Curve25519.KeyAgreement.PublicKey: @unchecked Sendable {}
extension P256.Signing.PrivateKey: @unchecked Sendable {}
extension P256.Signing.PublicKey: @unchecked Sendable {}
extension P256.KeyAgreement.PrivateKey: @unchecked Sendable {}
extension P256.KeyAgreement.PublicKey: @unchecked Sendable {}
#endif

public enum PlatformCryptoError: LocalizedError, Sendable, Equatable {
    case invalidByteCount
    case secureRandomFailed(Int)
    case secureRandomUnavailable
    case invalidSymmetricKey
    case invalidNonce
    case invalidCiphertext
    case invalidSigningKey
    case invalidVerifyingKey
    case canonicalEncodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidByteCount:
            return "Secure random byte count must be positive."
        case .secureRandomFailed(let status):
            return "Secure random generation failed with status \(status)."
        case .secureRandomUnavailable:
            return "No secure random source is available on this platform."
        case .invalidSymmetricKey:
            return "Symmetric keys must be 32 bytes."
        case .invalidNonce:
            return "AES-GCM nonces must be 12 bytes."
        case .invalidCiphertext:
            return "Ciphertext could not be opened."
        case .invalidSigningKey:
            return "Ed25519 signing key material is invalid."
        case .invalidVerifyingKey:
            return "Ed25519 verifying key material is invalid."
        case .canonicalEncodingFailed(let message):
            return "Canonical JSON encoding failed: \(message)"
        }
    }
}

public enum PlatformCrypto {
    public static func secureRandomBytes(count: Int) throws -> Data {
        guard count > 0 else { throw PlatformCryptoError.invalidByteCount }
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errSecParam
            }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw PlatformCryptoError.secureRandomFailed(Int(status))
        }
        return Data(bytes)
        #else
        guard let handle = FileHandle(forReadingAtPath: "/dev/urandom") else {
            throw PlatformCryptoError.secureRandomUnavailable
        }
        defer { try? handle.close() }

        var output = Data()
        output.reserveCapacity(count)
        while output.count < count {
            let chunk = try handle.read(upToCount: count - output.count) ?? Data()
            guard chunk.isEmpty == false else {
                throw PlatformCryptoError.secureRandomUnavailable
            }
            output.append(chunk)
        }
        return output
        #endif
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha256Hex(_ data: Data) -> String {
        hexString(sha256(data))
    }

    public static func hmacSHA256(_ data: Data, keyData: Data) throws -> Data {
        guard keyData.isEmpty == false else { throw PlatformCryptoError.invalidSymmetricKey }
        let code = HMAC<SHA256>.authenticationCode(
            for: data,
            using: SymmetricKey(data: keyData)
        )
        return Data(code)
    }

    public static func hmacSHA256Hex(_ data: Data, keyData: Data) throws -> String {
        try hexString(hmacSHA256(data, keyData: keyData))
    }

    public static func symmetricKey(data: Data) throws -> PlatformSymmetricKey {
        guard data.isEmpty == false else { throw PlatformCryptoError.invalidSymmetricKey }
        return SymmetricKey(data: data)
    }

    public static func symmetricKeyData(_ key: PlatformSymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    public static func deriveHKDFSHA256Key(
        inputKeyMaterial: Data,
        salt: Data = Data(),
        info: Data = Data(),
        outputByteCount: Int
    ) throws -> PlatformSymmetricKey {
        guard inputKeyMaterial.isEmpty == false else { throw PlatformCryptoError.invalidSymmetricKey }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inputKeyMaterial),
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        )
    }

    public static func deriveHKDFSHA256KeyData(
        inputKeyMaterial: Data,
        salt: Data = Data(),
        info: Data = Data(),
        outputByteCount: Int
    ) throws -> Data {
        symmetricKeyData(try deriveHKDFSHA256Key(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: info,
            outputByteCount: outputByteCount
        ))
    }

    public static func deriveHKDFSHA256Key(
        sharedSecret: PlatformSharedSecret,
        salt: Data = Data(),
        info: Data = Data(),
        outputByteCount: Int
    ) -> PlatformSymmetricKey {
        sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: outputByteCount
        )
    }

    public static func sealAESGCM(
        plaintext: Data,
        keyData: Data,
        nonce: Data,
        authenticating aad: Data = Data()
    ) throws -> Data {
        guard keyData.count == 32 else { throw PlatformCryptoError.invalidSymmetricKey }
        guard nonce.count == 12 else { throw PlatformCryptoError.invalidNonce }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            nonce: try AES.GCM.Nonce(data: nonce),
            authenticating: aad
        )
        guard let combined = sealed.combined else { throw PlatformCryptoError.invalidCiphertext }
        return combined
    }

    public static func sealAESGCM(
        plaintext: Data,
        keyData: Data,
        authenticating aad: Data = Data()
    ) throws -> Data {
        guard keyData.count == 32 else { throw PlatformCryptoError.invalidSymmetricKey }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: aad
        )
        guard let combined = sealed.combined else { throw PlatformCryptoError.invalidCiphertext }
        return combined
    }

    public static func sealAESGCMDetached(
        plaintext: Data,
        keyData: Data,
        authenticating aad: Data = Data()
    ) throws -> (nonce: Data, ciphertext: Data, tag: Data, combined: Data) {
        guard keyData.count == 32 else { throw PlatformCryptoError.invalidSymmetricKey }
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData),
            authenticating: aad
        )
        guard let combined = sealed.combined else { throw PlatformCryptoError.invalidCiphertext }
        let nonce = sealed.nonce.withUnsafeBytes { Data($0) }
        return (nonce, sealed.ciphertext, sealed.tag, combined)
    }

    public static func sealAESGCM(
        plaintext: Data,
        key: PlatformSymmetricKey,
        authenticating aad: Data = Data()
    ) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw PlatformCryptoError.invalidCiphertext }
        return combined
    }

    public static func openAESGCM(
        combined: Data,
        keyData: Data,
        authenticating aad: Data = Data()
    ) throws -> Data {
        guard keyData.count == 32 else { throw PlatformCryptoError.invalidSymmetricKey }
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: keyData),
                authenticating: aad
            )
        } catch {
            throw PlatformCryptoError.invalidCiphertext
        }
    }

    public static func openAESGCMDetached(
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        keyData: Data,
        authenticating aad: Data = Data()
    ) throws -> Data {
        guard keyData.count == 32 else { throw PlatformCryptoError.invalidSymmetricKey }
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: try AES.GCM.Nonce(data: nonce),
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(
                sealedBox,
                using: SymmetricKey(data: keyData),
                authenticating: aad
            )
        } catch {
            throw PlatformCryptoError.invalidCiphertext
        }
    }

    public static func openAESGCM(
        combined: Data,
        key: PlatformSymmetricKey,
        authenticating aad: Data = Data()
    ) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
        } catch {
            throw PlatformCryptoError.invalidCiphertext
        }
    }

    public static func ed25519PrivateKey(rawRepresentation: Data) throws -> PlatformEd25519PrivateKey {
        guard rawRepresentation.count == 32 else { throw PlatformCryptoError.invalidSigningKey }
        do {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation)
        } catch {
            throw PlatformCryptoError.invalidSigningKey
        }
    }

    public static func ed25519PrivateKey() -> PlatformEd25519PrivateKey {
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
        privateKey: PlatformEd25519PrivateKey
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
        do {
            return publicKey.isValidSignature(signature, for: message)
        } catch {
            throw PlatformCryptoError.invalidVerifyingKey
        }
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
        privateKey: PlatformP256SigningPrivateKey
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

    public static func p256KeyAgreementPrivateKey(rawRepresentation: Data) throws -> PlatformP256KeyAgreementPrivateKey {
        try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
    }

    public static func p256KeyAgreementPrivateKey() -> PlatformP256KeyAgreementPrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    public static func p256KeyAgreementPublicKey(x963Representation: Data) throws -> PlatformP256KeyAgreementPublicKey {
        try P256.KeyAgreement.PublicKey(x963Representation: x963Representation)
    }

    public static func p256KeyAgreementSharedSecret(
        privateKey: PlatformP256KeyAgreementPrivateKey,
        publicKey: PlatformP256KeyAgreementPublicKey
    ) throws -> PlatformSharedSecret {
        try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
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

    public static func hpkeOpenCurve25519SHA256ChaChaPoly(
        ciphertext: Data,
        recipientPrivateKey: PlatformCurve25519KeyAgreementPrivateKey,
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

    public static func hpkeSealP256SHA256AESGCM256(
        plaintext: Data,
        recipientPublicKey: PlatformP256KeyAgreementPublicKey,
        info: Data,
        aad: Data,
        authenticatedBy senderPrivateKey: PlatformP256KeyAgreementPrivateKey
    ) throws -> (encapsulatedKey: Data, ciphertext: Data) {
        var sender = try HPKE.Sender(
            recipientKey: recipientPublicKey,
            ciphersuite: .P256_SHA256_AES_GCM_256,
            info: info,
            authenticatedBy: senderPrivateKey
        )
        let ciphertext = try sender.seal(plaintext, authenticating: aad)
        return (sender.encapsulatedKey, ciphertext)
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

    public static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
