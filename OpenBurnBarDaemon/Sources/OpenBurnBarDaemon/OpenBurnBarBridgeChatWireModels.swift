import Foundation
import OpenBurnBarEngine

// MARK: - Inbound (lenient) chat wire views
//
// Decoded from client/upstream JSON. Fields stay lenient (`BurnBarBridgeValue`
// or optional leaves) so a weird-but-tolerated shape degrades exactly like the
// old `as?` chains (default/skip) instead of failing the whole document.

// Chat Completions request as seen by the bridges (Anthropic, Responses
// fallback). Only the keys the bridges read are modeled; everything else is
// intentionally not copied across the API boundary.
struct ChatBridgeInboundRequest: Decodable, Sendable {
    var messages: BurnBarBridgeValue?
    var temperature: BurnBarBridgeValue?
    var topP: BurnBarBridgeValue?
    var stop: BurnBarBridgeValue?
    var stream: BurnBarBridgeValue?
    var tools: BurnBarBridgeValue?
    var toolChoice: BurnBarBridgeValue?
    var responseFormat: BurnBarBridgeValue?
    var maxTokens: BurnBarBridgeValue?
    var maxCompletionTokens: BurnBarBridgeValue?
    var maxOutputTokens: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case messages
        case temperature
        case topP = "top_p"
        case stop
        case stream
        case tools
        case toolChoice = "tool_choice"
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case maxOutputTokens = "max_output_tokens"
    }

    init(
        messages: BurnBarBridgeValue? = nil,
        temperature: BurnBarBridgeValue? = nil,
        topP: BurnBarBridgeValue? = nil,
        stop: BurnBarBridgeValue? = nil,
        stream: BurnBarBridgeValue? = nil,
        tools: BurnBarBridgeValue? = nil,
        toolChoice: BurnBarBridgeValue? = nil,
        responseFormat: BurnBarBridgeValue? = nil,
        maxTokens: BurnBarBridgeValue? = nil,
        maxCompletionTokens: BurnBarBridgeValue? = nil,
        maxOutputTokens: BurnBarBridgeValue? = nil
    ) {
        self.messages = messages
        self.temperature = temperature
        self.topP = topP
        self.stop = stop
        self.stream = stream
        self.tools = tools
        self.toolChoice = toolChoice
        self.responseFormat = responseFormat
        self.maxTokens = maxTokens
        self.maxCompletionTokens = maxCompletionTokens
        self.maxOutputTokens = maxOutputTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeBridgeValue(forKey: .messages)
        temperature = try container.decodeBridgeValue(forKey: .temperature)
        topP = try container.decodeBridgeValue(forKey: .topP)
        stop = try container.decodeBridgeValue(forKey: .stop)
        stream = try container.decodeBridgeValue(forKey: .stream)
        tools = try container.decodeBridgeValue(forKey: .tools)
        toolChoice = try container.decodeBridgeValue(forKey: .toolChoice)
        responseFormat = try container.decodeBridgeValue(forKey: .responseFormat)
        maxTokens = try container.decodeBridgeValue(forKey: .maxTokens)
        maxCompletionTokens = try container.decodeBridgeValue(forKey: .maxCompletionTokens)
        maxOutputTokens = try container.decodeBridgeValue(forKey: .maxOutputTokens)
    }
}

struct ChatBridgeInboundMessage: Decodable, Sendable {
    var role: BurnBarBridgeValue?
    var content: BurnBarBridgeValue?
    var toolCalls: BurnBarBridgeValue?
    var toolCallID: BurnBarBridgeValue?
    var name: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
    }
}

struct ChatBridgeInboundToolCall: Decodable, Sendable {
    var id: BurnBarBridgeValue?
    var function: BurnBarBridgeValue?
}

struct ChatBridgeInboundTool: Decodable, Sendable {
    var type: BurnBarBridgeValue?
    var function: BurnBarBridgeValue?
    var name: BurnBarBridgeValue?
    var toolDescription: BurnBarBridgeValue?
    var parameters: BurnBarBridgeValue?
    var inputSchema: BurnBarBridgeValue?
    var strict: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case type
        case function
        case name
        case toolDescription = "description"
        case parameters
        case inputSchema = "input_schema"
        case strict
    }
}

// Chat completion (non-streaming) as returned by OpenAI-compatible upstreams,
// as seen by the reverse bridges.
struct ChatBridgeInboundCompletion: Decodable, Sendable {
    var id: BurnBarBridgeValue?
    var model: BurnBarBridgeValue?
    var choices: [ChatBridgeInboundChoice]?
    var usage: BurnBarBridgeValue?

