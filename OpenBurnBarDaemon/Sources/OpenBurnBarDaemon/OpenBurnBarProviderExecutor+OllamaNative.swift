import OpenBurnBarEngine
import Foundation

// Ollama native chat API <-> OpenAI-compatible request/response/stream conversion.
// Extracted from OpenBurnBarProviderExecutor.swift (god-type decomposition) — same module, same isolation, verbatim.

extension BurnBarOpenAICompatibleProviderExecutor {

    static func shouldUseOllamaNativeAPI(route: BurnBarProviderRoute, baseURL: URL) -> Bool {
        let providerID = route.providerID.lowercased()
        guard providerID == "ollama" || providerID == "ollama-local" else { return false }
        return !baseURL.path.lowercased().hasSuffix("/v1")
    }

    static func ollamaNativeChatEndpoint(baseURL: URL) -> URL {
        let normalizedPath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if normalizedPath == "api" || normalizedPath.hasSuffix("/api") {
            return baseURL.appending(path: "chat")
        }
        return baseURL.appending(path: "api").appending(path: "chat")
    }

    static func ollamaNativeRequestBody(
        from body: Data,
        modelID: String
    ) throws -> (Data, Bool) {
        var request = try BurnBarBridgeJSON.decodeBridgeRequest(OllamaNativeBridgeRequest.self, from: body)

        let streamRequested = request.stream?.bool ?? false
        request.model = .string(modelID)
        request.stream = .bool(streamRequested)

        if let responseFormat = request.responseFormat, responseFormat.object != nil {
            if responseFormat["type"]?.string == "json_object" {
                request.additionalFields["format"] = .string("json")
            } else if let schema = responseFormat["json_schema"]?["schema"] {
                request.additionalFields["format"] = schema
            }
        }
        request.responseFormat = nil

        var options = request.options?.object ?? [:]
        moveOpenAIOption("max_completion_tokens", to: "num_predict", from: &request, options: &options)
        moveOpenAIOption("max_tokens", to: "num_predict", from: &request, options: &options)
        moveOpenAIOption("temperature", to: "temperature", from: &request, options: &options)
        moveOpenAIOption("top_p", to: "top_p", from: &request, options: &options)
        if !options.isEmpty {
            request.options = .object(options)
        }

        if let effort = request.reasoning?["effort"]?.string {
            applyOllamaThinkValue(effort, to: &request)
        }
        request.reasoning = nil
        if let effort = request.reasoningEffort?.string {
            applyOllamaThinkValue(effort, to: &request)
        }
        request.reasoningEffort = nil

        for unsupportedKey in ["n", "user", "logit_bias", "presence_penalty", "frequency_penalty", "stream_options", "tool_choice"] {
            request.additionalFields.removeValue(forKey: unsupportedKey)
        }

        normalizeOllamaNativeMessages(in: &request)

        return (try BurnBarBridgeJSON.encode(request, sortedKeys: false), streamRequested)
    }

    static func normalizeOllamaNativeMessages(in request: inout OllamaNativeBridgeRequest) {
        guard let messages = request.messages?.array, messages.allSatisfy({ $0.object != nil }) else { return }
        request.messages = .array(messages.map { message in
            guard var view = try? message.decoded(as: OllamaBridgeMessage.self) else { return message }
            view.toolCalls = normalizeOllamaNativeToolCalls(view.toolCalls)
            view.toolCallsCamel = normalizeOllamaNativeToolCalls(view.toolCallsCamel)
            if view.content == .some(.null) {
                view.content = .string("")
            } else if let content = view.content,
                      content.string == nil {
                view.content = .string(responsesBridgeContentText(content))
            }
            return view.bridgeValue()
        })
    }

    static func normalizeOllamaNativeToolCalls(_ value: BurnBarBridgeValue?) -> BurnBarBridgeValue? {
        guard let value,
              let calls = value.array,
              calls.allSatisfy({ $0.object != nil }) else {
            return value
        }
        return .array(calls.map { call in
            guard var view = try? call.decoded(as: OllamaBridgeToolCall.self),
                  let function = view.function?.object,
                  let arguments = function["arguments"]?.string else {
                return call
            }
            var updated = function
            updated["arguments"] = ollamaNativeArgumentsObject(from: arguments)
            view.function = .object(updated)
            return view.bridgeValue()
        })
    }

    static func ollamaNativeArgumentsObject(from string: String) -> BurnBarBridgeValue {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? BurnBarBridgeJSON.decode(BurnBarBridgeValue.self, from: data) else {
            return .object([:])
        }
        return object
    }

    static func moveOpenAIOption(
        _ sourceKey: String,
        to targetKey: String,
        from request: inout OllamaNativeBridgeRequest,
        options: inout [String: BurnBarBridgeValue]
    ) {
        let value: BurnBarBridgeValue?
        switch sourceKey {
        case "max_completion_tokens":
            value = request.maxCompletionTokens
            request.maxCompletionTokens = nil
        case "max_tokens":
            value = request.maxTokens
            request.maxTokens = nil
        case "temperature":
            value = request.temperature
            request.temperature = nil
        case "top_p":
            value = request.topP
            request.topP = nil
        default:
            return
        }
        guard let value else { return }
        options[targetKey] = value
    }

