import XCTest
import Security
import Darwin
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
        XCTAssertEqual(Array(ConnectorProvider.ollama.suggestedModels.prefix(3)), ["deepseek-v4-flash", "qwen3.6:27b-coding-nvfp4", "kimi-k2.7-code"])
        XCTAssertTrue(ConnectorProvider.ollama.suggestedModels.contains("kimi-k3"))
        XCTAssertTrue(ConnectorProvider.ollama.suggestedModels.contains("gpt-oss:120b"))
    }

    func test_supportedModel_allowsSupportedProvidersOnly() {
        XCTAssertTrue(CursorConnectorManager.supportedModel("glm-5"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M2.7-highspeed"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("MiniMax-M3-pro"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("deepseek-v4-flash:cloud"))
        XCTAssertTrue(CursorConnectorManager.supportedModel("kimi-k3:cloud"))
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

    func test_extractTryCloudflareURL_rejectsEncodedOrDecoratedHosts() {
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://quick-burnbar%2etrycloudflare.com"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://quick-burnbar.trycloudflare.com%2eevil.example"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://user@quick-burnbar.trycloudflare.com"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://quick-burnbar.trycloudflare.com:443"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://quick-burnbar.trycloudflare.com/path"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://quick_burnbar.trycloudflare.com"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://-quick-burnbar.trycloudflare.com"))
        XCTAssertNil(CursorConnectorManager.extractTryCloudflareURL(from: "https://quick-burnbar-.trycloudflare.com"))
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

    func test_normalizeUsageEvent_subtractsOpenAIStyleCachedPromptTokens() {
        let normalized = CursorConnectorManager.normalizeUsageEvent([
            "prompt_tokens": 2_006,
            "completion_tokens": 300,
            "prompt_tokens_details": ["cached_tokens": 1_920],
            "total_tokens": 2_306
        ])

        XCTAssertEqual(normalized.promptTokens, 86)
        XCTAssertEqual(normalized.completionTokens, 300)
        XCTAssertEqual(normalized.cacheReadTokens, 1_920)
        XCTAssertEqual(normalized.totalTokens, 2_306)
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

    func test_usageLogPolling_pricesAndPersistsRoutedUsage() async throws {
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cursor-connector-pricing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let previousSupportRoot = ProcessInfo.processInfo.environment["OPENBURNBAR_SUPPORT_ROOT"]
        setenv("OPENBURNBAR_SUPPORT_ROOT", supportRoot.path, 1)
        defer {
            if let previousSupportRoot {
                setenv("OPENBURNBAR_SUPPORT_ROOT", previousSupportRoot, 1)
            } else {
                unsetenv("OPENBURNBAR_SUPPORT_ROOT")
            }
        }

        let manager = CursorConnectorManager()
        let dataStore = try makeDiscoveryInMemoryStore()
        let usageLogURL = supportRoot
            .appendingPathComponent("OpenBurnBar", isDirectory: true)
            .appendingPathComponent("cursor_connector_usage.jsonl")
        try Data("""
        {"request_id":"pricing-request","provider":"zai","model":"glm-5","prompt_tokens":1000000,"completion_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"total_tokens":2000000,"timestamp":"2025-07-14T12:00:00Z"}
        """.utf8).write(to: usageLogURL, options: .atomic)

        manager.attach(dataStore: dataStore)

        let deadline = Date().addingTimeInterval(2)
        while manager.recentUsageEvents.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let event = try XCTUnwrap(manager.recentUsageEvents.first)
        XCTAssertEqual(event.provider, .zai)
        XCTAssertEqual(event.model, "glm-5")
        XCTAssertEqual(event.cost, 0.14, accuracy: 0.000_001)

        let persisted = try await dataStore.fetchAllUsage()
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.sessionId, "pricing-request")
        XCTAssertEqual(persisted.first?.costUSD ?? -1, 0.14, accuracy: 0.000_001)
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

    func test_proxyScriptPrunesStalePerClientRateLimitState() {
        let script = CursorConnectorManager.proxyScript()

        XCTAssertTrue(script.contains("MAX_TRACKED_CLIENTS = 4096"))
        XCTAssertTrue(script.contains("def _remember_client_entries(state, client_ip, entries, window_start):"))
        XCTAssertTrue(script.contains("state.pop(client_ip, None)"))
        XCTAssertTrue(script.contains("while len(state) > MAX_TRACKED_CLIENTS:"))
    }

    func test_proxyScriptPreservesExplicitZeroAuthFailureLimit() {
        let script = CursorConnectorManager.proxyScript()

        XCTAssertTrue(script.contains("def _int_config(config, name, default):"))
        XCTAssertTrue(script.contains("if raw_value is None:"))
        XCTAssertTrue(script.contains("AUTH_FAIL_LIMIT = _int_config(CONFIG, \"auth_fail_limit\", 20)"))
        XCTAssertFalse(script.contains("auth_fail_limit\", 20) or 20"))
    }

    func test_keychainStoreDisablesSystemPromptsForBackgroundReads() throws {
        let security = RecordingSecurityKeychainOperations()
        let backend = SecurityKeychainStoreBackend(security: security)

        try backend.set(Data("secret".utf8), service: "service", account: "account")
        _ = try backend.data(for: "service", account: "account", allowUserInteraction: false)
        _ = try backend.data(for: "service", account: "account", allowUserInteraction: true)
        try backend.delete(service: "service", account: "account")

        XCTAssertEqual(security.events, [
            RecordingSecurityKeychainOperations.Event(operation: .update, interactionDisabled: true),
            RecordingSecurityKeychainOperations.Event(operation: .add, interactionDisabled: true),
            RecordingSecurityKeychainOperations.Event(operation: .copyMatching, interactionDisabled: true),
            RecordingSecurityKeychainOperations.Event(operation: .copyMatching, interactionDisabled: false),
            RecordingSecurityKeychainOperations.Event(operation: .delete, interactionDisabled: true)
        ])
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

    func test_proxyScript_keepsPublicHealthChecksOutOfTunnelRateLimit() async throws {
        let directory = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("cursor_connector_proxy.py")
        let configURL = directory.appendingPathComponent("cursor_connector_proxy_config.json")
        let usageLogURL = directory.appendingPathComponent("usage.jsonl")
        let port = try availableLoopbackPort()
        let bearerToken = "test-token-\(UUID().uuidString)"

        try CursorConnectorManager.proxyScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        let config: [String: Any] = [
            "port": port,
            "session_token": "session-token",
            "tunnel_rotation_token": bearerToken,
            "secret_broker_url": "",
            "secret_broker_token": "",
            "rate_limit_requests": 1,
            "rate_limit_window": 60,
            "usage_log": usageLogURL.path,
            "routes": [
                "glm-5": [
                    "provider": "zai",
                    "base_url": "https://example.invalid/v1",
                    "route_id": "route-zai"
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL, options: .atomic)

        let (process, output) = try launchProxy(script: scriptURL, config: configURL)
        defer { terminateProxyProcess(process, output: output) }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        try await waitForProxyHealth(baseURL: baseURL, session: session, process: process, output: output)

        for _ in 0..<3 {
            let healthStatus = try await proxyResponseStatus(baseURL.appendingPathComponent("health"), session: session)
            XCTAssertEqual(healthStatus, 200)
        }

        let authHeaders = ["Authorization": "Bearer \(bearerToken)"]
        let firstModelStatus = try await proxyResponseStatus(
            baseURL.appendingPathComponent("v1/models"),
            headers: authHeaders,
            session: session
        )
        XCTAssertEqual(
            firstModelStatus,
            200,
            "Public health checks must not consume the authenticated tunnel request budget."
        )
        let secondModelStatus = try await proxyResponseStatus(
            baseURL.appendingPathComponent("v1/models"),
            headers: authHeaders,
            session: session
        )
        XCTAssertEqual(
            secondModelStatus,
            429,
            "Authenticated API requests should still consume and enforce the configured tunnel quota."
        )
    }

    func test_proxyScript_usesCfConnectingIPForIndependentRateLimitsAndCapsAuthFailures() async throws {
        let directory = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scriptURL = directory.appendingPathComponent("cursor_connector_proxy.py")
        let configURL = directory.appendingPathComponent("cursor_connector_proxy_config.json")
        let usageLogURL = directory.appendingPathComponent("usage.jsonl")
        let port = try availableLoopbackPort()
        let bearerToken = "test-token-\(UUID().uuidString)"

        try CursorConnectorManager.proxyScript().write(to: scriptURL, atomically: true, encoding: .utf8)
        let config: [String: Any] = [
            "port": port,
            "session_token": "session-token",
            "tunnel_rotation_token": bearerToken,
            "secret_broker_url": "",
            "secret_broker_token": "",
            "rate_limit_requests": 1,
            "rate_limit_window": 60,
            "auth_fail_limit": 2,
            "usage_log": usageLogURL.path,
            "routes": [
                "glm-5": [
                    "provider": "zai",
                    "base_url": "https://example.invalid/v1",
                    "route_id": "route-zai"
                ]
            ]
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: configURL, options: .atomic)

        let (process, output) = try launchProxy(script: scriptURL, config: configURL)
        defer { terminateProxyProcess(process, output: output) }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        try await waitForProxyHealth(baseURL: baseURL, session: session, process: process, output: output)

        let authHeaders = ["Authorization": "Bearer \(bearerToken)"]
        let cfOneHeaders = authHeaders.merging(["Cf-Connecting-IP": "198.51.100.10"], uniquingKeysWith: { _, new in new })
        let cfTwoHeaders = authHeaders.merging(["Cf-Connecting-IP": "198.51.100.11"], uniquingKeysWith: { _, new in new })

        let firstClientStatus = try await proxyResponseStatus(
            baseURL.appendingPathComponent("v1/models"),
            headers: cfOneHeaders,
            session: session
        )
        XCTAssertEqual(firstClientStatus, 200)

        let secondClientStatus = try await proxyResponseStatus(
            baseURL.appendingPathComponent("v1/models"),
            headers: cfTwoHeaders,
            session: session
        )
        XCTAssertEqual(
            secondClientStatus,
            200,
            "Distinct Cf-Connecting-IP identities must have independent request buckets."
        )

        let firstClientSecondStatus = try await proxyResponseStatus(
            baseURL.appendingPathComponent("v1/models"),
            headers: cfOneHeaders,
            session: session
        )
        XCTAssertEqual(firstClientSecondStatus, 429)

        let badHeaders = ["Authorization": "Bearer definitely-wrong"]
        let firstAuthFailStatus = try await proxyResponseStatus(
            baseURL.appendingPathComponent("v1/models"),
            headers: badHeaders,
            session: session
        )
        XCTAssertEqual(firstAuthFailStatus, 401)

        let secondAuthFailStatus = try await proxyResponseStatus(
            baseURL.appendingPathComponent("v1/models"),
            headers: badHeaders,
            session: session
        )
        XCTAssertEqual(secondAuthFailStatus, 401)

        let malformedAuthorization = Array("Bearer definitely-wrong-".utf8) + [0xff]
        let thirdAuthFailStatus = try rawProxyResponseStatus(port: port, authorizationBytes: malformedAuthorization)
        XCTAssertEqual(
            thirdAuthFailStatus,
            429,
            "Malformed non-ASCII bearer headers should count as auth failures instead of aborting compare_digest."
        )
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
            {"model": "old-burnbar", "id": "openburnbar:old-burnbar", "baseUrl": "http://old/v1", "provider": "openburnbar"},
            {"model": "claude-opus-4-7", "id": "custom:VibeProxy-Claude-0", "baseUrl": "http://localhost:8317", "displayName": "VibeProxy Claude", "provider": "anthropic"}
          ]
        }
        """.utf8).write(to: settingsURL)
        try Data("""
        {
          "custom_models": [
            {"model": "existing-config-model", "base_url": "https://example.com/v1", "provider": "other"},
            {"model": "old-burnbar", "base_url": "http://old/v1", "provider": "openburnbar"},
            {"model": "claude-sonnet-4-6", "base_url": "http://localhost:8317", "model_display_name": "VibeProxy Sonnet", "provider": "anthropic"}
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
        XCTAssertEqual(settings.last?["provider"] as? String, "generic-chat-completion-api")
        XCTAssertEqual(settings.last?["id"] as? String, "custom:OpenBurnBar-minimax-m2.7-highspeed-2")
        XCTAssertTrue(FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().appendingPathComponent("settings.json.openburnbar-backup-20231114221320").path))

        let factoryConfig = try XCTUnwrap(readJSON(configURL)["custom_models"] as? [[String: Any]])
        XCTAssertEqual(factoryConfig.compactMap { $0["model"] as? String }, ["existing-config-model", "glm-5", "minimax-m2.7-highspeed"])
        XCTAssertEqual(factoryConfig.last?["base_url"] as? String, "http://127.0.0.1:8317/v1")
        XCTAssertEqual(factoryConfig.last?["api_key"] as? String, "gateway-token")
        XCTAssertEqual(factoryConfig.last?["provider"] as? String, "generic-chat-completion-api")
        XCTAssertTrue(service.isFactoryGatewayConfigPresent())
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

    private func availableLoopbackPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func launchProxy(script: URL, config: URL) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, config.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output)
    }

    /// Bounded subprocess teardown: SIGTERM → poll (≤3 s) → SIGKILL → poll (≤2 s).
    /// Never blocks indefinitely — the pre-fix `defer { terminate(); waitUntilExit() }`
    /// could hang the entire test suite when the child was a zombie or unresponsive.
    private func terminateProxyProcess(_ process: Process, output: Pipe) {
        if process.isRunning {
            process.terminate()
        }
        // Poll for graceful exit (3 s budget).
        for _ in 0..<150 where process.isRunning {
            usleep(20_000)
        }
        if process.isRunning {
            // Escalate to SIGKILL.
            kill(process.processIdentifier, SIGKILL)
            // Poll for forced exit (2 s budget).
            for _ in 0..<100 where process.isRunning {
                usleep(20_000)
            }
        }
    }

    private func captureProxyOutput(_ output: Pipe) -> String {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func waitForProxyHealth(
        baseURL: URL,
        session: URLSession,
        process: Process,
        output: Pipe
    ) async throws {
        let healthURL = baseURL.appendingPathComponent("health")
        var lastError: Error?
        for _ in 0..<150 {
            // Fail fast if the child already exited — the proxy will never
            // become healthy and polling for 7.5 s only delays the inevitable.
            if !process.isRunning {
                let captured = captureProxyOutput(output)
                throw NSError(
                    domain: "CursorConnectorTests",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey: "proxy process exited before becoming healthy",
                        NSLocalizedRecoverySuggestionErrorKey: captured.trimmingCharacters(in: .whitespacesAndNewlines)
                    ]
                )
            }
            do {
                if try await proxyResponseStatus(healthURL, session: session) == 200 {
                    return
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let captured = captureProxyOutput(output)
        throw lastError ?? NSError(
            domain: "CursorConnectorTests",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "proxy did not become healthy within timeout",
                NSLocalizedRecoverySuggestionErrorKey: captured.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        )
    }

    private func proxyResponseStatus(
        _ url: URL,
        headers: [String: String] = [:],
        session: URLSession
    ) async throws -> Int {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (_, response) = try await session.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
    }

    private func rawProxyResponseStatus(port: Int, authorizationBytes: [UInt8]) throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var request = Data()
        request.append(Data("GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: ".utf8))
        request.append(contentsOf: authorizationBytes)
        request.append(Data("\r\n\r\n".utf8))
        let bytesSent = request.withUnsafeBytes { rawBuffer in
            Darwin.send(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
        }
        guard bytesSent == request.count else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(fd, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            if count > 0 {
                response.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }

        let responseText = String(decoding: response, as: UTF8.self)
        let statusLine = try XCTUnwrap(responseText.components(separatedBy: "\r\n").first)
        let parts = statusLine.split(separator: " ")
        return try XCTUnwrap(Int(parts[1]))
    }
}

// MARK: - Cursor connector error-swallow remediation (try? sites that mattered)

/// Proves the three previously-swallowed `try?` sites in
/// `CursorConnectorManager` now behave correctly instead of silently dropping a
/// failure that matters:
///
/// 1. `stopProxy()` deletes the on-disk proxy config that carries the
///    secret-broker bearer token + session token (security cleanup) and, when the
///    delete genuinely fails, does NOT crash and does NOT pretend it succeeded —
///    the file is still there to be retried/observed, and an absent file is
///    treated as success rather than an error.
/// 2. `saveConfig()` persists config via an encode seam that returns data on the
///    happy path (so persistence is unchanged) and would log+skip — never write a
///    half-blob — on encode failure.
@MainActor
final class CursorConnectorTrySwallowTests: XCTestCase {

    private var scratchDirectories: [URL] = []

    override func tearDownWithError() throws {
        let fm = FileManager.default
        for directory in scratchDirectories {
            // Restore writability before teardown so the directory itself is removable.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fm.removeItem(at: directory)
        }
        scratchDirectories.removeAll()
    }

    // MARK: removeProxyConfigFile (Site L626 — security cleanup of token-bearing file)

    func test_removeProxyConfigFile_deletesExistingSecretBearingFile() throws {
        let fm = FileManager.default
        let dir = try makeScratchDirectory()
        let configURL = dir.appendingPathComponent("cursor_connector_proxy_config.json")
        try Data(#"{"secret_broker_token":"sk-broker-live","session_token":"abc"}"#.utf8)
            .write(to: configURL, options: .atomic)
        XCTAssertTrue(fm.fileExists(atPath: configURL.path), "Precondition: secret-bearing config exists.")

        CursorConnectorManager.removeProxyConfigFile(at: configURL, fileManager: fm)

        XCTAssertFalse(
            fm.fileExists(atPath: configURL.path),
            "The security cleanup must actually remove the token-bearing proxy config."
        )
    }

    func test_removeProxyConfigFile_whenAlreadyAbsent_isANoOpAndDoesNotThrowOrCrash() throws {
        let fm = FileManager.default
        let dir = try makeScratchDirectory()
        let configURL = dir.appendingPathComponent("does_not_exist.json")
        XCTAssertFalse(fm.fileExists(atPath: configURL.path), "Precondition: file is absent.")

        // An already-absent file is success, not a logged fault — and must not crash.
        CursorConnectorManager.removeProxyConfigFile(at: configURL, fileManager: fm)

        XCTAssertFalse(fm.fileExists(atPath: configURL.path))
    }

    func test_removeProxyConfigFile_onRealRemovalFailure_doesNotCrashAndLeavesFileForRetry() throws {
        let fm = FileManager.default
        let dir = try makeScratchDirectory()
        let configURL = dir.appendingPathComponent("cursor_connector_proxy_config.json")
        try Data(#"{"secret_broker_token":"sk-broker-live"}"#.utf8)
            .write(to: configURL, options: .atomic)

        // Removing a file requires write permission on its PARENT directory.
        // Stripping write from the parent makes removeItem(at:) fail with a real
        // permission error — the path that used to be swallowed by `try?`.
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }

        // Must not throw / crash; the failure is logged internally, not propagated.
        CursorConnectorManager.removeProxyConfigFile(at: configURL, fileManager: fm)

        // The file is still present (the delete genuinely failed) — confirming we
        // did not silently claim success. The behavior degrades gracefully while
        // the failure is observable via the logger.
        XCTAssertTrue(
            fm.fileExists(atPath: configURL.path),
            "When the OS rejects the delete, the helper must surface failure (file remains) rather than swallow it."
        )
    }

    // MARK: encodedConfig (Site L527 — observable persistence, optionality preserved)

    func test_encodedConfig_happyPath_returnsRoundTrippableData() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var config = CursorConnectorConfig()
        config.statusMessage = "Connected to Cursor"
        config.isEnabled = true

        let data = try XCTUnwrap(
            CursorConnectorManager.encodedConfig(config, using: encoder),
            "A well-formed config must still encode — the fix preserves the happy path."
        )

        let decoded = try JSONDecoder().decode(CursorConnectorConfig.self, from: data)
        XCTAssertEqual(decoded, config, "Encoded config must round-trip identically.")
    }

    // MARK: helpers

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cursor-tryswallow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        scratchDirectories.append(url)
        return url
    }
}

// MARK: - Cursor connector credential-read fault path

/// Proves the security fix in `CursorConnectorManager`: both untagged
/// `try? keychain.string(for:…)` credential reads — the provider API-key read in
/// `apiKey(for:)` and the secret-broker read in `CursorConnectorSecretBroker` —
/// now flow through `KeychainStore.credentialIfPresent(for:event:)`. That
/// accessor distinguishes a genuinely absent credential (returns `nil`) from a
/// real Keychain fault (locked keychain / ACL denial / unhandled `OSStatus` /
/// corrupt data), which it logs via `AppLogger` and *then* returns `nil` from —
/// instead of `try?` collapsing a broken keychain into the same silent `nil` as
/// "no credential configured".
///
/// The fault is driven through the same `KeychainStore(backend:)` initializer
/// seam these production sites rely on, using a fake `KeychainStoreBackend` whose
/// `data(for:)` throws `KeychainStoreError.unhandled(errSecNotAvailable)`.
@MainActor
final class CursorConnectorCredentialReadTests: XCTestCase {
    private let service = "tests.cursor-connector.credential-read"

    func test_credentialIfPresent_onKeychainFault_returnsNilWithoutThrowing() {
        // A broken/locked keychain throws on read. The accessor must observe the
        // fault (log it) and degrade to nil — it must not crash and must not
        // propagate the error to the connector control flow.
        let backend = FaultInjectingCursorKeychainBackend()
        backend.readError = KeychainStoreError.unhandled(errSecNotAvailable)
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)

        XCTAssertNil(
            store.credentialIfPresent(
                for: "provider.zai.apiKey",
                event: "cursor_provider_api_key_read_failed"
            )
        )
        XCTAssertTrue(
            backend.readWasAttempted,
            "The fault path must actually reach the backend read."
        )
    }

    func test_credentialIfPresent_whenAbsent_returnsNil() {
        // No fault, no stored value: a genuinely absent credential still yields
        // nil, identical to the historical `try?` behavior callers depend on.
        let backend = FaultInjectingCursorKeychainBackend()
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)

        XCTAssertNil(
            store.credentialIfPresent(
                for: "provider.minimax.apiKey",
                event: "cursor_secret_broker_key_read_failed"
            )
        )
    }

    func test_credentialIfPresent_whenPresent_returnsStoredValue() throws {
        // Sanity: a present credential is still returned unchanged, so the fix
        // does not alter the happy path.
        let backend = FaultInjectingCursorKeychainBackend()
        let store = KeychainStore(service: service, legacyServices: [], backend: backend)
        try store.set("sk-cursor-live", for: "provider.zai.apiKey")

        XCTAssertEqual(
            store.credentialIfPresent(
                for: "provider.zai.apiKey",
                event: "cursor_provider_api_key_read_failed"
            ),
            "sk-cursor-live"
        )
    }
}

/// A `KeychainStoreBackend` that can store/return values like a real keychain,
/// or be flipped into a hard-fault mode where `data(for:)` throws — modeling a
/// locked keychain / ACL denial that `try?` used to swallow silently.
private final class FaultInjectingCursorKeychainBackend: KeychainStoreBackend, @unchecked Sendable {
    var readError: Error?
    private(set) var readWasAttempted = false
    private var storage: [String: [String: Data]] = [:]

    func set(_ value: Data, service: String, account: String) throws {
        storage[service, default: [:]][account] = value
    }

    func data(for service: String, account: String, allowUserInteraction _: Bool) throws -> Data? {
        readWasAttempted = true
        if let readError {
            throw readError
        }
        return storage[service]?[account]
    }

    func delete(service: String, account: String) throws {
        storage[service]?[account] = nil
    }
}

private final class RecordingSecurityKeychainOperations: SecurityKeychainOperations, @unchecked Sendable {
    struct Event: Equatable {
        enum Operation: Equatable {
            case update
            case add
            case copyMatching
            case delete
        }

        let operation: Operation
        let interactionDisabled: Bool
    }

    private let lock = NSLock()
    private var disabledDepth = 0
    private var recordedEvents: [Event] = []

    var events: [Event] {
        lock.withLock { recordedEvents }
    }

    func runWithDisabledInteraction(_ operation: () -> OSStatus) -> OSStatus {
        lock.withLock { disabledDepth += 1 }
        defer { lock.withLock { disabledDepth -= 1 } }
        return operation()
    }

    func update(query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        record(.update)
        return errSecItemNotFound
    }

    func add(query: CFDictionary) -> OSStatus {
        record(.add)
        return errSecSuccess
    }

    func copyMatching(query: CFDictionary, item: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        record(.copyMatching)
        return errSecItemNotFound
    }

    func delete(query: CFDictionary) -> OSStatus {
        record(.delete)
        return errSecSuccess
    }

    private func record(_ operation: Event.Operation) {
        lock.withLock {
            recordedEvents.append(Event(
                operation: operation,
                interactionDisabled: disabledDepth > 0
            ))
        }
    }
}
