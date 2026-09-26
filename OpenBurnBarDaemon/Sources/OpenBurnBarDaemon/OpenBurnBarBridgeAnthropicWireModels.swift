import Foundation
import OpenBurnBarEngine

// MARK: - Anthropic passthrough request (live proxy rewriting)
//
// `/v1/messages` bodies BurnBar forwards upstream. Only the keys the proxy
// touches are modeled; every other key round-trips through `additionalFields`
// untouched so vendor betas and future fields survive the proxy.

struct AnthropicPassthroughRequest: Codable, Sendable {
    var model: BurnBarBridgeValue?
    var system: BurnBarBridgeValue?
    var thinking: BurnBarBridgeValue?
    var maxTokens: BurnBarBridgeValue?
    var stream: BurnBarBridgeValue?
    var additionalFields: [String: BurnBarBridgeValue]

    private enum CodingKeys: String, CodingKey {
        case model
        case system
        case thinking
        case maxTokens = "max_tokens"
        case stream
    }

    private static let knownKeys: Set<String> = ["model", "system", "thinking", "max_tokens", "stream"]

    init(
        model: BurnBarBridgeValue? = nil,
        system: BurnBarBridgeValue? = nil,
        thinking: BurnBarBridgeValue? = nil,
        maxTokens: BurnBarBridgeValue? = nil,
        stream: BurnBarBridgeValue? = nil,
        additionalFields: [String: BurnBarBridgeValue] = [:]
    ) {
        self.model = model
        self.system = system
        self.thinking = thinking
        self.maxTokens = maxTokens
        self.stream = stream
        self.additionalFields = additionalFields
    }

    init(from decoder: Decoder) throws {
        let known = try decoder.container(keyedBy: CodingKeys.self)
        model = try known.decodeBridgeValue(forKey: .model)
        system = try known.decodeBridgeValue(forKey: .system)
        thinking = try known.decodeBridgeValue(forKey: .thinking)
        maxTokens = try known.decodeBridgeValue(forKey: .maxTokens)
        stream = try known.decodeBridgeValue(forKey: .stream)
        let dynamic = try decoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        additionalFields = try dynamic.decodeExtras(excluding: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var known = encoder.container(keyedBy: CodingKeys.self)
        try known.encodeIfPresent(model, forKey: .model)
        try known.encodeIfPresent(system, forKey: .system)
        try known.encodeIfPresent(thinking, forKey: .thinking)
        try known.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try known.encodeIfPresent(stream, forKey: .stream)
        var dynamic = encoder.container(keyedBy: BurnBarBridgeCodingKey.self)
        try dynamic.encodeExtras(additionalFields)
    }
}

struct AnthropicThinkingConfig: Encodable, Sendable {
    var type: String
    var budgetTokens: Int

    private enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }

    func bridgeValue() -> BurnBarBridgeValue {
        .object(["type": .string(type), "budget_tokens": .int(budgetTokens)])
    }
}

// MARK: - Chat/Responses -> Anthropic bridged request

struct AnthropicBridgedRequest: Encodable, Sendable {
    var model: String
    var maxTokens: Int
    var messages: [AnthropicBridgedMessage]
    var system: String?
    var temperature: BurnBarBridgeValue?
    var topP: BurnBarBridgeValue?
    var stopSequences: BurnBarBridgeValue?
    var stream: Bool?
    var tools: [AnthropicBridgedTool]?
    var toolChoice: AnthropicBridgedToolChoice?
    var thinking: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case system
        case temperature
        case topP = "top_p"
        case stopSequences = "stop_sequences"
        case stream
        case tools
        case toolChoice = "tool_choice"
        case thinking
    }
}

struct AnthropicBridgedMessage: Encodable, Sendable {
    var role: String
    var content: [AnthropicBridgedBlock]
}

struct AnthropicBridgedBlock: Encodable, Sendable {
    var type: String
    var text: String?
    var id: String?
    var name: String?
    var input: BurnBarBridgeValue?
    var toolUseID: String?
    var content: String?
    var source: AnthropicBridgedSource?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case toolUseID = "tool_use_id"
        case content
        case source
    }

    struct AnthropicBridgedSource: Encodable, Sendable {
        var type: String
        var mediaType: String
        var data: String

        private enum CodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }
}

