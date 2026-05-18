import CryptoKit
import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import Security

/// Persists the Mac's Ed25519 pairing key. Public half is published to
/// Firestore at `users/{uid}/iroh_pairing_keys/host` by
/// `IrohPairingPublicKeyPublisher`; private half lives in the Keychain.
/// Rotating this key invalidates every iOS verifier — only do it on a hard
/// reset.
final class IrohPairingKeyStore: @unchecked Sendable {
    static let shared = IrohPairingKeyStore()

    private let service: String
    private let account: String

    init(
        service: String = "ai.openburnbar.iroh-pairing",
        account: String = "primary"
    ) {
        self.service = service
        self.account = account
    }

    func keypair() throws -> IrohPairingKeypair {
        if let existing = try loadFromKeychain() {
            return existing
        }
        let fresh = IrohPairingKeypair()
        try saveToKeychain(fresh)
        return fresh
    }

    var publicKeyBase64: String? {
        try? keypair().publicKeyBase64
    }

    // MARK: - Keychain plumbing

    private func loadFromKeychain() throws -> IrohPairingKeypair? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { return nil }
            do {
                let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
                return IrohPairingKeypair(signingKey: signingKey)
            } catch {
                throw IrohPairingKeyStoreError.invalidKey
            }
        case errSecItemNotFound:
            return nil
        default:
            throw IrohPairingKeyStoreError.keychainStatus(status)
        }
    }

    private func saveToKeychain(_ keypair: IrohPairingKeypair) throws {
        let raw = keypair.signingKey.rawRepresentation
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update: [String: Any] = [
                kSecValueData as String: raw,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus != errSecSuccess {
                throw IrohPairingKeyStoreError.keychainStatus(updateStatus)
            }
        default:
            throw IrohPairingKeyStoreError.keychainStatus(status)
        }
    }
}

enum IrohPairingKeyStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
    case invalidKey
}
