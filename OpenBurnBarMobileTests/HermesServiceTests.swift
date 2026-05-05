import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class HermesServiceTests: XCTestCase {

    func testInitialState() {
        let service = HermesService()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertFalse(service.isStreaming)
        XCTAssertNil(service.lastError)
        XCTAssertFalse(service.isReachable)
    }

    func testSendMessageAppendsUserMessage() {
        let service = HermesService()
        service.sendMessage("Hello Hermes")
        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages.first?.role, .user)
        XCTAssertEqual(service.messages.first?.text, "Hello Hermes")
        XCTAssertTrue(service.isStreaming)
    }

    func testSendEmptyMessageIsNoOp() {
        let service = HermesService()
        service.sendMessage("   ")
        XCTAssertTrue(service.messages.isEmpty)
    }

    func testClearChatRemovesMessages() {
        let service = HermesService()
        service.sendMessage("Test")
        service.clearChat()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertNil(service.lastError)
    }

    func testHermesChatMessageFields() {
        let msg = HermesChatMessage(role: .user, text: "Hi")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.text, "Hi")
        XCTAssertFalse(msg.isStreaming)
        XCTAssertFalse(msg.isError)
    }

    func testHermesChatMessageErrorFlag() {
        let msg = HermesChatMessage(role: .assistant, text: "Oops", isError: true)
        XCTAssertTrue(msg.isError)
        XCTAssertFalse(msg.isStreaming)
    }

    func testHermesServiceErrorDescriptions() {
        XCTAssertNotNil(HermesServiceError.invalidResponse.errorDescription)
        XCTAssertNotNil(HermesServiceError.httpStatus(code: 500).errorDescription)
        XCTAssertNotNil(HermesServiceError.decodingFailed.errorDescription)
    }

    func testRelayConnectionDoesNotRequireReachableURL() {
        let service = HermesService(relayTransport: FakeHermesRelayTransport())
        let relay = HermesConnectionRecord(
            id: "relay-mac",
            displayName: "Mac Hermes Relay",
            mode: .relayLink,
            status: .online,
            capabilities: ["chat_completions", "remote_relay"]
        )

        XCTAssertTrue(service.selectConnection(relay, refresh: false))
        XCTAssertEqual(service.selectedConnection.id, "relay-mac")
        XCTAssertNil(service.lastError)
    }

    func testRelayStreamingParsesTextAndToolCalls() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"id":"tool-1","function":{"name":"read_file"}}]}}]}"#,
            "data: [DONE]"
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Use the relay")
        await waitForStreamToFinish(service)

        XCTAssertEqual(relay.streamingPayloads.first?.connectionID, "relay-mac")
        XCTAssertEqual(service.messages.last?.role, .assistant)
        XCTAssertEqual(service.messages.last?.text, "Hello")
        XCTAssertEqual(service.messages.last?.toolCalls.first?.name, "read_file")
        XCTAssertFalse(service.isStreaming)
    }

    func testRelayStreamingSurfacesJSONErrorEvent() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"error":{"message":"Hermes profile is locked"}}"#
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Fail")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.lastError, "Hermes profile is locked")
        XCTAssertEqual(service.messages.last?.text, "Hermes profile is locked")
        XCTAssertTrue(service.messages.last?.isError ?? false)
    }

    func testRelayStreamingFailureReplacesBlankAssistantBubble() async {
        let relay = FakeHermesRelayTransport()
        relay.streamingError = HermesServiceError.relayUnavailable("Mac relay stopped.")
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        service.sendMessage("Fail")
        await waitForStreamToFinish(service)

        XCTAssertEqual(service.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(service.messages.last?.text, "Mac relay stopped.")
        XCTAssertTrue(service.messages.last?.isError ?? false)
    }

    func testRelayPayloadFiltersBlankAndErrorAssistantHistory() async throws {
        let relay = FakeHermesRelayTransport()
        relay.streamingEvents = [
            #"data: {"choices":[{"delta":{"content":"ok"}}]}"#
        ]
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))
        service.messages.append(HermesChatMessage(role: .assistant, text: "", isStreaming: true))
        service.messages.append(HermesChatMessage(role: .assistant, text: "Previous failure", isError: true))
        service.messages.append(HermesChatMessage(role: .user, text: "Previous useful turn"))

        service.sendMessage("Current turn")
        await waitForStreamToFinish(service)

        let body = try XCTUnwrap(relay.streamingPayloads.first?.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        XCTAssertEqual(messages.map { $0["content"] }, ["Previous useful turn", "Current turn"])
    }

    func testRelayReachabilityUsesRelayTransport() async {
        let relay = FakeHermesRelayTransport()
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        await service.checkReachability()

        XCTAssertTrue(service.isReachable)
        XCTAssertEqual(relay.unaryPayloads.first?.operation, .models)
        XCTAssertEqual(relay.unaryPayloads.first?.connectionID, "relay-mac")
    }

    func testRelayResumeSessionLoadsTranscript() async {
        let relay = FakeHermesRelayTransport()
        relay.unaryResponses[.sessionDetail] = Data(
            #"{"messages":[{"id":"u1","role":"user","content":"Remote question"},{"id":"a1","role":"assistant","content":"Remote answer"}]}"#.utf8
        )
        let service = HermesService(relayTransport: relay)
        XCTAssertTrue(service.selectConnection(relayConnection(), refresh: false))

        await service.resumeSession(HermesSessionSummary(id: "session-1"))

        XCTAssertEqual(relay.unaryPayloads.first?.operation, .sessionDetail)
        XCTAssertEqual(relay.unaryPayloads.first?.sessionID, "session-1")
        XCTAssertEqual(service.messages.map(\.text), ["Remote question", "Remote answer"])
    }

    func testDirectHTTP401ShowsAPIKeyErrorAndSendsAuthorizationHeader() async {
        let secretStore = FakeHermesSecretStore()
        secretStore.values["lan"] = "secret-token"
        let capture = RequestCapture()
        let session = Self.mockSession { request in
            capture.authorization = request.value(forHTTPHeaderField: "Authorization")
            return Self.response(status: 401, url: request.url!, body: #"{"error":"unauthorized"}"#)
        }
        let service = HermesService(urlSession: session, secretStore: secretStore)
        XCTAssertTrue(service.selectConnection(directConnection(), refresh: false))

        service.sendMessage("Hello")
        await waitForStreamToFinish(service)

        XCTAssertEqual(capture.authorization, "Bearer secret-token")
        XCTAssertTrue(service.lastError?.contains("API key") ?? false)
        XCTAssertTrue(service.messages.last?.isError ?? false)
    }

    func testResumeSessionLoadsTranscriptWithMockNetwork() async {
        let session = Self.mockSession { request in
            XCTAssertEqual(request.url?.path, "/api/sessions/session-1")
            return Self.response(
                status: 200,
                url: request.url!,
                body: #"{"messages":[{"id":"u1","role":"user","content":"Question"},{"id":"a1","role":"assistant","content":"Answer"}]}"#
            )
        }
        let service = HermesService(urlSession: session, secretStore: FakeHermesSecretStore())
        XCTAssertTrue(service.selectConnection(directConnection(), refresh: false))

        await service.resumeSession(HermesSessionSummary(id: "session-1"))

        XCTAssertEqual(service.messages.map(\.text), ["Question", "Answer"])
        XCTAssertEqual(service.messages.map(\.role), [.user, .assistant])
    }

    private func relayConnection() -> HermesConnectionRecord {
        HermesConnectionRecord(
            id: "relay-mac",
            displayName: "Mac Hermes Relay",
            mode: .relayLink,
            status: .online,
            capabilities: ["chat_completions", "remote_relay"]
        )
    }

    private func directConnection() -> HermesConnectionRecord {
        HermesConnectionRecord(
            id: "lan",
            displayName: "LAN Hermes",
            mode: .directURL,
            status: .online,
            endpointURL: "http://127.0.0.1:8642"
        )
    }

    private func waitForStreamToFinish(_ service: HermesService, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while service.isStreaming && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    nonisolated private static func mockSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockHermesURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHermesURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    nonisolated private static func response(status: Int, url: URL, body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }
}

private final class RequestCapture: @unchecked Sendable {
    nonisolated(unsafe) var authorization: String?
}

@MainActor
private final class FakeHermesRelayTransport: HermesRelayTransporting {
    var unaryResponses: [HermesRelayOperation: Data] = [
        .models: Data(#"{"data":[{"id":"hermes-test","owned_by":"hermes"}]}"#.utf8)
    ]
    var streamingEvents: [String] = []
    var streamingError: Error?
    private(set) var unaryPayloads: [HermesRelayPayload] = []
    private(set) var streamingPayloads: [HermesRelayPayload] = []

    func sendUnary(_ payload: HermesRelayPayload, timeout: TimeInterval) async throws -> Data {
        unaryPayloads.append(payload)
        return unaryResponses[payload.operation] ?? Data()
    }

    func sendStreaming(
        _ payload: HermesRelayPayload,
        timeout: TimeInterval,
        onSSEEvent: @escaping @MainActor (String) -> Void
    ) async throws {
        streamingPayloads.append(payload)
        if let streamingError {
            throw streamingError
        }
        for event in streamingEvents {
            onSSEEvent(event)
        }
    }
}

private final class FakeHermesSecretStore: HermesConnectionSecretStoring {
    var values: [String: String] = [:]

    func save(_ value: String, connectionID: String) throws {
        values[connectionID] = value
    }

    func load(connectionID: String) throws -> String? {
        values[connectionID]
    }

    func delete(connectionID: String) throws {
        values.removeValue(forKey: connectionID)
    }
}

private final class MockHermesURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
