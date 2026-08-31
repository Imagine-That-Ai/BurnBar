import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class ClaudeFableGatewayRoutingTests: XCTestCase {
    override func setUp() {
        GatewayUpstreamURLProtocol.reset()
        super.setUp()
    }

    override func tearDown() {
        GatewayUpstreamURLProtocol.reset()
        super.tearDown()
    }

    func testGatewayRoutesClaudeFable5WhenConfiguredOnStandardAPIKeyAccount() async throws {
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: """
            {
              "id": "msg_fable5",
              "type": "message",
              "role": "assistant",
              "model": "claude-fable-5",
              "content": [{"type": "text", "text": "Fable OK"}],
              "stop_reason": "end_turn",
              "usage": {
                "input_tokens": 5,
                "output_tokens": 3,
                "cache_creation_input_tokens": 0,
                "cache_read_input_tokens": 0
              }
            }
            """
        )
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-fable-5-family"],
                preferredCredentialSlotID: "default-plan"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "default-plan",
            label: "Default plan",
            apiKey: "sk-ant-api-standard"
        )
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (modelsResponse, modelsBody) = try await sendRequest(
            port: harness.port,
            method: "GET",
            path: "/v1/models"
        )
        XCTAssertEqual(modelsResponse.statusCode, 200)
        let modelsObject = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsBody) as? [String: Any])
        let modelsData = try XCTUnwrap(modelsObject["data"] as? [[String: Any]])
        let fable = try XCTUnwrap(modelsData.first {
            ($0["account_id"] as? String) == "default-plan"
                && ($0["id"] as? String) == "claude-fable-5"
        })
        XCTAssertEqual(fable["provider_id"] as? String, "anthropic")
        XCTAssertEqual(fable["route_eligible"] as? Bool, true)

        let (messageResponse, messageBody) = try await sendRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            body: Data(
                #"{"model":"claude-fable-5","max_tokens":16,"messages":[{"role":"user","content":"Hi"}]}"#.utf8
            )
        )
        XCTAssertEqual(messageResponse.statusCode, 200, String(decoding: messageBody, as: UTF8.self))
        let messageObject = try XCTUnwrap(JSONSerialization.jsonObject(with: messageBody) as? [String: Any])
        XCTAssertEqual(messageObject["model"] as? String, "claude-fable-5")
    }

    func testGatewayReturns429WhenAllConfiguredAnthropicAccountsAreCoolingDown() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let harness = try GatewayHarness(
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session),
            modelCatalogSession: session
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-fable-5-family"],
                preferredCredentialSlotID: "default-plan"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "default-plan",
            label: "Default plan",
            apiKey: "sk-ant-api-standard"
        )
        let cooldownUntil = Date().addingTimeInterval(300)
        try await harness.configStore.updateCredentialSlotStatus(
            providerID: "anthropic",
            slotID: "default-plan",
            status: .coolingDown,
            cooldownUntil: cooldownUntil,
            message: "Rate limit exceeded (HTTP 429)"
        )
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (messageResponse, messageBody) = try await sendRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            body: Data(
                #"{"model":"claude-fable-5","max_tokens":16,"messages":[{"role":"user","content":"Hi"}]}"#.utf8
            )
        )
        XCTAssertEqual(messageResponse.statusCode, 429)
        let rawBody = String(decoding: messageBody, as: UTF8.self)
        XCTAssertTrue(rawBody.contains("cooling down") || rawBody.contains("rate limit"), rawBody)
    }

    private func sendRequest(
        port: Int,
        method: String,
        path: String,
        body: Data? = nil
    ) async throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)"))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), data)
    }
}
