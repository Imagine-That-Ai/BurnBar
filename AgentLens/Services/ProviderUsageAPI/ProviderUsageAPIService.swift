import Foundation

// MARK: - Auth Method

enum ProviderAuthMethod {
    case apiKey
    case oauth
    case pat
}

// MARK: - Usage API Protocol

protocol ProviderUsageAPI: Sendable {
    var providerName: String { get }
    var authMethod: ProviderAuthMethod { get }

    /// Validate that the stored credentials are valid and the API is reachable.
    func validate() async throws -> Bool

    /// Fetch usage data since the given date.
    func fetchUsage(since: Date) async throws -> [ProviderUsageRecord]
}

// MARK: - Usage Record (from provider APIs)

struct ProviderUsageRecord: Sendable, Equatable {
    let providerName: String
    let model: String
    let date: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreationTokens: Int
    let costUSD: Double
    let requestCount: Int

    /// Convert to a TokenUsage for storage/display alongside log-parsed data.
    func toTokenUsage(provider: AgentProvider) -> TokenUsage {
        TokenUsage(
            provider: provider,
            sessionId: "api-\(providerName)-\(Int(date.timeIntervalSince1970))-\(model)",
            projectName: "\(providerName) API",
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            costUSD: costUSD,
            startTime: date,
            endTime: date,
            usageSource: .billingAPI,
            provenanceMethod: .billingAPI,
            provenanceConfidence: .exact
        )
    }

    var normalizedProviderName: String {
        providerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var mappedProvider: AgentProvider? {
        switch normalizedProviderName {
        case "factory":
            return .factory
        case "anthropic", "claude", "claude code", "claude-code":
            return .claudeCode
        case "openai", "codex", "openai codex":
            return .codex
        case "minimax":
            return .minimax
        case "z.ai", "zai":
            return .zai
        case "github copilot", "copilot":
            return .copilot
        default:
            return nil
        }
    }
}

// MARK: - API Key Store

/// Manages API keys for provider usage APIs via Keychain.
@MainActor
final class ProviderAPIKeyStore {
    static let shared = ProviderAPIKeyStore()

    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore(
        service: OpenBurnBarIdentity.providerAPIKeychainService,
        legacyServices: OpenBurnBarIdentity.legacyProviderAPIKeychainServices
    )) {
        self.keychain = keychain
    }

    func apiKey(for provider: String, allowUserInteraction: Bool = false) -> String? {
        try? keychain.string(for: provider, allowUserInteraction: allowUserInteraction)
    }

    func setAPIKey(_ key: String, for provider: String) throws {
        try keychain.set(key, for: provider)
    }

    func removeAPIKey(for provider: String) throws {
        try keychain.delete(account: provider)
    }

    func hasKey(for provider: String) -> Bool {
        apiKey(for: provider, allowUserInteraction: false) != nil
    }
}

// MARK: - Usage API Service (Coordinator)

@Observable
@MainActor
final class ProviderUsageAPIService {
    private let keyStore: ProviderAPIKeyStore
    private let connectorKeychain: KeychainStore
    private let environment: [String: String]
    private var apis: [any ProviderUsageAPI] = []

    private(set) var lastFetch: Date?
    private(set) var errors: [String: String] = [:]
    private(set) var isFetching = false

    init(
        keyStore: ProviderAPIKeyStore = .shared,
        connectorKeychain: KeychainStore = KeychainStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.keyStore = keyStore
        self.connectorKeychain = connectorKeychain
        self.environment = environment
        rebuildAPIs()
    }

