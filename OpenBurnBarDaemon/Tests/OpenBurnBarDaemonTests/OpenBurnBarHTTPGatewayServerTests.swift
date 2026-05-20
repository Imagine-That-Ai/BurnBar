import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Darwin
import Foundation
import XCTest

final class BurnBarHTTPGatewayServerTests: XCTestCase {
    override func tearDown() {
        GatewayUpstreamURLProtocol.reset()
        super.tearDown()
    }

    private func enqueueOpenAIModelCatalog(_ modelIDs: [String], times: Int = 1) {
        let rows = modelIDs.map { id in
            #"{"id":"\#(id)","display_name":"\#(id)"}"#
        }.joined(separator: ",")
        for _ in 0..<times {
            GatewayUpstreamURLProtocol.enqueue(
                status: 200,
                body: #"{"object":"list","data":[\#(rows)]}"#
            )
        }
    }

    private func enqueueOllamaCloudCatalog(_ modelIDs: [String], times: Int = 1) {
        let rows = modelIDs.map { id in
            #"<li x-test-model><a href="/library/\#(id)" class="group w-full"><span>\#(id)</span><span>cloud</span></a></li>"#
        }.joined(separator: "\n")
        for _ in 0..<times {
            GatewayUpstreamURLProtocol.enqueue(
                status: 200,
                body: #"<html><body><ol>\#(rows)</ol></body></html>"#
            )
        }
    }

