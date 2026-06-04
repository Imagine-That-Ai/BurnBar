import Foundation
import LocalAuthentication
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
    private let keychain: IrohRotatingKeychainSecretStore

    init(
        service: String = "ai.openburnbar.iroh-secret",
        account: String = "primary"
    ) {
        self.service = service
        self.account = account
        self.keychain = IrohRotatingKeychainSecretStore(service: service, account: account)
    }

    func secretKeyMaterial() throws -> IrohSecretKeyMaterial {
        do {
            if let existing = try loadFromKeychain() {
                return existing
            }
        } catch IrohRotatingKeychainSecretStoreError.accessDenied(let status) {
            AppLogger.network.notice(
                "iroh_relay_keychain_access_denied_regenerating",
                metadata: [
                    "service": service,
                    "account": account,
                    "status": "\(status)"
                ]
            )
            let fresh = IrohSecretKeyMaterial.generate()
            do {
                try keychain.replace(with: fresh.raw)
            } catch {
                AppLogger.network.error(
                    "iroh_relay_keychain_ephemeral_fallback",
                    metadata: [
                        "service": service,
                        "account": account,
                        "errorClass": "\(String(describing: type(of: error)))"
                    ]
                )
            }
            return fresh
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
        guard let data = try keychain.load() else { return nil }
        guard data.count == 32 else { return nil }
        return IrohSecretKeyMaterial(raw: data)
    }

    private func saveToKeychain(_ secret: IrohSecretKeyMaterial) throws {
        try keychain.save(secret.raw)
    }

    private func deleteFromKeychain() throws {
        try keychain.delete()
    }
}

enum IrohRelayKeyStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
}

struct IrohRotatingKeychainSecretStore: Sendable {
    let service: String
    let account: String

    func load() throws -> Data? {
        var query = baseQuery()
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = withKeychainInteractionDisabled {
            SecItemCopyMatching(query as CFDictionary, &item)
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw IrohRotatingKeychainSecretStoreError.unexpectedData
            }
            return data
        case errSecItemNotFound:
            return nil
        case let status where Self.isAccessDenied(status):
            throw IrohRotatingKeychainSecretStoreError.accessDenied(status)
        default:
            throw IrohRotatingKeychainSecretStoreError.keychainStatus(status)
        }
    }

    func save(_ data: Data) throws {
        let query = baseQuery()
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = withKeychainInteractionDisabled {
            SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            try add(data)
        case let status where Self.isAccessDenied(status):
            try replace(with: data)
        default:
            throw IrohRotatingKeychainSecretStoreError.keychainStatus(updateStatus)
        }
    }

    func delete() throws {
        let status = withKeychainInteractionDisabled {
            SecItemDelete(baseQuery() as CFDictionary)
        }
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case let status where Self.isAccessDenied(status):
            throw IrohRotatingKeychainSecretStoreError.accessDenied(status)
        default:
            throw IrohRotatingKeychainSecretStoreError.keychainStatus(status)
        }
    }

    func replace(with data: Data) throws {
        try delete()
        try add(data)
    }

    private func add(_ data: Data, retryingDuplicate: Bool = true) throws {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = withKeychainInteractionDisabled {
            SecItemAdd(attributes as CFDictionary, nil)
        }
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem where retryingDuplicate:
            try replace(with: data)
        case let status where Self.isAccessDenied(status):
            throw IrohRotatingKeychainSecretStoreError.accessDenied(status)
        default:
            throw IrohRotatingKeychainSecretStoreError.keychainStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func isAccessDenied(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecAuthFailed
    }
}

enum IrohRotatingKeychainSecretStoreError: Error, Equatable, LocalizedError {
    case accessDenied(OSStatus)
    case keychainStatus(OSStatus)
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .accessDenied(let status):
            return "Iroh Keychain access was denied (\(status))."
        case .keychainStatus(let status):
            return "Iroh Keychain operation failed (\(status))."
        case .unexpectedData:
            return "Iroh Keychain item contained unexpected data."
        }
    }
}
