import Foundation
import OpenBurnBarEngine

// MARK: - Anthropic stream translation
//
// Moved out of OpenBurnBarAnthropicProviderExecutor.swift (god-type
// decomposition): buffered and incremental SSE translators from Anthropic
// Messages streams to Chat Completions / Responses streams. Same module, same
// type, verbatim wire behavior.

extension BurnBarAnthropicProviderExecutor {

    static func chatCompletionsStreamFromAnthropicStream(
        _ response: BurnBarProviderProxyResponse,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let streamID = "chatcmpl_\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var finishReason = ChatBridgeFinishReason.null
        var output = Data()
        var toolBlocks: [Int: AnthropicStreamToolBlock] = [:]
        var nextToolIndex = 0
        try BurnBarBridgeJSON.appendSSEData(
            chatChunk(id: streamID, modelID: modelID, created: created, delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(role: "assistant"), finishReason: .null),
            to: &output
        )
        for event in serverSentEvents(from: response.body) {
            let payload = event.payload
            let type = payload.type
            if type == "content_block_start",
               let blockIndex = payload.index?.asNonNegativeInt,
               let block = payload.contentBlock,
               block["type"]?.string == "tool_use" {
                let toolIndex = nextToolIndex
                nextToolIndex += 1
                let toolID = block["id"]?.string ?? "toolu_\(blockIndex)"
                let name = block["name"]?.string ?? "tool"
                toolBlocks[blockIndex] = AnthropicStreamToolBlock(
                    id: toolID,
                    index: toolIndex,
                    name: name
                )
                var function = ChatBridgeStreamChunk.ChatBridgeStreamToolCall.ChatBridgeStreamFunction(name: name)
                if let input = block["input"]?.object,
                   !input.isEmpty,
                   let arguments = try? BurnBarBridgeJSON.encodeString(
                       BurnBarBridgeValue.object(input),
                       sortedKeys: true
                   ) {
                    function.arguments = arguments
                }
                try BurnBarBridgeJSON.appendSSEData(
                    chatChunk(
                        id: streamID,
                        modelID: modelID,
                        created: created,
                        delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(toolCalls: [
                            ChatBridgeStreamChunk.ChatBridgeStreamToolCall(
                                index: toolIndex,
                                id: toolID,
                                type: "function",
                                function: function
                            ),
                        ]),
                        finishReason: .null
                    ),
                    to: &output
                )
            }
            if type == "content_block_delta",
               let delta = payload.delta {
                if delta["type"]?.string == "text_delta",
                   let text = delta["text"]?.string,
                   !text.isEmpty {
                    try BurnBarBridgeJSON.appendSSEData(
                        chatChunk(id: streamID, modelID: modelID, created: created, delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(content: text), finishReason: .null),
                        to: &output
                    )
                } else if delta["type"]?.string == "input_json_delta",
                          let partialJSON = delta["partial_json"]?.string,
                          !partialJSON.isEmpty,
                          let blockIndex = payload.index?.asNonNegativeInt {
                    let toolBlock: AnthropicStreamToolBlock
                    if let existing = toolBlocks[blockIndex] {
                        toolBlock = existing
                    } else {
                        let synthesized = AnthropicStreamToolBlock(
                            id: "toolu_\(blockIndex)",
                            index: nextToolIndex,
                            name: "tool"
                        )
                        nextToolIndex += 1
                        toolBlocks[blockIndex] = synthesized
                        toolBlock = synthesized
                    }
                    try BurnBarBridgeJSON.appendSSEData(
                        chatChunk(
                            id: streamID,
                            modelID: modelID,
                            created: created,
                            delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(toolCalls: [
                                ChatBridgeStreamChunk.ChatBridgeStreamToolCall(
                                    index: toolBlock.index,
                                    id: toolBlock.id,
                                    type: "function",
                                    function: ChatBridgeStreamChunk.ChatBridgeStreamToolCall.ChatBridgeStreamFunction(
                                        name: toolBlock.name,
                                        arguments: partialJSON
                                    )
                                ),
                            ]),
                            finishReason: .null
                        ),
                        to: &output
                    )
                }
            }
            if type == "message_delta",
               let delta = payload.delta {
                finishReason = ChatBridgeFinishReason.fromAnthropicStopReason(delta["stop_reason"]?.string)
            }
            if type == "error" {
                try BurnBarBridgeJSON.appendSSEData(
                    BurnBarBridgeValue.object(["error": event.raw["error"] ?? .string("Anthropic stream error")]),
                    to: &output
                )
            }
        }
        try BurnBarBridgeJSON.appendSSEData(
            chatChunk(id: streamID, modelID: modelID, created: created, delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(), finishReason: finishReason),
            to: &output
        )
        output.append(Data("data: [DONE]\n\n".utf8))
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            headers: response.headers,
            body: output,
            usage: response.usage
        )
    }

    static func chatCompletionsStreamFromAnthropicMessagesStream(
        _ upstream: BurnBarProviderProxyStream,
        modelID: String
    ) -> BurnBarProviderProxyStream {
        let streamID = "chatcmpl_\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        let transformed = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var parser = AnthropicServerSentEventParser()
                var mapper = AnthropicChatCompletionsStreamMapper(
                    streamID: streamID,
                    modelID: modelID,
                    created: created
                )

                do {
                    continuation.yield(try mapper.startChunk())
                    for try await chunk in upstream.chunks {
                        for event in parser.consume(chunk) {
                            for output in try mapper.map(event) {
                                continuation.yield(output)
                            }
                        }
                    }
                    for event in parser.finish() {
                        for output in try mapper.map(event) {
                            continuation.yield(output)
                        }
                    }
                    try continuation.yield(mapper.finishChunk())
                    continuation.yield(Data("data: [DONE]\n\n".utf8))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return BurnBarProviderProxyStream(
            statusCode: upstream.statusCode,
            contentType: "text/event-stream",
            chunks: transformed
        )
    }

    private struct AnthropicStreamToolBlock {
        let id: String
        let index: Int
        let name: String
    }

    private struct AnthropicChatCompletionsStreamMapper {
        let streamID: String
        let modelID: String
        let created: Int
        var finishReason = ChatBridgeFinishReason.null
        var toolBlocks: [Int: AnthropicStreamToolBlock] = [:]
        var nextToolIndex = 0
        var usage = AnthropicStreamUsage()

        func startChunk() throws -> Data {
            try Self.chatCompletionsSSEData(
                id: streamID,
                modelID: modelID,
                created: created,
                delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(role: "assistant"),
                finishReason: .null,
                usage: nil
            )
        }

        mutating func map(_ event: AnthropicStreamEvent) throws -> [Data] {
            let payload = event.payload
            let type = payload.type
            if type == "message_start",
               let eventUsage = payload.message?["usage"],
               eventUsage.object != nil {
                usage.mergeAnthropicUsage(eventUsage)
            }

            if type == "content_block_start",
               let blockIndex = payload.index?.asNonNegativeInt,
               let block = payload.contentBlock,
               block["type"]?.string == "tool_use" {
                let toolIndex = nextToolIndex
                nextToolIndex += 1
                let toolID = block["id"]?.string ?? "toolu_\(blockIndex)"
                let name = block["name"]?.string ?? "tool"
                toolBlocks[blockIndex] = AnthropicStreamToolBlock(
                    id: toolID,
                    index: toolIndex,
                    name: name
                )
                var function = ChatBridgeStreamChunk.ChatBridgeStreamToolCall.ChatBridgeStreamFunction(name: name)
                if let input = block["input"]?.object,
                   !input.isEmpty,
                   let arguments = try? BurnBarBridgeJSON.encodeString(
                       BurnBarBridgeValue.object(input),
                       sortedKeys: true
                   ) {
                    function.arguments = arguments
                }
                return [
                    try Self.chatCompletionsSSEData(
                        id: streamID,
                        modelID: modelID,
                        created: created,
                        delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(toolCalls: [
                            ChatBridgeStreamChunk.ChatBridgeStreamToolCall(
                                index: toolIndex,
                                id: toolID,
                                type: "function",
                                function: function
                            ),
                        ]),
                        finishReason: .null,
                        usage: nil
                    ),
                ]
            }

            if type == "content_block_delta",
               let delta = payload.delta {
                if delta["type"]?.string == "text_delta",
                   let text = delta["text"]?.string,
                   !text.isEmpty {
                    return [
                        try Self.chatCompletionsSSEData(
                            id: streamID,
                            modelID: modelID,
                            created: created,
                            delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(content: text),
                            finishReason: .null,
                            usage: nil
                        ),
                    ]
                }
                if delta["type"]?.string == "input_json_delta",
                   let partialJSON = delta["partial_json"]?.string,
                   !partialJSON.isEmpty,
                   let blockIndex = payload.index?.asNonNegativeInt {
                    let toolBlock: AnthropicStreamToolBlock
                    if let existing = toolBlocks[blockIndex] {
                        toolBlock = existing
                    } else {
                        let synthesized = AnthropicStreamToolBlock(
                            id: "toolu_\(blockIndex)",
                            index: nextToolIndex,
                            name: "tool"
                        )
                        nextToolIndex += 1
                        toolBlocks[blockIndex] = synthesized
                        toolBlock = synthesized
                    }
                    return [
                        try Self.chatCompletionsSSEData(
                            id: streamID,
                            modelID: modelID,
                            created: created,
                            delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(toolCalls: [
                                ChatBridgeStreamChunk.ChatBridgeStreamToolCall(
                                    index: toolBlock.index,
                                    id: toolBlock.id,
                                    type: "function",
                                    function: ChatBridgeStreamChunk.ChatBridgeStreamToolCall.ChatBridgeStreamFunction(
                                        name: toolBlock.name,
                                        arguments: partialJSON
                                    )
                                ),
                            ]),
                            finishReason: .null,
                            usage: nil
                        ),
                    ]
                }
            }

            if type == "message_delta" {
                if let delta = payload.delta {
                    finishReason = ChatBridgeFinishReason.fromAnthropicStopReason(delta["stop_reason"]?.string)
                }
                if let eventUsage = payload.usage, eventUsage.object != nil {
                    usage.mergeAnthropicUsage(eventUsage)
                }
            }

            if type == "error" {
                return [try BurnBarBridgeJSON.sseData(
                    BurnBarBridgeValue.object(["error": event.raw["error"] ?? .string("Anthropic stream error")])
                )]
            }

            return []
        }

        func finishChunk() throws -> Data {
            try Self.chatCompletionsSSEData(
                id: streamID,
                modelID: modelID,
                created: created,
                delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta(),
                finishReason: finishReason,
                usage: usage.openAIUsageObject
            )
        }

        private static func chatCompletionsSSEData(
            id: String,
            modelID: String,
            created: Int,
            delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta,
            finishReason: ChatBridgeFinishReason,
            usage: ChatBridgeStreamUsage?
        ) throws -> Data {
            try BurnBarBridgeJSON.sseData(chatChunk(
                id: id,
                modelID: modelID,
                created: created,
                delta: delta,
                finishReason: finishReason,
                usage: usage
            ))
        }
    }

    private struct AnthropicStreamUsage {
        var inputTokens = 0
        var outputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var sawUsage = false

        mutating func mergeAnthropicUsage(_ usage: BurnBarBridgeValue) {
            sawUsage = true
            inputTokens = usage["input_tokens"]?.asPositiveInt ?? inputTokens
            outputTokens = usage["output_tokens"]?.asPositiveInt ?? outputTokens
            cacheCreationTokens = usage["cache_creation_input_tokens"]?.asPositiveInt ?? cacheCreationTokens
            cacheReadTokens = usage["cache_read_input_tokens"]?.asPositiveInt ?? cacheReadTokens
        }

        var openAIUsageObject: ChatBridgeStreamUsage? {
            guard sawUsage else { return nil }
            let promptTokens = inputTokens + cacheReadTokens
            return ChatBridgeStreamUsage(
                promptTokens: promptTokens,
                completionTokens: outputTokens,
                totalTokens: promptTokens + outputTokens + cacheCreationTokens,
                cacheCreationInputTokens: cacheCreationTokens,
                cachedTokens: cacheReadTokens
            )
        }
    }

    private struct AnthropicServerSentEventParser {
        private var buffer = ""

        mutating func consume(_ data: Data) -> [AnthropicStreamEvent] {
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            buffer += text.replacingOccurrences(of: "\r\n", with: "\n")
            return drainCompleteEvents()
        }

        mutating func finish() -> [AnthropicStreamEvent] {
            guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            defer { buffer.removeAll(keepingCapacity: false) }
            return parseEvent(buffer).map { [$0] } ?? []
        }

        private mutating func drainCompleteEvents() -> [AnthropicStreamEvent] {
            var events: [AnthropicStreamEvent] = []
            while let range = buffer.range(of: "\n\n") {
                let chunk = String(buffer[..<range.lowerBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                if let event = parseEvent(chunk) {
                    events.append(event)
                }
            }
            return events
        }

        private func parseEvent(_ chunk: String) -> AnthropicStreamEvent? {
            AnthropicStreamEventParser.parseEvent(chunk)
        }
    }

    static func responsesStreamFromAnthropicStream(
        _ response: BurnBarProviderProxyResponse,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let responseID = "resp_\(UUID().uuidString)"
        let itemID = "msg_\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var outputText = ""
        var output = Data()
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "response.created",
            payload: ResponsesBridgeEventCreated(response: baseResponseObject(id: responseID, itemID: itemID, modelID: modelID, created: created, outputText: "", status: "in_progress")),
            to: &output
        )
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "response.output_item.added",
            payload: ResponsesBridgeEventOutputItemAdded(
                type: "response.output_item.added",
                responseID: responseID,
                outputIndex: 0,
                item: .message(id: itemID, status: "in_progress", outputText: "", alwaysEmitPart: true)
            ),
            to: &output
        )
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "response.content_part.added",
            payload: ResponsesBridgeEventContentPartAdded(
                type: "response.content_part.added",
                responseID: responseID,
                itemID: itemID,
                outputIndex: 0,
                contentIndex: 0,
                part: ResponsesBridgeOutputText(text: "")
            ),
            to: &output
        )

        for event in serverSentEvents(from: response.body) {
            if event.payload.type == "content_block_delta",
               let delta = event.payload.delta,
               delta["type"]?.string == "text_delta",
               let text = delta["text"]?.string,
               !text.isEmpty {
                outputText += text
                try BurnBarBridgeJSON.appendNamedSSE(
                    event: "response.output_text.delta",
                    payload: ResponsesBridgeEventOutputTextDelta(
                        type: "response.output_text.delta",
                        responseID: responseID,
                        itemID: itemID,
                        outputIndex: 0,
                        contentIndex: 0,
                        delta: text
                    ),
                    to: &output
                )
            }
            if event.payload.type == "error" {
                try BurnBarBridgeJSON.appendNamedSSE(event: "error", payload: event.raw, to: &output)
            }
        }

        try BurnBarBridgeJSON.appendNamedSSE(
            event: "response.content_part.done",
            payload: ResponsesBridgeEventContentPartDone(
                type: "response.content_part.done",
                responseID: responseID,
                itemID: itemID,
                outputIndex: 0,
                contentIndex: 0,
                part: ResponsesBridgeOutputText(text: outputText)
            ),
            to: &output
        )
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "response.output_item.done",
            payload: ResponsesBridgeEventOutputItemDone(
                type: "response.output_item.done",
                responseID: responseID,
                outputIndex: 0,
                item: .message(id: itemID, status: "completed", outputText: outputText, alwaysEmitPart: true)
            ),
            to: &output
        )
        try BurnBarBridgeJSON.appendNamedSSE(
            event: "response.completed",
            payload: ResponsesBridgeEventCompleted(response: baseResponseObject(id: responseID, itemID: itemID, modelID: modelID, created: created, outputText: outputText, status: "completed")),
            to: &output
        )
        output.append(Data("data: [DONE]\n\n".utf8))
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            headers: response.headers,
            body: output,
            usage: response.usage
        )
    }

    private static func serverSentEvents(from data: Data) -> [AnthropicStreamEvent] {
        String(decoding: data, as: UTF8.self)
            .components(separatedBy: "\n\n")
            .compactMap(AnthropicStreamEventParser.parseEvent)
    }

    private static func chatChunk(
        id: String,
        modelID: String,
        created: Int,
        delta: ChatBridgeStreamChunk.ChatBridgeStreamDelta,
        finishReason: ChatBridgeFinishReason,
        usage: ChatBridgeStreamUsage? = nil
    ) -> ChatBridgeStreamChunk {
        ChatBridgeStreamChunk(
            id: id,
            object: "chat.completion.chunk",
            created: created,
            model: modelID,
            choices: [
                ChatBridgeStreamChunk.ChatBridgeStreamChoice(
                    index: 0,
                    delta: delta,
                    finishReason: finishReason
                ),
            ],
            usage: usage
        )
    }

    private static func baseResponseObject(
        id: String,
        itemID: String,
        modelID: String,
        created: Int,
        outputText: String,
        status: String
    ) -> ResponsesBridgeObject {
        ResponsesBridgeObject(
            id: id,
            object: "response",
            createdAt: created,
            model: modelID,
            status: status,
            output: [.message(id: itemID, status: status, outputText: outputText, alwaysEmitPart: true)],
            outputText: outputText
        )
    }
}

// MARK: - Shared Anthropic SSE frame parser

/// Parses one buffered SSE frame (`event:` + `data:` lines) into a typed
/// Anthropic stream event. Used by both the buffered and incremental translators.
enum AnthropicStreamEventParser {
    static func parseEvent(_ chunk: String) -> AnthropicStreamEvent? {
        var eventName: String?
        var dataLines: [String] = []
        for line in chunk.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event:") {
                eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let dataLine = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                if dataLine == "[DONE]" { return nil }
                dataLines.append(dataLine)
            }
        }
        guard !dataLines.isEmpty,
              let payloadData = dataLines.joined(separator: "\n").data(using: .utf8),
              let raw = try? BurnBarBridgeJSON.decode(BurnBarBridgeValue.self, from: payloadData),
              raw.object != nil,
              let payload = try? raw.decoded(as: AnthropicStreamEventPayload.self) else {
            return nil
        }
        return AnthropicStreamEvent(event: eventName, payload: payload, raw: raw)
    }
}
