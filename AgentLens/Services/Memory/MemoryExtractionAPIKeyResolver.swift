import Foundation

// MARK: - Memory Extraction API Key Resolver
//
// Resolves cloud-provider API keys for memory extraction, in the same order and from
// the same sources as `SummaryAPIKeyResolver` (the established pattern):
//   1. `ProviderAPIKeyStore` (user-configured keys in the app)
//   2. Keychain (Cursor Connector bridge keys)
//   3. Environment variables
//
// Kept as a dedicated type (rather than reusing `SummaryAPIKeyResolver`) so the
// memory subsystem owns its own egress seam and a future divergence in provider set
// or key precedence does not couple the two features. Local providers (`.local`,
// `.mlx`) never resolve a key — they are on-device and the cloud daily cap never
// applies to them, which is what makes the hard local-first default free.
struct MemoryExtractionAPIKeyResolver: Sendable {
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
              trimmed.isEmpty == false
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
            event: "memory_extraction_cursor_connector_key_read_failed"
        )
        return nonEmpty(raw)
    }
}