    struct ChatBridgeInboundChoice: Decodable, Sendable {
        var message: ChatBridgeInboundMessage?
        var delta: ChatBridgeInboundMessage?
        var finishReason: BurnBarBridgeValue?

        private enum CodingKeys: String, CodingKey {
            case message
            case delta
            case finishReason = "finish_reason"
        }
    }
}

extension ChatBridgeFinishReason {
    /// Anthropic `stop_reason` -> Chat Completions `finish_reason`.
    /// A missing reason encodes as explicit null (upstream still talking).
    static func fromAnthropicStopReason(_ stopReason: String?) -> ChatBridgeFinishReason {
        switch stopReason {
        case "tool_use":
            return .value("tool_calls")
        case "max_tokens":
            return .value("length")
        case nil:
            return .null
        default:
            return .value("stop")
        }
    }
}

// MARK: - Outbound chat wire models

/// Assistant message content: plain string, structured parts, or explicit null
/// (tool-call-only messages).
enum ChatBridgeOutboundContent: Encodable, Sendable {
    case string(String)
    case parts([ChatBridgeOutboundPart])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .parts(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

/// One outbound chat content part. All-value with a catch-all so the bridge
/// can forward preserved parts (audio, untyped fallbacks) verbatim, unknown
/// keys included. Total for any JSON object.
struct ChatBridgeOutboundPart: Codable, Sendable {
    var type: BurnBarBridgeValue?
    var text: BurnBarBridgeValue?
    var imageURL: BurnBarBridgeValue?
    var file: BurnBarBridgeValue?
    var inputAudio: BurnBarBridgeValue?
    var additionalFields: [String: BurnBarBridgeValue]

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case file
        case inputAudio = "input_audio"
    }

    private static let knownKeys: Set<String> = ["type", "text", "image_url", "file", "input_audio"]

    init(
        type: BurnBarBridgeValue? = nil,
        text: BurnBarBridgeValue? = nil,
        imageURL: BurnBarBridgeValue? = nil,
        file: BurnBarBridgeValue? = nil,
        inputAudio: BurnBarBridgeValue? = nil,
        additionalFields: [String: BurnBarBridgeValue] = [:]
    ) {
        self.type = type
        self.text = text
        self.imageURL = imageURL
        self.file = file
        self.inputAudio = inputAudio
        self.additionalFields = additionalFields
    }

    init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        type = try known.decodeBridgeValue(forKey: .type)
        text = try known.decodeBridgeValue(forKey: .text)
        imageURL = try known.decodeBridgeValue(forKey: .imageURL)
        file = try known.decodeBridgeValue(forKey: .file)
        inputAudio = try known.decodeBridgeValue(forKey: .inputAudio)
        let dynamic = try decoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        additionalFields = try dynamic.decodeExtras(excluding: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: CodingKeys.self)
        try known.encodeIfPresent(type, forKey: .type)
        try known.encodeIfPresent(text, forKey: .text)
        try known.encodeIfPresent(imageURL, forKey: .imageURL)
        try known.encodeIfPresent(file, forKey: .file)
        try known.encodeIfPresent(inputAudio, forKey: .inputAudio)
        var dynamic = encoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        try dynamic.encodeExtras(additionalFields)
    }
}

struct ChatBridgeOutboundMessage: Encodable, Sendable {
    var role: String
    var content: ChatBridgeOutboundContent
    // Opaque value (not typed calls): the Responses sanitizer copies client
    // `tool_calls` through verbatim, including malformed shapes.
    var toolCalls: BurnBarBridgeValue? = nil
    var toolCallID: String? = nil
    var name: String? = nil

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
        case name
    }
}

struct ChatBridgeOutboundToolCall: Encodable, Sendable {
    var id: String
    var type: String
    var function: ChatBridgeOutboundFunction
    var index: Int? = nil

    struct ChatBridgeOutboundFunction: Encodable, Sendable {
        var name: String
        var arguments: String
    }
}

struct ChatBridgeOutboundTool: Encodable, Sendable {
    var type: String
    var function: ChatBridgeOutboundToolFunction

    struct ChatBridgeOutboundToolFunction: Encodable, Sendable {
        var name: String
        var toolDescription: String? = nil
        var parameters: BurnBarBridgeValue
        var strict: Bool? = nil

