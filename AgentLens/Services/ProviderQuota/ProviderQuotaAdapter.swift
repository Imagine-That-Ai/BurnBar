import Foundation


protocol ProviderQuotaAdapter: Sendable {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot
}

struct ProviderQuotaAdapterContext {
    let appPaths: OpenBurnBarAppPaths
    let fileManager: FileManager
    let session: URLSession
    let environment: [String: String]
    let homeDirectoryURL: URL
    let dataStoreActor: DataStoreActor
    let snapshotStore: ProviderQuotaSnapshotStore
    let bridgeManager: ClaudeQuotaBridgeManager
    let miniMaxModeProvider: () -> MiniMaxQuotaMode
    let factoryPlanProvider: () -> FactoryQuotaPlanTier
    let claudeBridgeStatus: ClaudeQuotaBridgeStatus
    let codexRolloutScanCache: CodexRolloutScanCache
    let updateCodexRolloutScanCache: (CodexRolloutScanCache, Bool) -> Void
    let refreshClaudeBridgeStatus: () -> ClaudeQuotaBridgeStatus
    /// Reads Claude Code's OAuth credentials from the macOS Keychain
    /// (or `~/.claude/.credentials.json` fallback). Injected so tests
    /// can drive the OAuth-fetch path with synthetic credentials
    /// without touching the user's real Keychain.
    let claudeCredentialsReader: ClaudeCredentialsReading

    /// Pre-resolved API keys (read from ProviderAPIKeyStore on the main actor before dispatch).
    let resolvedAPIKeys: [String: String?]
}

// All properties are value types (Sendable); no @unchecked needed.
extension ProviderQuotaAdapterContext: Sendable {}

extension ProviderQuotaAdapterContext {
    func withResolvedAPIKeys(_ resolvedAPIKeys: [String: String?]) -> ProviderQuotaAdapterContext {
        ProviderQuotaAdapterContext(
            appPaths: appPaths,
            fileManager: fileManager,
            session: session,
            environment: environment,
            homeDirectoryURL: homeDirectoryURL,
            dataStoreActor: dataStoreActor,
            snapshotStore: snapshotStore,
            bridgeManager: bridgeManager,
            miniMaxModeProvider: miniMaxModeProvider,
            factoryPlanProvider: factoryPlanProvider,
            claudeBridgeStatus: claudeBridgeStatus,
            codexRolloutScanCache: codexRolloutScanCache,
            updateCodexRolloutScanCache: updateCodexRolloutScanCache,
            refreshClaudeBridgeStatus: refreshClaudeBridgeStatus,
            claudeCredentialsReader: claudeCredentialsReader,
            resolvedAPIKeys: resolvedAPIKeys
        )
    }
}

extension ProviderQuotaAdapter {
    func unavailableSnapshot(
        for provider: AgentProvider,
        source: ProviderQuotaSourceKind,
        message: String
    ) -> ProviderQuotaSnapshot {
        ProviderQuotaSnapshot(
            provider: provider,
            fetchedAt: Date(),
            source: source,
            confidence: .unavailable,
            managementURL: nil,
            statusMessage: message,
            buckets: []
        )
    }
}

struct OpenAIQuotaAdapter: ProviderQuotaAdapter {
    func fetch(context: ProviderQuotaAdapterContext) async throws -> ProviderQuotaSnapshot {
        guard let apiKey = quotaNonEmpty(context.resolvedAPIKeys["openai"] ?? nil) else {
            return unavailableSnapshot(
                for: .openAI,
                source: .officialAPI,
                message: "Add an OpenAI organization admin API key to refresh recent usage."
            )
        }

        let now = Date()
        let start = now.addingTimeInterval(-24 * 60 * 60)
        var components = URLComponents(string: "https://api.openai.com/v1/organization/usage/completions")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(now.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]
        guard let url = components.url else {
            return unavailableSnapshot(for: .openAI, source: .officialAPI, message: "OpenAI usage URL could not be built.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await context.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaServiceError.invalidResponse("OpenAI returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaServiceError.httpStatus(provider: .openAI, code: http.statusCode)
        }

        let totals = try parseUsageTotals(from: data)
        return ProviderQuotaSnapshot(
            provider: .openAI,
            providerID: .openAI,
            fetchedAt: now,
            source: .officialAPI,
            confidence: .exact,
            managementURL: "https://platform.openai.com/usage",
            statusMessage: "OpenAI reports recent organization usage; hard quota limits are not exposed by this endpoint.",
            buckets: [
                ProviderQuotaBucket(
                    key: "tokens-24h",
                    label: "Tokens used in the last 24 hours",
                    windowKind: .rollingHours,
                    usedValue: Double(totals.tokens),
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .tokens,
                    isEstimated: false
                ),
                ProviderQuotaBucket(
                    key: "requests-24h",
                    label: "Requests in the last 24 hours",
                    windowKind: .rollingHours,
                    usedValue: Double(totals.requests),
                    limitValue: nil,
                    remainingValue: nil,
                    usedPercent: nil,
                    resetsAt: nil,
                    unit: .requests,
                    isEstimated: false
                )
            ]
        )
    }

    private func parseUsageTotals(from data: Data) throws -> (tokens: Int, requests: Int) {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaServiceError.invalidResponse("OpenAI usage payload was not a JSON object.")
        }
        let buckets = object["data"] as? [[String: Any]] ?? []
        var tokens = 0
        var requests = 0

        for bucket in buckets {
            let results = bucket["results"] as? [[String: Any]] ?? [bucket]
            for result in results {
                let input = result["input_tokens"] as? Int ?? 0
                let output = result["output_tokens"] as? Int ?? 0
                tokens += input + output
                requests += result["num_model_requests"] as? Int ?? 0
            }
        }

        return (tokens, requests)
    }
}
