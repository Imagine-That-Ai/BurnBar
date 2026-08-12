@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class OllamaCloudDynamicRoutingGatewayTests: XCTestCase {
    override func setUp() {
        GatewayUpstreamURLProtocol.reset()
        super.setUp()
    }

    override func tearDown() {
        GatewayUpstreamURLProtocol.reset()
        super.tearDown()
    }

    func testGatewayRoutesLiveDiscoveredModelWithoutStaticConfiguration() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            <html><body><ol>
            <li x-test-model><a href="/library/glm-5.2"><span>glm-5.2</span><span>cloud</span></a></li>
            <li x-test-model><a href="/library/gemini-3-flash-preview"><span>gemini-3-flash-preview</span><span>cloud</span></a></li>
            </ol></body></html>
            """,
            path: "/search"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "gemini-3-flash-preview",
              "created_at": "2026-07-19T00:00:00Z",
              "message": {"role": "assistant", "content": "live discovered model answered"},
              "done": true,
              "done_reason": "stop",
              "prompt_eval_count": 7,
              "eval_count": 5
            }
            """,
            path: "/api/chat"
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session,
            modelCatalogCacheTTL: 600
        )
        try await harness.configureOllamaProviderForGateway(preferredModelIDs: ["glm-5.2"])
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (modelsResponse, modelsBody) = try await sendRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(modelsResponse.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBody) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        XCTAssertTrue(data.contains {
            ($0["id"] as? String) == "gemini-3-flash-preview:cloud"
                && ($0["provider_id"] as? String) == "ollama"
                && ($0["route_eligible"] as? Bool) == true
        })

        let (chatResponse, chatBody) = try await sendRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            body: Data(
                #"{"model":"gemini-3-flash-preview:cloud","messages":[{"role":"user","content":"hello"}],"stream":false}"#.utf8
            )
        )

        XCTAssertEqual(chatResponse.statusCode, 200, String(decoding: chatBody, as: UTF8.self))
        XCTAssertTrue(String(decoding: chatBody, as: UTF8.self).contains("live discovered model answered"))
        let upstreamRequests = GatewayUpstreamURLProtocol.recordedRequests()
        XCTAssertEqual(upstreamRequests.map(\.path), ["/search", "/api/chat"])
        XCTAssertEqual(upstreamRequests.last?.body.contains(#""model":"gemini-3-flash-preview""#), true)
        XCTAssertEqual(upstreamRequests.last?.body.contains(#""gemini-3-flash-preview:cloud""#), false)
        XCTAssertEqual(upstreamRequests.last?.authorization, "Bearer primary-ollama-key")
    }

    func testGatewayStopsAdvertisingRetiredDiscoveredModelButKeepsSibling() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            <html><body><ol>
            <li x-test-model><a href="/library/glm-5.2"><span>glm-5.2</span><span>cloud</span></a></li>
            <li x-test-model><a href="/library/gemini-3-flash-preview"><span>gemini-3-flash-preview</span><span>cloud</span></a></li>
            </ol></body></html>
            """,
            path: "/search"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 410,
            body: #"{"error":"gemini-3-flash-preview was retired"}"#,
            path: "/api/chat"
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session,
            modelCatalogCacheTTL: 600
        )
        try await harness.configureOllamaProviderForGateway(preferredModelIDs: ["glm-5.2"])
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (_, initialModelsBody) = try await sendRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(try advertisedModelIDs(in: initialModelsBody), [
            "gemini-3-flash-preview:cloud",
            "glm-5.2:cloud"
        ])

        let (chatResponse, chatBody) = try await sendRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            body: Data(
                #"{"model":"gemini-3-flash-preview:cloud","messages":[{"role":"user","content":"hello"}],"stream":false}"#.utf8
            )
        )
        XCTAssertEqual(chatResponse.statusCode, 410, String(decoding: chatBody, as: UTF8.self))

        let (_, recoveredModelsBody) = try await sendRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        let recoveredModelIDs = try advertisedModelIDs(in: recoveredModelsBody)
        XCTAssertFalse(recoveredModelIDs.contains("gemini-3-flash-preview:cloud"))
        XCTAssertTrue(recoveredModelIDs.contains("glm-5.2:cloud"))
        let recordedPaths = GatewayUpstreamURLProtocol.recordedRequests().map(\.path)
        XCTAssertEqual(recordedPaths.filter { $0 == "/api/chat" }, ["/api/chat"])
    }

    func testElderWandStopsAdvertisingRetiredPanelModelButKeepsSibling() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            <html><body><ol>
            <li x-test-model><a href="/library/glm-5.2"><span>glm-5.2</span><span>cloud</span></a></li>
            <li x-test-model><a href="/library/gemini-3-flash-preview"><span>gemini-3-flash-preview</span><span>cloud</span></a></li>
            </ol></body></html>
            """,
            path: "/search"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 410,
            body: #"{"error":"gemini-3-flash-preview was retired"}"#,
            path: "/api/chat"
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session,
            modelCatalogCacheTTL: 600
        )
        try await harness.configureOllamaProviderForGateway(preferredModelIDs: ["glm-5.2"])
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (_, initialModelsBody) = try await sendRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(try advertisedModelIDs(in: initialModelsBody), [
            "gemini-3-flash-preview:cloud",
            "glm-5.2:cloud"
        ])

        let fusionRequest = Data(
            """
            {
              "model": "glm-5.2:cloud",
              "messages": [{"role": "user", "content": "compare the options"}],
              "stream": false,
              "plugins": [{
                "id": "fusion",
                "enabled": true,
                "analysis_models": ["gemini-3-flash-preview:cloud"],
                "model": "glm-5.2:cloud",
                "max_tool_calls": 1
              }]
            }
            """.utf8
        )
        let (fusionResponse, fusionBody) = try await sendRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            body: fusionRequest
        )
        XCTAssertEqual(fusionResponse.statusCode, 502, String(decoding: fusionBody, as: UTF8.self))

        let (_, recoveredModelsBody) = try await sendRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        let recoveredModelIDs = try advertisedModelIDs(in: recoveredModelsBody)
        XCTAssertFalse(recoveredModelIDs.contains("gemini-3-flash-preview:cloud"))
        XCTAssertTrue(recoveredModelIDs.contains("glm-5.2:cloud"))
        let recordedPaths = GatewayUpstreamURLProtocol.recordedRequests().map(\.path)
        XCTAssertEqual(recordedPaths.filter { $0 == "/api/chat" }, ["/api/chat"])
    }

    func testElderWandMarksRejectedCredentialUnavailable() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            <html><body><ol>
            <li x-test-model><a href="/library/glm-5.2"><span>glm-5.2</span><span>cloud</span></a></li>
            </ol></body></html>
            """,
            path: "/search"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 401,
            body: #"{"error":"invalid api key"}"#,
            path: "/api/chat"
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session,
            modelCatalogCacheTTL: 600
        )
        try await harness.configureOllamaProviderForGateway(preferredModelIDs: ["glm-5.2"])
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let fusionRequest = Data(
            """
            {
              "model": "glm-5.2:cloud",
              "messages": [{"role": "user", "content": "compare the options"}],
              "stream": false,
              "plugins": [{
                "id": "fusion",
                "analysis_models": ["glm-5.2:cloud"],
                "model": "glm-5.2:cloud",
                "max_tool_calls": 1
              }]
            }
            """.utf8
        )
        let (fusionResponse, fusionBody) = try await sendRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            body: fusionRequest
        )
        XCTAssertEqual(fusionResponse.statusCode, 502, String(decoding: fusionBody, as: UTF8.self))

        let snapshot = try await harness.configStore.snapshot()
        let primaryStatus = snapshot.providerSettings(id: "ollama")?
            .credentialSlots.first(where: { $0.slotID == "primary" })?.status
        XCTAssertEqual(primaryStatus, .missingSecret)
        XCTAssertEqual(GatewayUpstreamURLProtocol.recordedRequests().map(\.path), ["/search", "/api/chat"])
    }

    func testElderWandRecordsAttributedFailureWhenBufferedSynthesisFallbackFails() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            <html><body><ol>
            <li x-test-model><a href="/library/glm-5.2"><span>glm-5.2</span><span>cloud</span></a></li>
            </ol></body></html>
            """,
            path: "/search"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "glm-5.2",
              "message": {"role": "assistant", "content": "panel answer"},
              "done": true,
              "prompt_eval_count": 3,
              "eval_count": 2
            }
            """,
            path: "/api/chat"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "model": "glm-5.2",
              "message": {"role": "assistant", "content": "{\\"consensus\\":\\"c\\",\\"contradictions\\":\\"x\\",\\"partial_coverage\\":\\"p\\",\\"unique_insights\\":\\"u\\",\\"blind_spots\\":\\"b\\"}"},
              "done": true,
              "prompt_eval_count": 4,
              "eval_count": 3
            }
            """,
            path: "/api/chat"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 429,
            body: #"{"error":"temporary capacity exhausted"}"#,
            path: "/api/chat"
        )

        let harness = try GatewayHarness(
            providerExecutor: BurnBarOpenAICompatibleProviderExecutor(session: session),
            modelCatalogSession: session,
            modelCatalogCacheTTL: 600
        )
        try await harness.configureOllamaProviderForGateway(preferredModelIDs: ["glm-5.2"])
        try await harness.configStore.removeCredentialSlot(providerID: "ollama", slotID: "backup")
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let fusionRequest = Data(
            """
            {
              "model": "glm-5.2:cloud",
              "messages": [{"role": "user", "content": "compare the options"}],
              "stream": true,
              "plugins": [{
                "id": "fusion",
                "enabled": true,
                "analysis_models": ["glm-5.2:cloud"],
                "model": "glm-5.2:cloud",
                "max_tool_calls": 1
              }]
            }
            """.utf8
        )
        let (fusionResponse, fusionBody) = try await sendRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/chat/completions",
            headers: await harness.safariHeaders(
                correlationID: "2B0D4A57-A4E2-4C18-9AF0-2026E06EAF51"
            ),
            body: fusionRequest
        )

        XCTAssertEqual(fusionResponse.statusCode, 429, String(decoding: fusionBody, as: UTF8.self))
        XCTAssertEqual(
            GatewayUpstreamURLProtocol.recordedRequests().map(\.path),
            ["/search", "/api/chat", "/api/chat", "/api/chat"]
        )

        let routeLog = try await harness.proxyRouteLogStore.recent(limit: 10)
        let synthesisRows = routeLog.filter { $0.endpoint == "Elder Wand Fusion (synthesis)" }
        XCTAssertEqual(synthesisRows.count, 1)
        let synthesis = try XCTUnwrap(synthesisRows.first)
        XCTAssertEqual(synthesis.finalStatus, .failed)
        XCTAssertEqual(synthesis.httpStatus, 429)
        XCTAssertFalse(synthesis.streamed)
        XCTAssertFalse(synthesis.streamInterrupted)
        XCTAssertNotNil(synthesis.parentRequestID)
        XCTAssertEqual(synthesis.clientSource, "openburnbar-safari-extension")
        XCTAssertEqual(synthesis.clientRequestCorrelationID, "2b0d4a57-a4e2-4c18-9af0-2026e06eaf51")

        let parentIDs = Set(
            routeLog
                .filter { $0.endpoint.hasPrefix("Elder Wand Fusion") }
                .compactMap(\.parentRequestID)
        )
        XCTAssertEqual(parentIDs, Set([try XCTUnwrap(synthesis.parentRequestID)]))

        let (_, advertisedBody) = try await sendRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertFalse(try advertisedModelIDs(in: advertisedBody).contains("glm-5.2:cloud"))
    }

    private func advertisedModelIDs(in body: Data) throws -> [String] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let data = try XCTUnwrap(object["data"] as? [[String: Any]])
        return data.compactMap { row in
            guard (row["provider_id"] as? String) == "ollama" else { return nil }
            return row["id"] as? String
        }.sorted()
    }

    private func sendRequest(
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
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }
}
