import Foundation

/// Shared registration helper for platform shells.
///
/// Platform code owns credential lookup. This helper owns the provider/model
/// list so macOS, iOS/iPadOS, and Android mirrors can expose the same Insights
/// families without copy-pasting drift-prone model metadata.
public enum InsightProviderGatewayRegistry {
    public typealias KeyProvider = @Sendable (_ provider: String, _ aliases: [String], _ envKeys: [String]) -> String?
    public typealias URLProvider = @Sendable (_ key: String) -> URL?

    public static func registerDefaultSwiftGateways(
        in catalog: InsightModelCatalog,
        keyProvider: KeyProvider,
        urlProvider: URLProvider = { _ in nil },
        includeLocalRules: Bool = true,
        includeOllama: Bool = true
    ) async {
        if includeLocalRules {
            await catalog.register(LocalRuleBasedAdapter())
        }
        if includeOllama {
            await catalog.register(OllamaInsightAdapter())
        }

        if let apiKey = keyProvider("openai", [], ["OPENAI_API_KEY"]) {
            await catalog.register(OpenAIInsightAdapter(apiKey: apiKey, modelCatalog: [
                .init(id: "gpt-5.5", displayName: "Codex / GPT-5.5", providerKey: "openai",
                      egressTier: .userKey, capabilities: .init(supportsStrictJSONSchema: true, supportsJSONObject: true, supportsThinking: true, supportsToolUse: true),
                      symbolName: "brain.fill"),
                .init(id: "gpt-5.4", displayName: "Codex / GPT-5.4", providerKey: "openai",
                      egressTier: .userKey, capabilities: .init(supportsStrictJSONSchema: true, supportsJSONObject: true, supportsThinking: true, supportsToolUse: true),
                      symbolName: "brain.fill")
            ] + OpenAIInsightAdapter.defaultModels))
        }

        if let apiKey = keyProvider("anthropic", ["claude"], ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]) {
            await catalog.register(AnthropicInsightAdapter(apiKey: apiKey))
        }

        if let apiKey = keyProvider("minimax", [], ["MINIMAX_API_KEY"]),
           let baseURL = urlProvider("INSIGHTS_MINIMAX_BASE_URL") ?? URL(string: "https://api.minimax.io") {
            await catalog.register(OpenAICompatibleInsightAdapter(
                providerKey: "minimax",
                displayName: "MiniMax",
                apiKey: apiKey,
                baseURL: baseURL,
                modelCatalog: [
                    .init(id: "minimax-m1", displayName: "MiniMax M1", providerKey: "minimax", egressTier: .userKey, capabilities: .init(), symbolName: "sparkles")
                ]
            ))
        }

        if let apiKey = keyProvider("zai", ["z.ai"], ["ZAI_API_KEY", "ZHIPUAI_API_KEY"]),
           let baseURL = urlProvider("INSIGHTS_ZAI_BASE_URL") ?? URL(string: "https://open.bigmodel.cn") {
            await catalog.register(OpenAICompatibleInsightAdapter(
                providerKey: "zai",
                displayName: "Z.ai",
                apiKey: apiKey,
                baseURL: baseURL,
                modelCatalog: [
                    .init(id: "glm-4.6", displayName: "GLM 4.6", providerKey: "zai", egressTier: .userKey, capabilities: .init(), symbolName: "sparkles")
                ],
                chatCompletionsPath: "/api/paas/v4/chat/completions"
            ))
        }

        if let apiKey = keyProvider("kimi", ["moonshot"], ["KIMI_API_KEY", "MOONSHOT_API_KEY"]),
           let baseURL = urlProvider("INSIGHTS_KIMI_BASE_URL") ?? URL(string: "https://api.moonshot.ai") {
            await catalog.register(OpenAICompatibleInsightAdapter(
                providerKey: "kimi",
                displayName: "Kimi",
                apiKey: apiKey,
                baseURL: baseURL,
                modelCatalog: [
                    .init(id: "kimi-k2", displayName: "Kimi K2", providerKey: "kimi", egressTier: .userKey, capabilities: .init(), symbolName: "moon.stars.fill")
                ]
            ))
        }
    }
}
