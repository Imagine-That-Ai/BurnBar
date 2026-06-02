import OpenBurnBarCore
import XCTest

final class HermesOpenAICompatibleStreamParserTests: XCTestCase {
    func testParserEmitsToolCallChunksAndFinishedEvent() {
        var parser = HermesOpenAICompatibleStreamParser()

        let first = parser.events(fromDataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"burn"}}]},"finish_reason":null}]}"#)
        let second = parser.events(fromDataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"bar\"}"}}]},"finish_reason":null}]}"#)
        let stop = parser.events(fromDataPayload: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#)

        XCTAssertEqual(first.events, [
            .toolCallChunk(id: "call_1", index: 0, name: "search", argumentsDelta: #"{"query":"burn"#)
        ])
        XCTAssertEqual(second.events, [
            .toolCallChunk(id: "call_1", index: 0, name: nil, argumentsDelta: #"bar"}"#)
        ])
        XCTAssertEqual(stop.events, [
            .toolCallFinished(id: "call_1", name: "search", arguments: #"{"query":"burnbar"}"#),
            .messageStop(finishReason: "tool_calls", outcome: .normal, usage: nil)
        ])
    }

    func testDoneFlushesPendingToolCallsWhenProviderOmitsFinishReason() {
        var parser = HermesOpenAICompatibleStreamParser()

        _ = parser.events(fromDataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"burn"}}]},"finish_reason":null}]}"#)
        _ = parser.events(fromDataPayload: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"bar\"}"}}]},"finish_reason":null}]}"#)
        let done = parser.events(fromDataPayload: "[DONE]")

        XCTAssertTrue(done.done)
        XCTAssertEqual(done.events, [
            .toolCallFinished(id: "call_1", name: "search", arguments: #"{"query":"burnbar"}"#)
        ])
    }

    func testTextChunkFlushesPendingToolCallsBeforeVisibleContent() {
        var parser = HermesOpenAICompatibleStreamParser()

        let result = parser.events(fromDataPayload: #"{"choices":[{"delta":{"content":"done","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"search","arguments":"{\"query\":\"burnbar\"}"}}]},"finish_reason":null}]}"#)

        XCTAssertEqual(result.events, [
            .toolCallChunk(id: "call_1", index: 0, name: "search", argumentsDelta: #"{"query":"burnbar"}"#),
            .toolCallFinished(id: "call_1", name: "search", arguments: #"{"query":"burnbar"}"#),
            .messageChunk(text: "done")
        ])
        XCTAssertTrue(result.streamedText)
    }

    func testParserEmitsReasoningAndRefusalChannels() {
        var parser = HermesOpenAICompatibleStreamParser()
        let result = parser.events(fromDataPayload: #"{"choices":[{"delta":{"reasoning_content":"think","refusal":"no"},"finish_reason":"stop"}]}"#)

        XCTAssertEqual(result.events, [
            .refusalChunk(text: "no"),
            .reasoningChunk(text: "think"),
            .messageStop(finishReason: "stop", outcome: .normal, usage: nil)
        ])
    }

    func testParserNormalizesOllamaUsageDurations() {
        var parser = HermesOpenAICompatibleStreamParser()
        let result = parser.events(fromDataPayload: #"{"eval_count":8,"eval_duration":2000000000,"total_duration":2500000000}"#)

        XCTAssertEqual(result.events, [
            .messageStop(
                finishReason: nil,
                outcome: .normal,
                usage: HermesTokenUsageStats(
                    promptTokens: nil,
                    outputTokens: 8,
                    totalTokens: 8,
                    generationDurationSeconds: 2,
                    totalDurationSeconds: 2.5
                )
            )
        ])
    }
}
