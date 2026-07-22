import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

extension BurnBarHTTPGatewayServerTests {
    func testGatewayExplainsLiveRejectedSavedOAuthToken() async throws {
        for _ in 0..<2 {
            GatewayUpstreamURLProtocol.enqueue(
                status: 401,
                body: #"{"error":{"message":"expired bearer"}}"#,
                path: "/anthropic/v1/models"
            )
        }
        let slotID = "live-rejected-claude-oauth-slot"
        let harness = try await makeClaudeOAuthRecoveryHarness(slotID: slotID, apiKey: "sk-ant-oat-expired")
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (response, body) = try await sendClaudeOAuthGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"model":"anthropic/live-rejected-claude-oauth-slot/claude-fable-5","max_tokens":16,"messages":[{"role":"user","content":"Reply OK"}]}"#.utf8
            )
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("credential is missing or expired"), bodyText)
        XCTAssertTrue(bodyText.contains("claude auth login"), bodyText)
    }

    func testGatewayDoesNotCallCoolingDownOAuthCredentialExpired() async throws {
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: #"{"data":[{"id":"claude-fable-5","display_name":"Claude Fable 5","type":"model"}],"has_more":false}"#,
            path: "/anthropic/v1/models"
        )
        let slotID = "cooling-claude-oauth-slot"
        let harness = try await makeClaudeOAuthRecoveryHarness(slotID: slotID, apiKey: "sk-ant-oat-cooling")
        _ = try await harness.configStore.updateCredentialSlotStatus(
            providerID: "anthropic",
            slotID: slotID,
            status: .coolingDown,
            cooldownUntil: Date().addingTimeInterval(600),
            message: "Rate limited"
        )
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let (response, body) = try await sendClaudeOAuthGatewayRequest(
            port: harness.port,
            method: "POST",
            path: "/v1/messages",
            headers: ["Content-Type": "application/json"],
            body: Data(
                #"{"model":"claude-fable-5","max_tokens":16,"messages":[{"role":"user","content":"Reply OK"}]}"#.utf8
            )
        )

        XCTAssertEqual(response.statusCode, 503)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(bodyText.contains("credential is missing or expired"), bodyText)
        XCTAssertFalse(bodyText.contains("claude auth login"), bodyText)
    }

    private func makeClaudeOAuthRecoveryHarness(slotID: String, apiKey: String) async throws -> GatewayHarness {
        let harness = try GatewayHarness()
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-opus-4-8-family"],
                preferredCredentialSlotID: slotID
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: slotID,
            label: "Claude OAuth",
            apiKey: apiKey,
            authMethodID: "anthropic-claude-oauth"
        )
        _ = try await harness.configStore.upsertCustomModel(
            providerID: "anthropic",
            customModel: BurnBarCustomModel(modelID: "claude-fable-5", displayName: "Claude Fable 5")
        )
        return harness
    }

    private func sendClaudeOAuthGatewayRequest(
        port: Int,
        method: String,
        path: String,
        headers: [String: String],
        body: Data
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
                return (try XCTUnwrap(response as? HTTPURLResponse), responseData)
            } catch {
                lastError = error
                let urlError = error as NSError
                guard attempt < 9,
                      urlError.domain == NSURLErrorDomain,
                      urlError.code == NSURLErrorCannotConnectToHost else {
                    throw error
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        throw lastError ?? URLError(.cannotConnectToHost)
    }
}
