import Foundation
import OpenBurnBarEngine

// MARK: - OpenAI-shape compatibility bridge (request/response translation)
//
// Moved out of OpenBurnBarAnthropicProviderExecutor.swift (god-type
// decomposition): Chat Completions / Responses <-> Anthropic Messages
// translation. Same module, same type, verbatim wire behavior.

extension BurnBarAnthropicProviderExecutor {

    static func anthropicMessagesBodyFromChatCompletionsRequest(
        _ body: Data,
        modelID: String,
        variant: BurnBarModelVariant? = nil
    ) throws -> (Data, Bool) {
        let request = try BurnBarBridgeJSON.decodeBridgeRequest(ChatBridgeInboundRequest.self, from: body)
        let (bridged, streamRequested) = try anthropicMessagesRequestFromChatRequest(
            request,
            modelID: modelID,
            variant: variant
        )
        return (try BurnBarBridgeJSON.encode(bridged, sortedKeys: true), streamRequested)
    }

    static func anthropicMessagesBodyFromResponsesRequest(
        _ body: Data,
        modelID: String,
        variant: BurnBarModelVariant? = nil
    ) throws -> (Data, Bool) {
        let request = try BurnBarBridgeJSON.decodeBridgeRequest(ResponsesBridgeInboundRequest.self, from: body)
        let chatRequest = try chatRequestFromResponsesRequest(request, modelID: modelID)
        let (bridged, streamRequested) = try anthropicMessagesRequestFromChatRequest(
            chatRequest,
            modelID: modelID,
            variant: variant
        )
        return (try BurnBarBridgeJSON.encode(bridged, sortedKeys: true), streamRequested)
    }

