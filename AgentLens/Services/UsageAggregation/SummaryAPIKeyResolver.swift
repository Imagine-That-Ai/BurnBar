import Foundation

/// Resolves API keys for cloud summary providers by checking (in order):
/// 1. `ProviderAPIKeyStore` (user-configured keys in the app)
/// 2. Keychain (Cursor Connector bridge keys)
/// 3. Environment variables
struct SummaryAPIKeyResolver {
    let providerAPIKeyStore: ProviderAPIKeyStore

    /// Constructs the Keychain used for Cursor Connector bridge-key lookups.
    /// Defaults to the live store; tests inject a fake backend through this seam.
    private let keychainStoreProvider: @Sendable () -> KeychainStore

    init(
        providerAPIKeyStore: ProviderAPIKeyStore,
        keychainStoreProvider: @escaping @Sendable () -> KeychainStore = { KeychainStore() }
    ) {
        self.providerAPIKeyStore = providerAPIKeyStore
        self.keychainStoreProvider = keychainStoreProvider
    }

    func resolveAPIKey(for provider: SummaryProviderID) async -> String? {
        let env = ProcessInfo.processInfo.environment
        let store = providerAPIKeyStore
        switch provider {
        case .local, .mlx:
            return nil
        case .openrouter:
            let key = await store.apiKey(for: "openrouter")
            return nonEmpty(key) ?? nonEmpty(env["OPENROUTER_API_KEY"])
        case .minimax:
            let key = await store.apiKey(for: "minimax")
            return nonEmpty(key) ?? cursorConnectorKey(for: "provider.minimax.apiKey")
                ?? nonEmpty(env["MINIMAX_API_KEY"])
        case .zai:
            let key = await store.apiKey(for: "zai")
            return nonEmpty(key) ?? cursorConnectorKey(for: "provider.zai.apiKey")
                ?? nonEmpty(env["ZAI_API_KEY"])
        case .ollama:
            let key = await store.apiKey(for: "ollama")
            return nonEmpty(key) ?? nonEmpty(env["OLLAMA_API_KEY"])
        }
    }

    // MARK: - Private

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }

    private func cursorConnectorKey(for account: String) -> String? {
        let keychain = keychainStoreProvider()
        let raw = keychain.credentialIfPresent(
            for: account,
            allowUserInteraction: false,
            event: "summary_cursor_connector_key_read_failed"
        )
        return nonEmpty(raw)
    }
}
