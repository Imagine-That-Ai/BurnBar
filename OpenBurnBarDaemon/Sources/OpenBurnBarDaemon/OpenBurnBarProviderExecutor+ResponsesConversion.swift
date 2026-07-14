import OpenBurnBarEngine
import Foundation

// OpenAI Responses API <-> Chat Completions request/response/stream conversion.
// Extracted from OpenBurnBarProviderExecutor.swift (god-type decomposition) — same module, same isolation, verbatim.

extension BurnBarOpenAICompatibleProviderExecutor {

    static func chatCompletionsBodyFromResponsesRequest(
        _ body: Data,
        modelID: String
    ) throws -> (Data, Bool) {
        let json = try JSONSerialization.jsonObject(with: body)
        guard let object = json as? [String: Any] else {
            throw BurnBarProviderExecutorError.invalidResponse
        }

        let streamRequested = object["stream"] as? Bool ?? false
        var messages: [[String: Any]] = []
        if let instructions = object["instructions"] as? String,
           !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(["role": "system", "content": instructions])
        }

        if let existingMessages = object["messages"] as? [[String: Any]], !existingMessages.isEmpty {
            messages.append(contentsOf: sanitizedChatMessages(existingMessages))
        } else if let input = object["input"] {
            messages.append(contentsOf: messagesFromResponsesInput(input))
        }
        messages = coalescedSystemMessages(messages)

        if messages.isEmpty {
            throw BurnBarProviderExecutorError.upstreamError(
                400,
                "Responses request must include input text or messages for chat-completions fallback."
            )
        }

        var chatObject: [String: Any] = [
            "model": modelID,
            "messages": messages
        ]
        for compatibleKey in [
            "temperature",
            "top_p",
            "stop",
            "stream",
            "presence_penalty",
            "frequency_penalty",
            "logit_bias",
            "seed",
            "user",
            "response_format",
            "max_tokens",
            "tools",
            "tool_choice"
        ] {
            if let value = object[compatibleKey] {
                chatObject[compatibleKey] = value
            }
        }
        if chatObject["max_tokens"] == nil, let maxOutputTokens = object["max_output_tokens"] {
            chatObject["max_tokens"] = maxOutputTokens
        }
        if chatObject["response_format"] == nil,
           let text = object["text"] as? [String: Any],
           let format = text["format"] as? [String: Any] {
            chatObject["response_format"] = format
        }
        normalizeResponsesToolsForChatCompletions(&chatObject)

