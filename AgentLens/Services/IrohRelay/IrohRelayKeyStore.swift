import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import Security

/// Persists the iroh endpoint's 32-byte secret key in the macOS Keychain.
/// Same trust boundary as `HermesRelayKeyStore` — generic password,
/// `WhenUnlockedThisDeviceOnly`, no iCloud sync, deleting the app removes
/// the entry.
///
/// We deliberately separate this from the Ed25519 *pairing* key (kept in
/// `IrohPairingKeyStore`) because the two have different rotation regimes:
/// the pairing key never rotates (its public half is the iOS verifier root),
/// while the iroh secret key can be regenerated to roll the NodeId without
/// invalidating verifiers.
final class IrohRelayKeyStore: @unchecked Sendable {
    static let shared = IrohRelayKeyStore()

    private let service: String
    private let account: String

    init(
        service: String = "ai.openburnbar.iroh-secret",
        account: String = "primary"
    ) {
        self.service = service
        self.account = account
    }

    func secretKeyMaterial() throws -> IrohSecretKeyMaterial {
        if let existing = try loadFromKeychain() {
            return existing
        }
        let fresh = IrohSecretKeyMaterial.generate()
        try saveToKeychain(fresh)
        return fresh
    }

    func resetSecret() throws {
        try deleteFromKeychain()
    }

    // MARK: - Keychain plumbing

    private func loadFromKeychain() throws -> IrohSecretKeyMaterial? {
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
            return IrohSecretKeyMaterial(raw: data)
        case errSecItemNotFound:
            return nil
        default:
            throw IrohRelayKeyStoreError.keychainStatus(status)
        }
    }

    private func saveToKeychain(_ secret: IrohSecretKeyMaterial) throws {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret.raw,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            // Replace the value if a stale entry already exists.
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update: [String: Any] = [
                kSecValueData as String: secret.raw,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            if updateStatus != errSecSuccess {
                throw IrohRelayKeyStoreError.keychainStatus(updateStatus)
            }
        default:
            throw IrohRelayKeyStoreError.keychainStatus(status)
        }
    }

    private func deleteFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw IrohRelayKeyStoreError.keychainStatus(status)
        }
    }
}

enum IrohRelayKeyStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
}
