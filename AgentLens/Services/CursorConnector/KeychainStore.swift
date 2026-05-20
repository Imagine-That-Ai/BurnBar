import Foundation
import LocalAuthentication
import Security

#if os(macOS)
// Legacy login-keychain ACL items can still show a password prompt even when
// the query uses a non-interactive LAContext. Keep Security.framework UI
// disabled around background reads so missing/locked secrets fail closed.
@inline(__always)
@_silgen_name("SecKeychainGetUserInteractionAllowed")
private func obbSecKeychainGetUserInteractionAllowed(_ allowed: UnsafeMutablePointer<DarwinBoolean>) -> OSStatus

@inline(__always)
@_silgen_name("SecKeychainSetUserInteractionAllowed")
private func obbSecKeychainSetUserInteractionAllowed(_ allowed: Bool) -> OSStatus

private func withKeychainInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
    var previousAllowed = DarwinBoolean(true)
    let readStatus = obbSecKeychainGetUserInteractionAllowed(&previousAllowed)
    let disableStatus = obbSecKeychainSetUserInteractionAllowed(false)
    defer {
        if disableStatus == errSecSuccess {
            if readStatus == errSecSuccess {
                _ = obbSecKeychainSetUserInteractionAllowed(previousAllowed.boolValue)
            } else {
                _ = obbSecKeychainSetUserInteractionAllowed(true)
            }
        }
    }
    return try operation()
}
#else
private func withKeychainInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
    try operation()
}
#endif

enum KeychainStoreError: Error {
    case unexpectedData
    case unhandled(OSStatus)
    case writeVerificationFailed
}

protocol KeychainStoreBackend: Sendable {
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

        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = withKeychainInteractionDisabled {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.unhandled(updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = value
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = withKeychainInteractionDisabled {
            SecItemAdd(createQuery as CFDictionary, nil)
        }
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
            // Force Security.framework to fail fast instead of presenting a
            // keychain prompt. Creating an LAContext for every background
            // probe wakes CoreAuthentication and generates a surprising amount
            // of work/log traffic when quota refreshes fan out across many
            // credential slots, so non-interactive reads use the Security UI
            // policy directly.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var item: CFTypeRef?
        let status: OSStatus
        if allowUserInteraction {
            status = SecItemCopyMatching(query as CFDictionary, &item)
        } else {
            status = withKeychainInteractionDisabled {
                SecItemCopyMatching(query as CFDictionary, &item)
            }
        }
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
        let status = withKeychainInteractionDisabled {
            SecItemDelete(query as CFDictionary)
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status)
        }
    }
}

struct KeychainStore: Sendable {
    private let service: String
    private let legacyServices: [String]
    private let backend: any KeychainStoreBackend

    init(
        service: String = OpenBurnBarIdentity.cursorConnectorKeychainService,
        legacyServices: [String] = OpenBurnBarIdentity.legacyCursorConnectorKeychainServices,
        backend: any KeychainStoreBackend = SecurityKeychainStoreBackend()
    ) {
        self.service = service
        self.legacyServices = legacyServices
        self.backend = backend
    }

    func set(_ value: String, for account: String) throws {
        let data = Data(value.utf8)
        try backend.set(data, service: service, account: account)
        try ensureNonInteractiveReadability(for: account, expectedData: data)
    }

    func string(for account: String, allowUserInteraction: Bool = false) throws -> String? {
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

    private func ensureNonInteractiveReadability(for account: String, expectedData: Data) throws {
        if let stored = try backend.data(for: service, account: account, allowUserInteraction: false) {
            // Reject silent corruption: the persisted bytes must match what we
            // wrote. A mismatch indicates a backing store that pretends to
            // accept the write but returns garbage on read (e.g. flaky
            // keychain provisioning), and silently accepting it would lose
            // the user's secret.
            guard stored == expectedData else {
                throw KeychainStoreError.writeVerificationFailed
            }
            return
        }

        try backend.delete(service: service, account: account)
        try backend.set(expectedData, service: service, account: account)

        guard let stored = try backend.data(for: service, account: account, allowUserInteraction: false) else {
            throw KeychainStoreError.writeVerificationFailed
        }
        guard stored == expectedData else {
            throw KeychainStoreError.writeVerificationFailed
        }
    }
}
