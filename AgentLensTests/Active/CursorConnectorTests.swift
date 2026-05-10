import XCTest
@testable import OpenBurnBar

@MainActor
final class CursorConnectorTests: XCTestCase {

    func test_connectorProvider_defaults_comeFromCatalog() {
        XCTAssertEqual(ConnectorProvider.zai.displayName, "Z.ai")
        XCTAssertEqual(ConnectorProvider.zai.defaultBaseURL, "https://api.z.ai/api/coding/paas/v4")
        XCTAssertEqual(ConnectorProvider.zai.suggestedModels, ["glm-5-turbo", "glm-5"])

        XCTAssertEqual(ConnectorProvider.minimax.displayName, "MiniMax")
        XCTAssertEqual(ConnectorProvider.minimax.defaultBaseURL, "https://api.minimax.io/v1")
        XCTAssertEqual(ConnectorProvider.minimax.suggestedModels, ["minimax-m2.7-highspeed"])

        XCTAssertEqual(ConnectorProvider.ollama.displayName, "Ollama Cloud")
        XCTAssertEqual(ConnectorProvider.ollama.defaultBaseURL, "https://ollama.com/api")
        XCTAssertEqual(Array(ConnectorProvider.ollama.suggestedModels.prefix(3)), ["deepseek-v4-flash", "qwen3.6:27b-coding-nvfp4", "gpt-oss:120b"])
    }

    func test_supportedModel_allowsSupportedProvidersOnly() {
        XCTAssertTrue(CursorConnectorManager.supportedModel("glm-5"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M2.7-highspeed"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M3-pro"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("deepseek-v4-flash:cloud"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("kimi-for-coding"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("pony-alpha-2"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("claude-3-7-sonnet"))
        XCTAssertFalse(CursorConnectorManager.supportedModel(""))
    }

    func test_supportedModel_respectsProviderCatalogMatchers() {
        XCTAssertTrue(CursorConnectorManager.supportedModel("glm-5-plus", provider: .zai))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M3-pro", provider: .minimax))
        XCTAssertTrue(CursorConnectorManager.supportedModel("gpt-oss:120b-cloud", provider: .ollama))
        XCTAssertFalse(CursorConnectorManager.supportedModel("MiniMax-M3-pro", provider: .zai))
    }

    func test_modelPricing_usesCatalogWithSharedFallback() {
        let zaiPricing = ModelPricing.lookup(model: "glm-5")
        XCTAssertEqual(zaiPricing.inputPerMToken, 0.07, accuracy: 0.001)
        XCTAssertEqual(zaiPricing.outputPerMToken, 0.07, accuracy: 0.001)

        let fallbackPricing = ModelPricing.lookup(model: "unknown-model")
        XCTAssertEqual(fallbackPricing.inputPerMToken, 2.5, accuracy: 0.001)
        XCTAssertEqual(fallbackPricing.outputPerMToken, 10, accuracy: 0.001)
        XCTAssertEqual(fallbackPricing.cacheReadPerMToken, 1.25, accuracy: 0.001)
    }

    func test_exposedModels_deduplicatesSelectionAndCustomValues() {
        let config = ConnectorProviderConfig(
            id: .zai,
            enabled: true,
            selectedModels: ["glm-5", "glm-5-turbo", "glm-5"],
            customModels: ["glm-5-turbo", "glm-5-plus"]
        )

        XCTAssertEqual(config.exposedModels, ["glm-5", "glm-5-turbo", "glm-5-plus"])
    }

    func test_cursorConnectorConfig_onlyIncludesEnabledProviders() {
        let config = CursorConnectorConfig(
            providerConfigs: [
                ConnectorProviderConfig(
                    id: .zai,
                    enabled: true,
                    selectedModels: ["glm-5"],
                    customModels: ["glm-5-turbo"]
                ),
                ConnectorProviderConfig(
                    id: .minimax,
                    enabled: false,
                    selectedModels: ["MiniMax-M2.7-highspeed"]
                )
            ]
        )

        XCTAssertEqual(config.exposedModels, ["glm-5", "glm-5-turbo"])
    }

    func test_extractTryCloudflareURL_acceptsCanonicalTunnelURL() {
        let output = "2026-05-08T12:00:00Z INF | https://quick-burnbar.trycloudflare.com | tunnel ready"

        XCTAssertEqual(
            CursorConnectorManager.extractTryCloudflareURL(from: output),
            "https://quick-burnbar.trycloudflare.com"
        )
    }

    func test_extractTryCloudflareURL_trimsLogPunctuationAndNormalizesHost() {
        let output = "<HTTPS://Mixed-Case.trycloudflare.com>, status=ok"

        XCTAssertEqual(
            CursorConnectorManager.extractTryCloudflareURL(from: output),
            "https://mixed-case.trycloudflare.com"
        )
    }

    func test_extractTryCloudflareURL_rejectsNonCanonicalOrUnsafeHosts() {
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "http://quick-burnbar.trycloudflare.com"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://nested.quick-burnbar.trycloudflare.com"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://quick-burnbar.trycloudflare.com.evil.example"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://trycloudflare.com"))
    }

    func test_normalizeUsageEvent_includesCacheCreationTokensInTotals() {
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "prompt_tokens": 120,
            "completion_tokens": 80,
            "cache_creation_input_tokens": 40,
            "cache_read_input_tokens": 20,
            "total_tokens": 260
        ])

        XCTAssertEqual(normalized.promptTokens, 120)
        XCTAssertEqual(normalized.completionTokens, 80)
        XCTAssertEqual(normalized.cacheCreationTokens, 40)
        XCTAssertEqual(normalized.cacheReadTokens, 20)
        XCTAssertEqual(normalized.totalTokens, 260)
    }

    func test_normalizeUsageEvent_backfillsPromptAndCompletionAfterCacheOverhead() {
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "cacheCreationTokens": 50,
            "cacheReadTokens": 25,
            "totalTokens": 275,
            "input_char_estimate": 620,
            "output_char_estimate": 310
        ])

        XCTAssertEqual(normalized.cacheCreationTokens, 50)
        XCTAssertEqual(normalized.cacheReadTokens, 25)
        XCTAssertEqual(normalized.promptTokens + normalized.completionTokens, 200)
        XCTAssertEqual(normalized.totalTokens, 275)
    }

