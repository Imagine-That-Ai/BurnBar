import Foundation

/// Resolves API keys for cloud summary providers by checking (in order):
/// 1. `ProviderAPIKeyStore` (user-configured keys in the app)
/// 2. Keychain (Cursor Connector bridge keys)
/// 3. Environment variables
@MainActor
struct SummaryAPIKeyResolver {
    let providerAPIKeyStore: ProviderAPIKeyStore

    func resolveAPIKey(for provider: SummaryProviderID) -> String? {
        let env = ProcessInfo.processInfo.environment
        switch provider {
        case .local, .mlx:
            return nil
        case .openrouter:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "openrouter"))
                ?? nonEmpty(env["OPENROUTER_API_KEY"])
        case .minimax:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "minimax"))
                ?? cursorConnectorKey(for: "provider.minimax.apiKey")
                ?? nonEmpty(env["MINIMAX_API_KEY"])
        case .zai:
            return nonEmpty(providerAPIKeyStore.apiKey(for: "zai"))
                ?? cursorConnectorKey(for: "provider.zai.apiKey")
                ?? nonEmpty(env["ZAI_API_KEY"])
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
        let keychain = KeychainStore()
        let raw = try? keychain.string(for: account, allowUserInteraction: false)
        return nonEmpty(raw ?? nil)
    }
}
