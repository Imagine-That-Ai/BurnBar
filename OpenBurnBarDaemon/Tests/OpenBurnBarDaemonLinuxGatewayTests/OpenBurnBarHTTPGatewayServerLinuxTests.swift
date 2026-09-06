#if os(Linux)
import Foundation
import Glibc
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class OpenBurnBarHTTPGatewayServerLinuxTests: XCTestCase {
    func testStreamsChatCompletionsThroughConfiguredProviderAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer()
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        try await harness.start()

        let body = #"{"model":"glm-5-turbo","stream":true,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body,
            headers: ["Origin": "http://localhost:3000", "X-OpenBurnBar-Client": "cursor/1.0"]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        XCTAssertEqual(response.headers["access-control-allow-origin"], "http://localhost:3000")
        XCTAssertEqual(response.headers["vary"], "Origin")
        XCTAssertTrue(response.body.contains("data: {\"id\":\"chatcmpl-linux\""))
        XCTAssertTrue(response.body.contains("data: [DONE]"))

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/chat/completions")
        XCTAssertEqual(upstreamRequest.authorization, "Bearer primary-key")
        XCTAssertTrue(upstreamRequest.body.contains("\"model\":\"glm-5-turbo\""))

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "zai")
        XCTAssertEqual(event.modelID, "glm-5-turbo")
        XCTAssertEqual(event.inputTokens, 5)
        XCTAssertEqual(event.outputTokens, 5)
        XCTAssertEqual(event.cacheReadTokens, 2)
        XCTAssertEqual(event.cacheCreationTokens, 3)
        XCTAssertEqual(event.reasoningTokens, 1)
        XCTAssertEqual(event.executionSourceID, "cursor")
        XCTAssertEqual(event.executionSourceName, "Cursor")
        XCTAssertEqual(event.executionSourceKind, .ide)
        XCTAssertEqual(event.executionSourceConfidence, .exact)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/chat/completions")
        XCTAssertEqual(entry.providerID, "zai")
        XCTAssertEqual(entry.finalStatus, .exact)
        XCTAssertEqual(entry.httpStatus, 200)
        XCTAssertTrue(entry.streamed)

    }

    func testMidStreamUpstreamDropClosesWithoutSecondHTTPResponse() async throws {
        let upstream = LinuxMockOpenAIStreamServer(dropsAfterFirstChunk: true)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        try await harness.start()

        let body = #"{"model":"glm-5-turbo","stream":true,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        XCTAssertTrue(response.body.contains("data: {\"id\":\"chatcmpl-linux\""))
        XCTAssertFalse(response.body.contains("HTTP/1.1 "), "gateway must not append a second buffered HTTP response after streaming starts")
        XCTAssertEqual(response.rawText.components(separatedBy: "HTTP/1.1 ").count - 1, 1)

        // Parity with the macOS gateway: the client sees a terminal SSE error
        // event instead of a silent hang-up.
        XCTAssertTrue(response.body.contains("event: error"), response.body)
        XCTAssertTrue(response.body.contains("upstream stream interrupted"), response.body)

        // Producer → persisted: a committed stream that breaks mid-flight is
        // first-class `interrupted` — never `failed` — and flags the stream.
        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.finalStatus, .interrupted)
        XCTAssertTrue(entry.streamed)
        XCTAssertTrue(entry.streamInterrupted)
        XCTAssertEqual(entry.attempts.first?.status, .interrupted)
        XCTAssertFalse(entry.finalStatus.countsAgainstRouteHealth)
    }

    func testStreamsAnthropicChatCompletionsThroughMessagesTransformerAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer(response: .anthropicMessagesStream)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureAnthropicProvider(baseURL: "http://127.0.0.1:\(upstream.port)/anthropic/v1")
        try await harness.start()

        let body = #"{"model":"claude-sonnet-4-6","stream":true,"max_tokens":64,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "text/event-stream")
        XCTAssertTrue(response.body.contains(#""object":"chat.completion.chunk""#), response.body)
        XCTAssertTrue(response.body.contains(#""delta":{"role":"assistant"}"#), response.body)
        XCTAssertTrue(response.body.contains(#""content":"hello ""#), response.body)
        XCTAssertTrue(response.body.contains(#""tool_calls""#), response.body)
        XCTAssertTrue(response.body.contains(#""arguments":"{\"city\":\"Ch""#), response.body)
        XCTAssertTrue(response.body.contains(#""finish_reason":"tool_calls""#), response.body)
        XCTAssertTrue(response.body.contains("data: [DONE]"), response.body)
        XCTAssertFalse(response.body.contains("event: content_block_delta"), response.body)

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/anthropic/v1/messages")
        XCTAssertEqual(upstreamRequest.xApiKey, "sk-ant-api03-primary-key")
        XCTAssertTrue(upstreamRequest.body.contains(#""stream":true"#), upstreamRequest.body)
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"claude-sonnet-4-6""#), upstreamRequest.body)

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "anthropic")
        XCTAssertEqual(event.modelID, "claude-sonnet-4-6")
        XCTAssertEqual(event.inputTokens, 11)
        XCTAssertEqual(event.outputTokens, 8)
        XCTAssertEqual(event.cacheCreationTokens, 3)
        XCTAssertEqual(event.cacheReadTokens, 2)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/chat/completions")
        XCTAssertEqual(entry.endpoint, "Chat Completions")
        XCTAssertTrue(entry.streamed)
        XCTAssertEqual(entry.usage?.inputTokens, 11)
        XCTAssertEqual(entry.usage?.outputTokens, 8)
    }

    func testProxiesResponsesThroughConfiguredProviderAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer(response: .openAIResponsesJSON)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        try await harness.start()

        let body = #"{"model":"glm-5-turbo","input":"ping"}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/responses",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertTrue(response.body.contains(#""object":"response""#), response.body)
        XCTAssertTrue(response.body.contains("response from linux"), response.body)

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/v1/responses")
        XCTAssertEqual(upstreamRequest.authorization, "Bearer primary-key")
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"glm-5-turbo""#), upstreamRequest.body)

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "zai")
        XCTAssertEqual(event.inputTokens, 13)
        XCTAssertEqual(event.outputTokens, 7)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/responses")
        XCTAssertEqual(entry.endpoint, "Responses")
        XCTAssertFalse(entry.streamed)
    }

    func testProxiesAnthropicMessagesThroughConfiguredProviderAndRecordsUsage() async throws {
        let upstream = LinuxMockOpenAIStreamServer(response: .anthropicMessagesJSON)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureAnthropicProvider(baseURL: "http://127.0.0.1:\(upstream.port)/anthropic/v1")
        try await harness.start()

        let body = #"{"model":"claude-sonnet-4-6","max_tokens":64,"messages":[{"role":"user","content":"ping"}]}"#
        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/messages",
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.headers["content-type"], "application/json")
        XCTAssertTrue(response.body.contains(#""type":"message""#), response.body)
        XCTAssertTrue(response.body.contains("anthropic linux"), response.body)

        let upstreamRequest = try XCTUnwrap(upstream.recordedRequests.first)
        XCTAssertEqual(upstreamRequest.path, "/anthropic/v1/messages")
        XCTAssertEqual(upstreamRequest.xApiKey, "sk-ant-api03-primary-key")
        XCTAssertTrue(upstreamRequest.body.contains(#""model":"claude-sonnet-4-6""#), upstreamRequest.body)

        let usage = try await harness.usageRecorder.recentUsage(limit: 1)
        let event = try XCTUnwrap(usage.first)
        XCTAssertEqual(event.providerID, "anthropic")
        XCTAssertEqual(event.inputTokens, 17)
        XCTAssertEqual(event.outputTokens, 4)

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 1)
        let entry = try XCTUnwrap(routeLog.first)
        XCTAssertEqual(entry.requestPath, "/v1/messages")
        XCTAssertEqual(entry.endpoint, "Anthropic Messages")
        XCTAssertFalse(entry.streamed)
    }

    func testRejectsMalformedChatCompletionsRequestBeforeRouting() async throws {
        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.start()

        let response = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: #"{"stream":true}"#
        )

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(response.body.contains("model field required"))
        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 10)
        XCTAssertTrue(routeLog.isEmpty)
    }

    func testModelsCatalogIncludesBaseVariantAliasAndCustomRows() async throws {
        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:1/v1")
        try await harness.configureModelRows()
        try await harness.start()

        let catalog = try await LinuxHTTPClient.get(port: harness.port, path: "/v1/models/catalog")
        XCTAssertEqual(catalog.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(catalog.body.utf8)) as? [String: Any])
        let rows = try XCTUnwrap(object["data"] as? [[String: Any]])
        let ids = Set(rows.compactMap { $0["id"] as? String })
        XCTAssertTrue(ids.contains("glm-5-turbo"), catalog.body)
        XCTAssertTrue(ids.contains("glm-5-turbo-high"), catalog.body)
        XCTAssertTrue(ids.contains("team-default"), catalog.body)
        XCTAssertTrue(ids.contains("custom-linux-model"), catalog.body)

        let publicModels = try await LinuxHTTPClient.get(port: harness.port, path: "/v1/models")
        XCTAssertEqual(publicModels.statusCode, 200)
        XCTAssertTrue(publicModels.body.contains("glm-5-turbo-high"))
        XCTAssertTrue(publicModels.body.contains("team-default"))
    }

    func testFailoverRecordsModelHealthAndSkipsCoolingRoute() async throws {
        let upstream = LinuxMockOpenAIStreamServer(response: .openAIChatPrimary429)
        try upstream.start()
        defer { upstream.stop() }

        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.configureZAIProvider(baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        try await harness.configureSecondaryZAICredential()
        try await harness.start()

        let body = #"{"model":"glm-5-turbo","messages":[{"role":"user","content":"ping"}]}"#
        let first = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body
        )
        XCTAssertEqual(first.statusCode, 200, first.body)
        let firstRequests = upstream.recordedRequests
        XCTAssertGreaterThanOrEqual(firstRequests.count, 2)
        XCTAssertEqual(firstRequests[0].authorization, "Bearer primary-key")
        XCTAssertEqual(firstRequests[1].authorization, "Bearer secondary-key")

        let failure = await harness.modelHealthStore.activeFailure(
            modelID: "glm-5-turbo",
            providerID: "zai",
            accountID: "primary",
            formatFamily: .openaiCompat
        )
        XCTAssertEqual(failure?.statusCode, 429)
        XCTAssertNotNil(failure?.blockedUntil)

        let second = try await LinuxHTTPClient.post(
            port: harness.port,
            path: "/v1/chat/completions",
            body: body
        )
        XCTAssertEqual(second.statusCode, 200, second.body)
        let secondRequests = upstream.recordedRequests
        XCTAssertEqual(secondRequests.last?.authorization, "Bearer secondary-key")
    }

    func testMalformedAndOversizedHTTPFramesFailWithTypedResponses() async throws {
        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.start()

        let oversized = try await LinuxHTTPClient.raw(
            port: harness.port,
            request: "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 16777217\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(oversized.statusCode, 413, oversized.rawText)
        XCTAssertTrue(oversized.body.contains("request_too_large"), oversized.body)

        let chunked = try await LinuxHTTPClient.raw(
            port: harness.port,
            request: "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n0\r\n\r\n"
        )
        XCTAssertEqual(chunked.statusCode, 501, chunked.rawText)
        XCTAssertTrue(chunked.body.contains("unsupported_transfer_encoding"), chunked.body)

        let incomplete = try await LinuxHTTPClient.raw(
            port: harness.port,
            request: "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 20\r\nConnection: close\r\n\r\n{}"
        )
        XCTAssertEqual(incomplete.statusCode, 400, incomplete.rawText)
        XCTAssertTrue(incomplete.body.contains("incomplete_request"), incomplete.body)
    }

    func testGatewayCORSAllowsLoopbackOriginsOnlyAndHandlesPreflight() async throws {
        let harness = try LinuxGatewayHarness()
        addTeardownBlock { await harness.stop() }
        try await harness.start()

        let allowed = try await LinuxHTTPClient.raw(
            port: harness.port,
            request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://localhost:3000\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(allowed.statusCode, 200, allowed.rawText)
        XCTAssertEqual(allowed.headers["access-control-allow-origin"], "http://localhost:3000")
        XCTAssertEqual(allowed.headers["access-control-allow-methods"], "GET, POST, OPTIONS")
        XCTAssertEqual(allowed.headers["access-control-allow-headers"], "Authorization, Content-Type, x-api-key")
        XCTAssertEqual(allowed.headers["vary"], "Origin")

        let ipv6Origin = try await LinuxHTTPClient.raw(
            port: harness.port,
            request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://[::1]:3000\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(ipv6Origin.statusCode, 200, ipv6Origin.rawText)
        XCTAssertEqual(ipv6Origin.headers["access-control-allow-origin"], "http://[::1]:3000")

        let blocked = try await LinuxHTTPClient.raw(
            port: harness.port,
            request: "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example.com\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(blocked.statusCode, 200, blocked.rawText)
        XCTAssertNil(blocked.headers["access-control-allow-origin"])

        let preflight = try await LinuxHTTPClient.raw(
            port: harness.port,
            request: "OPTIONS /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: http://127.0.0.1:5173\r\nAccess-Control-Request-Method: POST\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(preflight.statusCode, 204, preflight.rawText)
        XCTAssertEqual(preflight.headers["access-control-allow-origin"], "http://127.0.0.1:5173")
        XCTAssertEqual(preflight.headers["access-control-allow-methods"], "GET, POST, OPTIONS")
    }

    func testBindsIPv6LoopbackWhenAvailable() async throws {
        do {
            let harness = try LinuxGatewayHarness(host: "::1")
            addTeardownBlock { await harness.stop() }
            try await harness.start()

            let response = try await LinuxHTTPClient.get(
                host: "::1",
                port: harness.port,
                path: "/health"
            )
            XCTAssertEqual(response.statusCode, 200, response.rawText)
            XCTAssertTrue(response.body.contains(#""platform":"linux""#), response.body)
        } catch {
            // Some minimal/containerized Linux images disable IPv6 entirely.
            // That is an environment limitation, not a gateway regression.
            if LinuxSocketSupport.isIPv6Unavailable(error) {
                throw XCTSkip("IPv6 loopback is unavailable in this Linux environment: \(error)")
            }
            throw error
        }
    }
}

final class LinuxGatewayHarness: @unchecked Sendable {
    private let host: String
    let port: Int
    let usageRecorder: BurnBarUsageRecorder
    let proxyRouteLogStore: BurnBarProxyRouteLogStore
    let modelHealthStore: BurnBarGatewayModelHealthStore
    let configStore: BurnBarConfigStore
    private let server: BurnBarHTTPGatewayServer
    private let tempDirectory: URL

    init(
        host: String = "127.0.0.1",
        authToken: String? = nil,
        memoryEgress: ((BurnBarConfigStore, BurnBarUsageRecorder) -> BurnBarMemoryEgressEnforcer)? = nil
    ) throws {
        self.host = host
        self.port = try LinuxSocketSupport.reserveLoopbackPort(host: host)
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-gateway-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        configStore = BurnBarConfigStore(
            fileURL: tempDirectory.appendingPathComponent("provider-config.json"),
            catalog: BurnBarCatalogLoader.bundledCatalog,
            secretStore: BurnBarInMemorySecretStore(),
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
        usageRecorder = BurnBarUsageRecorder(
            fileURL: tempDirectory.appendingPathComponent("usage-ledger.jsonl"),
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
        proxyRouteLogStore = BurnBarProxyRouteLogStore(
            fileURL: tempDirectory.appendingPathComponent("proxy-route-events.jsonl"),
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
        modelHealthStore = BurnBarGatewayModelHealthStore(
            fileURL: tempDirectory.appendingPathComponent("model-health.json"),
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests")
        )
        server = BurnBarHTTPGatewayServer(
            configuration: BurnBarGatewayConfiguration(
                isEnabled: true,
                host: host,
                port: port,
                authToken: authToken,
                allowUnauthenticatedLoopback: authToken == nil
            ),
            configStore: configStore,
            usageRecorder: usageRecorder,
            proxyRouteLogStore: proxyRouteLogStore,
            modelHealthStore: modelHealthStore,
            logger: BurnBarDaemonLogger(category: "linux-gateway-tests"),
            memoryEgress: memoryEgress?(configStore, usageRecorder)
        )
    }

    func configureZAIProvider(baseURL: String) async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "zai",
                isEnabled: true,
                baseURL: baseURL,
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
    }

    func configureAnthropicProvider(baseURL: String) async throws {
        _ = try await configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: baseURL,
                preferredModelIDs: ["claude-sonnet-4-6"],
                preferredCredentialSlotID: "primary"
            )
        )
        _ = try await configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "primary",
            label: "Primary",
            apiKey: "sk-ant-api03-primary-key"
        )
    }

    func configureSecondaryZAICredential() async throws {
        _ = try await configStore.upsertCredentialSlot(
            providerID: "zai",
            slotID: "secondary",
            label: "Secondary",
            apiKey: "secondary-key"
        )
    }

    func configureModelRows() async throws {
        var snapshot = try await configStore.snapshot()
        guard var provider = snapshot.providers.first(where: { $0.providerID == "zai" }) else {
            XCTFail("zai provider missing")
            return
        }
        provider.modelVariants = [BurnBarModelVariant(
            variantID: "glm-5-turbo-high",
            label: "GLM High",
            baseModelID: "glm-5-turbo",
            thinkingLevel: .high
        )]
        provider.modelAliases = [BurnBarModelAlias(
            aliasID: "team-default",
            baseModelID: "glm-5-turbo",
            displayName: "Team Default"
        )]
        provider.customModels = [BurnBarCustomModel(modelID: "custom-linux-model", displayName: "Custom Linux")]
        snapshot.providers = [provider]
        try await configStore.replaceSnapshot(snapshot)
    }

    func start() async throws {
        try await server.start()
        try await LinuxSocketSupport.waitForListener(port: port, host: host)
    }

    func stop() async {
        await server.stop()
        try? FileManager.default.removeItem(at: tempDirectory)
    }
}

final class LinuxMockOpenAIStreamServer: @unchecked Sendable {
    struct Request: Sendable {
        let path: String
        let authorization: String?
        let xApiKey: String?
        let body: String
    }

    enum Response: Sendable {
        case openAIChatStream
        case openAIChatJSON
        case openAIChatUpstream500
        case openAIChatPrimary429
        case openAIResponsesJSON
        case anthropicMessagesJSON
        case anthropicMessagesStream
    }

    private let lock = NSLock()
    private var requests: [Request] = []
    private var listenFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private(set) var port: Int = 0
    private let dropsAfterFirstChunk: Bool
    private let response: Response

    init(dropsAfterFirstChunk: Bool = false, response: Response = .openAIChatStream) {
        self.dropsAfterFirstChunk = dropsAfterFirstChunk
        self.response = response
    }

    var recordedRequests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func start() throws {
        let socketFD = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var one: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x0100007F).littleEndian

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
            }
        }
        guard bindResult == 0 else {
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                Glibc.getsockname(socketFD, rebound, &boundLength)
            }
        }
        guard nameResult == 0 else {
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        port = Int(UInt16(bigEndian: boundAddress.sin_port))

        guard Glibc.listen(socketFD, SOMAXCONN) == 0 else {
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        listenFD = socketFD
        acceptTask = Task.detached(priority: .utility) { [weak self] in
            self?.acceptLoop(socketFD: socketFD)
        }
    }

    func stop() {
        acceptTask?.cancel()
        if listenFD >= 0 {
            // `close` alone does not wake a thread blocked in `accept` on
            // Linux; the blocked cooperative-pool worker would then starve
            // XCTest's async teardown blocks. Shut the socket down first, as
            // the gateway does.
            _ = Glibc.shutdown(listenFD, Int32(SHUT_RDWR))
            Glibc.close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop(socketFD: Int32) {
        while !Task.isCancelled {
            var address = sockaddr()
            var addressLength = socklen_t(MemoryLayout<sockaddr>.stride)
            let clientFD = Glibc.accept(socketFD, &address, &addressLength)
            guard clientFD >= 0 else { return }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { Glibc.close(clientFD) }

        guard let requestText = try? LinuxSocketSupport.readHTTPRequest(from: clientFD) else { return }
        let request = Self.parseRequest(requestText)
        lock.lock()
        requests.append(request)
        lock.unlock()

        switch response {
        case .openAIChatStream:
            let firstChunk = #"data: {"id":"chatcmpl-linux","object":"chat.completion.chunk","created":1783200000,"model":"glm-5-turbo","choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":null}]}"# + "\n\n"
            let truncationHeader = dropsAfterFirstChunk
                ? "Content-Length: \(firstChunk.utf8.count + 1_024)\r\n"
                : ""
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\n"
                + truncationHeader
                + "Connection: close\r\n"
                + "\r\n"
            _ = try? LinuxSocketSupport.sendAll(Data(head.utf8), to: clientFD)

            if dropsAfterFirstChunk {
                _ = try? LinuxSocketSupport.sendAll(Data(firstChunk.utf8), to: clientFD)
                var resetOnClose = linger(l_onoff: 1, l_linger: 0)
                _ = withUnsafePointer(to: &resetOnClose) { pointer in
                    Glibc.setsockopt(
                        clientFD,
                        SOL_SOCKET,
                        SO_LINGER,
                        pointer,
                        socklen_t(MemoryLayout<linger>.size)
                    )
                }
                return
            }
            _ = try? LinuxSocketSupport.sendAll(Data(firstChunk.utf8), to: clientFD)
            Glibc.usleep(50_000)
            let usageChunk = #"data: {"id":"chatcmpl-linux","object":"chat.completion.chunk","created":1783200000,"model":"glm-5-turbo","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"#
                + #""usage":{"prompt_tokens":7,"completion_tokens":5,"total_tokens":12,"cache_creation_input_tokens":3,"prompt_tokens_details":{"cached_tokens":2},"completion_tokens_details":{"reasoning_tokens":1}}}"# + "\n\n"
            _ = try? LinuxSocketSupport.sendAll(Data(usageChunk.utf8), to: clientFD)
            _ = try? LinuxSocketSupport.sendAll(Data("data: [DONE]\n\n".utf8), to: clientFD)
        case .openAIChatJSON:
            sendJSON(
                #"{"id":"chatcmpl-linux-json","object":"chat.completion","model":"glm-5-turbo","choices":[{"index":0,"message":{"role":"assistant","content":"{\"facts\":[]}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":4,"total_tokens":16}}"#,
                status: 200,
                to: clientFD
            )
        case .openAIChatUpstream500:
            sendJSON(#"{"error":{"message":"boom"}}"#, status: 500, to: clientFD)
        case .openAIChatPrimary429:
            if request.authorization == "Bearer primary-key" {
                sendJSON(
                    #"{"error":{"message":"rate limit"}}"#,
                    status: 429,
                    to: clientFD
                )
            } else {
                sendJSON(
                    #"{"id":"chatcmpl-secondary","object":"chat.completion","model":"glm-5-turbo","choices":[{"index":0,"message":{"role":"assistant","content":"secondary"},"finish_reason":"stop"}]}"#,
                    status: 200,
                    to: clientFD
                )
            }
        case .openAIResponsesJSON:
            sendJSON(
                """
                {"id":"resp_linux","object":"response","created_at":1783200000,"status":"completed","model":"glm-5-turbo",\
                "output":[{"id":"msg_linux","type":"message","status":"completed","role":"assistant","content":[{"type":"output_text","text":"response from linux","annotations":[]}]}],\
                "output_text":"response from linux","usage":{"input_tokens":13,"output_tokens":7,"total_tokens":20}}
                """,
                to: clientFD
            )
        case .anthropicMessagesJSON:
            sendJSON(
                """
                {"id":"msg_linux","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"anthropic linux"}],\
                "stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":17,"output_tokens":4,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
                """,
                to: clientFD
            )
        case .anthropicMessagesStream:
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + "Cache-Control: no-cache\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            _ = try? LinuxSocketSupport.sendAll(Data(head.utf8), to: clientFD)
            let chunks = [
                #"""
event: message_start
data: {"type":"message_start","message":{"id":"msg_stream","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[],"usage":{"input_tokens":11,"output_tokens":0,"cache_creation_input_tokens":3,"cache_read_input_tokens":2}}}

"""# + "\n",
                #"""
event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello "}}

"""# + "\n",
                #"""
event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_linux","name":"get_weather","input":{}}}

"""# + "\n",
                #"""
event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Ch"}}

"""# + "\n",
                #"""
event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"icago\"}"}}

"""# + "\n",
                #"""
event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":8}}

"""# + "\n",
                #"""
event: message_stop
data: {"type":"message_stop"}

"""# + "\n"
            ]
            for chunk in chunks {
                _ = try? LinuxSocketSupport.sendAll(Data(chunk.utf8), to: clientFD)
                Glibc.usleep(10_000)
            }
        }
    }

    private static func parseRequest(_ raw: String) -> Request {
        let sections = raw.components(separatedBy: "\r\n\r\n")
        let headerLines = sections.first?.components(separatedBy: "\r\n") ?? []
        let requestLine = headerLines.first?.split(separator: " ") ?? []
        let path = requestLine.count > 1 ? String(requestLine[1]) : ""
        let authorization = headerLines.first { $0.lowercased().hasPrefix("authorization:") }
            .map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
        let xApiKey = headerLines.first { $0.lowercased().hasPrefix("x-api-key:") }
            .map { $0.dropFirst("x-api-key:".count).trimmingCharacters(in: .whitespaces) }
        return Request(
            path: path,
            authorization: authorization,
            xApiKey: xApiKey,
            body: sections.dropFirst().joined(separator: "\r\n\r\n")
        )
    }

    private func sendJSON(_ body: String, status: Int = 200, to clientFD: Int32) {
        let data = Data(body.utf8)
        let reason: String
        switch status {
        case 429: reason = "Too Many Requests"
        case 500: reason = "Internal Server Error"
        default: reason = "OK"
        }
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        _ = try? LinuxSocketSupport.sendAll(Data(head.utf8), to: clientFD)
        _ = try? LinuxSocketSupport.sendAll(data, to: clientFD)
    }
}

enum LinuxHTTPClient {
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: String
        let rawText: String
    }

    static func post(
        host: String = "127.0.0.1",
        port: Int,
        path: String,
        body: String,
        headers: [String: String] = [:]
    ) async throws -> Response {
        try await request(
            method: "POST",
            host: host,
            port: port,
            path: path,
            headers: headers.merging([
                "Content-Type": "application/json",
                "Content-Length": "\(body.utf8.count)"
            ]) { _, requestHeader in requestHeader },
            body: body
        )
    }

    static func get(host: String = "127.0.0.1", port: Int, path: String) async throws -> Response {
        try await request(method: "GET", host: host, port: port, path: path, headers: [:], body: "")
    }

    static func raw(host: String = "127.0.0.1", port: Int, request: String) async throws -> Response {
        try await Task.detached(priority: .utility) {
            let socketFD = try LinuxSocketSupport.connectToLoopback(port: port, host: host)
            defer { Glibc.close(socketFD) }
            try LinuxSocketSupport.sendAll(Data(request.utf8), to: socketFD)
            // Signal end-of-request explicitly so malformed Content-Length
            // frames fail immediately instead of waiting for the gateway's
            // production receive timeout before it can return the typed error.
            guard Glibc.shutdown(socketFD, Int32(SHUT_WR)) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            return try parseResponse(try LinuxSocketSupport.readUntilEOF(from: socketFD))
        }.value
    }

    private static func request(
        method: String,
        host: String,
        port: Int,
        path: String,
        headers: [String: String],
        body: String
    ) async throws -> Response {
        try await Task.detached(priority: .utility) {
            let socketFD = try LinuxSocketSupport.connectToLoopback(port: port, host: host)
            defer { Glibc.close(socketFD) }
            let hostHeader = host == "::1" ? "[::1]:\(port)" : "\(host):\(port)"
            var request = "\(method) \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\n"
            for (name, value) in headers {
                request += "\(name): \(value)\r\n"
            }
            request += "Connection: close\r\n\r\n\(body)"
            try LinuxSocketSupport.sendAll(Data(request.utf8), to: socketFD)
            return try parseResponse(try LinuxSocketSupport.readUntilEOF(from: socketFD))
        }.value
    }

    private static func parseResponse(_ raw: Data) throws -> Response {
        let text = String(decoding: raw, as: UTF8.self)
        let parts = text.components(separatedBy: "\r\n\r\n")
        let headerText = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\r\n\r\n")
        let lines = headerText.components(separatedBy: "\r\n")
        let statusCode = Int(lines.first?.split(separator: " ").dropFirst().first ?? "") ?? 0
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[String(name)] = value
        }
        return Response(statusCode: statusCode, headers: headers, body: body, rawText: text)
    }
}

enum LinuxSocketSupport {
    static func reserveLoopbackPort(host: String = "127.0.0.1") throws -> Int {
        let isIPv6 = host == "::1"
        let socketFD = Glibc.socket(isIPv6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { Glibc.close(socketFD) }

        let bindResult: Int32
        if isIPv6 {
            var v6Only: Int32 = 1
            guard setsockopt(
                socketFD,
                Int32(IPPROTO_IPV6),
                IPV6_V6ONLY,
                &v6Only,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = 0
            guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
                throw POSIXError(.EINVAL)
            }
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Glibc.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in6>.stride))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr.s_addr = UInt32(0x0100007F).littleEndian
            bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Glibc.bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let boundPort: UInt16
        if isIPv6 {
            var boundAddress = sockaddr_in6()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.stride)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Glibc.getsockname(socketFD, rebound, &boundLength)
                }
            }
            guard nameResult == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            boundPort = boundAddress.sin6_port
        } else {
            var boundAddress = sockaddr_in()
            var boundLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
            let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Glibc.getsockname(socketFD, rebound, &boundLength)
                }
            }
            guard nameResult == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            boundPort = boundAddress.sin_port
        }
        return Int(UInt16(bigEndian: boundPort))
    }

    static func waitForListener(port: Int, host: String = "127.0.0.1") async throws {
        var lastError: Error?
        for _ in 0..<250 {
            do {
                let socketFD = try connectToLoopback(port: port, host: host)
                Glibc.close(socketFD)
                return
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw lastError ?? POSIXError(.ETIMEDOUT)
    }

    static func connectToLoopback(port: Int, host: String = "127.0.0.1") throws -> Int32 {
        let isIPv6 = host == "::1"
        let socketFD = Glibc.socket(isIPv6 ? AF_INET6 : AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        guard socketFD >= 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        let connectResult: Int32
        if isIPv6 {
            var address = sockaddr_in6()
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(port).bigEndian
            guard inet_pton(AF_INET6, "::1", &address.sin6_addr) == 1 else {
                Glibc.close(socketFD)
                throw POSIXError(.EINVAL)
            }
            connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Glibc.connect(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in6>.stride))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(port).bigEndian
            address.sin_addr.s_addr = UInt32(0x0100007F).littleEndian
            connectResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                    Glibc.connect(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
        }
        guard connectResult == 0 else {
            let code = errno
            Glibc.close(socketFD)
            throw POSIXError(.init(rawValue: code) ?? .ECONNREFUSED)
        }
        return socketFD
    }

    static func isIPv6Unavailable(_ error: Error) -> Bool {
        if let gatewayError = error as? BurnBarHTTPGatewayError,
           case let .listenerCreationFailed(underlying) = gatewayError {
            return isIPv6Unavailable(underlying)
        }
        guard let posixError = error as? POSIXError else { return false }
        let unavailableCodes: [Int32] = [EAFNOSUPPORT, EADDRNOTAVAIL, ENODEV, ENETUNREACH, EPROTONOSUPPORT]
        return unavailableCodes.contains(posixError.code.rawValue)
    }

    static func readHTTPRequest(from socketFD: Int32) throws -> String {
        var data = Data()
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let chunk = try recvChunk(from: socketFD)
            if chunk.isEmpty { break }
            data.append(chunk)
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
        }

        let headerText = String(decoding: data, as: UTF8.self)
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let currentBodyCount: Int
        if let headerEnd {
            currentBodyCount = data.distance(from: headerEnd.upperBound, to: data.endIndex)
        } else {
            currentBodyCount = 0
        }
        var remaining = max(contentLength - currentBodyCount, 0)
        while remaining > 0 {
            let chunk = try recvChunk(from: socketFD)
            if chunk.isEmpty { break }
            data.append(chunk)
            remaining -= chunk.count
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func readUntilEOF(from socketFD: Int32) throws -> Data {
        var data = Data()
        while true {
            let chunk = try recvChunk(from: socketFD)
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
    }

    static func sendAll(_ data: Data, to socketFD: Int32) throws {
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return -1 }
                return Glibc.send(socketFD, base.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
            }
            guard sent > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            offset += sent
        }
    }

    private static func recvChunk(from socketFD: Int32) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Glibc.recv(socketFD, &buffer, buffer.count, 0)
        if count < 0 {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        if count == 0 {
            return Data()
        }
        return Data(buffer.prefix(count))
    }
}

#else
import XCTest

final class OpenBurnBarHTTPGatewayServerLinuxTests: XCTestCase {
    func testLinuxGatewayCoverageRunsInDocker() throws {
        throw XCTSkip("Linux-only gateway parity coverage runs in the Docker toolchain.")
    }
}
#endif
