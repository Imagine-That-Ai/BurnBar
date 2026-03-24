import Foundation
import LocalAuthentication
import Security

enum KeychainStoreError: Error {
    case unexpectedData
    case unhandled(OSStatus)
}

protocol KeychainStoreBackend {
    func set(_ value: Data, service: String, account: String) throws
    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data?
    func delete(service: String, account: String) throws
}

struct SecurityKeychainStoreBackend: KeychainStoreBackend {
    func set(_ value: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [kSecValueData as String: value]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.unhandled(updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = value
        let addStatus = SecItemAdd(createQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unhandled(addStatus)
        }
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            // Force Security.framework to fail fast instead of presenting a keychain prompt.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound
            || status == errSecInteractionNotAllowed
            || status == errSecUserCanceled
            || status == errSecAuthFailed {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandled(status)
        }
        guard let data = item as? Data else {
            throw KeychainStoreError.unexpectedData
        }
        return data
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status)
        }
    }
}

struct KeychainStore {
    private let service: String
    private let legacyServices: [String]
    private let backend: any KeychainStoreBackend

    init(
        service: String = BurnBarIdentity.cursorConnectorKeychainService,
        legacyServices: [String] = BurnBarIdentity.legacyCursorConnectorKeychainServices,
        backend: any KeychainStoreBackend = SecurityKeychainStoreBackend()
    ) {
        self.service = service
        self.legacyServices = legacyServices
        self.backend = backend
    }

    func set(_ value: String, for account: String) throws {
        try backend.set(Data(value.utf8), service: service, account: account)
    }

    func string(for account: String, allowUserInteraction: Bool = true) throws -> String? {
        if let currentData = try backend.data(
            for: service,
            account: account,
            allowUserInteraction: allowUserInteraction
        ) {
            guard let string = String(data: currentData, encoding: .utf8) else {
                throw KeychainStoreError.unexpectedData
            }
            return string
        }

        for legacyService in legacyServices {
            guard let legacyData = try backend.data(
                for: legacyService,
                account: account,
                allowUserInteraction: allowUserInteraction
            ) else { continue }
            try backend.set(legacyData, service: service, account: account)
            guard let string = String(data: legacyData, encoding: .utf8) else {
                throw KeychainStoreError.unexpectedData
            }
            return string
        }

        return nil
    }

    func delete(account: String) throws {
        try backend.delete(service: service, account: account)
        for legacyService in legacyServices {
            try backend.delete(service: legacyService, account: account)
        }
    }
}