struct AnthropicBridgedTool: Encodable, Sendable {
    var name: String
    var inputSchema: BurnBarBridgeValue
    var toolDescription: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case inputSchema = "input_schema"
        case toolDescription = "description"
    }
}

struct AnthropicBridgedToolChoice: Encodable, Sendable {
    var type: String
    var name: String?
}

// MARK: - Anthropic inbound views (responses, requests, content blocks)

struct AnthropicInboundMessage: Decodable, Sendable {
    var content: BurnBarBridgeValue?
    var stopReason: BurnBarBridgeValue?
    var usage: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
        case usage
    }
}

struct AnthropicInboundUsage: Decodable, Sendable {
    var inputTokens: BurnBarBridgeValue?
    var outputTokens: BurnBarBridgeValue?
    var cacheCreationInputTokens: BurnBarBridgeValue?
    var cacheReadInputTokens: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

struct AnthropicUsageEnvelope: Decodable, Sendable {
    var usage: AnthropicInboundUsage?
}

/// One Anthropic content block in either direction.
struct AnthropicContentBlockWire: Decodable, Sendable {
    var type: BurnBarBridgeValue?
    var text: BurnBarBridgeValue?
    var id: BurnBarBridgeValue?
    var name: BurnBarBridgeValue?
    var input: BurnBarBridgeValue?
    var toolUseID: BurnBarBridgeValue?
    var content: BurnBarBridgeValue?
    var source: AnthropicBlockSource?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case toolUseID = "tool_use_id"
        case content
        case source
    }

    struct AnthropicBlockSource: Decodable, Sendable {
        var type: BurnBarBridgeValue?
        var mediaType: BurnBarBridgeValue?
        var data: BurnBarBridgeValue?

        private enum CodingKeys: String, CodingKey {
            case type
            case mediaType = "media_type"
            case data
        }
    }

    /// Plain-text message content expressed as a single text block.
    static func text(_ string: String) -> AnthropicContentBlockWire {
        AnthropicContentBlockWire(
            type: .string("text"),
            text: .string(string),
            id: nil,
            name: nil,
            input: nil,
            toolUseID: nil,
            content: nil,
            source: nil
        )
    }
}

/// Anthropic Messages request as seen by the reverse bridge
/// (Anthropic-shaped clients served from OpenAI-compatible routes).
struct AnthropicBridgeInboundRequest: Decodable, Sendable {
    var messages: BurnBarBridgeValue?
    var system: BurnBarBridgeValue?
    var maxTokens: BurnBarBridgeValue?
    var temperature: BurnBarBridgeValue?
    var topP: BurnBarBridgeValue?
    var stopSequences: BurnBarBridgeValue?
    var stream: BurnBarBridgeValue?
    var tools: BurnBarBridgeValue?
    var toolChoice: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case messages
        case system
        case maxTokens = "max_tokens"
        case temperature
        case topP = "top_p"
        case stopSequences = "stop_sequences"
        case stream
        case tools
        case toolChoice = "tool_choice"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = try container.decodeBridgeValue(forKey: .messages)
        system = try container.decodeBridgeValue(forKey: .system)
        maxTokens = try container.decodeBridgeValue(forKey: .maxTokens)
        temperature = try container.decodeBridgeValue(forKey: .temperature)
        topP = try container.decodeBridgeValue(forKey: .topP)
        stopSequences = try container.decodeBridgeValue(forKey: .stopSequences)
        stream = try container.decodeBridgeValue(forKey: .stream)
        tools = try container.decodeBridgeValue(forKey: .tools)
        toolChoice = try container.decodeBridgeValue(forKey: .toolChoice)
    }
}

struct AnthropicBridgeInboundMessage: Decodable, Sendable {
    var role: BurnBarBridgeValue?
    var content: BurnBarBridgeValue?
}