    // MARK: - Reasoning Token Extraction Tests (VAL-TOKEN-006)

    func test_normalizeUsageEvent_extractsReasoningTokens_fromFlatPayload() {
        // Test extraction from flat reasoning_tokens key
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "reasoning_tokens": 25,
            "total_tokens": 175
        ])

        XCTAssertEqual(normalized.promptTokens, 100)
        XCTAssertEqual(normalized.completionTokens, 50)
        XCTAssertEqual(normalized.reasoningTokens, 25)
        XCTAssertEqual(normalized.totalTokens, 175)
    }

    func test_normalizeUsageEvent_extractsReasoningTokens_fromNestedPayload() {
        // Test extraction from nested completion_tokens_details path
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "completion_tokens_details": ["reasoning_tokens": 30],
            "total_tokens": 180
        ])

        XCTAssertEqual(normalized.promptTokens, 100)
        XCTAssertEqual(normalized.completionTokens, 50)
        XCTAssertEqual(normalized.reasoningTokens, 30)
        XCTAssertEqual(normalized.totalTokens, 180)
    }

    func test_normalizeUsageEvent_extractsReasoningTokens_fromThinkingTokens() {
        // Test extraction from thinking_tokens alias
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "thinking_tokens": 20,
            "total_tokens": 170
        ])

        XCTAssertEqual(normalized.promptTokens, 100)
        XCTAssertEqual(normalized.completionTokens, 50)
        XCTAssertEqual(normalized.reasoningTokens, 20)
        XCTAssertEqual(normalized.totalTokens, 170)
    }

    func test_normalizeUsageEvent_extractsReasoningTokens_fromOutputTokensDetails() {
        // Test extraction from nested output_tokens_details path
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "prompt_tokens": 100,
            "output_tokens": 50,
            "output_tokens_details": ["reasoning_tokens": 35],
            "total_tokens": 185
        ])

        XCTAssertEqual(normalized.promptTokens, 100)
        XCTAssertEqual(normalized.completionTokens, 50)
        XCTAssertEqual(normalized.reasoningTokens, 35)
        XCTAssertEqual(normalized.totalTokens, 185)
    }

    func test_normalizeUsageEvent_hasNoExplicitBuckets_includesReasoningTokens() {
        // VAL-TOKEN-006: When reasoning tokens are present, hasNoExplicitBuckets should be false
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "reasoning_tokens": 25,
            "total_tokens": 25
        ])

        XCTAssertEqual(normalized.reasoningTokens, 25)
        XCTAssertFalse(normalized.hasNoExplicitBuckets)
    }

    func test_normalizeUsageEvent_hasNoExplicitBuckets_falseWhenOnlyReasoningPresent() {
        // Reasoning tokens alone mean explicit buckets exist - not a fallback case
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "reasoning_tokens": 50
        ])

        // hasNoExplicitBuckets checks prompt, completion, cacheCreation, cacheRead, AND reasoning
        XCTAssertEqual(normalized.reasoningTokens, 50)
        XCTAssertFalse(normalized.hasNoExplicitBuckets)
    }

    func test_proxyScript_resolvesProviderKeysThroughSecretBrokerOnly() {
        let script = CursorConnectorManager.proxyScript()

        XCTAssertTrue(script.contains("secret_broker_url"))
        XCTAssertTrue(script.contains("secret_broker_token"))
        XCTAssertTrue(script.contains("route_id"))
        XCTAssertFalse(script.contains("keychain_service"))
        XCTAssertFalse(script.contains("keychain_account"))
        XCTAssertFalse(script.contains("find-generic-password"))
        XCTAssertFalse(script.contains("/usr/bin/security"))
    }

    func test_proxyScript_preservesDeepSeekReasoningContentAcrossResponsesConversion() {
        let script = CursorConnectorManager.proxyScript()

        XCTAssertTrue(script.contains("reasoning_content"))
        XCTAssertTrue(script.contains("response_item_to_chat_messages"))
        XCTAssertTrue(script.contains("chat_message_to_response_output"))
        XCTAssertTrue(script.contains("(\"reasoning_content\", \"thinking\", \"reasoning\")"))
    }

    func test_proxyScript_preservesToolCallHistoryAcrossResponsesConversion() {
        let script = CursorConnectorManager.proxyScript()

        XCTAssertTrue(script.contains("function_call_output"))
        XCTAssertTrue(script.contains("tool_calls"))
        XCTAssertTrue(script.contains("tool_call_id"))
        XCTAssertTrue(script.contains("call_id"))
    }

    func test_routedClientSync_updatesBothFactoryConfigShapesAndPreservesExistingModels() throws {
        let home = try makeTemporaryHome()
        let factoryDirectory = home.appendingPathComponent(".factory", isDirectory: true)
        try FileManager.default.createDirectory(at: factoryDirectory, withIntermediateDirectories: true)
        let settingsURL = factoryDirectory.appendingPathComponent("settings.json")
        let configURL = factoryDirectory.appendingPathComponent("config.json")
        try Data("""
        {
          "theme": "factory",
          "customModels": [
            {"model": "existing-model", "baseUrl": "https://example.com/v1", "provider": "other"},
            {"model": "old-burnbar", "id": "openburnbar:old-burnbar", "baseUrl": "http://old/v1", "provider": "openburnbar"}
          ]
        }
        """.utf8).write(to: settingsURL)
        try Data("""
        {
          "custom_models": [
            {"model": "existing-config-model", "base_url": "https://example.com/v1", "provider": "other"},
            {"model": "old-burnbar", "base_url": "http://old/v1", "provider": "openburnbar"}
          ]
        }
        """.utf8).write(to: configURL)

        let service = RoutedClientConfigSyncService(
            homeDirectory: home,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        try service.applyFactoryGatewayConfig(
            RoutedClientGatewayConfig(
                baseURL: "http://127.0.0.1:8317/v1",
                bearerToken: "gateway-token",
                models: ["glm-5", "glm-5", "minimax-m2.7-highspeed"]
            )
        )

        let settings = try XCTUnwrap(readJSON(settingsURL)["customModels"] as? [[String: Any]])
        XCTAssertEqual(settings.compactMap { $0["model"] as? String }, ["existing-model", "glm-5", "minimax-m2.7-highspeed"])
        XCTAssertEqual(settings.last?["baseUrl"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(settings.last?["apiKey"] as? String, "gateway-token")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.openburnbar-backup-20231114221320").path))

        let factoryConfig = try XCTUnwrap(readJSON(configURL)["custom_models"] as? [[String: Any]])
        XCTAssertEqual(factoryConfig.compactMap { $0["model"] as? String }, ["existing-config-model", "glm-5", "minimax-m2.7-highspeed"])
        XCTAssertEqual(factoryConfig.last?["base_url"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(factoryConfig.last?["api_key"] as? String, "gateway-token")
    }

    func test_routedClientSync_writesOpenCodeProviderConfig() throws {
        let home = try makeTemporaryHome()
        let configDirectory = home.appendingPathComponent(".config/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let configURL = configDirectory.appendingPathComponent("opencode.json")
        try Data("""
        {
          // Existing OpenCode settings should survive JSONC parsing.
          "theme": "opencode",
          "provider": {
            "other": {"name": "Other"}
          }
        }
        """.utf8).write(to: configURL)

        let service = RoutedClientConfigSyncService(homeDirectory: home)
        try service.applyOpenCodeGatewayConfig(
            RoutedClientGatewayConfig(
                baseURL: "http://127.0.0.1:8317/v1",
                bearerToken: "",
                models: ["glm-5"]
            )
        )

        let root = try readJSON(configURL)
        XCTAssertEqual(root["theme"] as? String, "opencode")
        XCTAssertEqual(root["model"] as? String, "openburnbar/glm-5")
        let providers = try XCTUnwrap(root["provider"] as? [String: Any])
        XCTAssertNotNil(providers["other"])
        let burnbar = try XCTUnwrap(providers["openburnbar"] as? [String: Any])
        XCTAssertEqual(burnbar["npm"] as? String, "@ai-sdk/openai-compatible")
        let options = try XCTUnwrap(burnbar["options"] as? [String: Any])
        XCTAssertEqual(options["baseURL"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(options["apiKey"] as? String, "openburnbar-local")
        let models = try XCTUnwrap(burnbar["models"] as? [String: Any])
        XCTAssertNotNil(models["glm-5"])
    }

    private func makeTemporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-routed-client-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
