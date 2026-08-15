import BurnBarCore
import Foundation
import XCTest

@testable import BurnBar

// MARK: - Hermes Delivery Channel Tests (M4)

/// Hermes gateway delivery-channel tests (VAL-ORCH-014/030/036/037): the
/// documented acknowledgement contract fails closed on every malformed shape,
/// gateway failures are typed, and unsupported agents honest-degrade with no
/// side effects. The channel is exercised through a stubbed URLSession
/// (URLProtocol) — never the live gateway.
@MainActor
final class HermesDirectiveChannelTests: XCTestCase {

    private var session: URLSession!
    private var baseURL: URL!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
        baseURL = URL(string: "http://127.0.0.1:8642")!
    }

    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        session = nil
        baseURL = nil
        super.tearDown()
    }

    private func makeChannel() -> HermesDirectiveChannel {
        HermesDirectiveChannel(
            baseURL: baseURL,
            apiKey: "test-key",
            timeout: 5,
            session: session
        )
    }

    private func makeDirective(
        id: String = "m4-proposal-001",
        targetAgent: BurnBarFleetAgentID? = .hermes,
        state: BurnBarFleetDirectiveState = .approved
    ) -> BurnBarFleetDirective {
        BurnBarFleetDirective(
            id: id,
            kind: .askStatus,
            targetAgent: targetAgent,
            payload: "Report current status",
            state: state,
            createdAt: Date(timeIntervalSince1970: 1_752_000_000),
            decidedAt: Date(timeIntervalSince1970: 1_752_000_100)
        )
    }

    private func ackData(directiveID: String, status: String = "delivered") -> Data {
        let payload: [String: Any] = [
            "id": "chatcmpl-fake",
            "object": "chat.completion",
            "created": 1_752_000_200,
            "model": "hermes-gateway-fixture",
            "choices": [
                [
                    "index": 0,
                    "message": ["role": "assistant", "content": "directive acknowledged"],
                    "finish_reason": "stop"
                ]
            ],
            "burnbar_delivery": [
                "directive_id": directiveID,
                "status": status
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    // MARK: - Channel identity + support

    func test_channelNameIsHermesAndSupportsOnlyHermes() {
        let channel = makeChannel()
        XCTAssertEqual(channel.channelName, "hermes")
        XCTAssertTrue(channel.supports(targetAgent: .hermes))
        XCTAssertFalse(channel.supports(targetAgent: .claudeCode))
        XCTAssertFalse(channel.supports(targetAgent: .codex))
    }

    // MARK: - Delivered (VAL-ORCH-014 branch A)

    func test_validAckYieldsDelivered() async {
        StubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, self.ackData(directiveID: "m4-proposal-001"))
        }
        let outcome = await makeChannel().deliver(makeDirective())
        XCTAssertEqual(outcome, .delivered)
    }

    func test_requestCarriesBearerAuthAndDirectiveBody() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, self.ackData(directiveID: "m4-proposal-001"))
        }
        _ = await makeChannel().deliver(makeDirective())

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/v1/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        let userContent = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(userContent.contains("burnbar_directive:"))
        XCTAssertTrue(userContent.contains("m4-proposal-001"))
    }

    // MARK: - Malformed acks fail closed (VAL-ORCH-036)

    func test_invalidJSONAckFailsClosed() async {
        StubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{not json".utf8))
        }
        let outcome = await makeChannel().deliver(makeDirective())
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("malformedAck"), "got: \(reason)")
    }

    func test_missingAckKeyFailsClosed() async {
        StubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let payload = (try? JSONSerialization.data(withJSONObject: ["id": "chatcmpl-fake"])) ?? Data()
            return (response, payload)
        }
        let outcome = await makeChannel().deliver(makeDirective())
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("malformedAck"), "got: \(reason)")
    }

    func test_mismatchedDirectiveIDAckFailsClosed() async {
        StubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, self.ackData(directiveID: "some-other-id"))
        }
        let outcome = await makeChannel().deliver(makeDirective())
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("malformedAck"), "got: \(reason)")
        XCTAssertTrue(reason.contains("mismatch"), "got: \(reason)")
    }

    func test_contradictoryStatusAckFailsClosed() async {
        StubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, self.ackData(directiveID: "m4-proposal-001", status: "pending"))
        }
        let outcome = await makeChannel().deliver(makeDirective())
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("malformedAck"), "got: \(reason)")
        XCTAssertTrue(reason.contains("pending"), "got: \(reason)")
    }

    // MARK: - Gateway failure (VAL-ORCH-030)

    func test_http500YieldsTypedFailure() async {
        StubURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("{\"error\":\"gateway exploded\"}".utf8))
        }
        let outcome = await makeChannel().deliver(makeDirective())
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("HTTP 500"), "got: \(reason)")
    }

    func test_transportFailureYieldsTypedFailure() async {
        StubURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        let outcome = await makeChannel().deliver(makeDirective())
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("unreachable"), "got: \(reason)")
    }

    // MARK: - Unsupported agent (VAL-ORCH-037)

    func test_unsupportedAgentNeverCallsChannel() async {
        // The channel is never invoked for a non-hermes target: the runner
        // resolves no channel and honest-degrades. This test pins the
        // channel's own support gate.
        let channel = makeChannel()
        XCTAssertFalse(channel.supports(targetAgent: .claudeCode))
    }
}

