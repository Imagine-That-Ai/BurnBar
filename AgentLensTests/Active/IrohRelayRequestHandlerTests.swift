import XCTest
import OpenBurnBarIrohRelay
@testable import OpenBurnBar

final class IrohRelayRequestHandlerTests: XCTestCase {
    func test_usesBurnBarGatewayForOpenAICompatibleRelaySurface() {
        XCTAssertTrue(IrohRelayRequestHandler.usesBurnBarGateway(.models))
        XCTAssertTrue(IrohRelayRequestHandler.usesBurnBarGateway(.chatCompletions))
        XCTAssertFalse(IrohRelayRequestHandler.usesBurnBarGateway(.sessions))
        XCTAssertFalse(IrohRelayRequestHandler.usesBurnBarGateway(.sessionDetail))
    }

    func test_isSSEDoneLine_acceptsOpenAISentinelWithWhitespace() {
        XCTAssertTrue(IrohRelayRequestHandler.isSSEDoneLine("data: [DONE]"))
        XCTAssertTrue(IrohRelayRequestHandler.isSSEDoneLine(" data:   [DONE] \r"))
    }

    func test_isSSEDoneLine_rejectsNormalDataAndComments() {
        XCTAssertFalse(IrohRelayRequestHandler.isSSEDoneLine("data: {\"choices\":[]}"))
        XCTAssertFalse(IrohRelayRequestHandler.isSSEDoneLine(": keepalive"))
        XCTAssertFalse(IrohRelayRequestHandler.isSSEDoneLine(""))
    }

    func test_isSSEDoneEvent_detectsSentinelInsideBufferedEvent() {
        XCTAssertTrue(IrohRelayRequestHandler.isSSEDoneEvent("event: done\ndata: [DONE]"))
        XCTAssertFalse(IrohRelayRequestHandler.isSSEDoneEvent("event: chunk\ndata: {\"ok\":true}"))
    }

    func test_isSSETerminalChoiceEvent_detectsFinishReason() {
        XCTAssertTrue(
            IrohRelayRequestHandler.isSSETerminalChoiceEvent(
                #"data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"total_tokens":42}}"#
            )
        )
        XCTAssertTrue(
            IrohRelayRequestHandler.isSSETerminalChoiceEvent(
                """
                event: completion
                data: {"choices":[{"message":{"content":"ok"},"finish_reason":"length"}]}
                """
            )
        )
    }

    func test_isSSETerminalChoiceEvent_rejectsNonTerminalChunks() {
        XCTAssertFalse(
            IrohRelayRequestHandler.isSSETerminalChoiceEvent(
                #"data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"#
            )
        )
        XCTAssertFalse(IrohRelayRequestHandler.isSSETerminalChoiceEvent("data: [DONE]"))
        XCTAssertFalse(IrohRelayRequestHandler.isSSETerminalChoiceEvent("data: not-json"))
    }

    func test_shouldFlushBufferedTerminalSSEEvent_detectsUnterminatedFinalChunk() {
        XCTAssertTrue(
            IrohRelayRequestHandler.shouldFlushBufferedTerminalSSEEvent([
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
            ])
        )
        XCTAssertTrue(
            IrohRelayRequestHandler.shouldFlushBufferedTerminalSSEEvent([
                "event: completion",
                "data: {\"choices\":[{\"message\":{\"content\":\"ok\"},\"finish_reason\":\"length\"}]}"
            ])
        )
    }

    func test_shouldFlushBufferedTerminalSSEEvent_rejectsPartialChunk() {
        XCTAssertFalse(
            IrohRelayRequestHandler.shouldFlushBufferedTerminalSSEEvent([
                "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}"
            ])
        )
        XCTAssertFalse(IrohRelayRequestHandler.shouldFlushBufferedTerminalSSEEvent([]))
    }

    func test_bufferedTerminalSSEEvent_detectsUnterminatedTerminalLine() {
        let pendingLine = #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#

        XCTAssertEqual(
            IrohRelayRequestHandler.bufferedTerminalSSEEvent(
                eventLines: [],
                pendingLineBytes: Array(pendingLine.utf8)
            ),
            pendingLine
        )
    }

    func test_bufferedTerminalSSEEvent_preservesEventPrefixAndTrimsCR() {
        let pendingLine = #"data: {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}"# + "\r"

        XCTAssertEqual(
            IrohRelayRequestHandler.bufferedTerminalSSEEvent(
                eventLines: ["event: completion"],
                pendingLineBytes: Array(pendingLine.utf8)
            ),
            """
            event: completion
            data: {"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}]}
            """
        )
    }

    func test_bufferedTerminalSSEEvent_rejectsUnterminatedNonTerminalLine() {
        let pendingLine = #"data: {"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}"#

        XCTAssertNil(
            IrohRelayRequestHandler.bufferedTerminalSSEEvent(
                eventLines: [],
                pendingLineBytes: Array(pendingLine.utf8)
            )
        )
    }

