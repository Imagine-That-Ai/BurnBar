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

    init(keychain: KeychainStore = KeychainStore(service: OpenBurnBarIdentity.switcherAuthKeychainService, legacyServices: [])) {
        self.keychain = keychain
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
        // `KeychainStore.string` already returns nil for the soft cases
        // (item-not-found, interaction-not-allowed); a throw here is a genuinely
        // unexpected keychain fault worth tracking instead of swallowing.
        return AppLogger.shared.silently(
            "switcher_keychain_api_key_read",
            try keychain.string(for: account, allowUserInteraction: false),
            fallback: nil
        )
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
        return AppLogger.shared.silently(
            "switcher_keychain_oauth_token_read",
            try keychain.string(for: account, allowUserInteraction: false),
            fallback: nil
        )
    }

    // MARK: - Cleanup

    /// Deletes all credentials for a profile.
    ///
    /// A failed delete leaves a live credential in the Keychain, so each failure
    /// is surfaced via the logger rather than swallowed — but the loop continues
    /// so one stuck account never blocks removal of the rest.
    func deleteCredentials(forProfileID profileID: String) throws {
        for cliType in SwitcherCLIProfileType.allCases {
            let account = "switcher.\(profileID).\(cliType.rawValue).apiKey"
            do {
                try keychain.delete(account: account)
            } catch {
                AppLogger.shared.error(
                    "switcher_keychain_api_key_delete_failed",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
            }
        }
        for provider in ["google", "apple", "anthropic", "openai"] {
            let account = "switcher.\(profileID).\(provider).oauthToken"
            do {
                try keychain.delete(account: account)
            } catch {
                AppLogger.shared.error(
                    "switcher_keychain_oauth_token_delete_failed",
                    metadata: ["errorClass": "\(String(describing: type(of: error)))"]
                )
            }
        }
    }
}
