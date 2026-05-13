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
            + "Content-Length: 1048577\r\n"
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

    func testGatewayProxiesChatCompletionsAndFailsOverExhaustedPlan() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
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
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session)
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
        XCTAssertEqual(upstreamRequests.count, 2)
        XCTAssertEqual(upstreamRequests[0].authorization, "Bearer primary-key")
        XCTAssertEqual(upstreamRequests[1].authorization, "Bearer backup-key")
        XCTAssertTrue(upstreamRequests.allSatisfy { $0.body.contains(#""model":"glm-5-turbo""#) })

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

    func testGatewayRoutesOllamaCloudThroughNativeAPIAndFailsOverSlots() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
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
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session)
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

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("ollama backup answered"))
        XCTAssertTrue(bodyText.contains(#""prompt_tokens":13"#))
        XCTAssertTrue(bodyText.contains(#""completion_tokens":5"#))

        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.count, 2)
        XCTAssertTrue(upstreamRequests.allSatisfy { $0.path == "/api/chat" })
        XCTAssertEqual(upstreamRequests[0].authorization, "Bearer primary-ollama-key")
        XCTAssertEqual(upstreamRequests[1].authorization, "Bearer backup-ollama-key")
        XCTAssertTrue(upstreamRequests.allSatisfy { $0.body.contains(#""model":"deepseek-v4-flash""#) })
        XCTAssertTrue(upstreamRequests.allSatisfy { !$0.body.contains(#""deepseek-v4-flash:cloud""#) })
        XCTAssertTrue(upstreamRequests.allSatisfy { $0.body.contains(#""think":"high""#) })
        XCTAssertTrue(upstreamRequests.allSatisfy { $0.body.contains(#""num_predict":64"#) })
        XCTAssertTrue(upstreamRequests.allSatisfy { !$0.body.contains("reasoning_effort") })
        XCTAssertTrue(upstreamRequests.allSatisfy { !$0.body.contains("stream_options") })

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
        // sk-ant-… credentials must travel as x-api-key, not Authorization.
        XCTAssertNil(upstreamRequests[0].authorization)
        XCTAssertEqual(upstreamRequests[0].xApiKey, "sk-ant-primary-key")
        XCTAssertEqual(upstreamRequests[0].anthropicVersion, "2023-06-01")
        XCTAssertTrue(upstreamRequests[0].body.contains(#""model":"claude-sonnet-4-6-family""#))

        let usage = try await harness.usageRecorder.recentUsage(limit: 5)
        XCTAssertEqual(usage.count, 1)
        XCTAssertEqual(usage[0].providerID, "anthropic")
        XCTAssertEqual(usage[0].inputTokens, 17)
        XCTAssertEqual(usage[0].outputTokens, 4)
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
        XCTAssertEqual(upstreamRequests[0].xApiKey, "sk-ant-primary-key")
        XCTAssertEqual(upstreamRequests[1].xApiKey, "sk-ant-backup-key")

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
        XCTAssertTrue(bodyText.contains("OpenAI-compatible"), "body was: \(bodyText)")
        XCTAssertTrue(bodyText.contains("chat") && bodyText.contains("completions"), "body was: \(bodyText)")

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
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session)
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
        XCTAssertEqual(upstreamRequests.count, 2, clientName)
        XCTAssertEqual(upstreamRequests[0].authorization, "Bearer primary-key", clientName)
        XCTAssertEqual(upstreamRequests[1].authorization, "Bearer backup-key", clientName)

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
        XCTAssertEqual(upstreamRequests[0].xApiKey, "sk-ant-primary-key", clientName)
        XCTAssertEqual(upstreamRequests[1].xApiKey, "sk-ant-backup-key", clientName)

        let snapshot = try await harness.configStore.snapshot()
        let slots = try XCTUnwrap(snapshot.providerSettings(id: "anthropic")?.credentialSlots)
        XCTAssertEqual(slots.first(where: { $0.slotID == "primary" })?.status, .exhausted, clientName)
        XCTAssertEqual(slots.first(where: { $0.slotID == "backup" })?.status, .ready, clientName)
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

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        return (httpResponse, responseData)
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
        providerExecutor: BurnBarOpenAICompatibleProviderExecutor = BurnBarOpenAICompatibleProviderExecutor(),
        anthropicExecutor: BurnBarAnthropicProviderExecutor = BurnBarAnthropicProviderExecutor()
    ) throws {
        self.port = try Self.reservePort()

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-gateway-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        self.configStore = BurnBarConfigStore(
            fileURL: tempDirectory.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )
        self.usageRecorder = BurnBarUsageRecorder(
            fileURL: tempDirectory.appendingPathComponent("usage-ledger.jsonl"),
            logger: BurnBarDaemonLogger(category: "gateway-tests")
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
            logger: BurnBarDaemonLogger(category: "gateway-tests")
        )
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
            apiKey: "sk-ant-primary-key"
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "backup",
            label: "Backup",
            apiKey: "sk-ant-backup-key"
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
    let body: String
    let xApiKey: String?
    let anthropicVersion: String?
}

private final class GatewayUpstreamURLProtocol: URLProtocol {
    private struct Response {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queuedResponses: [Response] = []
    nonisolated(unsafe) private static var requests: [GatewayUpstreamRequest] = []

    static func enqueue(status: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        queuedResponses.append(Response(status: status, body: Data(body.utf8)))
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
        request.url?.host == "gateway-upstream.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let response = Self.queuedResponses.isEmpty
            ? Response(status: 500, body: Data(#"{"error":"missing fixture"}"#.utf8))
            : Self.queuedResponses.removeFirst()
        Self.requests.append(
            GatewayUpstreamRequest(
                authorization: request.value(forHTTPHeaderField: "Authorization"),
                path: request.url?.path ?? "",
                body: Self.bodyString(from: request),
                xApiKey: request.value(forHTTPHeaderField: "x-api-key"),
                anthropicVersion: request.value(forHTTPHeaderField: "anthropic-version")
            )
        )
        Self.lock.unlock()

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
