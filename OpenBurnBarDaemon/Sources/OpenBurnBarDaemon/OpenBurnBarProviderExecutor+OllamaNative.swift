import OpenBurnBarCore
import Foundation
import LocalAuthentication
import Security

// Ollama native chat API <-> OpenAI-compatible request/response/stream conversion.
// Extracted from OpenBurnBarProviderExecutor.swift (god-type decomposition) — same module, same isolation, verbatim.

extension BurnBarOpenAICompatibleProviderExecutor {

    static func shouldUseOllamaNativeAPI(route: BurnBarProviderRoute, baseURL: URL) -> Bool {
        guard route.providerID.lowercased() == "ollama" else { return false }
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
        let json = try JSONSerialization.jsonObject(with: body)
        guard var object = json as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let streamRequested = object["stream"] as? Bool ?? false
        object["model"] = modelID
        object["stream"] = streamRequested

        if let responseFormat = object.removeValue(forKey: "response_format") as? [String: Any] {
            if (responseFormat["type"] as? String) == "json_object" {
                object["format"] = "json"
            } else if let jsonSchema = responseFormat["json_schema"] as? [String: Any],
                      let schema = jsonSchema["schema"] {
                object["format"] = schema
            }
        }

        var options = object["options"] as? [String: Any] ?? [:]
        moveOpenAIOption("max_completion_tokens", to: "num_predict", from: &object, options: &options)
        moveOpenAIOption("max_tokens", to: "num_predict", from: &object, options: &options)
        moveOpenAIOption("temperature", to: "temperature", from: &object, options: &options)
        moveOpenAIOption("top_p", to: "top_p", from: &object, options: &options)
        if !options.isEmpty {
            object["options"] = options
        }

        if let reasoning = object.removeValue(forKey: "reasoning") as? [String: Any],
           let effort = reasoning["effort"] as? String {
            applyOllamaThinkValue(effort, to: &object)
        }
        if let effort = object.removeValue(forKey: "reasoning_effort") as? String {
            applyOllamaThinkValue(effort, to: &object)
        }

        for unsupportedKey in ["n", "user", "logit_bias", "presence_penalty", "frequency_penalty", "stream_options", "tool_choice"] {
            object.removeValue(forKey: unsupportedKey)
        }

        normalizeOllamaNativeMessages(in: &object)

        return (try JSONSerialization.data(withJSONObject: object, options: []), streamRequested)
    }

    static func normalizeOllamaNativeMessages(in object: inout [String: Any]) {
        guard let messages = object["messages"] as? [[String: Any]] else { return }
        object["messages"] = messages.map { message in
            var normalized = message
            normalizeOllamaNativeToolCalls(at: "tool_calls", in: &normalized)
            normalizeOllamaNativeToolCalls(at: "toolCalls", in: &normalized)
            if normalized["content"] is NSNull {
                normalized["content"] = ""
            } else if let content = normalized["content"],
                      !(content is String) {
                normalized["content"] = responsesContentText(content)
            }
            return normalized
        }
    }

    static func normalizeOllamaNativeToolCalls(at key: String, in message: inout [String: Any]) {
        guard let calls = message[key] as? [[String: Any]] else { return }
        message[key] = calls.map { call in
            var normalizedCall = call
            guard var function = normalizedCall["function"] as? [String: Any] else {
                return normalizedCall
            }
            if let arguments = function["arguments"] as? String {
                function["arguments"] = ollamaNativeArgumentsObject(from: arguments)
                normalizedCall["function"] = function
            }
            return normalizedCall
        }
    }