    func test_flushSSEEventLines_returnsBufferedEventAndClearsBuffer() {
        var lines = ["event: message", "data: {\"content\":\"hi\"}"]

        XCTAssertEqual(
            IrohRelayRequestHandler.flushSSEEventLines(&lines),
            ["event: message\ndata: {\"content\":\"hi\"}"]
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func test_requestedModel_extractsChatCompletionModel() {
        XCTAssertEqual(
            IrohRelayRequestHandler.requestedModel(
                fromBody: #"{"model":" gpt-5.5 ","messages":[]}"#
            ),
            "gpt-5.5"
        )
        XCTAssertNil(IrohRelayRequestHandler.requestedModel(fromBody: #"{"messages":[]}"#))
    }

    func test_chatRequestMetadata_countsShapeWithoutReadingContent() {
        let body = #"{"model":"gpt-5.5","messages":[{"role":"system","content":"private"},{"role":"user","content":"also private"}],"tools":[{"type":"function"}],"stream":true}"#

        let metadata = IrohRelayRequestHandler.chatRequestMetadata(fromBody: body)

        XCTAssertEqual(metadata.bodyBytes, "\(body.utf8.count)")
        XCTAssertEqual(metadata.messageCount, "2")
        XCTAssertEqual(metadata.toolCount, "1")
        XCTAssertEqual(metadata.stream, "true")
    }

    func test_upstreamErrorMessage_formatsSSEJSONErrorsWithRequestedModel() {
        let message = IrohRelayRequestHandler.upstreamErrorMessage(
            fromSSEEvent: """
            event: error
            data: {"error":{"message":"Weekly/Monthly Limit Exhausted"}}
            """,
            requestedModel: "glm-5.1"
        )

        XCTAssertEqual(
            message,
            "Hermes upstream model 'glm-5.1' failed: Weekly/Monthly Limit Exhausted"
        )
    }

    func test_upstreamErrorMessage_formatsHermesFailedTerminalChunk() {
        let message = IrohRelayRequestHandler.upstreamErrorMessage(
            fromSSEEvent: """
            data: {"choices":[{"delta":{},"finish_reason":"error"}],"hermes":{"completed":false,"failed":true,"error":"HTTP 503: no eligible OpenAI-compatible route for gpt-5.4-mini"}}
            """,
            requestedModel: "gpt-5.4-mini"
        )

        XCTAssertEqual(
            message,
            "Hermes upstream model 'gpt-5.4-mini' failed: HTTP 503: no eligible OpenAI-compatible route for gpt-5.4-mini"
        )
    }

    func test_upstreamErrorMessage_formatsChoiceErrorContentChunk() {
        let message = IrohRelayRequestHandler.upstreamErrorMessage(
            fromSSEEvent: """
            data: {"choices":[{"delta":{"content":"API call failed after 3 retries: HTTP 503: no eligible OpenAI-compatible route for gpt-5.4-mini"},"finish_reason":"error"}]}
            """,
            requestedModel: "gpt-5.4-mini"
        )

        XCTAssertEqual(
            message,
            "Hermes upstream model 'gpt-5.4-mini' failed: API call failed after 3 retries: HTTP 503: no eligible OpenAI-compatible route for gpt-5.4-mini"
        )
    }

    func test_hermesErrorHeader_trimsGatewayHeader() {
        let response = HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:8642/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["X-Hermes-Error": "  HTTP 503: no eligible route  "]
        )!

        XCTAssertEqual(
            IrohRelayRequestHandler.hermesErrorHeader(from: response),
            "HTTP 503: no eligible route"
        )
    }

    func test_httpStatusErrorMessage_parsesProviderErrorBody() {
        let message = IrohRelayRequestHandler.httpStatusErrorMessage(
            code: 429,
            body: #"{"error":{"message":"insufficient quota"}}"#,
            requestedModel: "gpt-5.5"
        )

        XCTAssertEqual(
            message,
            "Hermes upstream model 'gpt-5.5' returned HTTP 429: insufficient quota"
        )
    }
}

@MainActor
final class HermesIrohRelayHostClientRuntimeTests: XCTestCase {
    func testRecoverablePeerAcceptFailuresDoNotRebuildAndDropActiveEndpoint() async throws {
        let suiteName = "hermes.iroh.host.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        settings.hermesIrohTransportEnabled = true

        let directory = InMemoryIrohPairingDirectory()
        let keyPublisher = RecordingIrohPairingPublicKeyPublisher()
        let auditLogger = RecordingIrohTransportAuditLogger()
        let first = TestIrohRelayTransport(
            nodeId: "node-first",
            acceptBehavior: .failThenPark(
                .streamRejected("iroh stream failed: connection lost"),
                failures: 4
            )
        )
        let second = TestIrohRelayTransport(nodeId: "node-second", acceptBehavior: .park)
        var transports = [first, second]

        let client = HermesIrohRelayHostClient(
            settingsManager: settings,
            pairingKeyStore: IrohPairingKeyStore(
                service: "ai.openburnbar.tests.iroh-pairing.\(UUID().uuidString)",
                account: "host"
            ),
            directory: directory,
            publicKeyPublisher: keyPublisher,
            auditLogger: auditLogger,
            pairingPublishInterval: 3_600,
            transportFactory: { _ in
                transports.removeFirst()
            }
        )

        let started = await client.start(uid: "uid-1", connectionID: "connection-1")
        XCTAssertTrue(started)
        try await waitUntil(timeout: 3) {
            first.acceptCount >= 5
        }

        let record = try await directory.fetch(uid: "uid-1", connectionId: "connection-1")
        XCTAssertEqual(record?.nodeId, "node-first")
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(first.shutdownCount, 0)
        XCTAssertEqual(first.startCount, 1)
        XCTAssertEqual(second.startCount, 0)

        client.stop()
    }

    func testAcceptLoopClosedRuntimeRebuildsAndPublishesFreshIdentity() async throws {
        let suiteName = "hermes.iroh.host.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsManager(defaults: defaults, flushDelayNanoseconds: 0)
        settings.hermesIrohTransportEnabled = true

        let directory = InMemoryIrohPairingDirectory()
        let keyPublisher = RecordingIrohPairingPublicKeyPublisher()
        let auditLogger = RecordingIrohTransportAuditLogger()
        let first = TestIrohRelayTransport(
            nodeId: "node-first",
            acceptBehavior: .fail(.streamRejected("iroh accept failed: endpoint closed"))
        )
        let second = TestIrohRelayTransport(nodeId: "node-second", acceptBehavior: .park)
        var transports = [first, second]

        let client = HermesIrohRelayHostClient(
            settingsManager: settings,
            pairingKeyStore: IrohPairingKeyStore(
                service: "ai.openburnbar.tests.iroh-pairing.\(UUID().uuidString)",
                account: "host"
            ),
            directory: directory,
            publicKeyPublisher: keyPublisher,
            auditLogger: auditLogger,
            pairingPublishInterval: 3_600,
            transportFactory: { _ in
                transports.removeFirst()
            }
        )

        let started = await client.start(uid: "uid-1", connectionID: "connection-1")
        XCTAssertTrue(started)
        try await waitUntil(timeout: 3) {
            let record = try await directory.fetch(uid: "uid-1", connectionId: "connection-1")
            return record?.nodeId == "node-second"
        }

        let record = try await directory.fetch(uid: "uid-1", connectionId: "connection-1")
        XCTAssertEqual(record?.nodeId, "node-second")
        XCTAssertTrue(client.isReady)
        XCTAssertEqual(first.shutdownCount, 1)
        XCTAssertEqual(second.startCount, 1)

        client.stop()
    }
}

private actor RecordingIrohPairingPublicKeyPublisher: IrohPairingPublicKeyPublishing {
    private(set) var publishCount = 0

    func publish(uid: String, publicKeyBase64: String) async throws {
        publishCount += 1
    }
}

private actor RecordingIrohTransportAuditLogger: IrohTransportAuditLogging {
    private(set) var events: [IrohTransportAuditEvent] = []

    func record(
        event: IrohTransportAuditEvent,
        uid: String,
        connectionId: String,
        transport: IrohTransportSelection?,
        rttMillis: Int?,
        detail: [String: String]
    ) async {
        events.append(event)
    }
}

private final class TestIrohRelayTransport: IrohRelayTransport, @unchecked Sendable {
    enum AcceptBehavior: Sendable {
        case fail(IrohRelayTransportError)
        case failThenPark(IrohRelayTransportError, failures: Int)
        case park
    }

    private let identity: IrohEndpointIdentity
    private let acceptBehavior: AcceptBehavior
    private(set) var startCount = 0
    private(set) var shutdownCount = 0
    private(set) var acceptCount = 0

    init(nodeId: String, acceptBehavior: AcceptBehavior) {
        self.identity = IrohEndpointIdentity(
            nodeId: nodeId,
            rawPublicKey: Data(repeating: 0xAB, count: 32),
            relayURL: "https://relay.example/",
            directAddresses: ["127.0.0.1:1234"]
        )
        self.acceptBehavior = acceptBehavior
    }

    func start() async throws -> IrohEndpointIdentity {
        startCount += 1
        return identity
    }

    func connect(to target: IrohDialTarget, timeout: TimeInterval) async throws -> any IrohRelayStream {
        throw IrohRelayTransportError.endpointNotReady
    }

    func accept(timeout: TimeInterval) async throws -> any IrohRelayStream {
        acceptCount += 1
        switch acceptBehavior {
        case .fail(let error):
            throw error
        case .failThenPark(let error, let failures):
            if acceptCount <= failures {
                throw error
            }
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw IrohRelayTransportError.shutdown
        case .park:
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw IrohRelayTransportError.shutdown
        }
    }

    func shutdown() async {
        shutdownCount += 1
    }
}

private func waitUntil(
    timeout: TimeInterval,
    pollInterval: UInt64 = 50_000_000,
    condition: () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if try await condition() {
            return
        }
        try await Task.sleep(nanoseconds: pollInterval)
    }
    XCTFail("Timed out waiting for condition")
}