// MARK: - Delivery Runner Tests (M4)

/// Delivery-runner tests: the terminal record is written with the typed
/// outcome, an unsupported agent leaves the record `approved` with no side
/// effects, and a record-write failure surfaces typed (VAL-ORCH-014/030/037).
@MainActor
final class BurnBarFleetDeliveryRunnerTests: XCTestCase {

    private func makeDirective(
        id: String = "m4-proposal-001",
        targetAgent: BurnBarFleetAgentID? = .hermes
    ) -> BurnBarFleetDirective {
        BurnBarFleetDirective(
            id: id,
            kind: .askStatus,
            targetAgent: targetAgent,
            payload: "Report current status",
            state: .approved,
            createdAt: Date(timeIntervalSince1970: 1_752_000_000),
            decidedAt: Date(timeIntervalSince1970: 1_752_000_100)
        )
    }

    private final class StubChannel: BurnBarFleetDirectiveChannel, @unchecked Sendable {
        let outcome: BurnBarFleetDeliveryOutcome
        var deliveredDirectives: [BurnBarFleetDirective] = []
        init(outcome: BurnBarFleetDeliveryOutcome) {
            self.outcome = outcome
        }
        var channelName: String { "hermes" }
        func supports(targetAgent: BurnBarFleetAgentID) -> Bool {
            targetAgent == .hermes
        }
        func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome {
            deliveredDirectives.append(directive)
            return outcome
        }
    }

    func test_deliveredWritesTerminalRecordWithChannel() async throws {
        let channel = StubChannel(outcome: .delivered)
        var recorded: [BurnBarFleetDirective] = []
        let result = await BurnBarFleetDeliveryRunner.run(
            directive: makeDirective(),
            channel: channel,
            record: { directive in
                recorded.append(directive)
                return directive
            }
        )
        XCTAssertEqual(result.outcome, .delivered)
        XCTAssertEqual(recorded.count, 1)
        let terminal = try XCTUnwrap(recorded.first)
        XCTAssertEqual(terminal.state, .delivered)
        XCTAssertEqual(terminal.deliveryChannel, "hermes")
        XCTAssertEqual(terminal.decidedAt, makeDirective().decidedAt, "decidedAt preserved")
        XCTAssertNil(result.recordError)
    }

    func test_failedWritesTerminalFailedRecordWithReason() async throws {
        let channel = StubChannel(outcome: .failed(reason: "hermes gateway unreachable: boom"))
        var recorded: [BurnBarFleetDirective] = []
        let result = await BurnBarFleetDeliveryRunner.run(
            directive: makeDirective(),
            channel: channel,
            record: { directive in
                recorded.append(directive)
                return directive
            }
        )
        guard case .failed(let reason) = result.outcome else {
            return XCTFail("expected failed, got \(result.outcome)")
        }
        XCTAssertTrue(reason.contains("boom"))
        let terminal = try XCTUnwrap(recorded.first)
        guard case .failed(let terminalReason) = terminal.state else {
            return XCTFail("expected failed record, got \(terminal.state)")
        }
        XCTAssertTrue(terminalReason.contains("boom"))
        XCTAssertEqual(terminal.deliveryChannel, "hermes")
    }