    func testGatewayConfigurationValidationRejectsUnsafeHosts() {
        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "0.0.0.0", port: 8317, authToken: nil).validationError,
            "Gateway wildcard bind addresses are not allowed. Use a specific interface address."
        )

        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "bad host", port: 8317, authToken: nil).validationError,
            "Gateway host 'bad host' is not a valid hostname or IP address."
        )

        XCTAssertEqual(
            BurnBarGatewayConfiguration(isEnabled: true, host: "192.168.0.10", port: 8317, authToken: nil).validationError,
            "A non-loopback gateway bind address requires an auth token for security."
        )
    }

    func testGatewayReturns400ForInvalidCompletionPayload() async throws {
        let harness = try GatewayHarness()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data("{\"model\":}".utf8)
        )

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("invalid JSON request body"))
    }

    func testGatewayReturns413ForOversizedBody() async throws {
        let harness = try GatewayHarness()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let oversizedRequest = "POST /v1/chat/completions HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: 67108865\r\n"
            + "\r\n"
        let (status, _, _) = try sendRawGatewayRequest(
            port: harness.port,
            request: oversizedRequest
        )
        XCTAssertEqual(status, 413)
    }

    func testGatewayCORSAllowsLoopbackOriginsOnly() async throws {
        let harness = try GatewayHarness()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (allowedResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Origin": "http://localhost:3000"]
        )
        XCTAssertEqual(allowedResponse.statusCode, 200)
        XCTAssertEqual(allowedResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "http://localhost:3000")

        let (blockedResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Origin": "https://evil.example.com"]
        )
        XCTAssertEqual(blockedResponse.statusCode, 200)
        XCTAssertNil(blockedResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))

        let (preflightResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "OPTIONS",
            path: "/v1/chat/completions",
            headers: [
                "Origin": "http://127.0.0.1:5173",
                "Access-Control-Request-Method": "POST"
            ]
        )
        XCTAssertEqual(preflightResponse.statusCode, 204)
        XCTAssertEqual(preflightResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "http://127.0.0.1:5173")
    }

    func testGatewayAuthRequiresBearerTokenWhenConfigured() async throws {
        let harness = try GatewayHarness(authToken: "gateway-secret")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (missingAuthResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health"
        )
        XCTAssertEqual(missingAuthResponse.statusCode, 401)

        let (invalidAuthResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Authorization": "Bearer wrong"]
        )
        XCTAssertEqual(invalidAuthResponse.statusCode, 401)

        let (authorizedResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Authorization": "Bearer gateway-secret"]
        )
        XCTAssertEqual(authorizedResponse.statusCode, 200)
    }

    func testGatewayRateLimitingReturns429() async throws {
        let harness = try GatewayHarness(
            authToken: "gateway-secret",
            rateLimit: BurnBarRateLimitConfiguration(requestsPerSecond: 1, burstCapacity: 1)
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        // First request should be allowed
        let (allowedResponse, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Authorization": "Bearer gateway-secret"]
        )
        XCTAssertEqual(allowedResponse.statusCode, 200)

        // Second immediate request should be rate limited
        let (throttledResponse, throttledBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/health",
            headers: ["Authorization": "Bearer gateway-secret"]
        )
        XCTAssertEqual(throttledResponse.statusCode, 429)
        XCTAssertTrue(String(decoding: throttledBody, as: UTF8.self).contains("rate limit exceeded"))
        XCTAssertNotNil(throttledResponse.value(forHTTPHeaderField: "Retry-After"))
    }

    func testGatewayModelsAdvertisesLiveRouteCatalogWithAccountQuotaState() async throws {
        let harness = try GatewayHarness()
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.updateCredentialSlotQuota(
            providerID: "zai",
            slotID: "primary",
            remainingPercent: 42,
            resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
            message: "Primary has quota"
        )
        try await harness.configStore.updateCredentialSlotStatus(
            providerID: "zai",
            slotID: "backup",
            status: .exhausted,
            cooldownUntil: nil,
            message: "Backup exhausted"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        let primary = try XCTUnwrap(data.first {
            ($0["account_id"] as? String) == "primary" && ($0["id"] as? String) == "glm-5-turbo"
        })
        XCTAssertEqual(primary["id"] as? String, "glm-5-turbo")
        XCTAssertEqual(primary["owned_by"] as? String, "zai")
        XCTAssertEqual(primary["provider_id"] as? String, "zai")
        XCTAssertEqual(primary["account_label"] as? String, "Primary")
        XCTAssertEqual(primary["account_count"] as? Int, 1)
        XCTAssertEqual(primary["quota_state"] as? String, "healthy")
        XCTAssertEqual(primary["route_eligible"] as? Bool, true)
        XCTAssertTrue((primary["capabilities"] as? [String] ?? []).contains("openai_compat"))

        let codexModels = try XCTUnwrap(object["models"] as? [[String: Any]])
        let codexPrimary = try XCTUnwrap(codexModels.first {
            ($0["slug"] as? String) == "glm-5-turbo"
        })
        XCTAssertEqual(codexPrimary["display_name"] as? String, "GLM-5 Turbo")
        XCTAssertEqual(codexPrimary["description"] as? String, "Z.ai via OpenBurnBar")
        XCTAssertEqual(codexPrimary["shell_type"] as? String, "shell_command")
        XCTAssertEqual(codexPrimary["visibility"] as? String, "list")
        XCTAssertEqual(codexPrimary["supported_in_api"] as? Bool, true)
        XCTAssertEqual(codexPrimary["base_instructions"] as? String, "You are Codex, a coding agent.")
        let truncationPolicy = try XCTUnwrap(codexPrimary["truncation_policy"] as? [String: Any])
        XCTAssertEqual(truncationPolicy["mode"] as? String, "tokens")
        XCTAssertEqual(truncationPolicy["limit"] as? Int, 65_536)

        XCTAssertFalse(
            data.contains { ($0["account_id"] as? String) == "backup" },
            "/v1/models must not advertise exhausted or otherwise unroutable accounts to external clients."
        )
    }

    func testGatewayModelsCollapsesDuplicateAccountsIntoOneProviderModelRow() async throws {
        let harness = try GatewayHarness()
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        let rows = data.filter {
            ($0["provider_id"] as? String) == "zai"
                && (($0["id"] as? String)?.contains("glm-5-turbo") == true)
        }
        XCTAssertEqual(rows.count, 1, "/v1/models should export one logical model per provider, not one row per credential slot.")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["id"] as? String, "glm-5-turbo")
        XCTAssertEqual(row["account_id"] as? String, "auto")
        XCTAssertEqual(row["account_label"] as? String, "Auto failover (2 accounts)")
        XCTAssertEqual(row["account_count"] as? Int, 2)
        XCTAssertEqual(row["advertised"] as? Bool, true)
        XCTAssertFalse(data.contains { ($0["id"] as? String) == "zai/primary/glm-5-turbo" })
        XCTAssertFalse(data.contains { ($0["id"] as? String) == "zai/backup/glm-5-turbo" })

        let codexModels = try XCTUnwrap(object["models"] as? [[String: Any]])
        let codexRow = try XCTUnwrap(codexModels.first { ($0["slug"] as? String) == "glm-5-turbo" })
        XCTAssertEqual(codexRow["description"] as? String, "Z.ai via OpenBurnBar auto failover across 2 accounts")
    }

    func testGatewayModelsAdvertisesFactoryDroidHonestly() async throws {
        let harness = try GatewayHarness()
        try await harness.configureFactoryProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        let factory = try XCTUnwrap(data.first {
            ($0["provider_id"] as? String) == "factory" && ($0["id"] as? String) == "gpt-5.5"
        })
        XCTAssertEqual(factory["provider_name"] as? String, "Factory Droid")
        XCTAssertEqual(factory["display_name"] as? String, "GPT-5.5 via Factory")
        XCTAssertEqual(factory["source_kind"] as? String, "factory_droid_cli")
        XCTAssertEqual(factory["served_by"] as? String, "Factory Droid CLI")
        XCTAssertEqual(factory["usage_lane"] as? String, "standard")
        XCTAssertEqual(factory["native_streaming"] as? Bool, false)
        XCTAssertEqual(factory["route_eligible"] as? Bool, true)
        XCTAssertTrue((factory["capabilities"] as? [String] ?? []).contains("openai_compat"))

        let droidCore = try XCTUnwrap(data.first {
            ($0["provider_id"] as? String) == "factory" && ($0["id"] as? String) == "glm-5.1"
        })
        XCTAssertEqual(droidCore["source_kind"] as? String, "factory_droid_cli")
        XCTAssertEqual(droidCore["usage_lane"] as? String, "droid_core")
        XCTAssertEqual(droidCore["native_streaming"] as? Bool, false)
    }

    func testGatewayRoutesFactoryChatThroughDroidExecutor() async throws {
        let runner = RecordingFactoryDroidRunner(
            result: FactoryDroidProcessResult(exitCode: 0, stdout: #"{"result":"factory gateway ok"}"#, stderr: "")
        )
        let harness = try GatewayHarness(
            factoryExecutor: FactoryDroidProviderExecutor(runner: runner, timeout: 1)
        )
        try await harness.configureFactoryProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"gpt-5.5","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("factory gateway ok"))
        XCTAssertEqual(runner.lastEnvironment?["FACTORY_API_KEY"], "fk-gateway")
        XCTAssertTrue(runner.lastArguments?.contains("gpt-5.5") == true)
    }

    func testFactoryStandardExhaustionHidesOnlyStandardModelAndKeepsDroidCoreCustomModels() async throws {
        let runner = RecordingFactoryDroidRunner(
            result: FactoryDroidProcessResult(
                exitCode: 0,
                stdout: #"{"result":"Using Droid Core after Standard Usage is exhausted"}"#,
                stderr: ""
            )
        )
        let harness = try GatewayHarness(
            factoryExecutor: FactoryDroidProviderExecutor(runner: runner, timeout: 1)
        )
        try await harness.configureFactoryProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (failedResponse, failedBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"gpt-5.5","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        XCTAssertEqual(failedResponse.statusCode, 402, String(decoding: failedBody, as: UTF8.self))

        let (modelsResponse, modelsBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(modelsResponse.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBody) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertFalse(data.contains {
            ($0["provider_id"] as? String) == "factory" && ($0["id"] as? String) == "gpt-5.5"
        })
        let droidCore = try XCTUnwrap(data.first {
            ($0["provider_id"] as? String) == "factory" && ($0["id"] as? String) == "glm-5.1"
        })
        XCTAssertEqual(droidCore["usage_lane"] as? String, "droid_core")
        XCTAssertEqual(droidCore["route_eligible"] as? Bool, true)
    }

    func testGatewayRoutesProviderQualifiedAdvertisedModelIDsToExactAccount() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"glm-5-turbo","display_name":"GLM 5 Turbo"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-qualified","object":"chat.completion","model":"glm-5-turbo","choices":[{"index":0,"message":{"role":"assistant","content":"qualified answered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.updateCredentialSlotStatus(
            providerID: "zai",
            slotID: "backup",
            status: .exhausted,
            cooldownUntil: nil,
            message: "Backup exhausted"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"zai/primary/glm-5-turbo","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("qualified answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/chat/completions"])
        XCTAssertEqual(upstreamRequests.last?.authorization, "Bearer primary-key")
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""model":"glm-5-turbo""#) == true)
        XCTAssertFalse(upstreamRequests.last?.body.contains("zai/primary/glm-5-turbo") == true)
    }

    func testGatewayPreservesLiveDynamicModelIDInsteadOfCatalogFamilyDowngrade() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"deepseek-v4-flash","display_name":"DeepSeek V4 Flash"},{"id":"deepseek-v4-pro","display_name":"DeepSeek V4 Pro"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-live-pro","object":"chat.completion","model":"deepseek-v4-pro","choices":[{"index":0,"message":{"role":"assistant","content":"pro answered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["deepseek-v4-flash"],
                preferredCredentialSlotID: "default"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "default",
            label: "Default plan",
            apiKey: "deepseek-route-key"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"deepseek/default/deepseek-v4-pro","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("pro answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/chat/completions"])
        XCTAssertEqual(upstreamRequests.last?.authorization, "Bearer deepseek-route-key")
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""model":"deepseek-v4-pro""#) == true)
        XCTAssertFalse(upstreamRequests.last?.body.contains(#""model":"deepseek-chat""#) == true)
        XCTAssertFalse(upstreamRequests.last?.body.contains(#""model":"deepseek-v4-flash""#) == true)
    }

    func testGatewayModelsPrunesRemovedCredentialSlotsFromLiveCatalog() async throws {
        let harness = try GatewayHarness()
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "zai", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertTrue(data.contains { ($0["account_id"] as? String) == "primary" })
        XCTAssertFalse(data.contains { ($0["account_id"] as? String) == "backup" })
    }

    func testGatewayModelsUsesUpstreamModelsEndpointWhenAvailable() async throws {
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"glm-5-turbo","display_name":"GLM-5 Turbo Live"},{"id":"glm-5-live-new","display_name":"GLM-5 Live New"}]}"#
        )
        let harness = try GatewayHarness()
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "zai", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        let primary = try XCTUnwrap(data.first {
            ($0["account_id"] as? String) == "primary" && ($0["id"] as? String) == "glm-5-turbo"
        })
        XCTAssertEqual(primary["id"] as? String, "glm-5-turbo")
        XCTAssertEqual(primary["display_name"] as? String, "GLM-5 Turbo Live")
        XCTAssertEqual(primary["source_kind"] as? String, "upstream_models_endpoint")
        XCTAssertEqual(primary["route_eligible"] as? Bool, true)
        XCTAssertNil(primary["last_error"])
        let discovered = try XCTUnwrap(data.first { ($0["id"] as? String) == "glm-5-live-new" })
        XCTAssertEqual(discovered["display_name"] as? String, "GLM-5 Live New")
        XCTAssertEqual(discovered["source_kind"] as? String, "upstream_models_endpoint")
        XCTAssertEqual(discovered["route_eligible"] as? Bool, true)
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/v1/models"])
    }

    func testGatewayModelsHidesConfiguredModelWhenLiveEndpointOmitsIt() async throws {
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"glm-5-lite"}]}"#
        )
        let harness = try GatewayHarness()
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "zai", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertFalse(data.contains {
            ($0["account_id"] as? String) == "primary" && ($0["id"] as? String) == "glm-5-turbo"
        }, "External /v1/models must hide configured catalog rows the live upstream did not advertise.")
        let live = try XCTUnwrap(data.first { ($0["id"] as? String) == "glm-5-lite" })
        XCTAssertEqual(live["route_eligible"] as? Bool, true)
        XCTAssertEqual(live["source_kind"] as? String, "upstream_models_endpoint")
    }

    func testGatewayModelsDoesNotAdvertiseProviderWhenLiveEndpointRejectsCredential() async throws {
        GatewayUpstreamURLProtocol.enqueue(
            status: 401,
            body: #"{"error":{"message":"invalid key"}}"#
        )
        let harness = try GatewayHarness()
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "zai", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertFalse(data.contains {
            ($0["account_id"] as? String) == "primary" && ($0["provider_id"] as? String) == "zai"
        }, "External /v1/models must not advertise routes when the provider rejects the saved credential.")
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/v1/models"])
    }

    func testGatewayModelsDoesNotAdvertiseMissingCredentialCatalogRows() async throws {
        let harness = try GatewayHarness()
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "moonshot",
                isEnabled: true,
                baseURL: "https://api.moonshot.ai/v1",
                preferredModelIDs: ["kimi-k2.5"]
            )
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertFalse(
            data.contains { ($0["id"] as? String) == "kimi-k2.5" },
            "/v1/models must not advertise provider catalog rows that have no usable credential."
        )
    }

    func testGatewayModelsUsesOllamaCloudCatalogPageWhenAvailable() async throws {
        enqueueOllamaCloudCatalog([
            "kimi-k2.6",
            "glm-5.1",
            "deepseek-v4-pro",
            "minimax-m2.7",
            "deepseek-v3.2",
            "minimax-m2.1"
        ])
        let harness = try GatewayHarness()
        try await harness.configureOllamaProviderForGateway()
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://deepseek-upstream.test/v1",
                preferredModelIDs: ["deepseek-chat"]
            )
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://minimax-upstream.test/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"]
            )
        )
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        let advertisedIDs = Set(data.compactMap { $0["id"] as? String })
        XCTAssertTrue(advertisedIDs.contains("kimi-k2.6:cloud"))
        XCTAssertTrue(advertisedIDs.contains("glm-5.1:cloud"))
        XCTAssertTrue(advertisedIDs.contains("deepseek-v4-pro:cloud"))
        XCTAssertTrue(advertisedIDs.contains("minimax-m2.7:cloud"))
        XCTAssertTrue(advertisedIDs.contains("deepseek-v3.2:cloud"))
        XCTAssertTrue(advertisedIDs.contains("minimax-m2.1:cloud"))
        XCTAssertFalse(advertisedIDs.contains("kimi-k2.6"))
        XCTAssertFalse(advertisedIDs.contains("glm-5.1"))

        let discovered = try XCTUnwrap(data.first { ($0["id"] as? String) == "kimi-k2.6:cloud" })
        XCTAssertEqual(discovered["provider_id"] as? String, "ollama")
        XCTAssertEqual(discovered["provider_name"] as? String, "Ollama Cloud")
        XCTAssertEqual(discovered["source_kind"] as? String, "ollama_cloud_catalog_page")
        XCTAssertEqual(discovered["route_eligible"] as? Bool, true)
        XCTAssertEqual(discovered["format_family"] as? String, "openai_compat")
        XCTAssertTrue((discovered["served_endpoints"] as? [String] ?? []).contains("/v1/chat/completions"))
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/search"])
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.query), ["c=cloud"])
        XCTAssertNil(GatewayUpstreamURLProtocol.recordedRequests().first?.authorization)
    }

    func testGatewayModelAdvertisementToggleHidesPublicCatalogButKeepsSettingsCatalog() async throws {
        enqueueOllamaCloudCatalog(["kimi-k2.6", "glm-5.1"], times: 3)
        let harness = try GatewayHarness()
        try await harness.configureOllamaProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")

        let snapshot = try await harness.configStore.snapshot()
        var settings = try XCTUnwrap(snapshot.providerSettings(id: "ollama"))
        settings.setModelAdvertisement(modelID: "kimi-k2.6:cloud", isEnabled: false)
        _ = try await harness.configStore.upsertProvider(settings)

        try await harness.start()
        defer { Task { await harness.stop() } }

        let (publicResponse, publicBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(publicResponse.statusCode, 200)
        let publicObject = try XCTUnwrap(JSONSerialization.jsonObject(with: publicBody) as? [String: Any])
        let publicData = try XCTUnwrap(publicObject["data"] as? [[String: Any]])
        let publicIDs = Set(publicData.compactMap { $0["id"] as? String })
        XCTAssertFalse(publicIDs.contains("kimi-k2.6:cloud"))
        XCTAssertTrue(publicIDs.contains("glm-5.1:cloud"))

        let (catalogResponse, catalogBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models/catalog"
        )
        XCTAssertEqual(catalogResponse.statusCode, 200)
        let catalogObject = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogBody) as? [String: Any])
        let catalogData = try XCTUnwrap(catalogObject["data"] as? [[String: Any]])
        let hidden = try XCTUnwrap(catalogData.first { ($0["id"] as? String) == "kimi-k2.6:cloud" })
        XCTAssertEqual(hidden["advertisement_enabled"] as? Bool, false)
        XCTAssertEqual(hidden["advertised"] as? Bool, false)
        XCTAssertEqual(hidden["route_eligible"] as? Bool, true)
        let visible = try XCTUnwrap(catalogData.first { ($0["id"] as? String) == "glm-5.1:cloud" })
        XCTAssertEqual(visible["advertisement_enabled"] as? Bool, true)
        XCTAssertEqual(visible["advertised"] as? Bool, true)

        let (chatResponse, chatBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"kimi-k2.6:cloud","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )
        XCTAssertEqual(chatResponse.statusCode, 503)
        let bodyText = String(decoding: chatBody, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("No eligible route for kimi-k2.6:cloud"), "body was: \(bodyText)")
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/search", "/search", "/search"])
    }

    func testGatewayModelsUsesOllamaCloudCatalogPageWhenBaseURLOmitsAPIPath() async throws {
        enqueueOllamaCloudCatalog(["kimi-k2.6"])
        let harness = try GatewayHarness()
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test",
                preferredModelIDs: ["deepseek-v4-flash"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "ollama",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-ollama-key"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertTrue(data.contains {
            ($0["id"] as? String) == "kimi-k2.6:cloud"
                && ($0["provider_id"] as? String) == "ollama"
                && ($0["route_eligible"] as? Bool) == true
        })
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/search"])
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.query), ["c=cloud"])
    }

    func testGatewayModelsDoesNotAdvertiseOllamaCloudWithoutRoutingCredential() async throws {
        let harness = try GatewayHarness()
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/api",
                preferredModelIDs: ["deepseek-v4-flash"]
            )
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertFalse(data.contains { ($0["provider_id"] as? String) == "ollama" })
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().count, 0)
    }

    func testGatewayModelsAdvertisesAnthropicRoutesWithRealBridgeEndpoints() async throws {
        let harness = try GatewayHarness()
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )

        XCTAssertEqual(response.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        let claude = try XCTUnwrap(data.first {
            ($0["id"] as? String) == "claude-sonnet-4-6"
                && ($0["provider_id"] as? String) == "anthropic"
        })
        XCTAssertEqual(claude["format_family"] as? String, "anthropic")
        XCTAssertEqual(claude["route_eligible"] as? Bool, true)
        XCTAssertTrue((claude["capabilities"] as? [String] ?? []).contains("anthropic"))
        let endpoints = try XCTUnwrap(claude["served_endpoints"] as? [String])
        XCTAssertTrue(endpoints.contains("/v1/messages"))
        XCTAssertTrue(endpoints.contains("/v1/chat/completions"))
        XCTAssertTrue(endpoints.contains("/v1/responses"))

        let codexModels = try XCTUnwrap(object["models"] as? [[String: Any]])
        let codexClaude = try XCTUnwrap(codexModels.first {
            ($0["slug"] as? String) == "claude-sonnet-4-6"
        })
        XCTAssertEqual(codexClaude["supported_in_api"] as? Bool, true)
        XCTAssertEqual(codexClaude["context_window"] as? Int, 200_000)
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().count, 0)
    }

    func testGatewayChatCompletionsRoutesAdvertisedClaudeThroughAnthropicBridge() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_openai_bridge",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "hello through bridge"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 7,
                "output_tokens": 3,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","messages":[{"role":"system","content":"Be terse."},{"role":"user","content":"hi"}],"max_tokens":12}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(responseObject["object"] as? String, "chat.completion")
        XCTAssertEqual(responseObject["model"] as? String, "claude-sonnet-4-6")
        let choices = try XCTUnwrap(responseObject["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "hello through bridge")
        let usage = try XCTUnwrap(responseObject["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 7)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 3)

        let upstreamRequest = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().first)
        XCTAssertEqual(upstreamRequest.path, "/anthropic/v1/messages")
        XCTAssertEqual(upstreamRequest.xApiKey, "sk-ant-api03-primary-key")
        XCTAssertTrue(upstreamRequest.body.contains(#""max_tokens":12"#), upstreamRequest.body)
        XCTAssertTrue(upstreamRequest.body.contains(#""system":"Be terse.""#), upstreamRequest.body)
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"claude-sonnet-4-6""#), upstreamRequest.body)
    }

    func testGatewayStopsAdvertisingAnthropicModelAfterRealRouteFailure() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-opus-4-7-family", "claude-haiku-4-5-family"],
                preferredCredentialSlotID: "oauth"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "oauth",
            label: "Claude Max",
            apiKey: "sk-ant-oat01-test-token"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (_, modelsBeforeBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        let modelsBefore = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBeforeBody) as? [String: Any])
        let dataBefore = try XCTUnwrap(modelsBefore["data"] as? [[String: Any]])
        XCTAssertTrue(dataBefore.contains { ($0["id"] as? String) == "claude-opus-4-7" })
        XCTAssertTrue(dataBefore.contains { ($0["id"] as? String) == "claude-haiku-4-5" })

        let (failedResponse, failedBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-opus-4-7","max_tokens":8,"messages":[{"role":"user","content":"Reply exactly OK"}]}"#.utf8)
        )

        XCTAssertEqual(failedResponse.statusCode, 429)
        let failedText = String(decoding: failedBody, as: UTF8.self)
        XCTAssertTrue(failedText.contains("Claude Max"), failedText)
        XCTAssertTrue(failedText.contains("public Messages API"), failedText)
        XCTAssertFalse(failedText.contains(#""message":"Error""#), failedText)

        let (_, modelsAfterBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        let modelsAfter = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsAfterBody) as? [String: Any])
        let dataAfter = try XCTUnwrap(modelsAfter["data"] as? [[String: Any]])
        XCTAssertFalse(
            dataAfter.contains { ($0["id"] as? String) == "claude-opus-4-7" },
            "A model/account pair that just proved unroutable must disappear from /v1/models until its health block expires."
        )
        XCTAssertTrue(
            dataAfter.contains { ($0["id"] as? String) == "claude-haiku-4-5" },
            "Model health is per model; a failing Opus route must not hide Haiku."
        )
    }

    func testGatewayChatCompletionsTranslatesClaudeToolUseToOpenAIStyleToolCalls() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_tool_bridge",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [
                {
                  "type": "tool_use",
                  "id": "toolu_123",
                  "name": "shell_command",
                  "input": {"cmd": "pwd"}
                }
              ],
              "stop_reason": "tool_use",
              "usage": {
                "input_tokens": 9,
                "output_tokens": 4,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"""
                {
                  "model": "claude-sonnet-4-6",
                  "messages": [{"role":"user","content":"run pwd"}],
                  "tools": [{
                    "type": "function",
                    "function": {
                      "name": "shell_command",
                      "description": "Run a shell command.",
                      "parameters": {
                        "type": "object",
                        "properties": {"cmd": {"type": "string"}}
                      }
                    }
                  }],
                  "tool_choice": {"type":"function","function":{"name":"shell_command"}}
                }
                """#.utf8
            )
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let choices = try XCTUnwrap(responseObject["choices"] as? [[String: Any]])
        XCTAssertEqual(choices.first?["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(toolCalls.first?["id"] as? String, "toolu_123")
        let function = try XCTUnwrap(toolCalls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "shell_command")
        XCTAssertTrue((function["arguments"] as? String ?? "").contains(#""cmd":"pwd""#))

        let upstreamRequest = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().first)
        XCTAssertTrue(upstreamRequest.body.contains(#""tools""#), upstreamRequest.body)
        XCTAssertTrue(upstreamRequest.body.contains(#""input_schema""#), upstreamRequest.body)
        XCTAssertTrue(upstreamRequest.body.contains(#""tool_choice":{"name":"shell_command","type":"tool"}"#), upstreamRequest.body)
    }

    func testGatewayResponsesRoutesAdvertisedClaudeThroughAnthropicBridge() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_responses_bridge",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "responses bridge answered"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 5,
                "output_tokens": 4,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/responses",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","instructions":"Be direct.","input":"hello","max_output_tokens":16}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(responseObject["object"] as? String, "response")
        XCTAssertEqual(responseObject["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(responseObject["output_text"] as? String, "responses bridge answered")
        let usage = try XCTUnwrap(responseObject["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 5)
        XCTAssertEqual(usage["output_tokens"] as? Int, 4)

        let upstreamRequest = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().first)
        XCTAssertEqual(upstreamRequest.path, "/anthropic/v1/messages")
        XCTAssertTrue(upstreamRequest.body.contains(#""max_tokens":16"#), upstreamRequest.body)
        XCTAssertTrue(upstreamRequest.body.contains(#""system":"Be direct.""#), upstreamRequest.body)
    }

    func testGatewayRoutesModelDiscoveredFromLiveModelsEndpoint() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"glm-5-live-new","display_name":"GLM-5 Live New"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"glm-5-live-new","display_name":"GLM-5 Live New"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-live","object":"chat.completion","model":"glm-5-live-new","choices":[{"index":0,"message":{"role":"assistant","content":"live model answered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
        )
        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "zai", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (modelsResponse, modelsBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(modelsResponse.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBody) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertTrue(data.contains { ($0["id"] as? String) == "glm-5-live-new" && ($0["route_eligible"] as? Bool) == true })

        let (chatResponse, chatBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"glm-5-live-new","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(chatResponse.statusCode, 200, "body was: \(String(decoding: chatBody, as: UTF8.self))")
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/chat/completions"])
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""model":"glm-5-live-new""#) == true)
    }

    func testGatewayModelsOnlyAdvertisesMiniMaxLiveModelsTheRouterCanServe() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"MiniMax-M2.7","display_name":"MiniMax M2.7"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"MiniMax-M2.7","display_name":"MiniMax M2.7"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-minimax","object":"chat.completion","model":"MiniMax-M2.7","choices":[{"index":0,"message":{"role":"assistant","content":"minimax answered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"],
                preferredCredentialSlotID: "default"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "minimax",
            slotID: "default",
            label: "MiniMax API",
            apiKey: "sk-cp-minimax-route-key"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (modelsResponse, modelsBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(modelsResponse.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBody) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertTrue(
            data.contains {
                ($0["id"] as? String) == "MiniMax-M2.7"
                    && ($0["provider_id"] as? String) == "minimax"
                    && ($0["route_eligible"] as? Bool) == true
            },
            "/v1/models may advertise a live upstream model only when /v1/chat/completions can route the same id."
        )

        let (chatResponse, chatBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"MiniMax-M2.7","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(chatResponse.statusCode, 200, "body was: \(String(decoding: chatBody, as: UTF8.self))")
        XCTAssertTrue(String(decoding: chatBody, as: UTF8.self).contains("minimax answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/chat/completions"])
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""model":"MiniMax-M2.7""#) == true)
    }

    func testGatewayRejectsReasoningOnlyLengthResponsesInsteadOfReturningEmptyAssistantText() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"deepseek-v4-flash","display_name":"DeepSeek V4 Flash"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-empty-reasoning","object":"chat.completion","model":"deepseek-v4-flash","choices":[{"index":0,"message":{"role":"assistant","content":"","reasoning_content":"thinking but no final answer yet"},"finish_reason":"length"}],"usage":{"prompt_tokens":3,"completion_tokens":8,"total_tokens":11}}"#
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["deepseek-v4-flash"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "primary",
            label: "DeepSeek API",
            apiKey: "deepseek-route-key"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"hi"}],"max_tokens":8}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 502, String(decoding: body, as: UTF8.self))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "empty_assistant_content")
        XCTAssertTrue((error["message"] as? String ?? "").contains("reasoning-only output"))
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/v1/models", "/v1/chat/completions"])
        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertTrue(usage.isEmpty)
    }

    func testGatewayFlattensDroidArrayContentForOpenAICompatibleChat() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"deepseek-v4-flash","display_name":"DeepSeek V4 Flash"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-droid","object":"chat.completion","model":"deepseek-v4-flash","choices":[{"index":0,"message":{"role":"assistant","content":"deepseek answered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["deepseek-v4-flash"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "primary",
            label: "DeepSeek API",
            apiKey: "deepseek-route-key"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"deepseek-v4-flash","messages":[{"role":"user","content":[{"type":"text","text":"hello"},{"type":"text","text":"from droid"}]}],"stream":false}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/chat/completions"])
        let chatBody = try XCTUnwrap(upstreamRequests.last?.body)
        XCTAssertTrue(chatBody.contains(#""content":"hello\nfrom droid""#), chatBody)
        XCTAssertFalse(chatBody.contains(#""content":[{"#), chatBody)
    }

    func testGatewayModelsRefreshesProviderAccountsConcurrently() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let modelsBody = #"{"object":"list","data":[{"id":"glm-5-turbo"},{"id":"MiniMax-M2.7"},{"id":"deepseek-v4-flash"}]}"#
        for _ in 0..<3 {
            GatewayUpstreamURLProtocol.enqueue(
                status: 200,
                body: modelsBody,
                delayNanoseconds: 1_000_000_000
            )
        }

        let harness = try GatewayHarness(modelCatalogSession: session)
        try await harness.configureZAIProviderForGateway()
        _ = try await harness.configStore.removeCredentialSlot(providerID: "zai", slotID: "backup")
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "minimax",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["minimax-m2.7-highspeed"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "minimax",
            slotID: "primary",
            label: "MiniMax API",
            apiKey: "minimax-route-key"
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "deepseek",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["deepseek-v4-flash"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "deepseek",
            slotID: "primary",
            label: "DeepSeek API",
            apiKey: "deepseek-route-key"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let startedAt = Date()
        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        XCTAssertLessThan(elapsed, 2.2, "Live model refresh should fan out; sequential 1s provider probes make CLI clients look offline.")
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().filter { $0.path == "/v1/models" }.count, 3)
    }

    func testGatewayRoutesOpenCodeAuthJSONThroughOpenAICompatibleGateway() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"kimi-k2.6","display_name":"Kimi K2.6"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"kimi-k2.6","display_name":"Kimi K2.6"}]}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-opencode","object":"chat.completion","model":"kimi-k2.6","choices":[{"index":0,"message":{"role":"assistant","content":"opencode answered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "opencode",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/zen/go/v1",
                preferredModelIDs: ["kimi-k2.6"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "opencode",
            slotID: "primary",
            label: "OpenCode Go",
            apiKey: #"{"opencode-go":{"type":"api","key":"opencode-route-key"}}"#
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (modelsResponse, modelsBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(modelsResponse.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBody) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertTrue(data.contains { ($0["id"] as? String) == "kimi-k2.6" && ($0["provider_id"] as? String) == "opencode" })

        let (chatResponse, chatBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"kimi-k2.6","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(chatResponse.statusCode, 200, "body was: \(String(decoding: chatBody, as: UTF8.self))")
        XCTAssertTrue(String(decoding: chatBody, as: UTF8.self).contains("opencode answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/zen/go/v1/models", "/zen/go/v1/models", "/zen/go/v1/chat/completions"])
        XCTAssertEqual(upstreamRequests.last?.authorization, "Bearer opencode-route-key")
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""model":"kimi-k2.6""#) == true)
    }

    func testGatewayChatCompletionsRejectsUnadvertisedModelBeforeUpstream() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"object":"list","data":[{"id":"glm-5-turbo","display_name":"GLM-5 Turbo"}]}"#
        )
        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "zai", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"not-advertised-anywhere","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("No eligible route for not-advertised-anywhere"), "body was: \(bodyText)")
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/v1/models"])
    }

    func testGatewayChatCompletionsStopsBeforeSendingWhenNoEligibleRouteExists() async throws {
        let harness = try GatewayHarness()
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["glm-5-turbo"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-key"
        )
        try await harness.configStore.updateCredentialSlotStatus(
            providerID: "zai",
            slotID: "primary",
            status: .exhausted,
            cooldownUntil: nil,
            message: "Weekly/Monthly Limit Exhausted"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"glm-5-turbo","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("No eligible route for glm-5-turbo"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("Add or enable an account") && bodyText.contains("provider"), "body was: \(bodyText)")
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().count, 0)
    }

    func testGatewayResponsesProxiesSelectedModelThroughOpenAICompatibleRoute() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["glm-5-turbo"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "resp_test",
              "object": "response",
              "model": "glm-5-turbo",
              "output_text": "responses answered",
              "usage": {
                "input_tokens": 3,
                "output_tokens": 4
              }
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/responses",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"glm-5-turbo","input":"hello"}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("responses answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/responses"])
        let responseRequest = try XCTUnwrap(upstreamRequests.last)
        XCTAssertEqual(responseRequest.authorization, "Bearer primary-key")
        XCTAssertTrue(responseRequest.body.contains(#""model":"glm-5-turbo""#))

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].providerID, "zai")
        XCTAssertEqual(usage[0].modelID, "glm-5-turbo")
        XCTAssertEqual(usage[0].inputTokens, 3)
        XCTAssertEqual(usage[0].outputTokens, 4)
    }

    func testGatewayResponsesFallsBackToChatCompletionsWhenProviderDoesNotExposeResponses() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["glm-5-turbo"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(status: 404, body: "404 page not found")
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "chatcmpl_test",
              "object": "chat.completion",
              "model": "glm-5-turbo",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "fallback answered"
                  },
                  "finish_reason": "stop"
                }
              ],
              "usage": {
                "prompt_tokens": 3,
                "completion_tokens": 4
              }
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/responses",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"glm-5-turbo","input":"hello","max_output_tokens":5}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains(#""object":"response""#), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains(#""output_text":"fallback answered""#), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains(#""input_tokens":3"#), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains(#""output_tokens":4"#), "body was: \(bodyText)")
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/responses", "/v1/chat/completions"])
        let chatRequest = try XCTUnwrap(upstreamRequests.last)
        XCTAssertEqual(chatRequest.authorization, "Bearer primary-key")
        XCTAssertTrue(chatRequest.body.contains(#""model":"glm-5-turbo""#), "body was: \(chatRequest.body)")
        XCTAssertTrue(chatRequest.body.contains(#""messages""#), "body was: \(chatRequest.body)")
        XCTAssertTrue(chatRequest.body.contains(#""max_tokens":5"#), "body was: \(chatRequest.body)")
    }

    func testGatewayResponsesFallbackMapsDeveloperRoleToSystemForChatProviders() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["glm-5-turbo"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(status: 404, body: "404 page not found")
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "chatcmpl_test",
              "object": "chat.completion",
              "model": "glm-5-turbo",
              "choices": [
                {
                  "index": 0,
                  "message": {
                    "role": "assistant",
                    "content": "developer mapped"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/responses",
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"""
                {
                  "model": "glm-5-turbo",
                  "instructions": "You are Codex.",
                  "messages": [
                    {
                      "role": "developer",
                      "content": [
                        {
                          "type": "input_text",
                          "text": "follow this developer instruction"
                        }
                      ]
                    },
                    {
                      "role": "user",
                      "content": "hello"
                    }
                  ],
                  "tools": [
                    {
                      "type": "function",
                      "name": "shell_command",
                      "description": "Run a command.",
                      "parameters": {
                        "type": "object",
                        "properties": {
                          "cmd": { "type": "string" }
                        }
                      }
                    },
                    {
                      "type": "namespace",
                      "name": "mcp__playwright__",
                      "description": "Nested namespace tools are Responses-only and must not be forwarded as fake chat functions.",
                      "tools": [
                        {
                          "type": "function",
                          "name": "browser_click",
                          "parameters": {
                            "type": "object",
                            "properties": {}
                          }
                        }
                      ]
                    }
                  ],
                  "tool_choice": {
                    "type": "function",
                    "name": "shell_command"
                  },
                  "parallel_tool_calls": true,
                  "reasoning": { "effort": "low" },
                  "metadata": { "client": "codex" }
                }
                """#.utf8
            )
        )

        XCTAssertEqual(response.statusCode, 200)
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/responses", "/v1/chat/completions"])
        let chatRequest = try XCTUnwrap(upstreamRequests.last)
        let requestData = Data(chatRequest.body.utf8)
        let forwarded = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let messages = try XCTUnwrap(forwarded["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        let systemContent = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(systemContent.contains("You are Codex."))
        XCTAssertTrue(systemContent.contains("follow this developer instruction"))
        let tools = try XCTUnwrap(forwarded["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let firstTool = try XCTUnwrap(tools.first)
        XCTAssertEqual(firstTool["type"] as? String, "function")
        let function = try XCTUnwrap(firstTool["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "shell_command")
        XCTAssertEqual(function["description"] as? String, "Run a command.")
        XCTAssertNotNil(function["parameters"] as? [String: Any])
        let toolChoice = try XCTUnwrap(forwarded["tool_choice"] as? [String: Any])
        XCTAssertEqual(toolChoice["type"] as? String, "function")
        XCTAssertEqual((toolChoice["function"] as? [String: Any])?["name"] as? String, "shell_command")
        XCTAssertNil(forwarded["parallel_tool_calls"])
        XCTAssertNil(forwarded["reasoning"])
        XCTAssertNil(forwarded["metadata"])
    }

    func testGatewayResponsesStreamingFallbackEmitsResponsesEvents() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["glm-5-turbo"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(status: 404, body: "404 page not found")
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            data: {"id":"chatcmpl_test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"role":"assistant","content":"stream "},"finish_reason":null}]}

            data: {"id":"chatcmpl_test","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"fallback"},"finish_reason":null}]}

            data: [DONE]

            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/responses",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"glm-5-turbo","input":"hello","stream":true}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("event: response.created"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("event: response.output_item.added"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("event: response.content_part.added"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("event: response.output_text.delta"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains(#""delta":"stream ""#), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains(#""delta":"fallback""#), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("event: response.content_part.done"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("event: response.output_item.done"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("event: response.completed"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("data: [DONE]"), "body was: \(bodyText)")
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/responses", "/v1/chat/completions"])
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""stream":true"#) == true)
    }

    func testGatewayProxiesChatCompletionsAndFailsOverExhaustedPlan() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["glm-5-turbo"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 402,
            body: #"{"error":{"message":"quota exceeded"}}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "chatcmpl-test",
              "object": "chat.completion",
              "model": "glm-5-turbo",
              "choices": [
                {"message": {"role": "assistant", "content": "backup plan answered"}}
              ],
              "usage": {
                "prompt_tokens": 11,
                "completion_tokens": 7,
                "total_tokens": 18
              }
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"glm-5-turbo","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("backup plan answered"))

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/chat/completions", "/v1/chat/completions"])
        let chatRequests = upstreamRequests.filter { $0.path == "/v1/chat/completions" }
        XCTAssertEqual(chatRequests.count, 2)
        XCTAssertEqual(chatRequests[0].authorization, "Bearer primary-key")
        XCTAssertEqual(chatRequests[1].authorization, "Bearer backup-key")
        XCTAssertTrue(chatRequests.allSatisfy { $0.body.contains(#""model":"glm-5-turbo""#) })

        let snapshot = try await harness.configStore.snapshot()
        let slots = try XCTUnwrap(snapshot.providerSettings(id: "zai")?.credentialSlots)
        XCTAssertEqual(slots.first(where: { $0.slotID == "primary" })?.status, .exhausted)
        XCTAssertEqual(slots.first(where: { $0.slotID == "backup" })?.status, .ready)

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].providerID, "zai")
        XCTAssertEqual(usage[0].modelID, "glm-5-turbo")
        XCTAssertEqual(usage[0].inputTokens, 11)
        XCTAssertEqual(usage[0].outputTokens, 7)
    }

    func testCodexOpenAICompatRequestFailsOverWhenPrimaryQuotaExhausted() async throws {
        try await assertOpenAICompatibleQuotaFailover(
            clientName: "Codex CLI",
            extraHeaders: ["X-OpenBurnBar-Client": "codex"]
        )
    }

    func testDroidOpenAICompatRequestFailsOverWhenPrimaryQuotaExhausted() async throws {
        try await assertOpenAICompatibleQuotaFailover(
            clientName: "Droid CLI",
            extraHeaders: ["X-OpenBurnBar-Client": "droid"]
        )
    }

    func testForgeOpenAICompatRequestFailsOverWhenPrimaryQuotaExhausted() async throws {
        try await assertOpenAICompatibleQuotaFailover(
            clientName: "Forge CLI",
            extraHeaders: ["X-OpenBurnBar-Client": "forge"]
        )
    }

    func testGatewayDoesNotDowngradeAcrossCapabilityClassesDuringFailover() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["shared-code-model"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"error":{"message":"rate limited"}}"#
        )

        let harness = try GatewayHarness(
            catalog: capabilityClassGatewayCatalog(),
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await configureCapabilityClassProviders(harness: harness)
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"shared-code-model","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.localizedCaseInsensitiveContains("no exact same-model fallback"))

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        let chatRequests = upstreamRequests.filter { $0.path == "/v1/chat/completions" }
        XCTAssertEqual(chatRequests.count, 1, "Gateway must not jump to a different canonical model after a retryable failure.")
    }

    func testGatewayKeepsOriginalFailureForNonFailoverErrorsEvenWhenLowerTierExists() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["shared-code-model"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 400,
            body: #"{"error":{"message":"invalid request payload"}}"#
        )

        let harness = try GatewayHarness(
            catalog: capabilityClassGatewayCatalog(),
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await configureCapabilityClassProviders(harness: harness)
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"shared-code-model","messages":[{"role":"user","content":"hello"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 400)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.localizedCaseInsensitiveContains("invalid request payload"))
        XCTAssertFalse(bodyText.localizedCaseInsensitiveContains("routing failed"))
        XCTAssertFalse(bodyText.localizedCaseInsensitiveContains("no exact same-model fallback"))
        let chatRequests = GatewayUpstreamURLProtocol.recordedRequests().filter { $0.path == "/v1/chat/completions" }
        XCTAssertEqual(
            chatRequests.count,
            1,
            "Gateway should surface the original fatal provider error instead of reporting downgrade blocking."
        )
    }

    func testGatewayAnthropicDoesNotDowngradeAcrossCapabilityClassesDuringFailover() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"quota exhausted"}}"#
        )

        let harness = try GatewayHarness(
            catalog: anthropicCapabilityClassGatewayCatalog(),
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await configureAnthropicCapabilityClassProviders(harness: harness)
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"shared-claude-model","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.localizedCaseInsensitiveContains("no exact same-model fallback"))
        XCTAssertEqual(
            GatewayUpstreamURLProtocol.recordedRequests().count,
            1,
            "Anthropic gateway must stay on the exact canonical model when primary quota is exhausted."
        )
    }

    func testGatewayAnthropicKeepsOriginalFailureForNonFailoverErrors() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 400,
            body: #"{"type":"error","error":{"type":"invalid_request_error","message":"invalid request payload"}}"#
        )

        let harness = try GatewayHarness(
            catalog: anthropicCapabilityClassGatewayCatalog(),
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await configureAnthropicCapabilityClassProviders(harness: harness)
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"shared-claude-model","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 400)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.localizedCaseInsensitiveContains("invalid request payload"))
        XCTAssertFalse(bodyText.localizedCaseInsensitiveContains("routing failed"))
        XCTAssertFalse(bodyText.localizedCaseInsensitiveContains("no exact same-model fallback"))
        XCTAssertEqual(
            GatewayUpstreamURLProtocol.recordedRequests().count,
            1,
            "Anthropic gateway should return the original fatal provider error without triggering downgrade messaging."
        )
    }

    func testGatewayRoutesOllamaCloudThroughNativeAPIAndFailsOverSlots() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOllamaCloudCatalog(["deepseek-v4-flash"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"error":"quota exhausted"}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "deepseek-v4-flash",
              "created_at": "2026-05-06T00:00:00Z",
              "message": {"role": "assistant", "content": "ollama backup answered"},
              "done": true,
              "done_reason": "stop",
              "prompt_eval_count": 13,
              "eval_count": 5
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureOllamaProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"deepseek-v4-flash:cloud","messages":[{"role":"user","content":"hello"}],"stream":false,"reasoning_effort":"high","stream_options":{"include_usage":true},"max_completion_tokens":64}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("ollama backup answered"))
        XCTAssertTrue(bodyText.contains(#""prompt_tokens":13"#))
        XCTAssertTrue(bodyText.contains(#""completion_tokens":5"#))

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        let chatRequests = upstreamRequests.filter { $0.path == "/api/chat" }
        guard chatRequests.count == 2 else {
            XCTFail("Expected two upstream chat requests after primary Ollama slot exhaustion, got \(upstreamRequests)")
            return
        }
        XCTAssertEqual(chatRequests[0].authorization, "Bearer primary-ollama-key")
        XCTAssertEqual(chatRequests[1].authorization, "Bearer backup-ollama-key")
        XCTAssertTrue(chatRequests.allSatisfy { $0.body.contains(#""model":"deepseek-v4-flash""#) })
        XCTAssertTrue(chatRequests.allSatisfy { !$0.body.contains(#""deepseek-v4-flash:cloud""#) })
        XCTAssertTrue(chatRequests.allSatisfy { $0.body.contains(#""think":"high""#) })
        XCTAssertTrue(chatRequests.allSatisfy { $0.body.contains(#""num_predict":64"#) })
        XCTAssertTrue(chatRequests.allSatisfy { !$0.body.contains("reasoning_effort") })
        XCTAssertTrue(chatRequests.allSatisfy { !$0.body.contains("stream_options") })

        let snapshot = try await harness.configStore.snapshot()
        let slots = try XCTUnwrap(snapshot.providerSettings(id: "ollama")?.credentialSlots)
        XCTAssertEqual(slots.first(where: { $0.slotID == "primary" })?.status, .exhausted)
        XCTAssertEqual(slots.first(where: { $0.slotID == "backup" })?.status, .ready)

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].providerID, "ollama")
        XCTAssertEqual(usage[0].modelID, "deepseek-v4-flash")
        XCTAssertEqual(usage[0].inputTokens, 13)
        XCTAssertEqual(usage[0].outputTokens, 5)
    }

    func testGatewayDoesNotRouteUnsuffixedModelToOllamaCloudAlias() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOllamaCloudCatalog(["deepseek-v4-flash"], times: 1)

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureOllamaProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"hello"}],"stream":false}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("No eligible route for deepseek-v4-flash"), "body was: \(bodyText)")
        let upstreamPaths = GatewayUpstreamURLProtocol.recordedRequests().map(\.path)
        XCTAssertTrue(upstreamPaths.allSatisfy { $0 == "/search" }, "Unexpected upstream paths: \(upstreamPaths)")
        XCTAssertFalse(upstreamPaths.contains("/api/chat"))
    }

    func testGatewayRoutesOllamaCloudModelDiscoveredFromCatalogPage() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOllamaCloudCatalog(["kimi-k2.6"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "kimi-k2.6",
              "created_at": "2026-05-17T00:00:00Z",
              "message": {"role": "assistant", "content": "ollama cloud live answered"},
              "done": true,
              "done_reason": "stop",
              "prompt_eval_count": 9,
              "eval_count": 6
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureOllamaProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (modelsResponse, modelsBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(modelsResponse.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBody) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertTrue(data.contains {
            ($0["id"] as? String) == "kimi-k2.6:cloud"
                && ($0["provider_id"] as? String) == "ollama"
                && ($0["route_eligible"] as? Bool) == true
        })

        let (chatResponse, chatBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"kimi-k2.6:cloud","messages":[{"role":"user","content":"hello"}],"stream":false}"#.utf8)
        )

        XCTAssertEqual(chatResponse.statusCode, 200, String(decoding: chatBody, as: UTF8.self))
        XCTAssertTrue(String(decoding: chatBody, as: UTF8.self).contains("ollama cloud live answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/search", "/search", "/api/chat"])
        XCTAssertEqual(upstreamRequests.prefix(2).map(\.query), ["c=cloud", "c=cloud"])
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""model":"kimi-k2.6""#) == true)
        XCTAssertFalse(upstreamRequests.last?.body.contains(#""kimi-k2.6:cloud""#) == true)
        XCTAssertEqual(upstreamRequests.last?.authorization, "Bearer primary-ollama-key")
    }

    func testGatewayRejectsOllamaCloudLengthResponseWithoutAssistantText() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOllamaCloudCatalog(["kimi-k2.6"], times: 1)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "kimi-k2.6",
              "created_at": "2026-05-17T00:00:00Z",
              "message": {"role": "assistant", "content": "", "thinking": "reasoning but no final answer"},
              "done": true,
              "done_reason": "length",
              "prompt_eval_count": 24,
              "eval_count": 8
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureOllamaProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"kimi-k2.6:cloud","messages":[{"role":"user","content":"What model are ye?"}],"stream":false,"max_tokens":8}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 502, String(decoding: body, as: UTF8.self))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "empty_assistant_content")
        XCTAssertTrue((error["message"] as? String ?? "").contains("reasoning-only output"))
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/search", "/api/chat"])
        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertTrue(usage.isEmpty)
    }

    func testGatewayFlattensDroidArrayContentForOllamaCloudChat() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOllamaCloudCatalog(["deepseek-v4-pro"], times: 1)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "deepseek-v4-pro",
              "created_at": "2026-05-17T00:00:00Z",
              "message": {"role": "assistant", "content": "array content answered"},
              "done": true,
              "done_reason": "stop",
              "prompt_eval_count": 11,
              "eval_count": 4
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureOllamaProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (chatResponse, chatBody) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"deepseek-v4-pro:cloud","messages":[{"role":"user","content":[{"type":"text","text":"hello"},{"type":"text","text":"from droid"}]}],"stream":false}"#.utf8)
        )

        XCTAssertEqual(chatResponse.statusCode, 200, String(decoding: chatBody, as: UTF8.self))
        XCTAssertTrue(String(decoding: chatBody, as: UTF8.self).contains("array content answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/search", "/api/chat"])
        let chatBodyText = try XCTUnwrap(upstreamRequests.last?.body)
        XCTAssertTrue(chatBodyText.contains(#""content":"hello\nfrom droid""#), chatBodyText)
        XCTAssertFalse(chatBodyText.contains(#""content":[{"#), chatBodyText)
    }

    func testGatewayPreservesOllamaCloudToolCallsInStreamingChatCompletions() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOllamaCloudCatalog(["kimi-k2.6"])
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {"model":"kimi-k2.6","created_at":"2026-05-17T00:00:00Z","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"burnbar_runtime_status","arguments":{}}}]},"done":false}
            {"model":"kimi-k2.6","created_at":"2026-05-17T00:00:00Z","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":21,"eval_count":3}
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureOllamaProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"kimi-k2.6:cloud","messages":[{"role":"system","content":"Use burnbar_runtime_status when asked what model you are using."},{"role":"user","content":"What model are ye?"}],"stream":true,"tools":[{"type":"function","function":{"name":"burnbar_runtime_status","description":"Return selected model.","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":"auto"}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains(#""tool_calls""#), bodyText)
        XCTAssertTrue(bodyText.contains(#""name":"burnbar_runtime_status""#), bodyText)
        XCTAssertTrue(bodyText.contains(#""arguments":"{}""#), bodyText)
        XCTAssertTrue(bodyText.contains(#""finish_reason":"tool_calls""#), bodyText)
        XCTAssertTrue(bodyText.contains("data: [DONE]"), bodyText)

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/search", "/api/chat"])
        XCTAssertTrue(upstreamRequests.last?.body.contains(#""tools""#) == true)
        XCTAssertFalse(upstreamRequests.last?.body.contains(#""tool_choice""#) == true)
    }

    func testGatewayConvertsOpenAIToolReplayArgumentsForOllamaNativeChat() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOllamaCloudCatalog(["kimi-k2.6"])
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {"model":"kimi-k2.6","created_at":"2026-05-17T00:00:00Z","message":{"role":"assistant","content":"I am running through Hermes on kimi-k2.6."},"done":true,"done_reason":"stop","prompt_eval_count":34,"eval_count":9}
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureOllamaProviderForGateway()
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"kimi-k2.6:cloud","messages":[{"role":"user","content":"What model are ye?"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_ollama_0","type":"function","function":{"name":"burnbar_runtime_status","arguments":"{}"}}]},{"role":"tool","tool_call_id":"call_ollama_0","content":"{\"assistant\":\"Hermes\",\"model\":\"kimi-k2.6:cloud\",\"status\":\"online\"}"}],"stream":true,"tools":[{"type":"function","function":{"name":"burnbar_runtime_status","description":"Return selected model.","parameters":{"type":"object","properties":{},"required":[]}}}],"tool_choice":"auto"}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("I am running through Hermes on kimi-k2.6."), bodyText)

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/search", "/api/chat"])
        let forwardedBody = upstreamRequests.last?.body ?? ""
        XCTAssertTrue(forwardedBody.contains(#""arguments":{}"#), forwardedBody)
        XCTAssertFalse(forwardedBody.contains(#""arguments":"{}""#), forwardedBody)
        XCTAssertFalse(forwardedBody.contains(#""tool_choice""#), forwardedBody)
    }

    // MARK: - Anthropic-family pool (/v1/messages)

    func testGatewayProxiesAnthropicMessagesHappyPath() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_test_1",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "hello from claude"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 17,
                "output_tokens": 4,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("hello from claude"))

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.count, 1)
        XCTAssertEqual(upstreamRequests[0].path, "/anthropic/v1/messages")
        // Console API keys must travel as x-api-key, not Authorization.
        XCTAssertNil(upstreamRequests[0].authorization)
        XCTAssertEqual(upstreamRequests[0].xApiKey, "sk-ant-api03-primary-key")
        XCTAssertEqual(upstreamRequests[0].anthropicVersion, "2023-06-01")
        XCTAssertTrue(upstreamRequests[0].body.contains(#""model":"claude-sonnet-4-6""#))

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].providerID, "anthropic")
        XCTAssertEqual(usage[0].inputTokens, 17)
        XCTAssertEqual(usage[0].outputTokens, 4)
    }

    func testGatewayStripsClaudeCodeContextManagementBeforeAnthropicProxy() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_context_management_stripped",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "clean request"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 8,
                "output_tokens": 2,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","max_tokens":64,"context_management":{"edits":[{"type":"clear_tool_uses_20250919","trigger":{"type":"input_tokens","value":100000},"keep":{"type":"tool_uses","value":10}}]},"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("clean request"))

        let upstreamRequest = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().first)
        XCTAssertFalse(upstreamRequest.body.contains("context_management"))
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"claude-sonnet-4-6""#))
    }

    func testGatewaySendsClaudeOAuthTokenAsBearer() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_oauth_1",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "hello from oauth"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 8,
                "output_tokens": 3,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-sonnet-4-6-family"],
                preferredCredentialSlotID: "oauth"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "oauth",
            label: "Claude OAuth",
            apiKey: "sk-ant-oat01-test-token"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.count, 1)
        XCTAssertNil(upstreamRequests[0].xApiKey)
        XCTAssertEqual(upstreamRequests[0].authorization, "Bearer sk-ant-oat01-test-token")
    }

    // MARK: - Claude Max subscription identity

    /// Anthropic's public Messages API gates Opus on OAuth bearer tokens
    /// behind a Claude Code identity check. BurnBar must present that
    /// identity (beta header + system guard + `?beta=true`) on every
    /// `sk-ant-oat…` route — otherwise a Max subscriber gets a misleading
    /// HTTP 429 even though they are entitled to the model.
    func testGatewayPresentsClaudeCodeIdentityOnOAuthOpusRoute() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_oauth_opus",
              "type": "message",
              "role": "assistant",
              "model": "claude-opus-4-7",
              "content": [{"type": "text", "text": "OK"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 12,
                "output_tokens": 2,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-opus-4-7-family"],
                preferredCredentialSlotID: "oauth"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "oauth",
            label: "Claude Max",
            apiKey: "sk-ant-oat01-test-token"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-opus-4-7","max_tokens":16,"messages":[{"role":"user","content":"Reply OK"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))

        let upstreamRequest = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().first)
        XCTAssertEqual(upstreamRequest.authorization, "Bearer sk-ant-oat01-test-token")
        XCTAssertNil(upstreamRequest.xApiKey)
        XCTAssertEqual(
            upstreamRequest.query,
            "beta=true",
            "Claude Code OAuth routes must hit /v1/messages?beta=true so Anthropic applies Claude Code-specific gating."
        )
        let beta = try XCTUnwrap(upstreamRequest.anthropicBeta)
        XCTAssertTrue(beta.contains("claude-code-20250219"), beta)
        XCTAssertTrue(beta.contains("oauth-2025-04-20"), beta)
        XCTAssertFalse(
            beta.contains("context-management"),
            "BurnBar strips the context_management field, so it must not advertise that beta token."
        )
        XCTAssertEqual(upstreamRequest.xApp, "cli")
        XCTAssertEqual(upstreamRequest.directBrowserAccess, "true")
        let ua = try XCTUnwrap(upstreamRequest.userAgent)
        XCTAssertTrue(ua.hasPrefix("claude-cli/"), ua)
        XCTAssertTrue(
            upstreamRequest.body.contains(#""system":"You are Claude Code, Anthropic's official CLI for Claude.""#),
            upstreamRequest.body
        )
    }

    /// Console API key routes must not receive the Claude Code identity
    /// dress-up. Those credentials bill differently and Anthropic treats
    /// the beta+guard combination as a signal the request is coming from
    /// the Claude Code CLI — we never want to lie about provenance.
    func testGatewayDoesNotPresentClaudeCodeIdentityOnConsoleAPIKeyRoute() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_console",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "hello"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 4,
                "output_tokens": 1,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","max_tokens":16,"system":"Be terse.","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))

        let upstreamRequest = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().first)
        XCTAssertEqual(upstreamRequest.xApiKey, "sk-ant-api03-primary-key")
        XCTAssertNil(upstreamRequest.authorization)
        XCTAssertNil(
            upstreamRequest.query,
            "Console API key routes hit the bare /v1/messages URL; they must not get the Claude Code ?beta=true query."
        )
        XCTAssertNil(upstreamRequest.anthropicBeta)
        XCTAssertNil(upstreamRequest.xApp)
        XCTAssertNil(upstreamRequest.directBrowserAccess)
        XCTAssertFalse(
            upstreamRequest.body.contains("You are Claude Code"),
            "BurnBar must not inject the Claude Code system guard on Console API key routes."
        )
        XCTAssertTrue(
            upstreamRequest.body.contains(#""system":"Be terse.""#),
            "Caller-provided system text must pass through untouched on non-OAuth routes."
        )
    }

    /// When the caller already supplies a system field on an OAuth route,
    /// the Claude Code guard must be prepended — never replaced. Otherwise
    /// callers lose their own instructions when we add the identity.
    func testGatewayPreservesCallerSystemPromptWhenInjectingClaudeCodeGuard() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_preserve",
              "type": "message",
              "role": "assistant",
              "model": "claude-opus-4-7",
              "content": [{"type": "text", "text": "OK"}],
              "stop_reason": "end_turn",
              "usage": {"input_tokens": 5, "output_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-opus-4-7-family"],
                preferredCredentialSlotID: "oauth"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "oauth",
            label: "Claude Max",
            apiKey: "sk-ant-oat01-test-token"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-opus-4-7","max_tokens":16,"system":"Speak in haiku.","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let upstreamRequest = try XCTUnwrap(GatewayUpstreamURLProtocol.recordedRequests().first)
        XCTAssertTrue(
            upstreamRequest.body.contains(#""system":"You are Claude Code, Anthropic's official CLI for Claude.\n\nSpeak in haiku.""#),
            "Claude Code guard must be prepended to the caller's system text, not replace it. Body was: \(upstreamRequest.body)"
        )
    }

    /// When Opus is requested and only the OAuth route exists, a 429 must
    /// not silently retry against a different canonical model (Haiku /
    /// Sonnet). The user asked for Opus; if BurnBar can't serve Opus, it
    /// must say so precisely instead of returning a downgraded answer.
    func testGatewayDoesNotDowngradeOpusToHaikuOnOAuthFailure() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"Error"}}"#
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-opus-4-7-family", "claude-haiku-4-5-family"],
                preferredCredentialSlotID: "oauth"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "oauth",
            label: "Claude Max",
            apiKey: "sk-ant-oat01-test-token"
        )
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-opus-4-7","max_tokens":16,"messages":[{"role":"user","content":"Reply OK"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 429, "Opus 429 on the only configured route must surface — not downgrade silently.")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("claude-haiku"), "Response must not hint at a Haiku downgrade. Body: \(text)")
        XCTAssertFalse(text.contains("claude-sonnet"), "Response must not hint at a Sonnet downgrade. Body: \(text)")
        XCTAssertTrue(
            text.contains("claude-opus-4-7"),
            "Error message must clearly identify the requested Opus model. Body: \(text)"
        )
        // The upstream was hit exactly once — no silent retry-and-rewrite.
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().count, 1)
    }

    func testGatewayFailsOverAnthropicAccountOnQuotaExhausted() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"quota exhausted"}}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_test_2",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "backup plan answered"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 11,
                "output_tokens": 5,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("backup plan answered"))

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.count, 2)
        XCTAssertEqual(upstreamRequests[0].xApiKey, "sk-ant-api03-primary-key")
        XCTAssertEqual(upstreamRequests[1].xApiKey, "sk-ant-api03-backup-key")

        let snapshot = try await harness.configStore.snapshot()
        let slots = try XCTUnwrap(snapshot.providerSettings(id: "anthropic")?.credentialSlots)
        // 429 with "quota" / "rate" in body should mark primary as exhausted
        // and leave backup ready. Cooldown is asserted in router-level tests.
        XCTAssertEqual(slots.first(where: { $0.slotID == "primary" })?.status, .exhausted)
        XCTAssertEqual(slots.first(where: { $0.slotID == "backup" })?.status, .ready)

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].providerID, "anthropic")
        XCTAssertEqual(usage[0].inputTokens, 11)
        XCTAssertEqual(usage[0].outputTokens, 5)
    }

    func testClaudeCodeAnthropicRequestFailsOverWhenPrimaryQuotaExhausted() async throws {
        try await assertAnthropicQuotaFailover(
            clientName: "Claude Code",
            extraHeaders: ["X-OpenBurnBar-Client": "claude-code"]
        )
    }

    func testGatewayMessagesReturns503WhenOnlyOpenAICompatProvidersConfigured() async throws {
        let harness = try GatewayHarness()
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("Anthropic"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("v1") && bodyText.contains("messages"), "body was: \(bodyText)")

        // No upstream calls should have happened — pool isolation rejects
        // the request before it ever leaves the daemon.
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().count, 0)
    }

    func testGatewayChatCompletionsReturns503WhenOnlyAnthropicProvidersConfigured() async throws {
        let harness = try GatewayHarness()
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"glm-5-turbo","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("No eligible route for glm-5-turbo"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("Add or enable an account") && bodyText.contains("provider"), "body was: \(bodyText)")

        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().count, 0)
    }

    func testStructuredExecutorRoutesOllamaCloudThroughNativeAPI() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "deepseek-v4-flash",
              "created_at": "2026-05-06T00:00:00Z",
              "message": {"role": "assistant", "content": "{\\"ok\\":true}"},
              "done": true,
              "done_reason": "stop",
              "prompt_eval_count": 21,
              "eval_count": 8
            }
            """
        )

        let executor = BurnBarOpenAICompatibleProviderExecutor(session: session)
        let result = try await executor.completeStructured(
            BurnBarStructuredPromptRequest(
                systemPrompt: "Return JSON.",
                userPrompt: "Say OK.",
                jsonOnly: true
            ),
            route: BurnBarProviderRoute(
                providerID: "ollama",
                providerDisplayName: "Ollama Cloud",
                baseURL: "https://gateway-upstream.test/api",
                requestedModel: "deepseek-v4-flash:cloud",
                resolvedModelID: "deepseek-v4-flash",
                apiKey: "ollama-key",
                pricing: .defaultFallback
            )
        )

        XCTAssertEqual(result.outputText, #"{"ok":true}"#)
        XCTAssertEqual(result.inputTokens, 21)
        XCTAssertEqual(result.outputTokens, 8)

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.count, 1)
        XCTAssertEqual(upstreamRequests[0].path, "/api/chat")
        XCTAssertEqual(upstreamRequests[0].authorization, "Bearer ollama-key")
        XCTAssertTrue(upstreamRequests[0].body.contains(#""format":"json""#))
        XCTAssertTrue(upstreamRequests[0].body.contains(#""model":"deepseek-v4-flash""#))
        XCTAssertFalse(upstreamRequests[0].body.contains("chat/completions"))
    }

    private func assertOpenAICompatibleQuotaFailover(
        clientName: String,
        extraHeaders: [String: String]
    ) async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["glm-5-turbo"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"error":{"message":"quota exhausted"}}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "chatcmpl-\(clientName.replacingOccurrences(of: " ", with: "-").lowercased())",
              "object": "chat.completion",
              "model": "glm-5-turbo",
              "choices": [
                {"message": {"role": "assistant", "content": "\(clientName) backup answered"}}
              ],
              "usage": {
                "prompt_tokens": 9,
                "completion_tokens": 3,
                "total_tokens": 12
              }
            }
            """
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await harness.configureZAIProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        var headers = [
            "Content-Type": "application/json",
            "User-Agent": "\(clientName)/openburnbar-failover-test"
        ]
        for (name, value) in extraHeaders {
            headers[name] = value
        }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: headers,
            body: Data(#"{"model":"glm-5-turbo","messages":[{"role":"user","content":"simulate quota exhaustion"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, clientName)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("\(clientName) backup answered"), clientName)

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/v1/models", "/v1/models", "/v1/chat/completions", "/v1/chat/completions"], clientName)
        let chatRequests = upstreamRequests.filter { $0.path == "/v1/chat/completions" }
        XCTAssertEqual(chatRequests.count, 2, clientName)
        XCTAssertEqual(chatRequests[0].authorization, "Bearer primary-key", clientName)
        XCTAssertEqual(chatRequests[1].authorization, "Bearer backup-key", clientName)

        let snapshot = try await harness.configStore.snapshot()
        let slots = try XCTUnwrap(snapshot.providerSettings(id: "zai")?.credentialSlots)
        XCTAssertEqual(slots.first(where: { $0.slotID == "primary" })?.status, .exhausted, clientName)
        XCTAssertEqual(slots.first(where: { $0.slotID == "backup" })?.status, .ready, clientName)
    }

    private func assertAnthropicQuotaFailover(
        clientName: String,
        extraHeaders: [String: String]
    ) async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"type":"error","error":{"type":"rate_limit_error","message":"quota exhausted"}}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_claude_code_failover",
              "type": "message",
              "role": "assistant",
              "model": "claude-sonnet-4-6",
              "content": [{"type": "text", "text": "\(clientName) backup answered"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 9,
                "output_tokens": 3,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )

        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        try await harness.configureAnthropicProviderForGateway()
        try await harness.start()
        defer { Task { await harness.stop() } }

        var headers = [
            "Content-Type": "application/json",
            "User-Agent": "\(clientName)/openburnbar-failover-test"
        ]
        for (name, value) in extraHeaders {
            headers[name] = value
        }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: headers,
            body: Data(#"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"simulate quota exhaustion"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, clientName)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("\(clientName) backup answered"), clientName)

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.count, 2, clientName)
        XCTAssertEqual(upstreamRequests[0].xApiKey, "sk-ant-api03-primary-key", clientName)
        XCTAssertEqual(upstreamRequests[1].xApiKey, "sk-ant-api03-backup-key", clientName)

        let snapshot = try await harness.configStore.snapshot()
        let slots = try XCTUnwrap(snapshot.providerSettings(id: "anthropic")?.credentialSlots)
        XCTAssertEqual(slots.first(where: { $0.slotID == "primary" })?.status, .exhausted, clientName)
        XCTAssertEqual(slots.first(where: { $0.slotID == "backup" })?.status, .ready, clientName)
    }

    func testGatewayResolvesCapabilityClassFromCatalogBeforeRouting() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["shared-code-model"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"error":{"message":"rate limit exceeded","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#
        )

        let harness = try GatewayHarness(
            catalog: capabilityClassGatewayCatalog(),
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        try await configureCapabilityClassProviders(harness: harness)
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, body) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"shared-code-model","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(
            bodyText.localizedCaseInsensitiveContains("no exact same-model fallback"),
            "Gateway must report exact-model fail-closed when the catalog-resolved exact route is exhausted."
        )
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        let chatRequests = upstreamRequests.filter { $0.path == "/v1/chat/completions" }
        XCTAssertEqual(
            chatRequests.count, 1,
            "Gateway must only attempt the catalog-resolved exact route, not fall through to a similar base model."
        )
    }

    func testGatewayRoutesWithinSameClassWhenCatalogDeclaresMultipleSameClassProviders() async throws {
        let pro = BurnBarCatalogModel(
            id: "alpha-pro",
            displayName: "Alpha Pro",
            visibility: .public,
            aliases: ["shared-pro-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 12, outputPerMToken: 24, cacheReadPerMToken: 1),
            canonicalModelID: "shared-pro-model",
            capabilityClassID: "openai:pro",
            capabilityClassRank: 100
        )
        let altPro = BurnBarCatalogModel(
            id: "alt-pro",
            displayName: "Alt Pro",
            visibility: .public,
            aliases: ["shared-pro-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 10, outputPerMToken: 20, cacheReadPerMToken: 0.8),
            canonicalModelID: "shared-pro-model",
            capabilityClassID: "openai:pro",
            capabilityClassRank: 100
        )
        let base = BurnBarCatalogModel(
            id: "alpha-base",
            displayName: "Alpha Base",
            visibility: .public,
            aliases: ["shared-pro-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 2, cacheReadPerMToken: 0.1),
            capabilityClassID: "openai:base",
            capabilityClassRank: 10
        )
        let catalog = BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://gateway-upstream.test/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [pro, base]
                ),
                BurnBarCatalogProvider(
                    id: "alt",
                    displayName: "Alt",
                    baseURL: "https://gateway-upstream.test/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [altPro]
                )
            ]
        )

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        enqueueOpenAIModelCatalog(["shared-pro-model"], times: 2)
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"error":{"message":"rate limit exceeded","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"id":"chatcmpl-ok","object":"chat.completion","model":"shared-pro-model","choices":[{"index":0,"message":{"role":"assistant","content":"alt pro answered"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"total_tokens":3}}"#
        )

        let harness = try GatewayHarness(
            catalog: catalog,
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["alpha-pro"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "alpha",
            slotID: "primary",
            label: "Alpha Pro",
            apiKey: "sk-alpha-key"
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alt",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["alt-pro"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "alt",
            slotID: "primary",
            label: "Alt Pro",
            apiKey: "sk-alt-key"
        )
        try await harness.configStore.setRouterMode(.providerFamilyFailover)
        try await harness.start()
        defer { Task { await harness.stop() } }

        let (response, _) = try await sendGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"model":"shared-pro-model","messages":[{"role":"user","content":"hi"}]}"#.utf8)
        )

        XCTAssertEqual(response.statusCode, 200, "Gateway must succeed by failing over to an exact same-model alt provider.")
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        let chatRequests = upstreamRequests.filter { $0.path == "/v1/chat/completions" }
        XCTAssertEqual(chatRequests.count, 2, "Gateway must try alpha-pro first, then alt-pro on 429.")
        let requestPaths = chatRequests.map(\.path)
        XCTAssertTrue(
            requestPaths.allSatisfy { !$0.contains("alpha-base") },
            "Gateway must not try the base-tier route when exact-model alternatives exist."
        )
    }

    private func capabilityClassGatewayCatalog() -> BurnBarCatalog {
        let pro = BurnBarCatalogModel(
            id: "alpha-shared-pro",
            displayName: "Shared Pro",
            visibility: .public,
            aliases: ["shared-code-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 12, outputPerMToken: 24, cacheReadPerMToken: 1),
            capabilityClassID: "openai:shared:pro",
            capabilityClassRank: 100
        )
        let base = BurnBarCatalogModel(
            id: "beta-shared-base",
            displayName: "Shared Base",
            visibility: .public,
            aliases: ["shared-code-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 1, outputPerMToken: 2, cacheReadPerMToken: 0.1),
            capabilityClassID: "openai:shared:base",
            capabilityClassRank: 10
        )
        return BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "alpha",
                    displayName: "Alpha",
                    baseURL: "https://gateway-upstream.test/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [pro]
                ),
                BurnBarCatalogProvider(
                    id: "beta",
                    displayName: "Beta",
                    baseURL: "https://gateway-upstream.test/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [base]
                )
            ]
        )
    }

    private func anthropicCapabilityClassGatewayCatalog() -> BurnBarCatalog {
        let pro = BurnBarCatalogModel(
            id: "anth-shared-pro",
            displayName: "Shared Claude Pro",
            visibility: .public,
            aliases: ["shared-claude-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 15, outputPerMToken: 75, cacheReadPerMToken: 1),
            capabilityClassID: "anthropic:shared:pro",
            capabilityClassRank: 100
        )
        let base = BurnBarCatalogModel(
            id: "anth-shared-base",
            displayName: "Shared Claude Base",
            visibility: .public,
            aliases: ["shared-claude-model"],
            pricing: BurnBarModelPricing(inputPerMToken: 3, outputPerMToken: 15, cacheReadPerMToken: 0.5),
            capabilityClassID: "anthropic:shared:base",
            capabilityClassRank: 10
        )
        return BurnBarCatalog(
            schemaVersion: 1,
            providers: [
                BurnBarCatalogProvider(
                    id: "anth-alpha",
                    displayName: "Anth Alpha",
                    baseURL: "https://gateway-upstream.test/anthropic/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [pro],
                    formatFamily: .anthropic
                ),
                BurnBarCatalogProvider(
                    id: "anth-beta",
                    displayName: "Anth Beta",
                    baseURL: "https://gateway-upstream.test/anthropic/v1",
                    visibility: .public,
                    capabilities: [.routing],
                    models: [base],
                    formatFamily: .anthropic
                )
            ]
        )
    }

    private func configureCapabilityClassProviders(harness: GatewayHarness) async throws {
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "alpha",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["alpha-shared-pro"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "alpha",
            slotID: "primary",
            label: "Alpha Pro",
            apiKey: "alpha-key"
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "beta",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["beta-shared-base"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "beta",
            slotID: "primary",
            label: "Beta Base",
            apiKey: "beta-key"
        )
        try await harness.configStore.setRouterMode(.providerFamilyFailover)
    }

    private func configureAnthropicCapabilityClassProviders(harness: GatewayHarness) async throws {
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anth-alpha",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["anth-shared-pro"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anth-alpha",
            slotID: "primary",
            label: "Anth Alpha Pro",
            apiKey: "sk-ant-api03-alpha-key"
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anth-beta",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["anth-shared-base"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anth-beta",
            slotID: "primary",
            label: "Anth Beta Base",
            apiKey: "sk-ant-api03-beta-key"
        )
        try await harness.configStore.setRouterMode(.sameModelFailover)
    }

    private func sendGatewayRequest(
        port: Int,
        method: String,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        var lastError: Error?
        for attempt in 0..<10 {
            do {
                let (responseData, response) = try await URLSession.shared.data(for: request)
                let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
                return (httpResponse, responseData)
            } catch {
                lastError = error
                guard
                    attempt < 9,
                    (error as NSError).domain == NSURLErrorDomain,
                    (error as NSError).code == NSURLErrorCannotConnectToHost
                else {
                    throw error
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func sendRawGatewayRequest(
        port: Int,
        request: String
    ) throws -> (status: Int, headers: [String: String], body: String) {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { close(fileDescriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = 0x0100007F

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(fileDescriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .ECONNREFUSED)
        }

        guard let requestData = request.data(using: .utf8) else {
            throw POSIXError(.EILSEQ)
        }
        try requestData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesRemaining = rawBuffer.count
            var offset = 0
            while bytesRemaining > 0 {
                let wrote = write(fileDescriptor, baseAddress.advanced(by: offset), bytesRemaining)
                guard wrote > 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                bytesRemaining -= wrote
                offset += wrote
            }
        }

        shutdown(fileDescriptor, SHUT_WR)

        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = read(fileDescriptor, &buffer, buffer.count)
            guard bytesRead >= 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if bytesRead == 0 {
                break
            }
            responseData.append(contentsOf: buffer.prefix(bytesRead))
        }

        let responseText = String(decoding: responseData, as: UTF8.self)
        let sections = responseText.components(separatedBy: "\r\n\r\n")
        let headerSection = sections.first ?? ""
        let body = sections.dropFirst().joined(separator: "\r\n\r\n")
        let headerLines = headerSection.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw POSIXError(.EBADMSG)
        }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw POSIXError(.EBADMSG)
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        return (status: status, headers: headers, body: body)
    }
}

private final class GatewayHarness {
    let port: Int
    let configStore: BurnBarConfigStore
    let usageRecorder: BurnBarUsageRecorder
    private let server: BurnBarHTTPGatewayServer

    init(
        authToken: String? = nil,
        rateLimit: BurnBarRateLimitConfiguration? = nil,
        catalog: BurnBarCatalog = BurnBarCatalogLoader.bundledCatalog,
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor(),
        factoryExecutor: FactoryDroidProviderExecutor = FactoryDroidProviderExecutor(),
        modelCatalogSession: URLSession = GatewayHarness.makeUpstreamSession()
    ) throws {
        self.port = try Self.reservePort()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-gateway-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        self.configStore = BurnBarConfigStore(
            fileURL: tempDirectory.appendingPathComponent("provider-config.json"),
            catalog: catalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )
        self.usageRecorder = BurnBarUsageRecorder(
            fileURL: tempDirectory.appendingPathComponent("usage-ledger.jsonl"),
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )
        let modelHealthStore = BurnBarGatewayModelHealthStore(
            fileURL: tempDirectory.appendingPathComponent("gateway-model-health.json")
        )

        self.server = BurnBarHTTPGatewayServer(
            configuration: BurnBarGatewayConfiguration(
                isEnabled: true,
                host: "127.0.0.1",
                port: port,
                authToken: authToken,
                rateLimit: rateLimit
            ),
            configStore: configStore,
            usageRecorder: usageRecorder,
            providerExecutor: providerExecutor,
            anthropicExecutor: anthropicExecutor,
            factoryExecutor: factoryExecutor,
            modelHealthStore: modelHealthStore,
            modelCatalogSession: modelCatalogSession,
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )
    }

    static func makeUpstreamSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GatewayUpstreamURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func configureZAIProviderForGateway() async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/v1",
                preferredModelIDs: ["glm-5-turbo"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-key"
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "backup",
            label: "Backup",
            apiKey: "backup-key"
        )
    }

    func configureAnthropicProviderForGateway() async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-sonnet-4-6-family"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "primary",
            label: "Primary",
            apiKey: "sk-ant-api03-primary-key"
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "backup",
            label: "Backup",
            apiKey: "sk-ant-api03-backup-key"
        )
    }

    func configureOllamaProviderForGateway() async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "ollama",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/api",
                preferredModelIDs: ["deepseek-v4-flash"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "ollama",
            slotID: "primary",
            label: "Primary",
            apiKey: "primary-ollama-key"
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "ollama",
            slotID: "backup",
            label: "Backup",
            apiKey: "backup-ollama-key"
        )
    }

    func configureFactoryProviderForGateway() async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "factory",
                isEnabled: true,
                baseURL: "factory-droid://local",
                preferredModelIDs: ["gpt-5.5", "glm-5.1"],
                preferredCredentialSlotID: "max"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "factory",
            slotID: "max",
            label: "Factory Max",
            apiKey: "fk-gateway"
        )
    }

    func start() async throws {
        try await server.start()
        try await Task.sleep(nanoseconds: 30_000_000)
    }

    func stop() async {
        await server.stop()
    }

    private static func reservePort() throws -> Int {
        let socketFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = 0x0100007F

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Darwin.getsockname(socketFD, rebound, &length)
            }
        }
        guard nameResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private struct GatewayUpstreamRequest: Hashable {
    let authorization: String?
    let path: String
    let query: String?
    let body: String
    let xApiKey: String?
    let anthropicVersion: String?
    let anthropicBeta: String?
    let userAgent: String?
    let xApp: String?
    let directBrowserAccess: String?
}

private final class GatewayUpstreamURLProtocol: URLProtocol {
    private struct Response {
        let status: Int
        let body: Data
        let delayNanoseconds: UInt64
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuedResponses: [Response] = []
    nonisolated(unsafe) private static var requests: [GatewayUpstreamRequest] = []

    static func enqueue(status: Int, body: String, delayNanoseconds: UInt64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses.append(Response(status: status, body: Data(body.utf8), delayNanoseconds: delayNanoseconds))
    }

    static func recordedRequests() -> [GatewayUpstreamRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses = []
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host == "gateway-upstream.test" || host == "ollama.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.queuedResponses.isEmpty
            ? Response(status: 500, body: Data(#"{"error":"missing fixture"}"#.utf8), delayNanoseconds: 0)
            : Self.queuedResponses.removeFirst()
        Self.requests.append(
            GatewayUpstreamRequest(
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                path: request.url?.path ?? "",
                query: request.url?.query,
                body: Self.bodyString(from: request),
                xApiKey: request.value(forHTTPHeaderField: "x-api-key"),
                anthropicVersion: request.value(forHTTPHeaderField: "anthropic-version"),
                anthropicBeta: request.value(forHTTPHeaderField: "anthropic-beta"),
                userAgent: request.value(forHTTPHeaderField: "User-Agent"),
                xApp: request.value(forHTTPHeaderField: "x-app"),
                directBrowserAccess: request.value(forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            )
        )
        Self.lock.unlock()

        if response.delayNanoseconds > 0 {
            Task {
                try? await Task.sleep(nanoseconds: response.delayNanoseconds)
                self.send(response)
            }
            return
        }
        send(response)
    }

    private func send(_ response: Response) {
        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyString(from request: URLRequest) -> String {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8) ?? ""
        }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