    static func applyOllamaThinkValue(_ rawEffort: String, to request: inout OllamaNativeBridgeRequest) {
        switch rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "medium", "low":
            request.additionalFields["think"] = .string(rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case "none", "off", "false":
            request.additionalFields["think"] = .bool(false)
        default:
            break
        }
    }

    static func openAIProxyResponseFromOllama(
        requestBody: Data,
        responseBody: Data,
        modelID: String,
        streamRequested: Bool,
        headers: [String: String] = [:]
    ) throws -> BurnBarProviderProxyResponse {
        if streamRequested {
            return try openAIStreamResponseFromOllama(
                requestBody: requestBody,
                responseBody: responseBody,
                modelID: modelID,
                headers: headers
            )
        }

        let decoded = try JSONDecoder().decode(OllamaNativeChatResponse.self, from: responseBody)
        try validateOllamaNativeChatResponse(decoded, modelID: modelID)
        let body = try openAICompletionBodyFromOllama(decoded, modelID: modelID)
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
            headers: headers,
            body: body,
            usage: ollamaProxyUsage(requestBody: requestBody, response: decoded)
        )
    }

    static func validateOllamaNativeChatResponse(
        _ response: OllamaNativeChatResponse,
        modelID: String
    ) throws {
        let content = response.message?.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard content.isEmpty else { return }

        let doneReason = response.doneReason?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard doneReason == "length" || doneReason == "max_tokens" else {
            return
        }

        let thinking = response.message?.thinking?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let detail: String
        if thinking.isEmpty {
            detail = "Upstream returned no assistant text for \(modelID) because it hit the output token limit before producing final content. Increase max_tokens/max_output_tokens or choose a non-reasoning model."
        } else {
            detail = "Upstream returned reasoning-only output for \(modelID) and hit the output token limit before final assistant text. Increase max_tokens/max_output_tokens or choose a non-reasoning model."
        }

        throw BurnBarProviderExecutorError.upstreamError(
            502,
            Self.openAICompatibleErrorBody(message: detail, code: "empty_assistant_content")
        )
    }

    static func openAIStreamResponseFromOllama(
        requestBody: Data,
        responseBody: Data,
        modelID: String,
        headers: [String: String] = [:]
    ) throws -> BurnBarProviderProxyResponse {
        let responseID = "chatcmpl-\(UUID().uuidString)"
        let created = Int(Date().timeIntervalSince1970)
        var sse = Data()
        var finalResponse: OllamaNativeChatResponse?
        var streamedToolCalls = false

        let lines = String(decoding: responseBody, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        for line in lines {
            guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
            let decoded = try JSONDecoder().decode(OllamaNativeChatResponse.self, from: data)
            finalResponse = decoded

            let content = decoded.message?.content ?? ""
            if !content.isEmpty {
                try appendServerSentEvent(
                    chunk: openAIStreamChunk(
                        id: responseID,
                        created: created,
                        modelID: modelID,
                        content: content,
                        toolCalls: nil,
                        finishReason: nil
                    ),
                    to: &sse
                )
            }

            let toolCalls = openAIToolCalls(from: decoded, includeIndex: true)
            if let toolCalls, !toolCalls.isEmpty {
                streamedToolCalls = true
                try appendServerSentEvent(
                    chunk: openAIStreamChunk(
                        id: responseID,
                        created: created,
                        modelID: modelID,
                        content: nil,
                        toolCalls: toolCalls,
                        finishReason: nil
                    ),
                    to: &sse
                )
            }

            if decoded.done == true {
                try appendServerSentEvent(
                    chunk: openAIStreamChunk(
                        id: responseID,
                        created: created,
                        modelID: modelID,
                        content: nil,
                        toolCalls: nil,
                        finishReason: finishReason(
                            from: decoded.doneReason,
                            hasToolCalls: streamedToolCalls
                        )
                    ),
                    to: &sse
                )
            }
        }

        sse.append(Data("data: [DONE]\n\n".utf8))

        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "text/event-stream",
            headers: headers,
            body: sse,
            usage: finalResponse.map { ollamaProxyUsage(requestBody: requestBody, response: $0) }
        )
    }

    static func openAICompletionBodyFromOllama(
        _ response: OllamaNativeChatResponse,
        modelID: String
    ) throws -> Data {
        let content = response.message?.content ?? ""
        let toolCalls = openAIToolCalls(from: response, includeIndex: false)
        let toolCallsValue: BurnBarBridgeValue?
        if let toolCalls {
            toolCallsValue = try BurnBarBridgeJSON.bridgeValue(toolCalls)
        } else {
            toolCallsValue = nil
        }
        let message = ChatBridgeOutboundMessage(
            role: response.message?.role ?? "assistant",
            content: .string(content),
            toolCalls: toolCallsValue
        )
        let completion = ChatBridgeCompletion(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: response.model ?? modelID,
            choices: [
                ChatBridgeCompletion.ChatBridgeCompletionChoice(
                    index: 0,
                    message: message,
                    finishReason: .value(finishReason(
                        from: response.doneReason,
                        hasToolCalls: toolCalls?.isEmpty == false
                    ))
                )
            ],
            usage: openAIUsageFromOllama(response)
        )
        return try BurnBarBridgeJSON.encode(completion, sortedKeys: false)
    }

    static func openAIUsageFromOllama(_ response: OllamaNativeChatResponse) -> ChatBridgeUsage {
        let promptTokens = max(response.promptEvalCount ?? 0, 0)
        let completionTokens = max(response.evalCount ?? 0, 0)
        return ChatBridgeUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens
        )
    }

    static func openAIStreamChunk(
        id: String,
        created: Int,
        modelID: String,
        content: String?,
        toolCalls: [ChatBridgeOutboundToolCall]?,
        finishReason: String?
    ) -> ChatBridgeStreamChunk {
        var delta = ChatBridgeStreamChunk.ChatBridgeStreamDelta()
        if let content {
            delta.content = content
        }
        if let toolCalls, !toolCalls.isEmpty {
            delta.toolCalls = toolCalls.map { call in
                ChatBridgeStreamChunk.ChatBridgeStreamToolCall(
                    index: call.index,
                    id: call.id,
                    type: call.type,
                    function: ChatBridgeStreamChunk.ChatBridgeStreamToolCall.ChatBridgeStreamFunction(
                        name: call.function.name,
                        arguments: call.function.arguments
                    )
                )
            }
        }
        if finishReason == nil {
            delta.role = "assistant"
        }
        return ChatBridgeStreamChunk(
            id: id,
            object: "chat.completion.chunk",
            created: created,
            model: modelID,
            choices: [
                ChatBridgeStreamChunk.ChatBridgeStreamChoice(
                    index: 0,
                    delta: delta,
                    finishReason: finishReason.map(ChatBridgeFinishReason.value) ?? .null
                )
            ]
        )
    }

    static func appendServerSentEvent(chunk: ChatBridgeStreamChunk, to data: inout Data) throws {
        let payload = try BurnBarBridgeJSON.encode(chunk, sortedKeys: false)
        data.append(Data("data: ".utf8))
        data.append(payload)
        data.append(Data("\n\n".utf8))
    }

    static func openAIToolCalls(
        from response: OllamaNativeChatResponse,
        includeIndex: Bool
    ) -> [ChatBridgeOutboundToolCall]? {
        guard let calls = response.message?.toolCalls, !calls.isEmpty else {
            return nil
        }
        let mapped = calls.enumerated().compactMap { index, call in
            openAIToolCall(from: call, index: index, includeIndex: includeIndex)
        }
        return mapped.isEmpty ? nil : mapped
    }

    static func openAIToolCall(
        from call: OllamaNativeToolCall,
        index: Int,
        includeIndex: Bool
    ) -> ChatBridgeOutboundToolCall? {
        guard let function = call.function,
              let name = function.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        let id = call.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = call.type?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = (id?.isEmpty == false ? id : nil) ?? "call_ollama_\(index)"
        let resolvedType = (type?.isEmpty == false ? type : nil) ?? "function"
        return ChatBridgeOutboundToolCall(
            id: resolvedID,
            type: resolvedType,
            function: ChatBridgeOutboundToolCall.ChatBridgeOutboundFunction(
                name: name,
                arguments: openAIToolArguments(function.arguments)
            ),
            index: includeIndex ? index : nil
        )
    }

    static func openAIToolArguments(_ arguments: BurnBarJSONValue?) -> String {
        guard let arguments else { return "{}" }
        if case .string(let string) = arguments {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "{}" : string
        }
        guard let data = try? JSONEncoder().encode(arguments),
              let string = String(data: data, encoding: .utf8),
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "{}"
        }
        return string
    }

    static func finishReason(from doneReason: String?, hasToolCalls: Bool = false) -> String {
        if hasToolCalls {
            return "tool_calls"
        }
        switch doneReason?.lowercased() {
        case "length":
            return "length"
        case "tool_calls":
            return "tool_calls"
        default:
            return "stop"
        }
    }

    static func ollamaProxyUsage(
        requestBody: Data,
        response: OllamaNativeChatResponse
    ) -> BurnBarProviderProxyUsage {
        let outputText = response.message?.content ?? ""
        let inputHint = max(1, requestBody.count / 4)
        let outputHint = max(1, outputText.count / 4)
        let hasExplicitUsage = response.promptEvalCount != nil || response.evalCount != nil
        return BurnBarProviderProxyUsage(
            inputTokens: max(response.promptEvalCount ?? inputHint, 0),
            outputTokens: max(response.evalCount ?? outputHint, 0),
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            reasoningTokens: 0,
            confidence: hasExplicitUsage ? .exact : .lowConfidenceEstimate
        )
    }
}
