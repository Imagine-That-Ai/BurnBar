import CryptoKit
import Foundation
import OpenBurnBarCore
import Security

/// iOS Keychain-backed device keypair for escrow encryption.
/// Uses P-256 ECIES via CryptoKit with private key stored in Keychain.
final class iOSDeviceKeypair: DeviceKeypairProtocol {
    private static let keyTag = "com.openburnbar.mobile.escrow-key".data(using: .utf8)!
    private var privateKey: P256.KeyAgreement.PrivateKey
    public private(set) var keyVersion: Int

    // MARK: - Init

    init() throws {
        if let existing = Self.loadFromKeychain() {
            self.privateKey = existing.key
            self.keyVersion = existing.version
        } else {
            let key = P256.KeyAgreement.PrivateKey()
            self.privateKey = key
            self.keyVersion = 1
            try Self.saveToKeychain(key: key, version: 1)
        }
    }

    // MARK: - DeviceKeypairProtocol

    var publicKeyData: Data {
        privateKey.publicKey.x963Representation
    }

    var publicKeyFingerprint: String {
        let hash = SHA256.hash(data: publicKeyData)
        return Data(hash).base64EncodedString()
    }

    func encrypt(_ plaintext: Data, for recipientPublicKey: Data) throws -> Data {
        guard let recipientKey = try? P256.KeyAgreement.PublicKey(x963Representation: recipientPublicKey) else {
            throw EscrowCryptoError.invalidPublicKey
        }
        // Ephemeral-static ECIES: generate ephemeral keypair, derive shared secret
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: recipientKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: "OpenBurnBar-Escrow-v1".data(using: .utf8)!,
            outputByteCount: 32
        )
        let sealed = try AES.GCM.seal(plaintext, using: symmetricKey)
        guard let combined = sealed.combined else {
            throw EscrowCryptoError.encryptionFailed
        }
        // Prepend ephemeral public key: ephemeral_pub (65) || sealed_box
        return ephemeralKey.publicKey.x963Representation + combined
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        // Format: ephemeralPublicKey (65 bytes) || AES.GCM sealed box
        guard ciphertext.count > 65 else {
            throw EscrowCryptoError.invalidCiphertext
        }
        let ephemeralPubKeyData = ciphertext.prefix(65)
        let sealedBoxData = ciphertext.suffix(from: 65)

        guard let ephemeralKey = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPubKeyData) else {
            throw EscrowCryptoError.invalidPublicKey
        }
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: "OpenBurnBar-Escrow-v1".data(using: .utf8)!,
            outputByteCount: 32
        )
        let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    func rotateKey() throws {
        let newKey = P256.KeyAgreement.PrivateKey()
        // Store old key for decryption
        try Self.saveOldKey(key: privateKey, version: keyVersion)
        self.privateKey = newKey
        let newVersion = keyVersion + 1
        try Self.saveToKeychain(key: newKey, version: newVersion)
        self.keyVersion = newVersion
    }

    /// Attempt to decrypt with an old key version.
    func decryptWithOldVersion(_ ciphertext: Data, version: Int) throws -> Data {
        guard let oldKey = try Self.loadOldKey(version: version) else {
            throw EscrowCryptoError.privateKeyUnavailable
        }
        return try decryptWithKey(ciphertext, privateKey: oldKey)
    }

    // MARK: - Keychain

    private static func saveToKeychain(key: P256.KeyAgreement.PrivateKey, version: Int) throws {
        let raw = key.rawRepresentation
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "escrow-key-v\(version)"
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EscrowCryptoError.keychainError(status: Int(status))
        }
    }

    private static func loadFromKeychain() -> (key: P256.KeyAgreement.PrivateKey, version: Int)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        // Extract version from the label stored during save
        let label = dict[kSecAttrLabel as String] as? String ?? ""
        let version = label.components(separatedBy: "-v").last.flatMap(Int.init) ?? 1
        return (key, version)
    }

    private static func saveOldKey(key: P256.KeyAgreement.PrivateKey, version: Int) throws {
        let raw = key.rawRepresentation
        let oldTag = "com.openburnbar.mobile.escrow-key-v\(version)".data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: oldTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EscrowCryptoError.keychainError(status: Int(status))
        }
    }

    private static func loadOldKey(version: Int) throws -> P256.KeyAgreement.PrivateKey? {
        let oldTag = "com.openburnbar.mobile.escrow-key-v\(version)".data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: oldTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data) else {
            return nil
        }
        return key
    }

    private func decryptWithKey(_ ciphertext: Data, privateKey: P256.KeyAgreement.PrivateKey) throws -> Data {
        guard ciphertext.count > 65 else {
            throw EscrowCryptoError.invalidCiphertext
        }
        let ephemeralPubKeyData = ciphertext.prefix(65)
        let sealedBoxData = ciphertext.suffix(from: 65)

        guard let ephemeralKey = try? P256.KeyAgreement.PublicKey(x963Representation: ephemeralPubKeyData) else {
            throw EscrowCryptoError.invalidPublicKey
        }
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: "OpenBurnBar-Escrow-v1".data(using: .utf8)!,
            outputByteCount: 32
        )
        let sealedBox = try AES.GCM.SealedBox(combined: sealedBoxData)
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }
}

// MARK: - Errors

enum EscrowCryptoError: LocalizedError {
    case invalidPublicKey
    case invalidCiphertext
    case encryptionFailed
    case decryptionFailed
    case privateKeyUnavailable
    case keychainError(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey: return "The recipient's public key is invalid."
        case .invalidCiphertext: return "The ciphertext format is invalid or corrupted."
        case .encryptionFailed: return "Encryption failed."
        case .decryptionFailed: return "Decryption failed. The key or envelope may have been rotated."
        case .privateKeyUnavailable: return "This device's private key is unavailable."
        case .keychainError(let status): return "Keychain error: \(status)"
        }
    }
}
