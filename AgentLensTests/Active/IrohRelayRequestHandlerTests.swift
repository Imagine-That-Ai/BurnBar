import XCTest
@testable import OpenBurnBar

final class IrohRelayRequestHandlerTests: XCTestCase {
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
