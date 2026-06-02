@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class OpenBurnBarAnthropicProviderExecutorStreamTests: XCTestCase {
    func testChatCompletionsStreamPreservesAnthropicToolUseDeltas() throws {
        let anthropicSSE = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[]}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_weather","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"city\\":\\"Ch"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"icago\\"}"}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":8}}

        event: message_stop
        data: {"type":"message_stop"}

        """.data(using: .utf8)!
        let response = BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: anthropicSSE,
            usage: nil
        )

        let bridged = try BurnBarAnthropicProviderExecutor.chatCompletionsStreamFromAnthropicStream(
            response,
            modelID: "claude-sonnet"
        )
        let chunks = Self.sseDataObjects(from: bridged.body)

        let toolChunks = chunks.compactMap { object -> [[String: Any]]? in
            guard let choice = (object["choices"] as? [[String: Any]])?.first,
                  let delta = choice["delta"] as? [String: Any] else {
                return nil
            }
            return delta["tool_calls"] as? [[String: Any]]
        }.flatMap { $0 }

        XCTAssertEqual(toolChunks.count, 3)
        XCTAssertEqual(toolChunks.first?["id"] as? String, "toolu_1")
        XCTAssertEqual(toolChunks.first?["index"] as? Int, 0)
        XCTAssertEqual(toolChunks.first?["type"] as? String, "function")
        let firstFunction = toolChunks.first?["function"] as? [String: Any]
        XCTAssertEqual(firstFunction?["name"] as? String, "get_weather")

        let argumentDeltas = toolChunks.compactMap { (($0["function"] as? [String: Any])?["arguments"] as? String) }
        XCTAssertEqual(argumentDeltas, ["{\"city\":\"Ch", "icago\"}"])

        let finishReason = chunks.compactMap { object -> String? in
            guard let choice = (object["choices"] as? [[String: Any]])?.first else { return nil }
            return choice["finish_reason"] as? String
        }.last
        XCTAssertEqual(finishReason, "tool_calls")
    }

    private static func sseDataObjects(from body: Data) -> [[String: Any]] {
        String(decoding: body, as: UTF8.self)
            .components(separatedBy: "\n\n")
            .compactMap { chunk -> [String: Any]? in
                guard let dataLine = chunk
                    .split(separator: "\n")
                    .first(where: { $0.hasPrefix("data: ") }) else {
                    return nil
                }
                let payload = dataLine.dropFirst("data: ".count)
                guard payload != "[DONE]",
                      let data = String(payload).data(using: .utf8) else {
                    return nil
                }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }
}
