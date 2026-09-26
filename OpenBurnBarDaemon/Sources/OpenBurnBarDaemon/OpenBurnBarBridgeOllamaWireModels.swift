import Foundation
import OpenBurnBarEngine

// MARK: - Ollama native bridge request
//
// Chat Completions bodies translated to Ollama's native `/api/chat` shape.
// Only the keys the translation touches are modeled; every other key (tools,
// keep_alive, template, ...) round-trips through `additionalFields` untouched.

struct OllamaNativeBridgeRequest: Codable, Sendable {
    var model: BurnBarBridgeValue?
    var stream: BurnBarBridgeValue?
    var messages: BurnBarBridgeValue?
    var options: BurnBarBridgeValue?
    var responseFormat: BurnBarBridgeValue?
    var reasoning: BurnBarBridgeValue?
    var reasoningEffort: BurnBarBridgeValue?
    var maxCompletionTokens: BurnBarBridgeValue?
    var maxTokens: BurnBarBridgeValue?
    var temperature: BurnBarBridgeValue?
    var topP: BurnBarBridgeValue?
    var additionalFields: [String: BurnBarBridgeValue]

    private enum CodingKeys: String, CodingKey {
        case model
        case stream
        case messages
        case options
        case responseFormat = "response_format"
        case reasoning
        case reasoningEffort = "reasoning_effort"
        case maxCompletionTokens = "max_completion_tokens"
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
    }

    private static let knownKeys: Set<String> = [
        "model", "stream", "messages", "options", "response_format", "reasoning",
        "reasoning_effort", "max_completion_tokens", "max_tokens", "temperature", "top_p"
    ]

    init(
        model: BurnBarBridgeValue? = nil,
        stream: BurnBarBridgeValue? = nil,
        messages: BurnBarBridgeValue? = nil,
        options: BurnBarBridgeValue? = nil,
        responseFormat: BurnBarBridgeValue? = nil,
        reasoning: BurnBarBridgeValue? = nil,
        reasoningEffort: BurnBarBridgeValue? = nil,
        maxCompletionTokens: BurnBarBridgeValue? = nil,
        maxTokens: BurnBarBridgeValue? = nil,
        temperature: BurnBarBridgeValue? = nil,
        topP: BurnBarBridgeValue? = nil,
        additionalFields: [String: BurnBarBridgeValue] = [:]
    ) {
        self.model = model
        self.stream = stream
        self.messages = messages
        self.options = options
        self.responseFormat = responseFormat
        self.reasoning = reasoning
        self.reasoningEffort = reasoningEffort
        self.maxCompletionTokens = maxCompletionTokens
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.additionalFields = additionalFields
    }

    init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        model = try known.decodeBridgeValue(forKey: .model)
        stream = try known.decodeBridgeValue(forKey: .stream)
        messages = try known.decodeBridgeValue(forKey: .messages)
        options = try known.decodeBridgeValue(forKey: .options)
        responseFormat = try known.decodeBridgeValue(forKey: .responseFormat)
        reasoning = try known.decodeBridgeValue(forKey: .reasoning)
        reasoningEffort = try known.decodeBridgeValue(forKey: .reasoningEffort)
        maxCompletionTokens = try known.decodeBridgeValue(forKey: .maxCompletionTokens)
        maxTokens = try known.decodeBridgeValue(forKey: .maxTokens)
        temperature = try known.decodeBridgeValue(forKey: .temperature)
        topP = try known.decodeBridgeValue(forKey: .topP)
        let dynamic = try decoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        additionalFields = try dynamic.decodeExtras(excluding: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: CodingKeys.self)
        try known.encodeIfPresent(model, forKey: .model)
        try known.encodeIfPresent(stream, forKey: .stream)
        try known.encodeIfPresent(messages, forKey: .messages)
        try known.encodeIfPresent(options, forKey: .options)
        try known.encodeIfPresent(responseFormat, forKey: .responseFormat)
        try known.encodeIfPresent(reasoning, forKey: .reasoning)
        try known.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try known.encodeIfPresent(maxCompletionTokens, forKey: .maxCompletionTokens)
        try known.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try known.encodeIfPresent(temperature, forKey: .temperature)
        try known.encodeIfPresent(topP, forKey: .topP)
        var dynamic = encoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        try dynamic.encodeExtras(additionalFields)
    }
}

struct OllamaBridgeMessage: Decodable, Sendable {
    var role: BurnBarBridgeValue?
    var content: BurnBarBridgeValue?
    var toolCalls: BurnBarBridgeValue?
    var toolCallsCamel: BurnBarBridgeValue?
    var additionalFields: [String: BurnBarBridgeValue]

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallsCamel = "toolCalls"
    }

    private static let knownKeys: Set<String> = ["role", "content", "tool_calls", "toolCalls"]

    init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        role = try known.decodeBridgeValue(forKey: .role)
        content = try known.decodeBridgeValue(forKey: .content)
        toolCalls = try known.decodeBridgeValue(forKey: .toolCalls)
        toolCallsCamel = try known.decodeBridgeValue(forKey: .toolCallsCamel)
        let dynamic = try decoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        additionalFields = try dynamic.decodeExtras(excluding: Self.knownKeys)
    }

    func bridgeValue() -> BurnBarBridgeValue {
        var object = additionalFields
        if let role { object["role"] = role }
        if let content { object["content"] = content }
        if let toolCalls { object["tool_calls"] = toolCalls }
        if let toolCallsCamel { object["toolCalls"] = toolCallsCamel }
        return .object(object)
    }
}

struct OllamaBridgeToolCall: Decodable, Sendable {
    var id: BurnBarBridgeValue?
    var type: BurnBarBridgeValue?
    var function: BurnBarBridgeValue?
    var additionalFields: [String: BurnBarBridgeValue]

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case function
    }

    private static let knownKeys: Set<String> = ["id", "type", "function"]

    init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        id = try known.decodeBridgeValue(forKey: .id)
        type = try known.decodeBridgeValue(forKey: .type)
        function = try known.decodeBridgeValue(forKey: .function)
        let dynamic = try decoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        additionalFields = try dynamic.decodeExtras(excluding: Self.knownKeys)
    }

    func bridgeValue() -> BurnBarBridgeValue {
        var object = additionalFields
        if let id { object["id"] = id }
        if let type { object["type"] = type }
        if let function { object["function"] = function }
        return .object(object)
    }
}
