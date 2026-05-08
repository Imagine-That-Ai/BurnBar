import Foundation

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

final class InMemoryHomeAssistantTokenStore: HomeAssistantTokenStoring, @unchecked Sendable {
    private let queue = DispatchQueue(label: "openburnbar.ha.token-store.test")
    private var token: String?
    private var webhook: String?

    func loadAccessToken() throws -> String? { queue.sync { token } }
    func saveAccessToken(_ token: String) throws {
        queue.sync { self.token = token.isEmpty ? nil : token }
    }
    func deleteAccessToken() throws { queue.sync { self.token = nil } }

    func loadWebhookSecret() throws -> String? { queue.sync { webhook } }
    func saveWebhookSecret(_ secret: String) throws {
        queue.sync { self.webhook = secret.isEmpty ? nil : secret }
    }
    func deleteWebhookSecret() throws { queue.sync { self.webhook = nil } }
}
