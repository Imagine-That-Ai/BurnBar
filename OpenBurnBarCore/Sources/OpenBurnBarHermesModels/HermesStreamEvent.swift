import Foundation

public struct HermesTokenUsageStats: Codable, Sendable, Equatable, Hashable {
    public var promptTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var generationDurationSeconds: TimeInterval?
    public var totalDurationSeconds: TimeInterval?

    public init(
        promptTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        generationDurationSeconds: TimeInterval? = nil,
        totalDurationSeconds: TimeInterval? = nil
    ) {
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.generationDurationSeconds = generationDurationSeconds
        self.totalDurationSeconds = totalDurationSeconds
    }
}

public struct CLIUsageSnapshot: Codable, Sendable, Equatable, Hashable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let reasoningTokens: Int

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        reasoningTokens: Int
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.reasoningTokens = reasoningTokens
    }

    public var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens + reasoningTokens
    }

    public var hermesTokenUsage: HermesTokenUsageStats {
        HermesTokenUsageStats(
            promptTokens: inputTokens + cacheCreationTokens + cacheReadTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens
        )
    }
}

/// First-class classification of an assistant turn so UI surfaces can render
/// distinct visual treatment without parsing prose.
public enum HermesChatMessageOutcome: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case normal
    case refusal
    case reasoningFallback
    case lengthCap
    case contentFilter
    case toolCallNoFollowUp
    case empty

    public var supportsRetry: Bool {
        switch self {
        case .lengthCap, .contentFilter, .toolCallNoFollowUp, .empty:
            return true
        case .normal, .refusal, .reasoningFallback:
            return false
        }
    }

    public var badgeLabel: String? {
        switch self {
        case .normal: return nil
        case .refusal: return "Declined"
        case .reasoningFallback: return "Reasoning channel"
        case .lengthCap: return "Reply truncated"
        case .contentFilter: return "Filtered"
        case .toolCallNoFollowUp: return "Tool call dropped"
        case .empty: return "No reply"
        }
    }

    public var badgeSymbol: String? {
        switch self {
        case .normal: return nil
        case .refusal: return "hand.raised.fill"
        case .reasoningFallback: return "brain"
        case .lengthCap: return "scissors"
        case .contentFilter: return "shield.lefthalf.filled"
        case .toolCallNoFollowUp: return "wrench.and.screwdriver"
        case .empty: return "exclamationmark.bubble"
        }
    }
}

/// Presentation-layer stream vocabulary shared by Mac, iOS/iPadOS, and Android.
/// These events are never durable conversation history; final assistant text and
/// durable tool transcript rows remain authoritative.
public enum HermesStreamEvent: Codable, Sendable, Equatable, Hashable {
    case messageChunk(text: String)
    case reasoningChunk(text: String)
    case refusalChunk(text: String)
    case toolCallChunk(id: String, index: Int, name: String?, argumentsDelta: String)
    case toolCallFinished(id: String, name: String, arguments: String)
    case toolResult(id: String?, name: String, detail: String?)
    case longToolHint(toolName: String, message: String)
    case notice(level: String, text: String)
    case messageStop(finishReason: String?, outcome: HermesChatMessageOutcome, usage: HermesTokenUsageStats?)

    private enum EventType: String, Codable {
        case messageChunk
        case reasoningChunk
        case refusalChunk
        case toolCallChunk
        case toolCallFinished
        case toolResult
        case longToolHint
        case notice
        case messageStop
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case index
        case name
        case arguments
        case argumentsDelta
        case detail
        case toolName
        case message
        case level
        case finishReason
        case outcome
        case usage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)
        switch type {
        case .messageChunk:
            self = .messageChunk(text: try container.decode(String.self, forKey: .text))
        case .reasoningChunk:
            self = .reasoningChunk(text: try container.decode(String.self, forKey: .text))
        case .refusalChunk:
            self = .refusalChunk(text: try container.decode(String.self, forKey: .text))
        case .toolCallChunk:
            self = .toolCallChunk(
                id: try container.decode(String.self, forKey: .id),
                index: try container.decode(Int.self, forKey: .index),
                name: try container.decodeIfPresent(String.self, forKey: .name),
                argumentsDelta: try container.decode(String.self, forKey: .argumentsDelta)
            )
        case .toolCallFinished:
            self = .toolCallFinished(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                arguments: try container.decode(String.self, forKey: .arguments)
            )
        case .toolResult:
            self = .toolResult(
                id: try container.decodeIfPresent(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                detail: try container.decodeIfPresent(String.self, forKey: .detail)
            )
        case .longToolHint:
            self = .longToolHint(
                toolName: try container.decode(String.self, forKey: .toolName),
                message: try container.decode(String.self, forKey: .message)
            )
        case .notice:
            self = .notice(
                level: try container.decode(String.self, forKey: .level),
                text: try container.decode(String.self, forKey: .text)
            )
        case .messageStop:
            self = .messageStop(
                finishReason: try container.decodeIfPresent(String.self, forKey: .finishReason),
                outcome: try container.decode(HermesChatMessageOutcome.self, forKey: .outcome),
                usage: try container.decodeIfPresent(HermesTokenUsageStats.self, forKey: .usage)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .messageChunk(let text):
            try container.encode(EventType.messageChunk, forKey: .type)
            try container.encode(text, forKey: .text)
        case .reasoningChunk(let text):
            try container.encode(EventType.reasoningChunk, forKey: .type)
            try container.encode(text, forKey: .text)
        case .refusalChunk(let text):
            try container.encode(EventType.refusalChunk, forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolCallChunk(let id, let index, let name, let argumentsDelta):
            try container.encode(EventType.toolCallChunk, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(index, forKey: .index)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encode(argumentsDelta, forKey: .argumentsDelta)
        case .toolCallFinished(let id, let name, let arguments):
            try container.encode(EventType.toolCallFinished, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .toolResult(let id, let name, let detail):
            try container.encode(EventType.toolResult, forKey: .type)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(detail, forKey: .detail)
        case .longToolHint(let toolName, let message):
            try container.encode(EventType.longToolHint, forKey: .type)
            try container.encode(toolName, forKey: .toolName)
            try container.encode(message, forKey: .message)
        case .notice(let level, let text):
            try container.encode(EventType.notice, forKey: .type)
            try container.encode(level, forKey: .level)
            try container.encode(text, forKey: .text)
        case .messageStop(let finishReason, let outcome, let usage):
            try container.encode(EventType.messageStop, forKey: .type)
            try container.encodeIfPresent(finishReason, forKey: .finishReason)
            try container.encode(outcome, forKey: .outcome)
            try container.encodeIfPresent(usage, forKey: .usage)
        }
    }
}