    func test_unsupportedLeavesRecordApprovedNoSideEffects() async {
        let channel = StubChannel(outcome: .unsupported(reason: "no documented writable channel"))
        var recorded: [BurnBarFleetDirective] = []
        let result = await BurnBarFleetDeliveryRunner.run(
            directive: makeDirective(),
            channel: channel,
            record: { directive in
                recorded.append(directive)
                return directive
            }
        )
        guard case .unsupported(let reason) = result.outcome else {
            return XCTFail("expected unsupported, got \(result.outcome)")
        }
        XCTAssertTrue(reason.contains("no documented"))
        XCTAssertTrue(recorded.isEmpty, "unsupported must not write a terminal record")
        XCTAssertNil(result.recorded)
    }

    func test_recordWriteFailureSurfacesTyped() async {
        let channel = StubChannel(outcome: .delivered)
        let result = await BurnBarFleetDeliveryRunner.run(
            directive: makeDirective(),
            channel: channel,
            record: { _ in
                throw BurnBarFleetClientError.daemonUnavailable("connect failed")
            }
        )
        guard case .failed(let reason) = result.outcome else {
            return XCTFail("expected failed, got \(result.outcome)")
        }
        XCTAssertTrue(reason.contains("delivery record failed"), "got: \(reason)")
        XCTAssertNotNil(result.recordError)
    }

    func test_channelResolutionHonestDegradesForUnsupportedAgent() {
        // An agent with no documented writable channel resolves to nil — the
        // runner never invokes a channel for it (VAL-ORCH-037).
        let channel = BurnBarFleetDeliveryRunner.channel(
            for: .claudeCode,
            provider: { target in
                guard target == .hermes else { return nil }
                return StubChannel(outcome: .delivered)
            }
        )
        XCTAssertNil(channel)
        let hermesChannel = BurnBarFleetDeliveryRunner.channel(
            for: .hermes,
            provider: { target in
                guard target == .hermes else { return nil }
                return StubChannel(outcome: .delivered)
            }
        )
        XCTAssertNotNil(hermesChannel)
    }
}

// MARK: - Chat Delivery State Persistence (M4)

/// `ChatDeliveryState` wire round-trips through the persisted text column:
/// every typed state survives encode/decode, and malformed values decode to
/// nil (never a fabricated outcome).
final class ChatDeliveryStatePersistenceTests: XCTestCase {
    func test_allStatesRoundTripThroughRawValue() {
        let states: [ChatDeliveryState] = [
            .delivering,
            .delivered,
            .failed(reason: "hermes gateway unreachable: boom"),
            .unsupported(reason: "no documented writable channel for claude-code")
        ]
        for state in states {
            let decoded = ChatDeliveryState(rawValue: state.rawValue)
            XCTAssertEqual(decoded, state, "rawValue round-trip for \(state)")
        }
    }

    func test_malformedRawValueDecodesNil() {
        XCTAssertNil(ChatDeliveryState(rawValue: ""))
        XCTAssertNil(ChatDeliveryState(rawValue: "bogus"))
        XCTAssertNil(ChatDeliveryState(rawValue: "failed:"), "empty reason must not decode")
        XCTAssertNil(ChatDeliveryState(rawValue: "unsupported:"), "empty reason must not decode")
    }

    func test_reasonAndRetryableSemantics() {
        XCTAssertNil(ChatDeliveryState.delivering.reason)
        XCTAssertNil(ChatDeliveryState.delivered.reason)
        XCTAssertEqual(ChatDeliveryState.failed(reason: "x").reason, "x")
        XCTAssertEqual(ChatDeliveryState.unsupported(reason: "y").reason, "y")
        XCTAssertFalse(ChatDeliveryState.delivering.isRetryable)
        XCTAssertFalse(ChatDeliveryState.delivered.isRetryable)
        XCTAssertTrue(ChatDeliveryState.failed(reason: "x").isRetryable)
        XCTAssertTrue(ChatDeliveryState.unsupported(reason: "y").isRetryable)
    }
}

// MARK: - URLProtocol stub (shared by the channel tests)

private final class StubURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
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
            // URLSession delivers a request's httpBody to URLProtocol stubs
            // via httpBodyStream, never via httpBody. Materialize the stream
            // so handlers can inspect the request body.
            var captured = request
            if let stream = captured.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: buffer.count)
                    if read <= 0 { break }
                    body.append(buffer, count: read)
                }
                captured.httpBody = body
            }
            let (response, data) = try handler(captured)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}
