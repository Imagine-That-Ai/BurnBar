import Foundation
import OpenBurnBarEngine

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
        let request = try BurnBarBridgeJSON.decodeBridgeRequest(AnthropicBridgeInboundRequest.self, from: body)
        guard let rawMessages = request.messages?.array, !rawMessages.isEmpty,
              let anthropicMessages = try? rawMessages.map({ try $0.decoded(as: AnthropicBridgeInboundMessage.self) }) else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Anthropic Messages bridge requires at least one message."
            )
        }

        var messages: [ChatBridgeOutboundMessage] = []
        if let systemText = systemText(from: request.system), !systemText.isEmpty {
            messages.append(ChatBridgeOutboundMessage(role: "system", content: .string(systemText)))
        }

        for message in anthropicMessages {
            let role = message.role?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "user"
            let blocks = anthropicContentBlocks(from: message.content)
            let toolResults = blocks.compactMap(openAIToolMessageFromAnthropicToolResult)
            let conversationalContent = openAIContent(fromAnthropicBlocks: blocks.filter {
                $0.type?.string != "tool_result"
            })

            if !isEmptyOpenAIContent(conversationalContent) {
                var converted = ChatBridgeOutboundMessage(
                    role: role == "assistant" ? "assistant" : "user",
                    content: conversationalContent
                )
                if role == "assistant" {
                    let toolCalls = blocks.compactMap(openAIToolCallFromAnthropicToolUse)
                    if !toolCalls.isEmpty {
                        converted.toolCalls = try BurnBarBridgeJSON.bridgeValue(toolCalls)
                        if isEmptyOpenAIContent(conversationalContent) {
                            converted.content = .null
                        }
                    }
                }
                messages.append(converted)
            } else if role == "assistant" {
                let toolCalls = blocks.compactMap(openAIToolCallFromAnthropicToolUse)
                if !toolCalls.isEmpty {
                    messages.append(ChatBridgeOutboundMessage(
                        role: "assistant",
                        content: .null,
                        toolCalls: try BurnBarBridgeJSON.bridgeValue(toolCalls)
                    ))
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

        var chat = ChatBridgeOutboundRequest(model: modelID, messages: messages)
        if let maxTokens = request.maxTokens {
            chat.maxCompletionTokens = maxTokens
            chat.maxTokens = maxTokens
        }
        chat.temperature = request.temperature
        chat.topP = request.topP
        chat.stream = request.stream
        if let stopSequences = request.stopSequences {
            chat.stop = stopSequences
        }
        if let tools = openAITools(fromAnthropicTools: request.tools), !tools.isEmpty {
            chat.tools = try BurnBarBridgeJSON.bridgeValue(tools)
            if let toolChoice = openAIToolChoice(fromAnthropicToolChoice: request.toolChoice) {
                chat.toolChoice = try BurnBarBridgeJSON.bridgeValue(toolChoice)
            }
        }

        let streamRequested = request.stream?.bool ?? false
        return (try BurnBarBridgeJSON.encode(chat, sortedKeys: true), streamRequested)
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
            headers: chatResponse.headers,
            body: body,
            usage: chatResponse.usage
        )
    }

    private static func anthropicMessagesBodyFromChatCompletion(
        _ body: Data,
        modelID: String
    ) throws -> Data {
        let completion = try BurnBarBridgeJSON.decodeBridgeRequest(ChatBridgeInboundCompletion.self, from: body)
        guard let firstChoice = completion.choices?.first,
              let message = firstChoice.message else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        var content: [AnthropicBridgedBlock] = []
        let text = openAIContentText(message.content)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append(AnthropicBridgedBlock(type: "text", text: text))
        }
        if let toolCalls = message.toolCalls?.array, toolCalls.allSatisfy({ $0.object != nil }) {
            content.append(contentsOf: toolCalls.compactMap(anthropicToolUseBlock(fromOpenAIToolCall:)))
        }

        let outbound = AnthropicOutboundMessage(
            id: completion.id?.string ?? "msg_\(UUID().uuidString)",
            type: "message",
            role: "assistant",
            model: completion.model?.string ?? modelID,
            content: content,
            stopReason: AnthropicBridgeStopReason.fromChatFinishReason(firstChoice.finishReason?.string),
            stopSequence: .null,
            usage: anthropicUsage(fromOpenAIUsage: completion.usage)
        )
        return try BurnBarBridgeJSON.encode(outbound, sortedKeys: true)
    }

    private static func anthropicMessagesStreamFromChatCompletionStream(
        _ response: BurnBarProviderProxyResponse,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let messageID = "msg_\(UUID().uuidString)"
        var output = Data()
        var outputText = ""
        var stopReason = "end_turn"
        var usage = AnthropicOutboundMessage.AnthropicOutboundUsage(inputTokens: 0, outputTokens: 0)
        var streamedToolCalls: [Int: StreamedToolCall] = [:]

        try BurnBarBridgeJSON.appendNamedSSE(
            event: "message_start",
            payload: AnthropicOutboundMessageStart(
                type: "message_start",
                message: AnthropicOutboundMessageStart.AnthropicOutboundMessageStartBody(
                    id: messageID,
                    type: "message",
                    role: "assistant",
                    model: modelID,
                    content: [],
                    stopReason: .null,
                    stopSequence: .null,
                    usage: usage
                )
            ),
            to: &output
        )
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "content_block_start",
            payload: AnthropicOutboundContentBlockStart(
                type: "content_block_start",
                index: 0,
                contentBlock: .object(["type": .string("text"), "text": .string("")])
            ),
            to: &output
        )

        for event in serverSentEvents(from: response.body) {
            if let eventUsage = event.usage {
                usage = anthropicUsage(fromOpenAIUsage: eventUsage)
            }
            guard let choice = event.choices?.first else {
                continue
            }
            if let finish = choice.finishReason?.string {
                stopReason = AnthropicBridgeStopReason.fromChatFinishReason(finish)
            }
            guard let delta = choice.delta else { continue }
            if let text = delta.content?.string, !text.isEmpty {
                outputText += text
                try BurnBarBridgeJSON.appendNamedSSE(
                    event: "content_block_delta",
                    payload: AnthropicOutboundContentBlockDelta(
                        type: "content_block_delta",
                        index: 0,
                        delta: .object(["type": .string("text_delta"), "text": .string(text)])
                    ),
                    to: &output
                )
            }
            if let toolCalls = delta.toolCalls?.array, toolCalls.allSatisfy({ $0.object != nil }) {
                merge(toolCalls: toolCalls, into: &streamedToolCalls)
            }
        }

        try BurnBarBridgeJSON.appendNamedSSE(
            event: "content_block_stop",
            payload: AnthropicOutboundContentBlockStop(type: "content_block_stop", index: 0),
            to: &output
        )

        var nextIndex = 1
        for call in streamedToolCalls.values.sorted(by: { $0.index < $1.index }) {
            try BurnBarBridgeJSON.appendNamedSSE(
                event: "content_block_start",
                payload: AnthropicOutboundContentBlockStart(
                    type: "content_block_start",
                    index: nextIndex,
                    contentBlock: .object([
                        "type": .string("tool_use"),
                        "id": .string(call.id),
                        "name": .string(call.name),
                        "input": objectFromJSONString(call.arguments) ?? .object([:])
                    ])
                ),
                to: &output
            )
            try BurnBarBridgeJSON.appendNamedSSE(
                event: "content_block_stop",
                payload: AnthropicOutboundContentBlockStop(type: "content_block_stop", index: nextIndex),
                to: &output
            )
            nextIndex += 1
        }

        if usage.outputTokens == 0 {
            usage.outputTokens = max(1, outputText.count / 4)
        }
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "message_delta",
            payload: AnthropicOutboundMessageDelta(
                type: "message_delta",
                delta: AnthropicOutboundMessageDelta.AnthropicOutboundMessageDeltaBody(
                    stopReason: stopReason,
                    stopSequence: .null
                ),
                usage: AnthropicOutboundMessageDelta.AnthropicOutboundMessageDeltaUsage(
                    outputTokens: usage.outputTokens
                )
            ),
            to: &output
        )
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "message_stop",
            payload: AnthropicOutboundMessageStop(type: "message_stop"),
            to: &output
        )

        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            headers: response.headers,
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

    private static func merge(toolCalls: [BurnBarBridgeValue], into accumulator: inout [Int: StreamedToolCall]) {
        for call in toolCalls {
            let index = call["index"]?.asInt ?? accumulator.count
            var existing = accumulator[index] ?? StreamedToolCall(
                index: index,
                id: "call_\(UUID().uuidString)",
                name: "tool",
                arguments: ""
            )
            if let id = call["id"]?.string, !id.isEmpty {
                existing.id = id
            }
            if let function = call["function"], function.object != nil {
                if let name = function["name"]?.string, !name.isEmpty {
                    existing.name = name
                }
                if let arguments = function["arguments"]?.string, !arguments.isEmpty {
                    existing.arguments += arguments
                }
            }
            accumulator[index] = existing
        }
    }

    private static func serverSentEvents(from data: Data) -> [ChatBridgeInboundCompletion] {
        BurnBarBridgeJSON.eventPayloads(from: data).compactMap { payload in
            try? JSONDecoder().decode(ChatBridgeInboundCompletion.self, from: payload)
        }
    }

    private static func systemText(from value: BurnBarBridgeValue?) -> String? {
        if let string = value?.string {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        guard let blocks = value?.array, blocks.allSatisfy({ $0.object != nil }) else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard let view = try? block.decoded(as: AnthropicContentBlockWire.self),
                  view.type?.string == "text",
                  let text = view.text?.string else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private static func anthropicContentBlocks(from value: BurnBarBridgeValue?) -> [AnthropicContentBlockWire] {
        guard let value else { return [] }
        if let string = value.string {
            return [AnthropicContentBlockWire.text(string)]
        }
        guard let blocks = value.array, blocks.allSatisfy({ $0.object != nil }) else { return [] }
        return blocks.compactMap { try? $0.decoded(as: AnthropicContentBlockWire.self) }
    }

    private static func openAIContent(fromAnthropicBlocks blocks: [AnthropicContentBlockWire]) -> ChatBridgeOutboundContent {
        var parts: [ChatBridgeOutboundPart] = []
        var textOnly: [String] = []
        var sawNonText = false

        for block in blocks {
            switch block.type?.string {
            case "text":
                let text = block.text?.string ?? ""
                if !sawNonText {
                    textOnly.append(text)
                }
                parts.append(ChatBridgeOutboundPart(type: .string("text"), text: .string(text)))
            case "image":
                sawNonText = true
                if let mediaType = block.source?.mediaType?.string,
                   let data = block.source?.data?.string {
                    parts.append(ChatBridgeOutboundPart(
                        type: .string("image_url"),
                        imageURL: .object(["url": .string("data:\(mediaType);base64,\(data)")])
                    ))
                }
            case "document":
                sawNonText = true
                if let mediaType = block.source?.mediaType?.string,
                   let data = block.source?.data?.string,
                   mediaType.caseInsensitiveCompare("application/pdf") == .orderedSame {
                    parts.append(ChatBridgeOutboundPart(
                        type: .string("file"),
                        file: .object(["file_data": .string("data:\(mediaType);base64,\(data)")])
                    ))
                }
            default:
                continue
            }
        }

        if sawNonText {
            return .parts(parts)
        }
        return .string(textOnly.joined())
    }

    private static func isEmptyOpenAIContent(_ value: ChatBridgeOutboundContent) -> Bool {
        switch value {
        case .string(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .parts(let parts):
            return parts.isEmpty
        case .null:
            return true
        }
    }

    private static func openAIContentText(_ value: BurnBarBridgeValue?) -> String {
        guard let value else { return "" }
        if let string = value.string { return string }
        guard let parts = value.array, parts.allSatisfy({ $0.object != nil }) else { return "" }
        return parts.compactMap { part -> String? in
            guard let view = try? part.decoded(as: AnthropicContentBlockWire.self),
                  view.type?.string == "text" else { return nil }
            return view.text?.string
        }.joined()
    }

    private static func openAIToolMessageFromAnthropicToolResult(_ block: AnthropicContentBlockWire) -> ChatBridgeOutboundMessage? {
        guard block.type?.string == "tool_result",
              let toolUseID = block.toolUseID?.string,
              !toolUseID.isEmpty else {
            return nil
        }
        return ChatBridgeOutboundMessage(
            role: "tool",
            content: .string(openAIContentText(block.content)),
            toolCallID: toolUseID
        )
    }

    private static func openAIToolCallFromAnthropicToolUse(_ block: AnthropicContentBlockWire) -> ChatBridgeOutboundToolCall? {
        guard block.type?.string == "tool_use",
              let id = block.id?.string,
              let name = block.name?.string,
              !id.isEmpty,
              !name.isEmpty else {
            return nil
        }
        let input = block.input?.object.map(BurnBarBridgeValue.object) ?? .object([:])
        return ChatBridgeOutboundToolCall(
            id: id,
            type: "function",
            function: ChatBridgeOutboundToolCall.ChatBridgeOutboundFunction(
                name: name,
                arguments: (try? BurnBarBridgeJSON.encodeString(input, sortedKeys: true)) ?? "{}"
            )
        )
    }

    private static func anthropicToolUseBlock(fromOpenAIToolCall call: BurnBarBridgeValue) -> AnthropicBridgedBlock? {
        guard let view = try? call.decoded(as: ChatBridgeInboundToolCall.self),
              let name = view.function?["name"]?.string,
              !name.isEmpty else {
            return nil
        }
        let arguments = view.function?["arguments"]?.string ?? "{}"
        return AnthropicBridgedBlock(
            type: "tool_use",
            id: view.id?.string ?? "call_\(UUID().uuidString)",
            name: name,
            input: objectFromJSONString(arguments) ?? .object([:])
        )
    }

    private static func openAITools(fromAnthropicTools value: BurnBarBridgeValue?) -> [ChatBridgeOutboundTool]? {
        guard let tools = value?.array, tools.allSatisfy({ $0.object != nil }) else { return nil }
        return tools.compactMap { tool in
            guard let view = try? tool.decoded(as: AnthropicBridgeInboundTool.self),
                  let name = view.name?.string, !name.isEmpty else { return nil }
            let description = view.toolDescription?.string
            return ChatBridgeOutboundTool(
                type: "function",
                function: ChatBridgeOutboundTool.ChatBridgeOutboundToolFunction(
                    name: name,
                    toolDescription: description.flatMap { $0.isEmpty ? nil : $0 },
                    parameters: view.inputSchema?.object.map(BurnBarBridgeValue.object)
                        ?? .object(["type": .string("object"), "properties": .object([:])])
                )
            )
        }
    }

    private static func openAIToolChoice(fromAnthropicToolChoice value: BurnBarBridgeValue?) -> ChatBridgeOutboundToolChoice? {
        if let string = value?.string {
            switch string {
            case "auto": return .string("auto")
            case "none": return .string("none")
            case "any": return .string("required")
            default: return nil
            }
        }
        guard let value, value.object != nil,
              let type = value["type"]?.string else {
            return nil
        }
        if type == "auto" { return .string("auto") }
        if type == "none" { return .string("none") }
        if type == "any" { return .string("required") }
        if type == "tool", let name = value["name"]?.string, !name.isEmpty {
            return .namedFunction(name)
        }
        return nil
    }

    private static func anthropicUsage(fromOpenAIUsage value: BurnBarBridgeValue?) -> AnthropicOutboundMessage.AnthropicOutboundUsage {
        let input = value?["prompt_tokens"]?.asInt ?? value?["input_tokens"]?.asInt ?? 0
        let output = value?["completion_tokens"]?.asInt ?? value?["output_tokens"]?.asInt ?? 0
        return AnthropicOutboundMessage.AnthropicOutboundUsage(inputTokens: input, outputTokens: output)
    }

    private static func objectFromJSONString(_ value: String?) -> BurnBarBridgeValue? {
        guard let value,
              let data = value.data(using: .utf8),
              let parsed = try? BurnBarBridgeJSON.decode(BurnBarBridgeValue.self, from: data),
              case .object = parsed else {
            return nil
        }
        return parsed
    }
}
