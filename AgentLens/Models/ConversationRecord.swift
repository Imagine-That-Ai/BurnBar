import Foundation
import OpenBurnBarCore

// MARK: - Conversation Source Type

/// Discriminates between indexed provider transcripts and the in-app CLI assistant log.
enum ConversationSourceType: String, Codable {
    case providerLog  = "provider_log"
    case cliAssistant = "cli_assistant"
}

// MARK: - Conversation Record

/// Indexed session transcript and metadata for local search and context.
struct ConversationRecord: Codable, Identifiable, Hashable {
    let id: String
    let provider: AgentProvider
    let sessionId: String
    let projectName: String
    let startTime: Date?
    let endTime: Date?
    let messageCount: Int
    let userWordCount: Int
    let assistantWordCount: Int
    let keyFiles: [String]
    let keyCommands: [String]
    let keyTools: [String]
    let inferredTaskTitle: String
    let lastAssistantMessage: String
    let fullText: String
    let indexedAt: Date
    /// Source log file modification time; used to skip unchanged files.
    let fileModifiedAt: Date?
    /// Populated after on-demand CLI summarization in Session detail.
    let summary: String?
    /// Short generated session name for list/search usability.
    let summaryTitle: String?
    /// Last time summary/title were generated.
    let summaryUpdatedAt: Date?
    /// Provider/model provenance for generated summary.
    let summaryProvider: String?
    let summaryModel: String?
    /// Whether this record comes from a provider log file or the in-app CLI assistant thread.
    let sourceType: ConversationSourceType
    /// Non-nil for conversations downloaded from another device via cloud sync.
    let sourceDeviceId: String?
    /// Human-readable name of the source device.
    let sourceDeviceName: String?
    /// True for rows downloaded from Firestore; excluded from upload sync.
    let isRemote: Bool

    init(
        id: String,
        provider: AgentProvider,
        sessionId: String,
        projectName: String,
        startTime: Date?,
        endTime: Date?,
        messageCount: Int,
        userWordCount: Int,
        assistantWordCount: Int,
        keyFiles: [String],
        keyCommands: [String],
        keyTools: [String],
        inferredTaskTitle: String,
        lastAssistantMessage: String,
        fullText: String,
        indexedAt: Date = Date(),
        fileModifiedAt: Date?,
        summary: String? = nil,
        summaryTitle: String? = nil,
        summaryUpdatedAt: Date? = nil,
        summaryProvider: String? = nil,
        summaryModel: String? = nil,
        sourceType: ConversationSourceType = .providerLog,
        sourceDeviceId: String? = nil,
        sourceDeviceName: String? = nil,
        isRemote: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.sessionId = sessionId
        self.projectName = projectName
        self.startTime = startTime
        self.endTime = endTime
        self.messageCount = messageCount
        self.userWordCount = userWordCount
        self.assistantWordCount = assistantWordCount
        self.keyFiles = keyFiles
        self.keyCommands = keyCommands
        self.keyTools = keyTools
        self.inferredTaskTitle = inferredTaskTitle
        self.lastAssistantMessage = lastAssistantMessage
        self.fullText = fullText
        self.indexedAt = indexedAt
        self.fileModifiedAt = fileModifiedAt
        self.summary = summary
        self.summaryTitle = summaryTitle
        self.summaryUpdatedAt = summaryUpdatedAt
        self.summaryProvider = summaryProvider
        self.summaryModel = summaryModel
        self.sourceType = sourceType
        self.sourceDeviceId = sourceDeviceId
        self.sourceDeviceName = sourceDeviceName
        self.isRemote = isRemote
    }

    /// Stable synthetic ID for the in-app CLI assistant conversation.
    static let cliAssistantId = "cli_assistant:local"

    static func stableId(provider: AgentProvider, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }
}

// MARK: - Chat Message (persisted)

enum ChatMessageRole: String, Codable {
    case user
    case assistant
    case system
}

/// Ordered segments for assistant messages (text interleaved with tool calls). User messages use `content` only.
struct ChatTranscriptPiece: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case text
        case toolUse
        case toolResult
    }

    let id: String
    let kind: Kind
    /// Prose for `.text`; tool label (e.g. Read, Bash) for tool events.
    var value: String
    let detail: String?

    init(id: String = UUID().uuidString, kind: Kind, value: String, detail: String? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.detail = detail
    }
}