    private static func anthropicMessagesRequestFromChatRequest(
        _ request: ChatBridgeInboundRequest,
        modelID: String,
        variant: BurnBarModelVariant? = nil
    ) throws -> (AnthropicBridgedRequest, Bool) {
        guard let rawMessages = request.messages?.array, !rawMessages.isEmpty,
              let messages = try? rawMessages.map({ try $0.decoded(as: ChatBridgeInboundMessage.self) }) else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "OpenAI-compatible Anthropic bridge requires at least one message."
            )
        }

        var systemText: [String] = []
        var anthropicMessages: [AnthropicBridgedMessage] = []

        func appendMessage(role: String, content: [AnthropicBridgedBlock]) {
            guard !content.isEmpty else { return }
            if let last = anthropicMessages.last, last.role == role {
                anthropicMessages[anthropicMessages.count - 1].content.append(contentsOf: content)
            } else {
                anthropicMessages.append(AnthropicBridgedMessage(role: role, content: content))
            }
        }

        for message in messages {
            let role = message.role?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "user"
            if role == "system" || role == "developer" {
                let text = openAIContentText(message.content)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    systemText.append(text)
                }
                continue
            }

            if role == "tool" {
                guard let toolResult = anthropicToolResultBlock(from: message) else { continue }
                appendMessage(role: "user", content: [toolResult])
                continue
            }

            var contentBlocks = anthropicContentBlocks(from: message.content)
            if role == "assistant" {
                contentBlocks.append(contentsOf: anthropicToolUseBlocks(from: message.toolCalls))
            }
            guard !contentBlocks.isEmpty else { continue }

            appendMessage(role: role == "assistant" ? "assistant" : "user", content: contentBlocks)
        }

        guard !anthropicMessages.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "OpenAI-compatible Anthropic bridge could not derive any Anthropic messages from the request."
            )
        }

        var bridged = AnthropicBridgedRequest(
            model: modelID,
            maxTokens: maxTokens(from: request),
            messages: anthropicMessages
        )
        if !systemText.isEmpty {
            bridged.system = systemText.joined(separator: "\n\n")
        }
        bridged.temperature = request.temperature
        bridged.topP = request.topP
        if let stop = request.stop {
            bridged.stopSequences = stopSequences(from: stop)
        }
        if let tools = anthropicTools(from: request.tools), !tools.isEmpty {
            bridged.tools = tools
            bridged.toolChoice = anthropicToolChoice(from: request.toolChoice)
        }

        if wantsJSONMode(request) {
            bridged.system = (bridged.system.map { $0 + "\n\n" } ?? "") + "Return valid JSON only."
        }

        let streamRequested = request.stream?.bool ?? false
        if streamRequested {
            bridged.stream = true
        }
        if let variant {
            var thinkingValue: BurnBarBridgeValue? = bridged.thinking
            var maxTokensValue: BurnBarBridgeValue? = .int(bridged.maxTokens)
            Self.applyAnthropicVariant(
                variant,
                thinking: &thinkingValue,
                maxTokens: &maxTokensValue
            )
            bridged.thinking = thinkingValue
            bridged.maxTokens = maxTokensValue?.asPositiveInt ?? bridged.maxTokens
        }
        return (bridged, streamRequested)
    }

    private static func chatRequestFromResponsesRequest(
        _ request: ResponsesBridgeInboundRequest,
        modelID: String
    ) throws -> ChatBridgeInboundRequest {
        var messages: [BurnBarBridgeValue] = []
        if let instructions = request.instructions?.string,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(.object(["role": .string("system"), "content": .string(instructions)]))
        }

        if let existing = request.messages?.array, !existing.isEmpty,
           existing.allSatisfy({ $0.object != nil }) {
            messages.append(contentsOf: existing)
        } else if let input = request.input {
            messages.append(contentsOf: openAIMessagesFromResponsesInput(input))
        }

        guard !messages.isEmpty else {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Responses request must include input text or messages for Anthropic bridge routing."
            )
        }

        return ChatBridgeInboundRequest(
            messages: .array(messages),
            temperature: request.temperature,
            topP: request.topP,
            stop: request.stop,
            stream: request.stream,
            tools: request.tools,
            toolChoice: request.toolChoice,
            responseFormat: request.responseFormat ?? request.text?["format"],
            maxTokens: request.maxOutputTokens ?? request.maxTokens,
            maxCompletionTokens: nil,
            maxOutputTokens: nil
        )
    }

    private static func openAIMessagesFromResponsesInput(_ input: BurnBarBridgeValue) -> [BurnBarBridgeValue] {
        if let text = input.string {
            return [.object(["role": .string("user"), "content": .string(text)])]
        }
        guard let items = input.array, items.allSatisfy({ $0.object != nil }) else {
            return []
        }
        return items.compactMap { item in
            guard let object = item.object else { return nil }
            let content = object["content"] ?? object["text"]
            guard let content, !openAIContentIsEmpty(content) else { return nil }
            return .object([
                "role": object["role"] ?? .string("user"),
                "content": content,
            ])
        }
    }

    private static func maxTokens(from request: ChatBridgeInboundRequest) -> Int {
        request.maxTokens?.asPositiveInt
            ?? request.maxCompletionTokens?.asPositiveInt
            ?? request.maxOutputTokens?.asPositiveInt
            ?? 4096
    }

    private static func stopSequences(from value: BurnBarBridgeValue) -> BurnBarBridgeValue {
        if let string = value.string {
            return .array([.string(string)])
        }
        return value
    }

    private static func wantsJSONMode(_ request: ChatBridgeInboundRequest) -> Bool {
        guard let type = request.responseFormat?["type"]?.string else { return false }
        return type == "json_object" || type == "json_schema"
    }

    private static func anthropicContentBlocks(from value: BurnBarBridgeValue?) -> [AnthropicBridgedBlock] {
        guard let value else { return [] }
        if let text = value.string {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [AnthropicBridgedBlock(type: "text", text: text)]
        }
        guard let parts = value.array, parts.allSatisfy({ $0.object != nil }) else { return [] }
        return parts.compactMap { part in
            guard let view = try? part.decoded(as: ResponsesBridgeContentPart.self) else { return nil }
            return anthropicContentBlock(view)
        }
    }

    private static func openAIContentText(_ value: BurnBarBridgeValue?) -> String {
        guard let value else { return "" }
        if let text = value.string {
            return text
        }
        guard let parts = value.array, parts.allSatisfy({ $0.object != nil }) else {
            return ""
        }
        return parts.compactMap { part -> String? in
            guard let view = try? part.decoded(as: ResponsesBridgeContentPart.self) else { return nil }
            return view.text?.string ?? view.inputText?.string ?? view.outputText?.string
        }.joined(separator: "\n")
    }

    private static func openAIContentIsEmpty(_ value: BurnBarBridgeValue?) -> Bool {
        guard let value else { return true }
        if let text = value.string {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let parts = value.array {
            return parts.isEmpty
        }
        return false
    }

    private static func anthropicContentBlock(_ part: ResponsesBridgeContentPart) -> AnthropicBridgedBlock? {
        let type = part.type?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch type {
        case "text", "input_text", "output_text":
            guard let text = part.text?.string ?? part.inputText?.string ?? part.outputText?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AnthropicBridgedBlock(type: "text", text: text)
        case "image_url", "input_image":
            return anthropicImageBlock(from: part)
        case "file", "input_file":
            return anthropicDocumentBlock(from: part)
        default:
            if part.imageURL != nil || part.url != nil {
                return anthropicImageBlock(from: part)
            }
            if let text = part.text?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AnthropicBridgedBlock(type: "text", text: text)
            }
            return nil
        }
    }

    private static func anthropicImageBlock(from part: ResponsesBridgeContentPart) -> AnthropicBridgedBlock? {
        let imageURL = part.imageURL?["url"]?.string
            ?? part.imageURL?.string
            ?? part.url?.string
        guard let dataURL = imageURL,
              let parsed = parseDataURL(dataURL),
              parsed.mediaType.hasPrefix("image/") || parsed.mediaType == "application/pdf" else {
            return nil
        }
        if parsed.mediaType == "application/pdf" {
            return anthropicDocumentBlock(mediaType: parsed.mediaType, data: parsed.base64Data)
        }
        return AnthropicBridgedBlock(
            type: "image",
            source: AnthropicBridgedBlock.AnthropicBridgedSource(
                type: "base64",
                mediaType: parsed.mediaType,
                data: parsed.base64Data
            )
        )
    }

    private static func anthropicDocumentBlock(from part: ResponsesBridgeContentPart) -> AnthropicBridgedBlock? {
        let dataURL = part.file?["file_data"]?.string
            ?? part.file?["data"]?.string
            ?? part.fileData?.string
            ?? part.url?.string
        guard let dataURL,
              let parsed = parseDataURL(dataURL),
              parsed.mediaType == "application/pdf" else {
            return nil
        }
        return anthropicDocumentBlock(mediaType: parsed.mediaType, data: parsed.base64Data)
    }

    private static func anthropicDocumentBlock(mediaType: String, data: String) -> AnthropicBridgedBlock {
        AnthropicBridgedBlock(
            type: "document",
            source: AnthropicBridgedBlock.AnthropicBridgedSource(
                type: "base64",
                mediaType: mediaType,
                data: data
            )
        )
    }

    private static func parseDataURL(_ value: String) -> (mediaType: String, base64Data: String)? {
        guard value.lowercased().hasPrefix("data:"),
              let comma = value.firstIndex(of: ",") else {
            return nil
        }
        let metadata = value[value.index(value.startIndex, offsetBy: 5)..<comma]
        let payload = value[value.index(after: comma)...]
        let metadataParts = metadata.split(separator: ";").map(String.init)
        let mediaType = metadataParts.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard metadataParts.contains(where: { $0.caseInsensitiveCompare("base64") == .orderedSame }),
              let mediaType,
              !mediaType.isEmpty,
              !payload.isEmpty else {
            return nil
        }
        return (mediaType, String(payload))
    }

    private static func anthropicToolUseBlocks(from value: BurnBarBridgeValue?) -> [AnthropicBridgedBlock] {
        guard let calls = value?.array, calls.allSatisfy({ $0.object != nil }) else { return [] }
        return calls.compactMap { call in
            guard let view = try? call.decoded(as: ChatBridgeInboundToolCall.self),
                  let id = view.id?.string,
                  let name = view.function?["name"]?.string,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let arguments = view.function?["arguments"]
            return AnthropicBridgedBlock(
                type: "tool_use",
                id: id,
                name: name,
                input: objectFromJSONString(arguments?.string) ?? .object(["arguments": arguments ?? .string("")])
            )
        }
    }

    private static func anthropicToolResultBlock(from message: ChatBridgeInboundMessage) -> AnthropicBridgedBlock? {
        guard let id = message.toolCallID?.string, !id.isEmpty else {
            return nil
        }
        return AnthropicBridgedBlock(
            type: "tool_result",
            toolUseID: id,
            content: openAIContentText(message.content)
        )
    }

    private static func anthropicTools(from value: BurnBarBridgeValue?) -> [AnthropicBridgedTool]? {
        guard let tools = value?.array, tools.allSatisfy({ $0.object != nil }) else { return nil }
        return tools.compactMap { tool -> AnthropicBridgedTool? in
            guard let view = try? tool.decoded(as: ChatBridgeInboundTool.self) else {
                return nil
            }
            let function = view.function?.object.map(BurnBarBridgeValue.object)
            guard let name = function?["name"]?.string ?? view.name?.string,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let inputSchema = function?["parameters"]
                ?? view.parameters
                ?? .object(["type": .string("object"), "properties": .object([:])])
            let description = function?["description"]?.string ?? view.toolDescription?.string
            return AnthropicBridgedTool(
                name: name,
                inputSchema: inputSchema,
                toolDescription: description.flatMap { $0.isEmpty ? nil : $0 }
            )
        }
    }

    private static func anthropicToolChoice(from value: BurnBarBridgeValue?) -> AnthropicBridgedToolChoice? {
        if let string = value?.string {
            switch string {
            case "required":
                return AnthropicBridgedToolChoice(type: "any")
            case "auto":
                return AnthropicBridgedToolChoice(type: "auto")
            case "none":
                return nil
            default:
                return nil
            }
        }
        guard let value, value.object != nil else { return nil }
        if let name = value["name"]?.string ?? value["function"]?["name"]?.string,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AnthropicBridgedToolChoice(type: "tool", name: name)
        }
        if value["type"]?.string == "required" {
            return AnthropicBridgedToolChoice(type: "any")
        }
        return nil
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

    static func chatCompletionsBodyFromAnthropicMessage(
        _ body: Data,
        modelID: String
    ) throws -> Data {
        let message = try BurnBarBridgeJSON.decodeBridgeRequest(AnthropicInboundMessage.self, from: body)
        let content = anthropicMessageContent(from: message)
        let outbound = ChatBridgeCompletion(
            id: "chatcmpl_\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: modelID,
            choices: [
                ChatBridgeCompletion.ChatBridgeCompletionChoice(
                    index: 0,
                    message: ChatBridgeOutboundMessage(
                        role: "assistant",
                        content: content.text.isEmpty && !content.toolCalls.isEmpty
                            ? .null : .string(content.text),
                        toolCalls: content.toolCalls.isEmpty
                            ? nil : try BurnBarBridgeJSON.bridgeValue(content.toolCalls)
                    ),
                    finishReason: ChatBridgeFinishReason.fromAnthropicStopReason(message.stopReason?.string)
                ),
            ],
            usage: openAIUsage(fromAnthropicMessage: message)
        )
        return try BurnBarBridgeJSON.encode(outbound, sortedKeys: true)
    }

    static func responsesBodyFromAnthropicMessage(
        _ body: Data,
        modelID: String
    ) throws -> Data {
        let message = try BurnBarBridgeJSON.decodeBridgeRequest(AnthropicInboundMessage.self, from: body)
        let content = anthropicMessageContent(from: message)
        let responseID = "resp_\(UUID().uuidString)"
        let messageID = "msg_\(UUID().uuidString)"
        var output: [ResponsesBridgeOutputItem] = []
        if !content.text.isEmpty {
            output.append(.message(id: messageID, status: "completed", outputText: content.text, alwaysEmitPart: true))
        }
        for toolCall in content.toolCalls {
            output.append(.functionCall(
                id: "fc_\(UUID().uuidString)",
                status: "completed",
                callID: toolCall.id,
                name: toolCall.function.name,
                arguments: toolCall.function.arguments
            ))
        }
        if output.isEmpty {
            output.append(.message(id: messageID, status: "completed", outputText: "", alwaysEmitPart: false))
        }
        let usage = message.usage
        let usageInput = usage?["input_tokens"]?.asPositiveInt ?? 0
        let usageOutput = usage?["output_tokens"]?.asPositiveInt ?? 0
        let outbound = ResponsesBridgeObject(
            id: responseID,
            object: "response",
            createdAt: Int(Date().timeIntervalSince1970),
            model: modelID,
            status: "completed",
            output: output,
            outputText: content.text,
            usage: ResponsesBridgeUsageOut(
                inputTokens: usageInput,
                outputTokens: usageOutput,
                totalTokens: usageInput + usageOutput,
                reasoningTokens: nil
            )
        )
        return try BurnBarBridgeJSON.encode(outbound, sortedKeys: true)
    }

    private static func anthropicMessageContent(
        from message: AnthropicInboundMessage
    ) -> (text: String, toolCalls: [ChatBridgeOutboundToolCall]) {
        guard let blocks = message.content?.array, blocks.allSatisfy({ $0.object != nil }) else {
            return ("", [])
        }
        var textParts: [String] = []
        var toolCalls: [ChatBridgeOutboundToolCall] = []
        for block in blocks {
            guard let view = try? block.decoded(as: AnthropicContentBlockWire.self) else { continue }
            let type = view.type?.string
            if type == "text", let text = view.text?.string {
                textParts.append(text)
            } else if type == "tool_use",
                      let id = view.id?.string,
                      let name = view.name?.string {
                let input = (view.input?.object).map(BurnBarBridgeValue.object) ?? .object([:])
                let arguments = (try? BurnBarBridgeJSON.encodeString(input, sortedKeys: true)) ?? "{}"
                toolCalls.append(ChatBridgeOutboundToolCall(
                    id: id,
                    type: "function",
                    function: ChatBridgeOutboundToolCall.ChatBridgeOutboundFunction(
                        name: name,
                        arguments: arguments
                    )
                ))
            }
        }
        return (textParts.joined(), toolCalls)
    }

    private static func openAIUsage(fromAnthropicMessage message: AnthropicInboundMessage) -> ChatBridgeUsage {
        let input = message.usage?["input_tokens"]?.asPositiveInt ?? 0
        let output = message.usage?["output_tokens"]?.asPositiveInt ?? 0
        return ChatBridgeUsage(promptTokens: input, completionTokens: output, totalTokens: input + output)
    }
}
