import CryptoKit
import Foundation
import OpenBurnBarCore
import Security

/// iOS Keychain-backed device keypair for escrow encryption.
/// Uses P-256 ECIES via CryptoKit with private key stored in Keychain.
final class iOSDeviceKeypair: DeviceKeypairProtocol {
    private static let keyTag = "com.openburnbar.mobile.escrow-key".data(using: .utf8)!
    private var privateKey: P256.KeyAgreement.PrivateKey
    private(set) var keyVersion: Int

    // MARK: - Init

    init() throws {
        if let existing = Self.loadFromKeychain() {
            self.privateKey = existing.key
            self.keyVersion = existing.version
            // T-IOS-09 — migrate a legacy `WhenUnlockedThisDeviceOnly` (no
            // access-control) item up to the biometry-gated policy in place when
            // the gate is enabled and the loaded item is not already gated. This
            // is the migration path for existing items: the key bytes are
            // preserved (same `version`), only the at-rest protection hardens. A
            // re-save failure is non-fatal — the existing usable item stays.
            if EscrowKeychainBiometryPolicy.isEnabled(), !existing.isAccessControlGated {
                try? Self.saveToKeychain(key: existing.key, version: existing.version)
            }
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: raw,
            kSecAttrLabel as String: "escrow-key-v\(version)"
        ]
        // T-IOS-09 — gate the at-rest escrow private key with biometry when the
        // device supports it (mirrors the ComputerUse SE+biometry posture in
        // `PhoneControlSigningKeyStore`). When the access-control object cannot be
        // built (no enrolled biometric, older OS), fall back to the device-only
        // accessibility class so the silent vault-unwrap path keeps working —
        // never a weaker-than-before posture. The key stays an extractable raw
        // private key (the ECIES wrap/unwrap below needs `rawRepresentation`); a
        // non-extractable Secure Enclave key would require redesigning the ECIES
        // decrypt and is tracked as the Deferred SE portion of T-IOS-09 / T-CVS-03.
        if let access = Self.escrowAccessControl() {
            query[kSecAttrAccessControl as String] = access
        } else {
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag
        ] as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw EscrowCryptoError.keychainError(status: Int(status))
        }
    }

    /// T-IOS-09 — build the biometry-gated access-control object for the escrow
    /// private key. `.biometryCurrentSet` invalidates the item if the enrolled
    /// biometric set changes (a re-enrolled finger/face can no longer read the
    /// key), matching the ComputerUse SE keystore. Returns `nil` when the OS
    /// refuses the flags (e.g. no biometric enrolled) so the caller falls back to
    /// the device-only accessibility class rather than failing to persist.
    private static func escrowAccessControl() -> SecAccessControl? {
        guard EscrowKeychainBiometryPolicy.isEnabled() else { return nil }
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.biometryCurrentSet],
            &error
        )
        return access
    }

    private static func loadFromKeychain() -> (key: P256.KeyAgreement.PrivateKey, version: Int, isAccessControlGated: Bool)? {
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
        // A biometry-gated item carries a `kSecAttrAccessControl` attribute; a
        // legacy item carries only `kSecAttrAccessible`. Used by `init()` to
        // decide whether the loaded item still needs the T-IOS-09 migration.
        let isGated = dict[kSecAttrAccessControl as String] != nil
        return (key, version, isGated)
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

// MARK: - T-IOS-09 biometry gate

/// Rollout flag for biometry-gating the at-rest escrow private key
/// (`kSecAccessControl .biometryCurrentSet`), mirroring
/// ``IrohHostKeyPinEnforcementFlag``. Default **off**: the escrow key is read on
/// the *silent, non-interactive* vault-unwrap path
/// (`MobileCloudVaultKeyAccess.keyForReading/Writing`), so a `.biometryCurrentSet`
/// item would force a Face ID / Touch ID prompt on every background unwrap. The
/// flag stays off until that flow is wired to present an `LAContext`; flipping it
/// on hardens the at-rest key without any code change here. A `UserDefaults`
/// override lets QA exercise the gated path on a device with biometry enrolled.
enum EscrowKeychainBiometryPolicy {
    static let userDefaultsKey = "openburnbar.escrowKey.biometryGate.enabled"

    nonisolated(unsafe) static var defaultEnabled = false

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: userDefaultsKey) != nil {
            return defaults.bool(forKey: userDefaultsKey)
        }
        return defaultEnabled
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
