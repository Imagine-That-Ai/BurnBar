import Foundation
import LocalAuthentication
import OpenBurnBarCore
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

func withKeychainInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
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
func withKeychainInteractionDisabled<T>(_ operation: () throws -> T) rethrows -> T {
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

protocol SecurityKeychainOperations: Sendable {
    func runWithDisabledInteraction(_ operation: () -> OSStatus) -> OSStatus
    func update(query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func add(query: CFDictionary) -> OSStatus
    func copyMatching(query: CFDictionary, item: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func delete(query: CFDictionary) -> OSStatus
}

struct LiveSecurityKeychainOperations: SecurityKeychainOperations {
    func runWithDisabledInteraction(_ operation: () -> OSStatus) -> OSStatus {
        withKeychainInteractionDisabled(operation)
    }

    func update(query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }

    func add(query: CFDictionary) -> OSStatus {
        SecItemAdd(query, nil)
    }

    func copyMatching(query: CFDictionary, item: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(query, item)
    }

    func delete(query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

struct SecurityKeychainStoreBackend: KeychainStoreBackend {
    private let security: any SecurityKeychainOperations

    /// One process-wide context for NON-INTERACTIVE reads. Allocating a fresh
    /// `LAContext` per read made `LAContext.__allocating_init` (and its
    /// securityd handshake) dominate the keychain path in CPU profiles:
    /// `ProviderQuotaService.makeContext` resolves dozens of provider keys on
    /// every quota refresh, and each *missing* key re-scans every legacy
    /// service too — so one `apiKey(for:)` can be many `SecItemCopyMatching`
    /// calls, each previously minting a new context. The context only carries
    /// `interactionNotAllowed = true`: a set-once, read-only configuration that
    /// is never mutated and never drives a policy evaluation (the sole
    /// concurrency hazard for `LAContext`), so sharing one instance is
    /// semantically identical and safe to read from any thread. The global
    /// `withKeychainInteractionDisabled` toggle still wraps every read, so the
    /// legacy-ACL belt-and-suspenders documented at file top is unchanged.
    nonisolated(unsafe) private static let nonInteractiveContext: LAContext = {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }()

    init(security: any SecurityKeychainOperations = LiveSecurityKeychainOperations()) {
        self.security = security
    }

    /// The `class + service + account` generic-password shape all three
    /// operations below start from.
    private static func genericPasswordQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func set(_ value: Data, service: String, account: String) throws {
        let query = Self.genericPasswordQuery(service: service, account: account)

        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = security.runWithDisabledInteraction {
            security.update(query: query as CFDictionary, attributes: attributes as CFDictionary)
        }
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.unhandled(updateStatus)
        }

        var createQuery = query
        createQuery[kSecValueData as String] = value
        createQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = security.runWithDisabledInteraction {
            security.add(query: createQuery as CFDictionary)
        }
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unhandled(addStatus)
        }
    }

    func data(for service: String, account: String, allowUserInteraction: Bool) throws -> Data? {
        var query = Self.genericPasswordQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUserInteraction {
            query[kSecUseAuthenticationContext as String] = Self.nonInteractiveContext
        }
        var item: CFTypeRef?
        let status: OSStatus
        if allowUserInteraction {
            status = security.copyMatching(query: query as CFDictionary, item: &item)
        } else {
            status = security.runWithDisabledInteraction {
                security.copyMatching(query: query as CFDictionary, item: &item)
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
        let query = Self.genericPasswordQuery(service: service, account: account)
        let status = security.runWithDisabledInteraction {
            security.delete(query: query as CFDictionary)
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
        service: String = OpenBurnBarCore.OpenBurnBarIdentity.cursorConnectorKeychainService,
        legacyServices: [String] = OpenBurnBarCore.OpenBurnBarIdentity.legacyCursorConnectorKeychainServices,
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

extension KeychainStore {
    /// Reads a stored credential, returning `nil` when the item is genuinely
    /// absent and surfacing real Keychain faults to the log.
    ///
    /// `string(for:)` already maps the benign cases — item-not-found,
    /// interaction-not-allowed, user-cancelled, auth-failed — to `nil`. The only
    /// thing it *throws* for is a genuinely unexpected backend fault: a locked
    /// keychain, an ACL denial, an unhandled `OSStatus`, or corrupt data. Those
    /// were historically swallowed by `try?` at every call site, which made a
    /// broken/locked Keychain indistinguishable from "no credential configured"
    /// and silently degraded auth/quota flows with no diagnostic.
    ///
    /// This accessor preserves the nil-on-absent contract callers rely on while
    /// making a real credential-availability fault observable. Use it instead of
    /// an optional-try keychain read wherever a missing credential should degrade
    /// gracefully but a *broken* keychain should not be silently misread as
    /// "not configured".
    ///
    /// - Parameters:
    ///   - account: the credential account to read.
    ///   - allowUserInteraction: whether to permit an interactive unlock prompt.
    ///   - event: a telemetry event name logged if an unexpected fault occurs.
    /// - Returns: the credential if present, or `nil` if absent or unreadable.
    func credentialIfPresent(
        for account: String,
        allowUserInteraction: Bool = false,
        event: String = "keychain_credential_read_failed"
    ) -> String? {
        do {
            return try string(for: account, allowUserInteraction: allowUserInteraction)
        } catch {
            AppLogger.shared.error(
                event,
                metadata: ["errorClass": "\(String(describing: type(of: error)))"]
            )
            return nil
        }
    }
}
