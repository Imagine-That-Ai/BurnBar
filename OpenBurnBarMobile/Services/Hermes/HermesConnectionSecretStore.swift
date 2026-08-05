import Foundation
import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

final class HermesConnectionSecretStore: HermesConnectionSecretStoring {
    nonisolated(unsafe) static let shared = HermesConnectionSecretStore()

    private let keychainService = "com.openburnbar.mobile.hermes-connection"

    func save(_ value: String, connectionID: String) throws {
        let data = Data(value.utf8)
        let query = KeychainGenericPasswordQuery.base(service: keychainService, account: connectionID)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var create = query
            create[kSecValueData as String] = data
            create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(create as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw HermesServiceError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw HermesServiceError.keychain(status)
        }
    }

    func load(connectionID: String) throws -> String? {
        let query = KeychainGenericPasswordQuery.read(service: keychainService, account: connectionID)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data else {
            throw HermesServiceError.keychain(status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(connectionID: String) throws {
        let query = KeychainGenericPasswordQuery.base(service: keychainService, account: connectionID)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HermesServiceError.keychain(status)
        }
    }
}
