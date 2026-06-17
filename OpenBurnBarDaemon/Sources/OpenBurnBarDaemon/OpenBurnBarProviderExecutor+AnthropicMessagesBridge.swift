import Foundation
import OpenBurnBarCore

extension BurnBarOpenAICompatibleProviderExecutor {

    public func proxyMessages(
        body: Data,
        route: BurnBarProviderRoute,
        variant: BurnBarModelVariant? = nil
    ) async throws -> BurnBarProviderProxyResponse {
        let (chatBody, streamRequested) = try Self.chatCompletionsBodyFromAnthropicMessagesRequest(
            body,
            modelID: route.resolvedModelID
        )
        let chatResponse = try await proxyChatCompletions(body: chatBody, route: route, variant: variant)
        return try Self.anthropicMessagesProxyResponse(
            from: chatResponse,
            modelID: route.resolvedModelID,
            streamRequested: streamRequested
        )
    }

    static func chatCompletionsBodyFromAnthropicMessagesRequest(
        _ body: Data,
        modelID: String
    ) throws -> (Data, Bool) {
        guard let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        guard let anthropicMessages = object["messages"] as? [[String: Any]], !anthropicMessages.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Anthropic Messages bridge requires at least one message."
            )
        }

        var messages: [[String: Any]] = []
        if let systemText = systemText(from: object["system"]), !systemText.isEmpty {
            messages.append(["role": "system", "content": systemText])
        }

        for message in anthropicMessages {
            let role = ((message["role"] as? String) ?? "user")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let blocks = anthropicContentBlocks(from: message["content"])
            let toolResults = blocks.compactMap(openAIToolMessageFromAnthropicToolResult)
            let conversationalContent = openAIContent(fromAnthropicBlocks: blocks.filter {
                ($0["type"] as? String) != "tool_result"
            })

            if !isEmptyOpenAIContent(conversationalContent) {
                var converted: [String: Any] = [
                    "role": role == "assistant" ? "assistant" : "user",
                    "content": conversationalContent
                ]
                if role == "assistant" {
                    let toolCalls = blocks.compactMap(openAIToolCallFromAnthropicToolUse)
                    if !toolCalls.isEmpty {
                        converted["tool_calls"] = toolCalls
                        if isEmptyOpenAIContent(conversationalContent) {
                            converted["content"] = NSNull()
                        }
                    }
                }
                messages.append(converted)
            } else if role == "assistant" {
                let toolCalls = blocks.compactMap(openAIToolCallFromAnthropicToolUse)
                if !toolCalls.isEmpty {
                    messages.append([
                        "role": "assistant",
                        "content": NSNull(),
                        "tool_calls": toolCalls
                    ])
                }
            }

            messages.append(contentsOf: toolResults)
        }

        guard !messages.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Anthropic Messages bridge could not derive any OpenAI-compatible messages from the request."
            )
        }

        var chat: [String: Any] = [
            "model": modelID,
            "messages": messages
        ]
        if let maxTokens = object["max_tokens"] {
            chat["max_completion_tokens"] = maxTokens
            chat["max_tokens"] = maxTokens
        }
        for key in ["temperature", "top_p", "stream"] {
            if let value = object[key] {
                chat[key] = value
            }
        }
        if let stopSequences = object["stop_sequences"] {
            chat["stop"] = stopSequences
        }
        if let tools = openAITools(fromAnthropicTools: object["tools"]), !tools.isEmpty {
            chat["tools"] = tools
            if let toolChoice = openAIToolChoice(fromAnthropicToolChoice: object["tool_choice"]) {
                chat["tool_choice"] = toolChoice
            }
        }

        let streamRequested = object["stream"] as? Bool ?? false
        return (try jsonData(chat), streamRequested)
    }

    static func anthropicMessagesProxyResponse(
        from chatResponse: BurnBarProviderProxyResponse,
        modelID: String,
        streamRequested: Bool
    ) throws -> BurnBarProviderProxyResponse {
        if streamRequested || chatResponse.contentType.lowercased().contains("text/event-stream") {
            return try anthropicMessagesStreamFromChatCompletionStream(chatResponse, modelID: modelID)
        }
        let body = try anthropicMessagesBodyFromChatCompletion(chatResponse.body, modelID: modelID)
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            body: body,
            usage: chatResponse.usage
        )
    }

    private static func anthropicMessagesBodyFromChatCompletion(
        _ body: Data,
        modelID: String
    ) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: body, options: []) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        var content: [[String: Any]] = []
        let text = openAIContentText(message["content"])
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(["type": "text", "text": text])
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            content.append(contentsOf: toolCalls.compactMap(anthropicToolUseBlock(fromOpenAIToolCall:)))
        }

        let responseObject: [String: Any] = [
            "id": (object["id"] as? String) ?? "msg_\(UUID().uuidString)",
            "type": "message",
            "role": "assistant",
            "model": (object["model"] as? String) ?? modelID,
            "content": content,
            "stop_reason": anthropicStopReason(fromChatFinishReason: firstChoice["finish_reason"] as? String),
            "stop_sequence": NSNull(),
            "usage": anthropicUsage(fromOpenAIUsage: object["usage"])
        ]
        return try jsonData(responseObject)
    }

    private static func anthropicMessagesStreamFromChatCompletionStream(
        _ response: BurnBarProviderProxyResponse,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let messageID = "msg_\(UUID().uuidString)"
        var output = Data()
        var outputText = ""
        var stopReason = "end_turn"
        var usage: [String: Any] = ["input_tokens": 0, "output_tokens": 0]
        var streamedToolCalls: [Int: StreamedToolCall] = [:]

        try appendNamedSSE(event: "message_start", payload: [
            "type": "message_start",
            "message": [
                "id": messageID,
                "type": "message",
                "role": "assistant",
                "model": modelID,
                "content": [],
                "stop_reason": NSNull(),
                "stop_sequence": NSNull(),
                "usage": usage
            ]
        ], to: &output)
        try appendNamedSSE(event: "content_block_start", payload: [
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "text", "text": ""]
        ], to: &output)

        for event in serverSentEvents(from: response.body) {
            if let eventUsage = event.payload["usage"] as? [String: Any] {
                usage = anthropicUsage(fromOpenAIUsage: eventUsage)
            }
            guard let choices = event.payload["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                continue
            }
            if let finish = choice["finish_reason"] as? String {
                stopReason = anthropicStopReason(fromChatFinishReason: finish)
            }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let text = delta["content"] as? String, !text.isEmpty {
                outputText += text
                try appendNamedSSE(event: "content_block_delta", payload: [
                    "type": "content_block_delta",
                    "index": 0,
                    "delta": ["type": "text_delta", "text": text]
                ], to: &output)
            }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                merge(toolCalls: toolCalls, into: &streamedToolCalls)
            }
        }

        try appendNamedSSE(event: "content_block_stop", payload: [
            "type": "content_block_stop",
            "index": 0
        ], to: &output)

        var nextIndex = 1
        for call in streamedToolCalls.values.sorted(by: { $0.index < $1.index }) {
            try appendNamedSSE(event: "content_block_start", payload: [
                "type": "content_block_start",
                "index": nextIndex,
                "content_block": [
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": objectFromJSONString(call.arguments) ?? [:]
                ]
            ], to: &output)
            try appendNamedSSE(event: "content_block_stop", payload: [
                "type": "content_block_stop",
                "index": nextIndex
            ], to: &output)
            nextIndex += 1
        }

        if usage["output_tokens"] as? Int == 0 {
            usage["output_tokens"] = max(1, outputText.count / 4)
        }
        try appendNamedSSE(event: "message_delta", payload: [
            "type": "message_delta",
            "delta": [
                "stop_reason": stopReason,
                "stop_sequence": NSNull()
            ],
            "usage": ["output_tokens": usage["output_tokens"] ?? 0]
        ], to: &output)
        try appendNamedSSE(event: "message_stop", payload: ["type": "message_stop"], to: &output)

        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            body: output,
            usage: response.usage
        )
    }

    private struct StreamedToolCall {
        var index: Int
        var id: String
        var name: String
        var arguments: String
    }

    private static func merge(toolCalls: [[String: Any]], into accumulator: inout [Int: StreamedToolCall]) {
        for call in toolCalls {
            let index = intValue(call["index"]) ?? accumulator.count
            var existing = accumulator[index] ?? StreamedToolCall(
                index: index,
                id: "call_\(UUID().uuidString)",
                name: "tool",
                arguments: ""
            )
            if let id = call["id"] as? String, !id.isEmpty {
                existing.id = id
            }
            if let function = call["function"] as? [String: Any] {
                if let name = function["name"] as? String, !name.isEmpty {
                    existing.name = name
                }
                if let arguments = function["arguments"] as? String, !arguments.isEmpty {
                    existing.arguments += arguments
                }
            }
            accumulator[index] = existing
        }
    }

    private struct ServerSentEvent {
        let payload: [String: Any]
    }

    private static func serverSentEvents(from data: Data) -> [ServerSentEvent] {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\n\n").compactMap { chunk in
            var dataLines: [String] = []
            for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.hasPrefix("data:") else { continue }
                let dataLine = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if dataLine == "[DONE]" { return nil }
                dataLines.append(dataLine)
            }
            guard !dataLines.isEmpty,
                  let payloadData = dataLines.joined(separator: "\n").data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                return nil
            }
            return ServerSentEvent(payload: payload)
        }
    }

    private static func systemText(from value: Any?) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        guard let blocks = value as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let text = block["text"] as? String else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private static func anthropicContentBlocks(from value: Any?) -> [[String: Any]] {
        if let string = value as? String {
            return [["type": "text", "text": string]]
        }
        return (value as? [[String: Any]]) ?? []
    }

    private static func openAIContent(fromAnthropicBlocks blocks: [[String: Any]]) -> Any {
        var parts: [[String: Any]] = []
        var textOnly: [String] = []
        var sawNonText = false

        for block in blocks {
            switch block["type"] as? String {
            case "text":
                let text = (block["text"] as? String) ?? ""
                if !sawNonText {
                    textOnly.append(text)
                }
                parts.append(["type": "text", "text": text])
            case "image":
                sawNonText = true
                if let source = block["source"] as? [String: Any],
                   let mediaType = source["media_type"] as? String,
                   let data = source["data"] as? String {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mediaType);base64,\(data)"]
                    ])
                }
            default:
                continue
            }
        }

        if sawNonText {
            return parts
        }
        return textOnly.joined()
    }

    private static func isEmptyOpenAIContent(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let parts = value as? [[String: Any]] {
            return parts.isEmpty
        }
        return false
    }

    private static func openAIContentText(_ value: Any?) -> String {
        if let string = value as? String { return string }
        guard let parts = value as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }.joined()
    }

    private static func openAIToolMessageFromAnthropicToolResult(_ block: [String: Any]) -> [String: Any]? {
        guard block["type"] as? String == "tool_result",
              let toolUseID = block["tool_use_id"] as? String,
              !toolUseID.isEmpty else {
            return nil
        }
        return [
            "role": "tool",
            "tool_call_id": toolUseID,
            "content": openAIContentText(block["content"])
        ]
    }

    private static func openAIToolCallFromAnthropicToolUse(_ block: [String: Any]) -> [String: Any]? {
        guard block["type"] as? String == "tool_use",
              let id = block["id"] as? String,
              let name = block["name"] as? String,
              !id.isEmpty,
              !name.isEmpty else {
            return nil
        }
        let input = (block["input"] as? [String: Any]) ?? [:]
        return [
            "id": id,
            "type": "function",
            "function": [
                "name": name,
                "arguments": (try? jsonString(input)) ?? "{}"
            ]
        ]
    }

    private static func anthropicToolUseBlock(fromOpenAIToolCall call: [String: Any]) -> [String: Any]? {
        guard let function = call["function"] as? [String: Any],
              let name = function["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        let arguments = (function["arguments"] as? String) ?? "{}"
        return [
            "type": "tool_use",
            "id": (call["id"] as? String) ?? "call_\(UUID().uuidString)",
            "name": name,
            "input": objectFromJSONString(arguments) ?? [:]
        ]
    }

    private static func openAITools(fromAnthropicTools value: Any?) -> [[String: Any]]? {
        guard let tools = value as? [[String: Any]] else { return nil }
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String, !name.isEmpty else { return nil }
            var function: [String: Any] = [
                "name": name,
                "parameters": (tool["input_schema"] as? [String: Any]) ?? ["type": "object", "properties": [:]]
            ]
            if let description = tool["description"] as? String, !description.isEmpty {
                function["description"] = description
            }
            return ["type": "function", "function": function]
        }
    }

    private static func openAIToolChoice(fromAnthropicToolChoice value: Any?) -> Any? {
        if let string = value as? String {
            switch string {
            case "auto": return "auto"
            case "none": return "none"
            case "any": return "required"
            default: return nil
            }
        }
        guard let object = value as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        if type == "auto" { return "auto" }
        if type == "none" { return "none" }
        if type == "any" { return "required" }
        if type == "tool", let name = object["name"] as? String, !name.isEmpty {
            return ["type": "function", "function": ["name": name]]
        }
        return nil
    }

    private static func anthropicStopReason(fromChatFinishReason value: String?) -> String {
        switch value {
        case "tool_calls":
            return "tool_use"
        case "length", "max_tokens":
            return "max_tokens"
        default:
            return "end_turn"
        }
    }

    private static func anthropicUsage(fromOpenAIUsage value: Any?) -> [String: Any] {
        let usage = value as? [String: Any] ?? [:]
        let input = intValue(usage["prompt_tokens"]) ?? intValue(usage["input_tokens"]) ?? 0
        let output = intValue(usage["completion_tokens"]) ?? intValue(usage["output_tokens"]) ?? 0
        return [
            "input_tokens": input,
            "output_tokens": output
        ]
    }

    private static func objectFromJSONString(_ value: String?) -> [String: Any]? {
        guard let value,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func jsonData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BurnBarProviderExecutorError.invalidResponse
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonString(_ object: Any) throws -> String {
        let data = try jsonData(object)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func appendNamedSSE(event: String, payload: [String: Any], to output: inout Data) throws {
        output.append(Data("event: \(event)\n".utf8))
        output.append(Data("data: \(try jsonString(payload))\n\n".utf8))
    }

}
