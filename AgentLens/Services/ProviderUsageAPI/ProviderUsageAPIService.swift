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

struct ProviderUsageRecord: Sendable {
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
            endTime: date
        )
    }
}

// MARK: - API Key Store

/// Manages API keys for provider usage APIs via Keychain.
@MainActor
final class ProviderAPIKeyStore {
    static let shared = ProviderAPIKeyStore()

    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore(
        service: "com.burnbar.provider-api-keys",
        legacyServices: []
    )) {
        self.keychain = keychain
    }

    func apiKey(for provider: String) -> String? {
        try? keychain.string(for: provider)
    }

    func setAPIKey(_ key: String, for provider: String) throws {
        try keychain.set(key, for: provider)
    }

    func removeAPIKey(for provider: String) throws {
        try keychain.delete(account: provider)
    }

    func hasKey(for provider: String) -> Bool {
        (try? keychain.string(for: provider)) != nil
    }
}

// MARK: - Usage API Service (Coordinator)

@Observable
@MainActor
final class ProviderUsageAPIService {
    private let keyStore: ProviderAPIKeyStore
    private var apis: [any ProviderUsageAPI] = []

    private(set) var lastFetch: Date?
    private(set) var errors: [String: String] = [:]
    private(set) var isFetching = false

    init(keyStore: ProviderAPIKeyStore = .shared) {
        self.keyStore = keyStore
        rebuildAPIs()
    }

    /// Rebuild the active API list based on which providers have keys configured.
    func rebuildAPIs() {
        var active: [any ProviderUsageAPI] = []

        if let key = keyStore.apiKey(for: "anthropic") {
            active.append(AnthropicUsageAPI(apiKey: key))
        }
        if let key = keyStore.apiKey(for: "openai") {
            active.append(OpenAIUsageAPI(apiKey: key))
        }
        if let key = keyStore.apiKey(for: "openrouter") {
            active.append(OpenRouterUsageAPI(apiKey: key))
        }
        if let key = keyStore.apiKey(for: "github") {
            active.append(GitHubCopilotUsageAPI(pat: key))
        }

        // Z.ai and MiniMax probes — use existing connector API keys if available
        if let key = keyStore.apiKey(for: "zai") {
            active.append(ZaiUsageProbe(apiKey: key))
        }
        if let key = keyStore.apiKey(for: "minimax") {
            active.append(MiniMaxUsageProbe(apiKey: key))
        }

        apis = active
    }

    var configuredProviders: [String] {
        apis.map(\.providerName)
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
}
