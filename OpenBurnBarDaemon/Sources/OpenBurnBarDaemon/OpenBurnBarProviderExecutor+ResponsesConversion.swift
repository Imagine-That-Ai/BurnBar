import OpenBurnBarEngine
import Foundation

// OpenAI Responses API <-> Chat Completions request/response/stream conversion.
// Extracted from OpenBurnBarProviderExecutor.swift (god-type decomposition) — same module, same isolation, verbatim.

extension BurnBarOpenAICompatibleProviderExecutor {

    static func chatCompletionsBodyFromResponsesRequest(
        _ body: Data,
        modelID: String
    ) throws -> (Data, Bool) {
        let request = try BurnBarBridgeJSON.decodeBridgeRequest(ResponsesBridgeInboundRequest.self, from: body)

        let streamRequested = request.stream?.bool ?? false
        var messages: [ChatBridgeOutboundMessage] = []
        if let instructions = request.instructions?.string,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ChatBridgeOutboundMessage(role: "system", content: .string(instructions)))
        }

        if let existing = request.messages?.array, !existing.isEmpty,
           existing.allSatisfy({ $0.object != nil }) {
            messages.append(contentsOf: sanitizedChatMessages(existing))
        } else if let input = request.input {
            messages.append(contentsOf: messagesFromResponsesInput(input))
        }
        messages = coalescedSystemMessages(messages)

        if messages.isEmpty {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Responses request must include input text or messages for chat-completions fallback."
            )
        }

        var chat = ChatBridgeOutboundRequest(model: modelID, messages: messages)
        chat.temperature = request.temperature
        chat.topP = request.topP
        chat.stop = request.stop
        chat.stream = request.stream
        chat.presencePenalty = request.presencePenalty
        chat.frequencyPenalty = request.frequencyPenalty
        chat.logitBias = request.logitBias
        chat.seed = request.seed
        chat.user = request.user
        chat.responseFormat = request.responseFormat
        chat.maxTokens = request.maxTokens
        chat.tools = request.tools
        chat.toolChoice = request.toolChoice
        if chat.maxTokens == nil, let maxOutputTokens = request.maxOutputTokens {
            chat.maxTokens = maxOutputTokens
        }
        if chat.responseFormat == nil,
           let format = request.text?["format"], format.object != nil {
            chat.responseFormat = format
        }
        try normalizeResponsesToolsForChatCompletions(&chat)

        return (try BurnBarBridgeJSON.encode(chat, sortedKeys: false), streamRequested)
    }

    static func normalizeResponsesToolsForChatCompletions(_ request: inout ChatBridgeOutboundRequest) throws {
        if let tools = request.tools?.array, tools.allSatisfy({ $0.object != nil }) {
            let normalized = tools.compactMap(chatCompletionsTool)
            request.tools = normalized.isEmpty
                ? nil
                : try BurnBarBridgeJSON.bridgeValue(normalized)
        }

        guard let toolChoice = request.toolChoice, toolChoice.object != nil else {
            return
        }
        guard let toolName = toolChoice["name"]?.string
                ?? toolChoice["function"]?["name"]?.string,
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            request.toolChoice = nil
            return
        }
        request.toolChoice = .object([
            "type": .string("function"),
            "function": .object(["name": .string(toolName)]),
        ])
    }

    static func chatCompletionsTool(_ tool: BurnBarBridgeValue) -> ChatBridgeOutboundTool? {
        guard tool.object != nil,
              let view = try? tool.decoded(as: ChatBridgeInboundTool.self) else {
            return nil
        }
        let function = view.function?.object.map(BurnBarBridgeValue.object)
        if let type = view.type?.string,
           type.lowercased() != "function",
           function == nil {
            return nil
        }
        guard let name = function?["name"]?.string ?? view.name?.string,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let description = function?["description"]?.string ?? view.toolDescription?.string
        let parameters = function?["parameters"]
            ?? function?["input_schema"]
            ?? view.parameters
            ?? view.inputSchema
            ?? .object(["type": .string("object"), "properties": .object([:])])

        return ChatBridgeOutboundTool(
            type: "function",
            function: ChatBridgeOutboundTool.ChatBridgeOutboundToolFunction(
                name: name,
                toolDescription: description.flatMap { $0.isEmpty ? nil : $0 },
                parameters: parameters,
                strict: function?["strict"]?.bool ?? view.strict?.bool
            )
        )
    }

    static func sanitizedChatMessages(_ messages: [BurnBarBridgeValue]) -> [ChatBridgeOutboundMessage] {
        messages.compactMap(sanitizedChatMessage)
    }

    static func coalescedSystemMessages(_ messages: [ChatBridgeOutboundMessage]) -> [ChatBridgeOutboundMessage] {
        var systemText: [String] = []
        var orderedNonSystemMessages: [ChatBridgeOutboundMessage] = []

        for message in messages {
            if message.role == "system",
               case .string(let content) = message.content,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                systemText.append(content)
            } else {
                orderedNonSystemMessages.append(message)
            }
        }

        guard !systemText.isEmpty else {
            return orderedNonSystemMessages
        }

        return [ChatBridgeOutboundMessage(role: "system", content: .string(systemText.joined(separator: "\n\n")))]
            + orderedNonSystemMessages
    }

    static func sanitizedChatMessage(_ message: BurnBarBridgeValue) -> ChatBridgeOutboundMessage? {
        guard let item = try? message.decoded(as: ResponsesBridgeInboundItem.self),
              let content = chatBridgeContent(from: item.content ?? item.text),
              !chatCompletionsContentIsEmpty(content) else {
            return nil
        }

        var sanitized = ChatBridgeOutboundMessage(
            role: chatCompletionsRole(item.role?.string),
            content: content
        )
        if let name = item.name?.string, !name.isEmpty {
            sanitized.name = name
        }
        if let toolCallID = item.toolCallID?.string, !toolCallID.isEmpty {
            sanitized.toolCallID = toolCallID
        }
        if let toolCalls = item.toolCalls {
            sanitized.toolCalls = toolCalls
        }
        return sanitized
    }

    static func chatCompletionsRole(_ role: String?) -> String {
        switch role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "system", "developer":
            return "system"
        case "assistant":
            return "assistant"
        case "tool":
            return "tool"
        default:
            return "user"
        }
    }

    static func messagesFromResponsesInput(_ input: BurnBarBridgeValue) -> [ChatBridgeOutboundMessage] {
        if let string = input.string {
            return [ChatBridgeOutboundMessage(role: "user", content: .string(string))]
        }

        guard let items = input.array, items.allSatisfy({ $0.object != nil }) else {
            return []
        }

        return items.compactMap { item in
            guard let view = try? item.decoded(as: ResponsesBridgeInboundItem.self),
                  let content = chatBridgeContent(from: view.content ?? view.text),
                  !chatCompletionsContentIsEmpty(content) else {
                return nil
            }
            return ChatBridgeOutboundMessage(role: chatCompletionsRole(view.role?.string), content: content)
        }
    }

    /// Untyped entry point kept for `normalizeOpenAICompatibleMessages`: the
    /// main executor passes schemaless content through this bridge helper.
    static func chatCompletionsContent(from value: Any?) -> Any? {
        guard let input = BurnBarBridgeValue.from(untyped: value),
              let converted = chatBridgeContent(from: input) else {
            return nil
        }
        // Plain strings return directly: JSONSerialization refuses top-level
        // fragments, so they cannot round-trip through `jsonObject`.
        if case .string(let text) = converted {
            return text
        }
        guard let data = try? BurnBarBridgeJSON.encode(converted, sortedKeys: false),
              let untyped = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return untyped
    }

    static func chatBridgeContent(from value: BurnBarBridgeValue?) -> ChatBridgeOutboundContent? {
        guard let value else { return nil }
        if let string = value.string {
            return .string(string)
        }
        guard let parts = value.array, parts.allSatisfy({ $0.object != nil }) else {
            return nil
        }
        let converted = parts.compactMap { part -> ChatBridgeOutboundPart? in
            guard let view = try? part.decoded(as: ResponsesBridgeContentPart.self) else { return nil }
            return chatBridgeContentPart(view, original: part)
        }
        if !converted.isEmpty {
            return .parts(converted)
        }
        let text = responsesBridgeContentText(value)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .string(text)
    }

    static func chatBridgeContentPart(
        _ part: ResponsesBridgeContentPart,
        original: BurnBarBridgeValue
    ) -> ChatBridgeOutboundPart? {
        let type = part.type?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch type {
        case "text":
            guard let text = part.text?.string else { return nil }
            return ChatBridgeOutboundPart(type: .string("text"), text: .string(text))
        case "input_text", "output_text":
            guard let text = part.text?.string
                ?? part.inputText?.string
                ?? part.outputText?.string else { return nil }
            return ChatBridgeOutboundPart(type: .string("text"), text: .string(text))
        case "image_url":
            if let imageURL = part.imageURL?.object {
                return ChatBridgeOutboundPart(
                    type: .string("image_url"),
                    imageURL: .object(imageURL)
                )
            }
            if let imageURL = part.imageURL?.string {
                return ChatBridgeOutboundPart(
                    type: .string("image_url"),
                    imageURL: .object(["url": .string(imageURL)])
                )
            }
            return nil
        case "input_image":
            if let imageURL = part.imageURL?.string ?? part.url?.string {
                return ChatBridgeOutboundPart(
                    type: .string("image_url"),
                    imageURL: .object(["url": .string(imageURL)])
                )
            }
            if let imageURL = part.imageURL?.object {
                return ChatBridgeOutboundPart(
                    type: .string("image_url"),
                    imageURL: .object(imageURL)
                )
            }
            return nil
        case "input_audio":
            guard part.inputAudio != nil else { return nil }
            return chatBridgePartPreserving(original, type: nil)
        case "file", "input_file":
            // Responses clients use `input_file` for PDFs and other
            // document inputs. A provider that lacks `/responses` falls
            // back to Chat Completions, whose compatible native wire shape
            // is the same data URL used by the macOS attachment encoder.
            // File IDs and remote URLs cannot be dereferenced by this
            // bounded bridge, so leave those out rather than silently
            // forwarding an unsupported part.
            guard let dataURL = responsesInputFileDataURL(from: part) else {
                return nil
            }
            return fileOrImagePart(dataURL: dataURL, filename: responsesInputFileName(from: part))
        default:
            if part.imageURL != nil {
                return chatBridgePartPreserving(original, type: "image_url")
            }
            if part.inputAudio != nil {
                return chatBridgePartPreserving(original, type: "input_audio")
            }
            if part.file != nil || part.fileData != nil {
                guard let dataURL = responsesInputFileDataURL(from: part) else { return nil }
                var file: [String: BurnBarBridgeValue] = ["file_data": .string(dataURL)]
                if let filename = responsesInputFileName(from: part) {
                    file["filename"] = .string(filename)
                }
                return ChatBridgeOutboundPart(type: .string("file"), file: .object(file))
            }
            if let text = part.text?.string {
                return ChatBridgeOutboundPart(type: .string("text"), text: .string(text))
            }
            return nil
        }
    }

    private static func fileOrImagePart(dataURL: String, filename: String?) -> ChatBridgeOutboundPart {
        if dataURLMediaType(dataURL) == "application/pdf" {
            var file: [String: BurnBarBridgeValue] = ["file_data": .string(dataURL)]
            if let filename {
                file["filename"] = .string(filename)
            }
            return ChatBridgeOutboundPart(type: .string("file"), file: .object(file))
        }
        return ChatBridgeOutboundPart(
            type: .string("image_url"),
            imageURL: .object(["url": .string(dataURL), "detail": .string("auto")])
        )
    }

    /// Preserve an input part verbatim (unknown keys included), optionally
    /// forcing its `type` marker. Used for `input_audio` and untyped fallbacks.
    private static func chatBridgePartPreserving(
        _ original: BurnBarBridgeValue,
        type: String?
    ) -> ChatBridgeOutboundPart? {
        guard var part = try? original.decoded(as: ChatBridgeOutboundPart.self) else { return nil }
        if let type {
            part.type = .string(type)
        }
        return part
    }

    private static func responsesInputFileDataURL(from part: ResponsesBridgeContentPart) -> String? {
        let candidate = part.fileData?.string
            ?? part.data?.string
            ?? part.file?["file_data"]?.string
            ?? part.file?["data"]?.string
        guard let candidate,
              candidate.lowercased().hasPrefix("data:"),
              let comma = candidate.firstIndex(of: ",") else {
            return nil
        }
        let metadata = candidate[candidate.index(candidate.startIndex, offsetBy: 5)..<comma]
        let payload = candidate[candidate.index(after: comma)...]
        let components = metadata.split(separator: ";").map(String.init)
        guard components.contains(where: { $0.caseInsensitiveCompare("base64") == .orderedSame }),
              !payload.isEmpty,
              let mediaType = components.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              mediaType == "application/pdf" || mediaType.hasPrefix("image/") else {
            return nil
        }
        return candidate
    }

    private static func responsesInputFileName(from part: ResponsesBridgeContentPart) -> String? {
        let candidate = part.filename?.string
            ?? part.file?["filename"]?.string
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty,
              trimmed.count <= 256,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            return nil
        }
        return trimmed
    }

    private static func dataURLMediaType(_ value: String) -> String {
        guard value.lowercased().hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else {
            return ""
        }
        return value[value.index(value.startIndex, offsetBy: 5)..<comma]
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    static func chatCompletionsContentIsEmpty(_ value: ChatBridgeOutboundContent) -> Bool {
        switch value {
        case .string(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .parts(let parts):
            return parts.isEmpty
        case .null:
            return true
        }
    }

    static func responsesContentText(_ value: Any?) -> String {
        guard let input = BurnBarBridgeValue.from(untyped: value) else { return "" }
        return responsesBridgeContentText(input)
    }

    static func responsesBridgeContentText(_ value: BurnBarBridgeValue?) -> String {
        guard let value else { return "" }
        if let string = value.string {
            return string
        }
        if let parts = value.array, parts.allSatisfy({ $0.object != nil }) {
            return parts.compactMap { part in
                guard let view = try? part.decoded(as: ResponsesBridgeContentPart.self) else { return nil }
                return view.text?.string ?? view.inputText?.string ?? view.outputText?.string
            }
            .joined(separator: "\n")
        }
        return ""
    }

    static func responsesBodyFromChatCompletion(
        _ chatBody: Data,
        modelID: String
    ) throws -> Data {
        let decoded = try JSONDecoder().decode(ProviderCompletionResponse.self, from: chatBody)
        let outputText = decoded.choices.first?.message.content ?? ""
        let usage = decoded.usage?.normalized(
            inputHint: max(1, chatBody.count / 4),
            outputHint: max(1, outputText.count / 4)
        )
        return try responseBody(
            id: "resp_\(UUID().uuidString)",
            modelID: modelID,
            outputText: outputText,
            usage: usage
        )
    }

    static func responsesStreamFromChatCompletionStream(
        _ chatResponse: BurnBarProviderProxyResponse,
        modelID: String
    ) throws -> BurnBarProviderProxyResponse {
        let responseID = "resp_\(UUID().uuidString)"
        let itemID = "msg_\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var outputText = ""
        var didEmitDelta = false
        var sse = Data()

        try appendResponseServerSentEvent(
            event: "response.created",
            payload: ResponsesBridgeEventCreated(response: baseResponsesObject(
                id: responseID,
                itemID: itemID,
                modelID: modelID,
                created: created,
                status: "in_progress",
                outputText: "",
                usage: nil
            )),
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.output_item.added",
            payload: ResponsesBridgeEventOutputItemAdded(
                type: "response.output_item.added",
                responseID: responseID,
                outputIndex: 0,
                item: responseMessageItem(itemID: itemID, status: "in_progress", outputText: "")
            ),
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.content_part.added",
            payload: ResponsesBridgeEventContentPartAdded(
                type: "response.content_part.added",
                responseID: responseID,
                itemID: itemID,
                outputIndex: 0,
                contentIndex: 0,
                part: ResponsesBridgeOutputText(text: "")
            ),
            to: &sse
        )

        let lines = String(decoding: chatResponse.body, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                break
            }
            guard let data = payload.data(using: .utf8) else { continue }
            // Mirror the legacy guard-try: malformed SSE data lines abort the
            // conversion with the parse error; valid-but-unexpected lines skip.
            _ = try JSONSerialization.jsonObject(with: data)
            guard let chunk = try? JSONDecoder().decode(ChatBridgeInboundCompletion.self, from: data),
                  let firstChoice = chunk.choices?.first else {
                continue
            }
            let content = firstChoice.delta?.content?.string
                ?? firstChoice.message?.content?.string
                ?? ""
            guard !content.isEmpty else { continue }
            outputText += content
            didEmitDelta = true
            try appendResponseServerSentEvent(
                event: "response.output_text.delta",
                payload: ResponsesBridgeEventOutputTextDelta(
                    type: "response.output_text.delta",
                    responseID: responseID,
                    itemID: itemID,
                    outputIndex: 0,
                    contentIndex: 0,
                    delta: content
                ),
                to: &sse
            )
        }

        if !didEmitDelta,
           let decoded = try? JSONDecoder().decode(ProviderCompletionResponse.self, from: chatResponse.body) {
            let content = decoded.choices.first?.message.content ?? ""
            if !content.isEmpty {
                outputText = content
                try appendResponseServerSentEvent(
                    event: "response.output_text.delta",
                    payload: ResponsesBridgeEventOutputTextDelta(
                        type: "response.output_text.delta",
                        responseID: responseID,
                        itemID: itemID,
                        outputIndex: 0,
                        contentIndex: 0,
                        delta: content
                    ),
                    to: &sse
                )
            }
        }

        try appendResponseServerSentEvent(
            event: "response.output_text.done",
            payload: ResponsesBridgeEventOutputTextDone(
                type: "response.output_text.done",
                responseID: responseID,
                itemID: itemID,
                outputIndex: 0,
                contentIndex: 0,
                text: outputText
            ),
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.content_part.done",
            payload: ResponsesBridgeEventContentPartDone(
                type: "response.content_part.done",
                responseID: responseID,
                itemID: itemID,
                outputIndex: 0,
                contentIndex: 0,
                part: ResponsesBridgeOutputText(text: outputText)
            ),
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.output_item.done",
            payload: ResponsesBridgeEventOutputItemDone(
                type: "response.output_item.done",
                responseID: responseID,
                outputIndex: 0,
                item: responseMessageItem(itemID: itemID, status: "completed", outputText: outputText)
            ),
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.completed",
            payload: ResponsesBridgeEventCompleted(response: baseResponsesObject(
                id: responseID,
                itemID: itemID,
                modelID: modelID,
                created: created,
                status: "completed",
                outputText: outputText,
                usage: chatResponse.usage
            )),
            to: &sse
        )
        sse.append(Data("data: [DONE]\n\n".utf8))

        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            headers: chatResponse.headers,
            body: sse,
            usage: chatResponse.usage
        )
    }

    static func responseBody(
        id: String,
        modelID: String,
        outputText: String,
        usage: ProviderCompletionResponse.Usage.NormalizedUsage?
    ) throws -> Data {
        let object = baseResponsesObject(
            id: id,
            modelID: modelID,
            created: Int(Date().timeIntervalSince1970),
            status: "completed",
            outputText: outputText,
            usage: usage.map {
                BurnBarProviderProxyUsage(
                    inputTokens: $0.promptTokens,
                    outputTokens: $0.completionTokens,
                    cacheCreationTokens: $0.cacheCreationTokens,
                    cacheReadTokens: $0.cacheReadTokens,
                    reasoningTokens: $0.reasoningTokens,
                    confidence: .exact
                )
            }
        )
        return try BurnBarBridgeJSON.encode(object, sortedKeys: false)
    }

    static func baseResponsesObject(
        id: String,
        itemID: String = "msg_\(UUID().uuidString)",
        modelID: String,
        created: Int,
        status: String,
        outputText: String,
        usage: BurnBarProviderProxyUsage?
    ) -> ResponsesBridgeObject {
        ResponsesBridgeObject(
            id: id,
            object: "response",
            createdAt: created,
            model: modelID,
            status: status,
            output: [.message(id: itemID, status: status, outputText: outputText, alwaysEmitPart: true)],
            outputText: outputText,
            usage: usage.map {
                ResponsesBridgeUsageOut(
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    totalTokens: $0.inputTokens + $0.outputTokens + $0.cacheCreationTokens + $0.cacheReadTokens,
                    reasoningTokens: $0.reasoningTokens
                )
            }
        )
    }

    static func responseMessageItem(
        itemID: String,
        status: String,
        outputText: String
    ) -> ResponsesBridgeOutputItem {
        .message(id: itemID, status: status, outputText: outputText, alwaysEmitPart: false)
    }

    static func appendResponseServerSentEvent(
        event: String,
        payload: some Encodable,
        to data: inout Data
    ) throws {
        try BurnBarBridgeJSON.appendNamedSSE(event: event, payload: payload, to: &data)
    }

    static func extractResponsesUsage(responseBody: Data) -> BurnBarProviderProxyUsage? {
        guard let envelope = try? JSONDecoder().decode(ResponsesUsageEnvelope.self, from: responseBody),
              let usage = envelope.usage else {
            return nil
        }

        var inputTokens = usage.inputTokens?.asInt
            ?? usage.promptTokens?.asInt
            ?? 0
        let outputTokens = usage.outputTokens?.asInt
            ?? usage.completionTokens?.asInt
            ?? 0
        let cacheCreationTokens = usage.cacheCreationInputTokens?.asInt
            ?? usage.cacheCreationTokens?.asInt
            ?? 0
        let exclusiveCacheReadTokens = usage.cacheReadInputTokens?.asInt
            ?? usage.cacheReadTokens?.asInt
            ?? 0
        let inclusiveCacheReadTokens = usage.inputCachedTokens?.asInt
            ?? usage.cachedInputTokens?.asInt
            ?? usage.cachedTokens?.asInt
            ?? usage.promptTokensDetails?["cached_tokens"]?.asInt
            ?? usage.inputTokensDetails?["cached_tokens"]?.asInt
            ?? 0
        let cacheReadTokens = exclusiveCacheReadTokens > 0 ? exclusiveCacheReadTokens : inclusiveCacheReadTokens
        if inclusiveCacheReadTokens > 0 && exclusiveCacheReadTokens == 0 {
            inputTokens = max(inputTokens - inclusiveCacheReadTokens, 0)
        }
        let reasoningTokens = usage.reasoningTokens?.asInt ?? 0

        guard inputTokens > 0 || outputTokens > 0 || cacheCreationTokens > 0 || cacheReadTokens > 0 || reasoningTokens > 0 else {
            return nil
        }

        return BurnBarProviderProxyUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            reasoningTokens: reasoningTokens,
            confidence: .exact
        )
    }
}
