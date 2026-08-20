import Foundation
import Security

// MARK: - PetKeychainStore

/// Per-provider Keychain storage for the pet companion (PLAN C10).
///
/// The companion **never holds raw keys in UserDefaults or on disk**: the local
/// agent CLIs (Codex, Claude) already manage their own credentials, and this
/// store only persists the *extra* secrets a provider needs that the CLIs do not
/// already hold — e.g. a Hermes/OpenClaw bearer token, or an Anthropic API key
/// used when the Claude CLI is absent but the API path is available.
///
/// Each provider gets a distinct generic-password service following the PLAN
/// naming contract: `"BurnBar.PetCompanion.<Provider>"` (PLAN §6 lists
/// `"BurnBar.Hermes"` / `"BurnBar.Codex"` / `"BurnBar.Claude"`; we namespace
/// under `PetCompanion` so the pet's secrets are visibly distinct from any
/// future app-wide BurnBar Keychain items in Keychain Access).
///
/// Pure value type wrapping the Security framework. `Sendable`: it carries no
/// mutable state, so it is safe to call from any actor; the SecItem APIs are
/// thread-safe.
struct PetKeychainStore: Sendable {

    /// The credential slots the pet's providers can persist. The `rawValue` is the
    /// Keychain *service* suffix, so renaming a case migrates the service name —
    /// keep these stable.
    enum Slot: String, Sendable, CaseIterable {
        case codex = "Codex"
        case claude = "Claude"
        case hermes = "Hermes"
        case openclaw = "OpenClaw"
        case openClaude = "OpenClaude"
        case omp = "OMP"
        case piAgent = "PiAgent"
        case droid = "Droid"
        case forge = "Forge"
        case antigravity = "Antigravity"
        case cursorAgent = "CursorAgent"
        case junie = "Junie"
        case grok = "Grok"
        case kimi = "Kimi"

        /// The full Keychain service string for this slot.
        var service: String { "BurnBar.PetCompanion.\(rawValue)" }

        /// Map a chat backend to its credential slot (1:1 today).
        init(_ backend: ChatBackendID) {
            switch backend {
            case .codex: self = .codex
            case .claude: self = .claude
            case .hermes: self = .hermes
            case .openclaw: self = .openclaw
            case .openClaude: self = .openClaude
            case .omp: self = .omp
            case .piAgent: self = .piAgent
            case .droid: self = .droid
            case .forge: self = .forge
            case .antigravity: self = .antigravity
            case .cursorAgent: self = .cursorAgent
            case .junie: self = .junie
            case .grok, .kimi: self = .xAI
            }
        }
    }

    /// Errors surfaced from the Security framework, carrying the `OSStatus` so a
    /// caller can log/inspect the underlying cause.
    enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case dataEncodingFailed
    }

    /// The account sub-key within a service. Most providers store a single
    /// `"token"`; callers can use distinct accounts (e.g. `"baseURL"`) to stash
    /// more than one value under the same provider service.
    static let defaultAccount = "token"

    // MARK: Round-trip API

    /// Store (or overwrite) `secret` for `slot` under `account`. Passing an empty
    /// string removes the item (so callers can "clear" a token by saving "").
    func set(_ secret: String, for slot: Slot, account: String = defaultAccount) throws {
        guard !secret.isEmpty else { try remove(slot, account: account); return }
        guard let data = secret.data(using: .utf8) else { throw KeychainError.dataEncodingFailed }

        let query = baseQuery(slot, account: account)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    /// Read the secret for `slot`, or `nil` if no item is stored.
    func get(_ slot: Slot, account: String = defaultAccount) throws -> String? {
        var query = baseQuery(slot, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Remove the stored item for `slot` (no-op if absent).
    func remove(_ slot: Slot, account: String = defaultAccount) throws {
        let status = SecItemDelete(baseQuery(slot, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Whether a non-empty secret is present for `slot`.
    func has(_ slot: Slot, account: String = defaultAccount) -> Bool {
        ((try? get(slot, account: account)) ?? nil)?.isEmpty == false
    }

    // MARK: Private

    private func baseQuery(_ slot: Slot, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: slot.service,
            kSecAttrAccount as String: account
        ]
    }
}
