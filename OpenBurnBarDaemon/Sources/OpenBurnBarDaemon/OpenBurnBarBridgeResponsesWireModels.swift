import Foundation
import OpenBurnBarEngine

// MARK: - Inbound (lenient) Responses wire views

/// Responses request as seen by the fallbacks. Copied-through keys stay
/// opaque values so exotic-but-valid shapes survive the hop to Chat Completions.
struct ResponsesBridgeInboundRequest: Decodable, Sendable {
    var instructions: BurnBarBridgeValue?
    var messages: BurnBarBridgeValue?
    var input: BurnBarBridgeValue?
    var temperature: BurnBarBridgeValue?
    var topP: BurnBarBridgeValue?
    var stop: BurnBarBridgeValue?
    var stream: BurnBarBridgeValue?
    var presencePenalty: BurnBarBridgeValue?
    var frequencyPenalty: BurnBarBridgeValue?
    var logitBias: BurnBarBridgeValue?
    var seed: BurnBarBridgeValue?
    var user: BurnBarBridgeValue?
    var responseFormat: BurnBarBridgeValue?
    var maxTokens: BurnBarBridgeValue?
    var maxOutputTokens: BurnBarBridgeValue?
    var tools: BurnBarBridgeValue?
    var toolChoice: BurnBarBridgeValue?
    var text: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case instructions
        case messages
        case input
        case temperature
        case topP = "top_p"
        case stop
        case stream
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case logitBias = "logit_bias"
        case seed
        case user
        case responseFormat = "response_format"
        case maxTokens = "max_tokens"
        case maxOutputTokens = "max_output_tokens"
        case tools
        case toolChoice = "tool_choice"
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instructions = try container.decodeBridgeValue(forKey: .instructions)
        messages = try container.decodeBridgeValue(forKey: .messages)
        input = try container.decodeBridgeValue(forKey: .input)
        temperature = try container.decodeBridgeValue(forKey: .temperature)
        topP = try container.decodeBridgeValue(forKey: .topP)
        stop = try container.decodeBridgeValue(forKey: .stop)
        stream = try container.decodeBridgeValue(forKey: .stream)
        presencePenalty = try container.decodeBridgeValue(forKey: .presencePenalty)
        frequencyPenalty = try container.decodeBridgeValue(forKey: .frequencyPenalty)
        logitBias = try container.decodeBridgeValue(forKey: .logitBias)
        seed = try container.decodeBridgeValue(forKey: .seed)
        user = try container.decodeBridgeValue(forKey: .user)
        responseFormat = try container.decodeBridgeValue(forKey: .responseFormat)
        maxTokens = try container.decodeBridgeValue(forKey: .maxTokens)
        maxOutputTokens = try container.decodeBridgeValue(forKey: .maxOutputTokens)
        tools = try container.decodeBridgeValue(forKey: .tools)
        toolChoice = try container.decodeBridgeValue(forKey: .toolChoice)
        text = try container.decodeBridgeValue(forKey: .text)
    }
}

/// One Responses `input` item (or an embedded chat message): role plus
/// content under either the `content` or the `text` key.
struct ResponsesBridgeInboundItem: Decodable, Sendable {
    var role: BurnBarBridgeValue?
    var content: BurnBarBridgeValue?
    var text: BurnBarBridgeValue?
    var name: BurnBarBridgeValue?
    var toolCallID: BurnBarBridgeValue?
    var toolCalls: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case text
        case name
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeBridgeValue(forKey: .role)
        content = try container.decodeBridgeValue(forKey: .content)
        text = try container.decodeBridgeValue(forKey: .text)
        name = try container.decodeBridgeValue(forKey: .name)
        toolCallID = try container.decodeBridgeValue(forKey: .toolCallID)
        toolCalls = try container.decodeBridgeValue(forKey: .toolCalls)
    }
}

/// One content part inside Responses input / chat content arrays.
struct ResponsesBridgeContentPart: Decodable, Sendable {
    var type: BurnBarBridgeValue?
    var text: BurnBarBridgeValue?
    var inputText: BurnBarBridgeValue?
    var outputText: BurnBarBridgeValue?
    var imageURL: BurnBarBridgeValue?
    var url: BurnBarBridgeValue?
    var inputAudio: BurnBarBridgeValue?
    var file: BurnBarBridgeValue?
    var fileData: BurnBarBridgeValue?
    var data: BurnBarBridgeValue?
    var filename: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case inputText = "input_text"
        case outputText = "output_text"
        case imageURL = "image_url"
        case url
        case inputAudio = "input_audio"
        case file
        case fileData = "file_data"
        case data
        case filename
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeBridgeValue(forKey: .type)
        text = try container.decodeBridgeValue(forKey: .text)
        inputText = try container.decodeBridgeValue(forKey: .inputText)
        outputText = try container.decodeBridgeValue(forKey: .outputText)
        imageURL = try container.decodeBridgeValue(forKey: .imageURL)
        url = try container.decodeBridgeValue(forKey: .url)
        inputAudio = try container.decodeBridgeValue(forKey: .inputAudio)
        file = try container.decodeBridgeValue(forKey: .file)
        fileData = try container.decodeBridgeValue(forKey: .fileData)
        data = try container.decodeBridgeValue(forKey: .data)
        filename = try container.decodeBridgeValue(forKey: .filename)
    }
}