    /// Rebuild the active API list based on which providers have keys configured.
    func rebuildAPIs() {
        var active: [any ProviderUsageAPI] = []

        if let key = resolvedAPIKey(for: "anthropic") {
            active.append(AnthropicUsageAPI(apiKey: key))
        }
        if let key = resolvedAPIKey(for: "openai") {
            active.append(OpenAIUsageAPI(apiKey: key))
        }
        if let key = resolvedAPIKey(for: "openrouter") {
            active.append(OpenRouterUsageAPI(apiKey: key))
        }
        if let key = resolvedAPIKey(for: "github") {
            active.append(GitHubCopilotUsageAPI(pat: key))
        }

        // Z.ai and MiniMax probes — use existing connector API keys if available
        if let key = resolvedAPIKey(for: "zai") {
            active.append(ZaiUsageProbe(apiKey: key))
        }
        if let key = resolvedAPIKey(for: "minimax") {
            active.append(MiniMaxUsageProbe(apiKey: key))
        }

        // Ollama local probe — always attempt if server is running.
        let ollamaHost = environment["OLLAMA_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ollamaBase = ollamaHost.isEmpty ? "http://localhost:11434" : (ollamaHost.hasPrefix("http") ? ollamaHost : "http://\(ollamaHost)")
        active.append(OllamaUsageProbe(baseURL: ollamaBase, apiKey: resolvedAPIKey(for: "ollama")))

        apis = active
    }

    var configuredProviders: [String] {
        apis.map(\.providerName)
    }

    /// Rebuilds APIs and returns a snapshot of the active `ProviderUsageAPI` instances.
    /// Call this on `@MainActor` before entering a background context so billing
    /// reconciliation can run without main-actor hops.
    func snapshotAPIs() -> [any ProviderUsageAPI] {
        rebuildAPIs()
        return apis
    }

    /// Fetch usage from all configured provider APIs.
    func fetchAll(since: Date) async -> [ProviderUsageRecord] {
        guard !isFetching else { return [] }
        isFetching = true
        defer { isFetching = false }
        errors = [:]

        var allRecords: [ProviderUsageRecord] = []

        for api in apis {
            do {
                let records = try await api.fetchUsage(since: since)
                allRecords.append(contentsOf: records)
            } catch {
                errors[api.providerName] = error.localizedDescription
            }
        }

        lastFetch = Date()
        return allRecords
    }

    /// Validate a specific provider's credentials.
    func validate(provider: String) async -> Bool {
        guard let api = apis.first(where: { $0.providerName == provider }) else { return false }
        return (try? await api.validate()) ?? false
    }

    private func resolvedAPIKey(for provider: String) -> String? {
        switch provider {
        case "anthropic":
            return nonEmpty(keyStore.apiKey(for: provider))
                ?? nonEmpty(environment["ANTHROPIC_API_KEY"])
        case "openai":
            return nonEmpty(keyStore.apiKey(for: provider))
                ?? nonEmpty(environment["OPENAI_API_KEY"])
        case "openrouter":
            return nonEmpty(keyStore.apiKey(for: provider))
                ?? nonEmpty(environment["OPENROUTER_API_KEY"])
        case "github":
            return nonEmpty(keyStore.apiKey(for: provider))
                ?? nonEmpty(environment["GITHUB_TOKEN"])
        case "zai":
            return nonEmpty(keyStore.apiKey(for: provider))
                ?? connectorKey(for: "provider.zai.apiKey")
                ?? nonEmpty(environment["ZAI_API_KEY"])
                ?? nonEmpty(environment["Z_AI_API_KEY"])
        case "minimax":
            return nonEmpty(keyStore.apiKey(for: provider))
                ?? connectorKey(for: "provider.minimax.apiKey")
                ?? nonEmpty(environment["MINIMAX_API_KEY"])
        case "ollama":
            return nonEmpty(keyStore.apiKey(for: provider))
                ?? nonEmpty(environment["OLLAMA_API_KEY"])
        default:
            return nonEmpty(keyStore.apiKey(for: provider))
        }
    }

    private func connectorKey(for account: String) -> String? {
        let raw = try? connectorKeychain.string(for: account, allowUserInteraction: false)
        return nonEmpty(raw ?? nil)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
