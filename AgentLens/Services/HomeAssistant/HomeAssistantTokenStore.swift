import Foundation
import OpenBurnBarCore

// MARK: - Home Assistant Token Store
//
// Wraps `KeychainStore` so all HA token reads/writes go through one
// audited surface. The HA long-lived access token is treated as a
// password-class secret: it lives in the keychain, never in
// UserDefaults, never in a Codable plist, never logged.

protocol HomeAssistantTokenStoring: Sendable {
    func loadAccessToken() throws -> String?
    func saveAccessToken(_ token: String) throws
    func deleteAccessToken() throws

    func loadWebhookSecret() throws -> String?
    func saveWebhookSecret(_ secret: String) throws
    func deleteWebhookSecret() throws
}

struct HomeAssistantTokenStore: HomeAssistantTokenStoring {

    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore(
        service: OpenBurnBarIdentity.homeAssistantKeychainService,
        legacyServices: []
    )) {
        self.keychain = keychain
    }

    func loadAccessToken() throws -> String? {
        try keychain.string(for: OpenBurnBarIdentity.homeAssistantAccessTokenAccount)
    }

    func saveAccessToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteAccessToken()
        } else {
            try keychain.set(trimmed, for: OpenBurnBarIdentity.homeAssistantAccessTokenAccount)
        }
    }

    func deleteAccessToken() throws {
        try keychain.delete(account: OpenBurnBarIdentity.homeAssistantAccessTokenAccount)
    }

    func loadWebhookSecret() throws -> String? {
        try keychain.string(for: OpenBurnBarIdentity.homeAssistantWebhookSecretAccount)
    }

    func saveWebhookSecret(_ secret: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try deleteWebhookSecret()
        } else {
            try keychain.set(trimmed, for: OpenBurnBarIdentity.homeAssistantWebhookSecretAccount)
        }
    }

    func deleteWebhookSecret() throws {
        try keychain.delete(account: OpenBurnBarIdentity.homeAssistantWebhookSecretAccount)
    }
}

// MARK: - In-memory token store for tests

final class InMemoryHomeAssistantTokenStore: HomeAssistantTokenStoring, Sendable {
    private struct State {
        var token: String?
        var webhook: String?
    }

    private let state = Locked(State())

    func loadAccessToken() throws -> String? { state.withLock { $0.token } }
    func saveAccessToken(_ token: String) throws {
        state.withLock { $0.token = token.isEmpty ? nil : token }
    }
    func deleteAccessToken() throws { state.withLock { $0.token = nil } }

    func loadWebhookSecret() throws -> String? { state.withLock { $0.webhook } }
    func saveWebhookSecret(_ secret: String) throws {
        state.withLock { $0.webhook = secret.isEmpty ? nil : secret }
    }
    func deleteWebhookSecret() throws { state.withLock { $0.webhook = nil } }
}