    static func ollamaNativeArgumentsObject(from string: String) -> Any {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return [:] as [String: Any]
        }
        return object
    }

    static func moveOpenAIOption(
        _ sourceKey: String,
        to targetKey: String,
        from object: inout [String: Any],
        options: inout [String: Any]
    ) {
        guard let value = object.removeValue(forKey: sourceKey) else { return }
        options[targetKey] = value
    }

    static func applyOllamaThinkValue(_ rawEffort: String, to object: inout [String: Any]) {
        switch rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "high", "medium", "low":
            object["think"] = rawEffort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case "none", "off", "false":
            object["think"] = false
        default:
            break
        }
    }

    static func openAIProxyResponseFromOllama(
        requestBody: Data,
        responseBody: Data,
        modelID: String,
        streamRequested: Bool
    ) throws -> BurnBarProviderProxyResponse {
        if streamRequested {
            return try openAIStreamResponseFromOllama(
                requestBody: requestBody,
                responseBody: responseBody,
                modelID: modelID
            )
        }

        let decoded = try JSONDecoder().decode(OllamaNativeChatResponse.self, from: responseBody)
        try validateOllamaNativeChatResponse(decoded, modelID: modelID)
        let body = try openAICompletionBodyFromOllama(decoded, modelID: modelID)
        return BurnBarProviderProxyResponse(
            statusCode: 200,
            contentType: "application/json",
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
        modelID: String
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
            body: sse,
            usage: finalResponse.map { ollamaProxyUsage(requestBody: requestBody, response: $0) }
        )
    }

    static func openAICompletionBodyFromOllama(
        _ response: OllamaNativeChatResponse,
        modelID: String
    ) throws -> Data {
        let content = response.message?.content ?? ""
        var message: [String: Any] = [
            "role": response.message?.role ?? "assistant",
            "content": content
        ]
        let toolCalls = openAIToolCalls(from: response, includeIndex: false)
        if let toolCalls, !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls
        }
        let choice: [String: Any] = [
            "index": 0,
            "message": message,
            "finish_reason": finishReason(
                from: response.doneReason,
                hasToolCalls: toolCalls?.isEmpty == false
            )
        ]
        let body: [String: Any] = [
            "id": "chatcmpl-\(UUID().uuidString)",
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": response.model ?? modelID,
            "choices": [choice],
            "usage": openAIUsageFromOllama(response)
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [])
    }

    static func openAIUsageFromOllama(_ response: OllamaNativeChatResponse) -> [String: Any] {
        let promptTokens = max(response.promptEvalCount ?? 0, 0)
        let completionTokens = max(response.evalCount ?? 0, 0)
        return [
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": promptTokens + completionTokens
        ]
    }

    static func openAIStreamChunk(
        id: String,
        created: Int,
        modelID: String,
        content: String?,
        toolCalls: [[String: Any]]?,
        finishReason: String?
    ) -> [String: Any] {
        var delta: [String: Any] = [:]
        if let content {
            delta["content"] = content
        }
        if let toolCalls, !toolCalls.isEmpty {
            delta["tool_calls"] = toolCalls
        }
        if finishReason == nil {
            delta["role"] = "assistant"
        }
        return [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": modelID,
            "choices": [
                [
                    "index": 0,
                    "delta": delta,
                    "finish_reason": finishReason.map { $0 as Any } ?? NSNull()
                ]
            ]
        ]
    }

    static func appendServerSentEvent(chunk: [String: Any], to data: inout Data) throws {
        let payload = try JSONSerialization.data(withJSONObject: chunk, options: [])
        data.append(Data("data: ".utf8))
        data.append(payload)
        data.append(Data("\n\n".utf8))
    }

    static func openAIToolCalls(
        from response: OllamaNativeChatResponse,
        includeIndex: Bool
    ) -> [[String: Any]]? {
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
    ) -> [String: Any]? {
        guard let function = call.function,
              let name = function.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        let id = call.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = call.type?.trimmingCharacters(in: .whitespacesAndNewlines)
        var mapped: [String: Any] = [
            "id": id?.isEmpty == false ? id! : "call_ollama_\(index)",
            "type": type?.isEmpty == false ? type! : "function",
            "function": [
                "name": name,
                "arguments": openAIToolArguments(function.arguments)
            ]
        ]
        if includeIndex {
            mapped["index"] = index
        }
        return mapped
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