// Usage object with every alias the bridges accept, from both the Responses
// (`input_tokens`) and Chat (`prompt_tokens`) spellings.
struct ResponsesBridgeUsage: Decodable, Sendable {
    var inputTokens: BurnBarBridgeValue?
    var promptTokens: BurnBarBridgeValue?
    var outputTokens: BurnBarBridgeValue?
    var completionTokens: BurnBarBridgeValue?
    var cacheCreationInputTokens: BurnBarBridgeValue?
    var cacheCreationTokens: BurnBarBridgeValue?
    var cacheReadInputTokens: BurnBarBridgeValue?
    var cacheReadTokens: BurnBarBridgeValue?
    var inputCachedTokens: BurnBarBridgeValue?
    var cachedInputTokens: BurnBarBridgeValue?
    var cachedTokens: BurnBarBridgeValue?
    var reasoningTokens: BurnBarBridgeValue?
    var promptTokensDetails: BurnBarBridgeValue?
    var inputTokensDetails: BurnBarBridgeValue?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case promptTokens = "prompt_tokens"
        case outputTokens = "output_tokens"
        case completionTokens = "completion_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreationTokens = "cache_creation_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheReadTokens = "cache_read_tokens"
        case inputCachedTokens = "input_cached_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cachedTokens = "cached_tokens"
        case reasoningTokens = "reasoning_tokens"
        case promptTokensDetails = "prompt_tokens_details"
        case inputTokensDetails = "input_tokens_details"
    }

}

struct ResponsesUsageEnvelope: Decodable, Sendable {
    var usage: ResponsesBridgeUsage?
}

// MARK: - Outbound Responses wire models

struct ResponsesBridgeUsageOut: Encodable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
    var reasoningTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
        case reasoningTokens = "reasoning_tokens"
    }
}

struct ResponsesBridgeOutputText: Encodable, Sendable {
    var type: String
    var text: String
    var annotations: [BurnBarBridgeValue]

    init(text: String) {
        self.type = "output_text"
        self.text = text
        self.annotations = []
    }
}

enum ResponsesBridgeOutputItem: Encodable, Sendable {
    case message(id: String, status: String, outputText: String, alwaysEmitPart: Bool)
    case functionCall(id: String, status: String, callID: String, name: String, arguments: String)

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case status
        case role
        case content
        case callID = "call_id"
        case name
        case arguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let id, let status, let outputText, let alwaysEmitPart):
            try container.encode(id, forKey: .id)
            try container.encode("message", forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode("assistant", forKey: .role)
            if outputText.isEmpty && !alwaysEmitPart {
                try container.encode([ResponsesBridgeOutputText](), forKey: .content)
            } else {
                try container.encode([ResponsesBridgeOutputText(text: outputText)], forKey: .content)
            }
        case .functionCall(let id, let status, let callID, let name, let arguments):
            try container.encode(id, forKey: .id)
            try container.encode("function_call", forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

struct ResponsesBridgeObject: Encodable, Sendable {
    var id: String
    var object: String
    var createdAt: Int
    var model: String
    var status: String
    var output: [ResponsesBridgeOutputItem]
    var outputText: String
    var usage: ResponsesBridgeUsageOut?

    private enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case model
        case status
        case output
        case outputText = "output_text"
        case usage
    }
}

// MARK: - Responses SSE event payloads

struct ResponsesBridgeEventCreated: Encodable, Sendable {
    var type: String
    var response: ResponsesBridgeObject

    init(response: ResponsesBridgeObject) {
        self.type = "response.created"
        self.response = response
    }
}

struct ResponsesBridgeEventOutputItemAdded: Encodable, Sendable {
    var type: String
    var responseID: String
    var outputIndex: Int
    var item: ResponsesBridgeOutputItem

    private enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case outputIndex = "output_index"
        case item
    }
}

struct ResponsesBridgeEventContentPartAdded: Encodable, Sendable {
    var type: String
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var part: ResponsesBridgeOutputText

    private enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
    }
}

struct ResponsesBridgeEventOutputTextDelta: Encodable, Sendable {
    var type: String
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var delta: String

    private enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case delta
    }
}

struct ResponsesBridgeEventOutputTextDone: Encodable, Sendable {
    var type: String
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var text: String

    private enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case text
    }
}

struct ResponsesBridgeEventContentPartDone: Encodable, Sendable {
    var type: String
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var part: ResponsesBridgeOutputText

    private enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
    }
}

struct ResponsesBridgeEventOutputItemDone: Encodable, Sendable {
    var type: String
    var responseID: String
    var outputIndex: Int
    var item: ResponsesBridgeOutputItem

    private enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case outputIndex = "output_index"
        case item
    }
}

struct ResponsesBridgeEventCompleted: Encodable, Sendable {
    var type: String
    var response: ResponsesBridgeObject

    init(response: ResponsesBridgeObject) {
        self.type = "response.completed"
        self.response = response
    }
}