        private enum CodingKeys: String, CodingKey {
            case name
            case toolDescription = "description"
            case parameters
            case strict
        }
    }
}

enum ChatBridgeOutboundToolChoice: Encodable, Sendable {
    case string(String)
    case namedFunction(String)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .namedFunction(let name):
            var container = encoder.container(keyedBy: BurnBarBridgeCodingKey.self)
            try container.encode("function", forKey: BurnBarBridgeCodingKey(stringValue: "type"))
            var function = container.nestedContainer(
                keyedBy: BurnBarBridgeCodingKey.self,
                forKey: BurnBarBridgeCodingKey(stringValue: "function")
            )
            try function.encode(name, forKey: BurnBarBridgeCodingKey(stringValue: "name"))
        }
    }
}

/// `finish_reason`: a string, or explicit null when the upstream gave none.
enum ChatBridgeFinishReason: Encodable, Sendable {
    case value(String)
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .value(let reason):
            try container.encode(reason)
        case .null:
            try container.encodeNil()
        }
    }
}

struct ChatBridgeUsage: Encodable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

// Chat Completions request built by the reverse bridges.
struct ChatBridgeOutboundRequest: Encodable, Sendable {
    var model: String
    var messages: [ChatBridgeOutboundMessage]
    var temperature: BurnBarBridgeValue? = nil
    var topP: BurnBarBridgeValue? = nil
    var stop: BurnBarBridgeValue? = nil
    var stream: BurnBarBridgeValue? = nil
    var maxTokens: BurnBarBridgeValue? = nil
    var maxCompletionTokens: BurnBarBridgeValue? = nil
    // Opaque values: the bridges normalize valid shapes into these, but
    // malformed client values still pass through verbatim.
    var tools: BurnBarBridgeValue? = nil
    var toolChoice: BurnBarBridgeValue? = nil
    var presencePenalty: BurnBarBridgeValue? = nil
    var frequencyPenalty: BurnBarBridgeValue? = nil
    var logitBias: BurnBarBridgeValue? = nil
    var seed: BurnBarBridgeValue? = nil
    var user: BurnBarBridgeValue? = nil
    var responseFormat: BurnBarBridgeValue? = nil

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case topP = "top_p"
        case stop
        case stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case tools
        case toolChoice = "tool_choice"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case logitBias = "logit_bias"
        case seed
        case user
        case responseFormat = "response_format"
    }
}

// Non-streaming Chat Completions response built by the forward bridges.
struct ChatBridgeCompletion: Encodable, Sendable {
    var id: String
    var object: String
    var created: Int
    var model: String
    var choices: [ChatBridgeCompletionChoice]
    var usage: ChatBridgeUsage

    struct ChatBridgeCompletionChoice: Encodable, Sendable {
        var index: Int
        var message: ChatBridgeOutboundMessage
        var finishReason: ChatBridgeFinishReason

        private enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }
}

// Streaming Chat Completions chunk built by the forward bridges.
struct ChatBridgeStreamChunk: Encodable, Sendable {
    var id: String
    var object: String
    var created: Int
    var model: String
    var choices: [ChatBridgeStreamChoice]
    var usage: ChatBridgeStreamUsage? = nil

    struct ChatBridgeStreamChoice: Encodable, Sendable {
        var index: Int
        var delta: ChatBridgeStreamDelta
        var finishReason: ChatBridgeFinishReason

        private enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct ChatBridgeStreamDelta: Encodable, Sendable {
        var role: String? = nil
        var content: String? = nil
        var toolCalls: [ChatBridgeStreamToolCall]? = nil

        private enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct ChatBridgeStreamToolCall: Encodable, Sendable {
        var index: Int? = nil
        var id: String? = nil
        var type: String? = nil
        var function: ChatBridgeStreamFunction? = nil

        struct ChatBridgeStreamFunction: Encodable, Sendable {
            var name: String? = nil
            var arguments: String? = nil
        }
    }
}

/// Usage object attached to the terminal chunk by the Anthropic stream mapper.
struct ChatBridgeStreamUsage: Encodable, Sendable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int
    var cacheCreationInputTokens: Int
    var cachedTokens: Int

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    private enum DetailsKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encode(cacheCreationInputTokens, forKey: .cacheCreationInputTokens)
        var details = container.nestedContainer(keyedBy: DetailsKeys.self, forKey: .promptTokensDetails)
        try details.encode(cachedTokens, forKey: .cachedTokens)
    }
}