struct AnthropicBridgeInboundTool: Decodable, Sendable {
    var name: BurnBarBridgeValue?
    var toolDescription: BurnBarBridgeValue?
    var inputSchema: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case name
        case toolDescription = "description"
        case inputSchema = "input_schema"
    }
}

// MARK: - Anthropic outbound message (reverse bridge responses)

struct AnthropicOutboundMessage: Encodable, Sendable {
    var id: String
    var type: String
    var role: String
    var model: String
    var content: [AnthropicBridgedBlock]
    var stopReason: String
    var stopSequence: BurnBarBridgeValue
    var usage: AnthropicOutboundUsage

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case model
        case content
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
    }

    struct AnthropicOutboundUsage: Encodable, Sendable {
        var inputTokens: Int
        var outputTokens: Int

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

enum AnthropicBridgeStopReason {
    /// Chat Completions `finish_reason` -> Anthropic `stop_reason`.
    static func fromChatFinishReason(_ value: String?) -> String {
        switch value {
        case "tool_calls":
            return "tool_use"
        case "length", "max_tokens":
            return "max_tokens"
        default:
            return "end_turn"
        }
    }
}

// MARK: - Anthropic SSE event payloads (typed views)

/// Typed view over one upstream Anthropic SSE `data:` payload. `raw` keeps the
/// original value so error payloads forward through verbatim. Sub-objects stay
/// lenient values so a malformed sibling never drops an otherwise usable event.
struct AnthropicStreamEventPayload: Decodable, Sendable {
    var type: String?
    var index: BurnBarBridgeValue?
    var delta: BurnBarBridgeValue?
    var contentBlock: BurnBarBridgeValue?
    var message: BurnBarBridgeValue?
    var usage: BurnBarBridgeValue?
    var error: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case type
        case index
        case delta
        case contentBlock = "content_block"
        case message
        case usage
        case error
    }
}

struct AnthropicStreamEvent: Sendable {
    var event: String?
    var payload: AnthropicStreamEventPayload
    var raw: BurnBarBridgeValue
}

// MARK: - Anthropic outbound SSE payloads

struct AnthropicOutboundMessageStart: Encodable, Sendable {
    var type: String
    var message: AnthropicOutboundMessageStartBody

    struct AnthropicOutboundMessageStartBody: Encodable, Sendable {
        var id: String
        var type: String
        var role: String
        var model: String
        var content: [BurnBarBridgeValue]
        var stopReason: BurnBarBridgeValue
        var stopSequence: BurnBarBridgeValue
        var usage: AnthropicOutboundMessage.AnthropicOutboundUsage

        private enum CodingKeys: String, CodingKey {
            case id
            case type
            case role
            case model
            case content
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
            case usage
        }
    }
}

struct AnthropicOutboundContentBlockStart: Encodable, Sendable {
    var type: String
    var index: Int
    var contentBlock: BurnBarBridgeValue

    private enum CodingKeys: String, CodingKey {
        case type
        case index
        case contentBlock = "content_block"
    }
}

struct AnthropicOutboundContentBlockDelta: Encodable, Sendable {
    var type: String
    var index: Int
    var delta: BurnBarBridgeValue

    private enum CodingKeys: String, CodingKey {
        case type
        case index
        case delta
    }
}

struct AnthropicOutboundContentBlockStop: Encodable, Sendable {
    var type: String
    var index: Int

    private enum CodingKeys: String, CodingKey {
        case type
        case index
    }
}

struct AnthropicOutboundMessageDelta: Encodable, Sendable {
    var type: String
    var delta: AnthropicOutboundMessageDeltaBody
    var usage: AnthropicOutboundMessageDeltaUsage

    struct AnthropicOutboundMessageDeltaBody: Encodable, Sendable {
        var stopReason: String
        var stopSequence: BurnBarBridgeValue

        private enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
        }
    }

    struct AnthropicOutboundMessageDeltaUsage: Encodable, Sendable {
        var outputTokens: Int

        private enum CodingKeys: String, CodingKey {
            case outputTokens = "output_tokens"
        }
    }
}

struct AnthropicOutboundMessageStop: Encodable, Sendable {
    var type: String
}
