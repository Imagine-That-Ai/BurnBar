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
    }

    func test_supportedModel_allowsSupportedProvidersOnly() {
        XCTAssertTrue(CursorConnectorManager.supportedModel("glm-5"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M2.7-highspeed"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M3-pro"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("kimi-for-coding"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("pony-alpha-2"))
        XCTAssertFalse(CursorConnectorManager.supportedModel("claude-3-7-sonnet"))
        XCTAssertFalse(CursorConnectorManager.supportedModel(""))
    }

    func test_supportedModel_respectsProviderCatalogMatchers() {
        XCTAssertTrue(CursorConnectorManager.supportedModel("glm-5-plus", provider: .zai))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M3-pro", provider: .minimax))
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

    func test_proxyScript_resolvesProviderKeysFromKeychainMetadata() {
        let script = CursorConnectorManager.proxyScript()

        XCTAssertTrue(script.contains("keychain_service"))
        XCTAssertTrue(script.contains("keychain_account"))
        XCTAssertTrue(script.contains("find-generic-password"))
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
}
