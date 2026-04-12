import Foundation
import OpenBurnBarCore

// MARK: - Switcher Auth Store

/// Stores auth credentials for switcher profiles in the macOS Keychain.
///
/// Security model:
/// - Profile metadata lives in SwitcherProfileRecord (SQLite) — non-sensitive only
/// - Credentials live here (Keychain) — never in the database
/// - Follows the same pattern as CursorConnectorManager's API key storage
///
/// This enables the onboarding wizard to import existing auth tokens
/// so that launch services can use them without re-authentication.
final class SwitcherAuthStore {
    private let keychain: KeychainStore

    static let service = OpenBurnBarIdentity.switcherAuthKeychainService

    init() {
        self.keychain = KeychainStore(service: Self.service, legacyServices: [])
    }

    // MARK: - API Key

    /// Stores an API key for a profile.
    func storeAPIKey(_ key: String, forProfileID profileID: String, cliType: SwitcherCLIProfileType) throws {
        let account = "switcher.\(profileID).\(cliType.rawValue).apiKey"
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keychain.delete(account: account)
        } else {
            try keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
        }
    }

    /// Retrieves the API key for a profile (if stored).
    func apiKey(forProfileID profileID: String, cliType: SwitcherCLIProfileType) -> String? {
        let account = "switcher.\(profileID).\(cliType.rawValue).apiKey"
        return try? keychain.string(for: account, allowUserInteraction: false)
    }

    // MARK: - OAuth Token

    /// Stores an OAuth token for a profile.
    func storeOAuthToken(_ token: String, forProfileID profileID: String, provider: String) throws {
        let account = "switcher.\(profileID).\(provider).oauthToken"
        if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try keychain.delete(account: account)
        } else {
            try keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
        }
    }

    /// Retrieves the OAuth token for a profile (if stored).
    func oauthToken(forProfileID profileID: String, provider: String) -> String? {
        let account = "switcher.\(profileID).\(provider).oauthToken"
        return try? keychain.string(for: account, allowUserInteraction: false)
    }

    // MARK: - Cleanup

    /// Deletes all credentials for a profile.
    func deleteCredentials(forProfileID profileID: String) throws {
        // Try to delete known account patterns
        for cliType in SwitcherCLIProfileType.allCases {
            try? keychain.delete(account: "switcher.\(profileID).\(cliType.rawValue).apiKey")
        }
        for provider in ["google", "apple", "anthropic", "openai"] {
            try? keychain.delete(account: "switcher.\(profileID).\(provider).oauthToken")
        }
    }
}