        return (try JSONSerialization.data(withJSONObject: chatObject, options: []), streamRequested)
    }

    static func normalizeResponsesToolsForChatCompletions(_ object: inout [String: Any]) {
        if let responseTools = object["tools"] as? [[String: Any]] {
            let chatTools = responseTools.compactMap(chatCompletionsTool)
            if chatTools.isEmpty {
                object.removeValue(forKey: "tools")
            } else {
                object["tools"] = chatTools
            }
        }

        guard let toolChoice = object["tool_choice"] as? [String: Any] else {
            return
        }
        guard let toolName = (toolChoice["name"] as? String)
                ?? ((toolChoice["function"] as? [String: Any])?["name"] as? String),
              !toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            object.removeValue(forKey: "tool_choice")
            return
        }
        object["tool_choice"] = [
            "type": "function",
            "function": ["name": toolName]
        ]
    }

    static func chatCompletionsTool(_ tool: [String: Any]) -> [String: Any]? {
        let function = tool["function"] as? [String: Any]
        if let type = tool["type"] as? String,
           type.lowercased() != "function",
           function == nil {
            return nil
        }
        guard let name = (function?["name"] as? String) ?? (tool["name"] as? String),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let description = (function?["description"] as? String) ?? (tool["description"] as? String)
        let parameters = (function?["parameters"] as? [String: Any])
            ?? (function?["input_schema"] as? [String: Any])
            ?? (tool["parameters"] as? [String: Any])
            ?? (tool["input_schema"] as? [String: Any])
            ?? [
                "type": "object",
                "properties": [:]
            ]

        var chatFunction: [String: Any] = [
            "name": name,
            "parameters": parameters
        ]
        if let description, !description.isEmpty {
            chatFunction["description"] = description
        }
        if let strict = (function?["strict"] as? Bool) ?? (tool["strict"] as? Bool) {
            chatFunction["strict"] = strict
        }

        return [
            "type": "function",
            "function": chatFunction
        ]
    }

    static func sanitizedChatMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.compactMap(sanitizedChatMessage)
    }

    static func coalescedSystemMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        var systemText: [String] = []
        var orderedNonSystemMessages: [[String: Any]] = []

        for message in messages {
            if (message["role"] as? String) == "system",
               let content = message["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                systemText.append(content)
            } else {
                orderedNonSystemMessages.append(message)
            }
        }

        guard !systemText.isEmpty else {
            return orderedNonSystemMessages
        }

        return [["role": "system", "content": systemText.joined(separator: "\n\n")]]
            + orderedNonSystemMessages
    }

    static func sanitizedChatMessage(_ message: [String: Any]) -> [String: Any]? {
        guard let content = chatCompletionsContent(from: message["content"] ?? message["text"]),
              !chatCompletionsContentIsEmpty(content) else {
            return nil
        }

        var sanitized: [String: Any] = [
            "role": chatCompletionsRole(message["role"] as? String),
            "content": content
        ]
        if let name = message["name"] as? String, !name.isEmpty {
            sanitized["name"] = name
        }
        if let toolCallID = message["tool_call_id"] as? String, !toolCallID.isEmpty {
            sanitized["tool_call_id"] = toolCallID
        }
        if let toolCalls = message["tool_calls"] {
            sanitized["tool_calls"] = toolCalls
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

    static func messagesFromResponsesInput(_ input: Any) -> [[String: Any]] {
        if let string = input as? String {
            return [["role": "user", "content": string]]
        }

        guard let items = input as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let content = chatCompletionsContent(from: item["content"] ?? item["text"]),
                  !chatCompletionsContentIsEmpty(content) else {
                return nil
            }
            return ["role": chatCompletionsRole(item["role"] as? String), "content": content]
        }
    }

    static func chatCompletionsContent(from value: Any?) -> Any? {
        if let string = value as? String {
            return string
        }
        guard let parts = value as? [[String: Any]] else {
            return nil
        }
        let convertedParts = parts.compactMap(chatCompletionsContentPart)
        if !convertedParts.isEmpty {
            return convertedParts
        }
        let text = responsesContentText(value)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    static func chatCompletionsContentPart(_ part: [String: Any]) -> [String: Any]? {
        let type = (part["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch type {
        case "text":
            guard let text = part["text"] as? String else { return nil }
            return ["type": "text", "text": text]
        case "input_text", "output_text":
            guard let text = (part["text"] as? String)
                ?? (part["input_text"] as? String)
                ?? (part["output_text"] as? String) else { return nil }
            return ["type": "text", "text": text]
        case "image_url":
            if let imageURL = part["image_url"] as? [String: Any] {
                return ["type": "image_url", "image_url": imageURL]
            }
            if let imageURL = part["image_url"] as? String {
                return ["type": "image_url", "image_url": ["url": imageURL]]
            }
            return nil
        case "input_image":
            if let imageURL = (part["image_url"] as? String) ?? (part["url"] as? String) {
                return ["type": "image_url", "image_url": ["url": imageURL]]
            }
            if let imageURL = part["image_url"] as? [String: Any] {
                return ["type": "image_url", "image_url": imageURL]
            }
            return nil
        case "input_audio":
            guard part["input_audio"] != nil else { return nil }
            return part
        case "file":
            return part
        default:
            if part["image_url"] != nil {
                var normalized = part
                normalized["type"] = "image_url"
                return normalized
            }
            if part["input_audio"] != nil {
                var normalized = part
                normalized["type"] = "input_audio"
                return normalized
            }
            if let text = part["text"] as? String {
                return ["type": "text", "text": text]
            }
            return nil
        }
    }

    static func chatCompletionsContentIsEmpty(_ value: Any) -> Bool {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let parts = value as? [[String: Any]] {
            return parts.isEmpty
        }
        return false
    }

    static func responsesContentText(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String {
                    return text
                }
                if let text = part["input_text"] as? String {
                    return text
                }
                if let text = part["output_text"] as? String {
                    return text
                }
                return nil
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
            payload: [
                "type": "response.created",
                "response": baseResponsesObject(
                    id: responseID,
                    itemID: itemID,
                    modelID: modelID,
                    created: created,
                    status: "in_progress",
                    outputText: "",
                    usage: nil
                )
            ],
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.output_item.added",
            payload: [
                "type": "response.output_item.added",
                "response_id": responseID,
                "output_index": 0,
                "item": responseMessageItem(
                    itemID: itemID,
                    status: "in_progress",
                    outputText: ""
                )
            ],
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.content_part.added",
            payload: [
                "type": "response.content_part.added",
                "response_id": responseID,
                "item_id": itemID,
                "output_index": 0,
                "content_index": 0,
                "part": [
                    "type": "output_text",
                    "text": "",
                    "annotations": []
                ]
            ],
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
            guard let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let firstChoice = choices.first else {
                continue
            }
            let delta = firstChoice["delta"] as? [String: Any]
            let content = (delta?["content"] as? String)
                ?? ((firstChoice["message"] as? [String: Any])?["content"] as? String)
                ?? ""
            guard !content.isEmpty else { continue }
            outputText += content
            didEmitDelta = true
            try appendResponseServerSentEvent(
                event: "response.output_text.delta",
                payload: [
                    "type": "response.output_text.delta",
                    "response_id": responseID,
                    "item_id": itemID,
                    "output_index": 0,
                    "content_index": 0,
                    "delta": content
                ],
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
                    payload: [
                        "type": "response.output_text.delta",
                        "response_id": responseID,
                        "item_id": itemID,
                        "output_index": 0,
                        "content_index": 0,
                        "delta": content
                    ],
                    to: &sse
                )
            }
        }

        try appendResponseServerSentEvent(
            event: "response.output_text.done",
            payload: [
                "type": "response.output_text.done",
                "response_id": responseID,
                "item_id": itemID,
                "output_index": 0,
                "content_index": 0,
                "text": outputText
            ],
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.content_part.done",
            payload: [
                "type": "response.content_part.done",
                "response_id": responseID,
                "item_id": itemID,
                "output_index": 0,
                "content_index": 0,
                "part": [
                    "type": "output_text",
                    "text": outputText,
                    "annotations": []
                ]
            ],
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.output_item.done",
            payload: [
                "type": "response.output_item.done",
                "response_id": responseID,
                "output_index": 0,
                "item": responseMessageItem(
                    itemID: itemID,
                    status: "completed",
                    outputText: outputText
                )
            ],
            to: &sse
        )
        try appendResponseServerSentEvent(
            event: "response.completed",
            payload: [
                "type": "response.completed",
                "response": baseResponsesObject(
                    id: responseID,
                    itemID: itemID,
                    modelID: modelID,
                    created: created,
                    status: "completed",
                    outputText: outputText,
                    usage: chatResponse.usage
                )
            ],
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
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }

    static func baseResponsesObject(
        id: String,
        itemID: String = "msg_\(UUID().uuidString)",
        modelID: String,
        created: Int,
        status: String,
        outputText: String,
        usage: BurnBarProviderProxyUsage?
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "object": "response",
            "created_at": created,
            "model": modelID,
            "status": status,
            "output": [
                [
                    "id": itemID,
                    "type": "message",
                    "status": status,
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": outputText,
                            "annotations": []
                        ]
                    ]
                ]
            ],
            "output_text": outputText
        ]
        if let usage {
            object["usage"] = [
                "input_tokens": usage.inputTokens,
                "output_tokens": usage.outputTokens,
                "total_tokens": usage.inputTokens + usage.outputTokens + usage.cacheCreationTokens + usage.cacheReadTokens,
                "reasoning_tokens": usage.reasoningTokens
            ]
        }
        return object
    }

    static func responseMessageItem(
        itemID: String,
        status: String,
        outputText: String
    ) -> [String: Any] {
        [
            "id": itemID,
            "type": "message",
            "status": status,
            "role": "assistant",
            "content": outputText.isEmpty ? [] : [
                [
                    "type": "output_text",
                    "text": outputText,
                    "annotations": []
                ]
            ]
        ]
    }

    static func appendResponseServerSentEvent(
        event: String,
        payload: [String: Any],
        to data: inout Data
    ) throws {
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [])
        data.append(Data("event: \(event)\n".utf8))
        data.append(Data("data: ".utf8))
        data.append(payloadData)
        data.append(Data("\n\n".utf8))
    }

    static func extractResponsesUsage(responseBody: Data) -> BurnBarProviderProxyUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: responseBody) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }

        var inputTokens = intValue(usage["input_tokens"])
            ?? intValue(usage["prompt_tokens"])
            ?? 0
        let outputTokens = intValue(usage["output_tokens"])
            ?? intValue(usage["completion_tokens"])
            ?? 0
        let cacheCreationTokens = intValue(usage["cache_creation_input_tokens"])
            ?? intValue(usage["cache_creation_tokens"])
            ?? 0
        let exclusiveCacheReadTokens = intValue(usage["cache_read_input_tokens"])
            ?? intValue(usage["cache_read_tokens"])
            ?? 0
        let promptDetails = usage["prompt_tokens_details"] as? [String: Any]
        let inputDetails = usage["input_tokens_details"] as? [String: Any]
        let inclusiveCacheReadTokens = intValue(usage["input_cached_tokens"])
            ?? intValue(usage["cached_input_tokens"])
            ?? intValue(usage["cached_tokens"])
            ?? intValue(promptDetails?["cached_tokens"])
            ?? intValue(inputDetails?["cached_tokens"])
            ?? 0
        let cacheReadTokens = exclusiveCacheReadTokens > 0 ? exclusiveCacheReadTokens : inclusiveCacheReadTokens
        if inclusiveCacheReadTokens > 0 && exclusiveCacheReadTokens == 0 {
            inputTokens = max(inputTokens - inclusiveCacheReadTokens, 0)
        }
        let reasoningTokens = intValue(usage["reasoning_tokens"]) ?? 0

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
