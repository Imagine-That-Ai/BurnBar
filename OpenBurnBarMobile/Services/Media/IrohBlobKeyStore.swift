import Foundation
import OpenBurnBarCore
import OpenBurnBarIrohRelay
import Security

/// iOS-side persistence of the iroh BLOB endpoint's 32-byte secret key.
/// Distinct Keychain entry from the chat secret (`IrohRelayKeyStore`) for
/// the same reason the Mac splits them: two iroh endpoints need two
/// NodeIds so discovery can resolve each ALPN to its own physical
/// listener.
final class IrohBlobKeyStore: @unchecked Sendable {
    static let shared = IrohBlobKeyStore()

    private let service: String
    private let account: String

    init(
        service: String = "ai.openburnbar.iroh-blob-secret",
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

    private func loadFromKeychain() throws -> IrohSecretKeyMaterial? {
        let query: [String: Any] = [
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
            throw IrohBlobKeyStoreError.keychainStatus(status)
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
                throw IrohBlobKeyStoreError.keychainStatus(updateStatus)
            }
        default:
            throw IrohBlobKeyStoreError.keychainStatus(status)
        }
    }

    private func deleteFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw IrohBlobKeyStoreError.keychainStatus(status)
        }
    }
}

enum IrohBlobKeyStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
}