struct ChatMessageRecord: Codable, Identifiable, Hashable {
    let id: String
    let role: ChatMessageRole
    let content: String
    let timestamp: Date
    let cliUsed: String?
    /// Populated for assistant streams that emit tool events; empty means treat `content` as plain text.
    let transcriptPieces: [ChatTranscriptPiece]
    /// Files the user attached when sending this message. Persisted with the
    /// transcript so attachments stay visible after a chat is reopened.
    let attachments: [HermesAttachment]

    init(
        id: String = UUID().uuidString,
        role: ChatMessageRole,
        content: String,
        timestamp: Date = Date(),
        cliUsed: String? = nil,
        transcriptPieces: [ChatTranscriptPiece] = [],
        attachments: [HermesAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.cliUsed = cliUsed
        self.transcriptPieces = transcriptPieces
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, cliUsed, transcriptPieces, attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(ChatMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        cliUsed = try container.decodeIfPresent(String.self, forKey: .cliUsed)
        transcriptPieces = try container.decodeIfPresent([ChatTranscriptPiece].self, forKey: .transcriptPieces) ?? []
        attachments = try container.decodeIfPresent([HermesAttachment].self, forKey: .attachments) ?? []
    }

    /// Pieces for display (legacy rows use a single synthetic text piece from `content`).
    var displayTranscript: [ChatTranscriptPiece] {
        if !transcriptPieces.isEmpty { return transcriptPieces }
        guard !content.isEmpty else { return [] }
        return [ChatTranscriptPiece(id: "\(id)-legacy", kind: .text, value: content, detail: nil)]
    }

    /// Joined text segments for persistence / search parity.
    static func joinedText(from pieces: [ChatTranscriptPiece]) -> String {
        pieces.filter { $0.kind == .text }.map(\.value).joined()
    }
}

/// Groups consecutive tool transcript pieces for horizontal strip rendering.
/// Used by both the dashboard `ChatMessageView` and the popover `HermesPopoverBubble`.
enum TranscriptGroup: Identifiable {
    case toolGroup([ChatTranscriptPiece])
    case single(ChatTranscriptPiece)

    var id: String {
        switch self {
        case .toolGroup(let pieces):
            return "tg-\(pieces.first?.id ?? UUID().uuidString)"
        case .single(let piece):
            return piece.id
        }
    }

    /// Partitions transcript pieces into groups: consecutive tool pieces
    /// become `.toolGroup`, individual `.text` pieces become `.single`.
    static func group(_ transcript: [ChatTranscriptPiece]) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var pendingTools: [ChatTranscriptPiece] = []

        for piece in transcript {
            switch piece.kind {
            case .toolUse, .toolResult:
                pendingTools.append(piece)
            case .text:
                if !pendingTools.isEmpty {
                    groups.append(.toolGroup(pendingTools))
                    pendingTools = []
                }
                groups.append(.single(piece))
            }
        }
        if !pendingTools.isEmpty {
            groups.append(.toolGroup(pendingTools))
        }
        return groups
    }
}

/// Summary row for a persisted Burn Bar chat thread.
struct ChatThreadSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let preview: String
    let attachments: [HermesAttachment]
    let messageCount: Int
    let createdAt: Date
    let updatedAt: Date
    let lastMessageAt: Date?

    var lastActivityAt: Date {
        lastMessageAt ?? updatedAt
    }
}

enum ConversationJumpSource: String, Codable, Hashable, Sendable {
    case aggregateExact = "aggregate_exact"
    case retrieval = "retrieval"
}

struct ConversationJumpTarget: Identifiable, Hashable, Sendable {
    let conversation: ConversationRecord
    let snippet: String
    let startOffset: Int
    let endOffset: Int
    let source: ConversationJumpSource

    var id: String {
        "\(conversation.id)|\(startOffset)|\(endOffset)|\(source.rawValue)"
    }

    var displayTimestamp: Date {
        conversation.endTime ?? conversation.startTime ?? conversation.indexedAt
    }
}

struct CredentialExposureScanResult: Hashable, Sendable {
    let totalMatches: Int
    let jumpTargets: [ConversationJumpTarget]
}

struct ConversationProviderOccurrence: Hashable, Sendable {
    let provider: AgentProvider
    let occurrenceCount: Int
    let conversationCount: Int
}
