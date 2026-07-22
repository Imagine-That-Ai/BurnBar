@testable import OpenBurnBarDaemon
import OpenBurnBarEngine
import Foundation
import XCTest

final class ElderWandCredentialRefreshGatewayTests: XCTestCase {
    override func setUp() {
        GatewayUpstreamURLProtocol.reset()
        super.setUp()
    }

    override func tearDown() {
        GatewayUpstreamURLProtocol.reset()
        super.tearDown()
    }

    func testElderWandRetriesRotatedCurrentClaudeCredentialOnce() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [GatewayUpstreamURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        GatewayUpstreamURLProtocol.enqueue(
            status: 401,
            body: try jsonString([
                "type": "error",
                "error": ["type": "authentication_error", "message": "expired login"]
            ]),
            path: "/anthropic/v1/messages"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: try anthropicMessageBody(id: "msg_panel", text: "Panel answer", inputTokens: 7, outputTokens: 3),
            path: "/anthropic/v1/messages"
        )
        let judgeVerdict = try jsonString([
            "consensus": "Ship in stages.",
            "contradictions": "None.",
            "partial_coverage": "Rollback.",
            "unique_insights": "Watch metrics.",
            "blind_spots": "None."
        ])
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: try anthropicMessageBody(id: "msg_judge", text: judgeVerdict, inputTokens: 11, outputTokens: 9),
            path: "/anthropic/v1/messages"
        )
        GatewayUpstreamURLProtocol.enqueue(
            status: 200,
            body: try anthropicMessageBody(
                id: "msg_synthesis",
                text: "FINAL_ROTATED_CREDENTIAL_OK",
                inputTokens: 13,
                outputTokens: 4
            ),
            path: "/anthropic/v1/messages"
        )

        let secretStore = RotatingCurrentClaudeSecretStore(
            staleToken: "sk-ant-oat-stale",
            freshToken: "sk-ant-oat-fresh"
        )
        let harness = try GatewayHarness(
            secretStore: secretStore,
            anthropicExecutor: BurnBarAnthropicProviderExecutor(session: session)
        )
        _ = try await harness.configStore.upsertProvider(
            BurnBarProviderSettings(
                providerID: "anthropic",
                isEnabled: true,
                baseURL: "https://gateway-upstream.test/anthropic/v1",
                preferredModelIDs: ["claude-haiku-4-5-family"],
                preferredCredentialSlotID: "current-claude-code-login"
            )
        )
        _ = try await harness.configStore.upsertCredentialSlot(
            providerID: "anthropic",
            slotID: "current-claude-code-login",
            label: "Current Claude Code login",
            apiKey: "sk-ant-oat-stale",
            authMethodID: "anthropic-claude-oauth"
        )
        try await harness.start()
        addTeardownBlock { await harness.stop() }

        let requestBody = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5",
            "messages": [["role": "user", "content": "Plan a safe rollout."]],
            "stream": false,
            "plugins": [[
                "id": "fusion",
                "enabled": true,
                "analysis_models": ["claude-haiku-4-5"],
                "model": "claude-haiku-4-5",
                "max_tool_calls": 1
            ]]
        ])
        let (response, body) = try await sendRequest(port: harness.port, body: requestBody)

        XCTAssertEqual(response.statusCode, 200, String(decoding: body, as: UTF8.self))
        let responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let choices = try XCTUnwrap(responseObject["choices"] as? [[String: Any]])
        let message = try XCTUnwrap(choices.first?["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "FINAL_ROTATED_CREDENTIAL_OK")

        let messageRequests = GatewayUpstreamURLProtocol.recordedRequests()
            .filter { $0.path == "/anthropic/v1/messages" }
        XCTAssertEqual(messageRequests.count, 4)
        XCTAssertEqual(messageRequests[0].authorization, "Bearer sk-ant-oat-stale")
        XCTAssertEqual(messageRequests[1].authorization, "Bearer sk-ant-oat-fresh")
        XCTAssertEqual(messageRequests[0].body, messageRequests[1].body)
        XCTAssertTrue(messageRequests.dropFirst().allSatisfy { $0.authorization == "Bearer sk-ant-oat-fresh" })

        let snapshot = try await harness.configStore.snapshot()
        let status = snapshot.providerSettings(id: "anthropic")?
            .credentialSlots.first(where: { $0.slotID == "current-claude-code-login" })?.status
        XCTAssertEqual(status, .ready)
    }

    private func anthropicMessageBody(
        id: String,
        text: String,
        inputTokens: Int,
        outputTokens: Int
    ) throws -> String {
        try jsonString([
            "id": id,
            "type": "message",
            "role": "assistant",
            "model": "claude-haiku-4-5",
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": inputTokens, "output_tokens": outputTokens]
        ])
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func sendRequest(port: Int, body: Data) async throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/chat/completions"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        return (try XCTUnwrap(response as? HTTPURLResponse), responseData)
    }
}

private actor RotatingCurrentClaudeSecretStore: BurnBarProviderSecretStoring {
    private var secrets: [String: String] = [:]
    private let staleToken: String
    private let freshToken: String

    init(staleToken: String, freshToken: String) {
        self.staleToken = staleToken
        self.freshToken = freshToken
    }

    func secret(for providerID: String) async throws -> String? {
        guard providerID.caseInsensitiveCompare("anthropic.slot.current-claude-code-login") == .orderedSame else {
            return secrets[providerID]
        }
        let firstAttemptFinished = GatewayUpstreamURLProtocol.recordedRequests()
            .contains { $0.path == "/anthropic/v1/messages" }
        return firstAttemptFinished ? freshToken : (secrets[providerID] ?? staleToken)
    }

    func setSecret(_ secret: String?, for providerID: String) async throws {
        let normalized = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized, !normalized.isEmpty {
            secrets[providerID] = normalized
        } else {
            secrets.removeValue(forKey: providerID)
        }
    }
}
