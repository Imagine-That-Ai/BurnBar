import Foundation

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
        sourceType: ConversationSourceType = .providerLog
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
    }

    let id: String
    let kind: Kind
    /// Prose for `.text`; tool label (e.g. Read, Bash) for `.toolUse`.
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

    init(
        id: String = UUID().uuidString,
        role: ChatMessageRole,
        content: String,
        timestamp: Date = Date(),
        cliUsed: String? = nil,
        transcriptPieces: [ChatTranscriptPiece] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.cliUsed = cliUsed
        self.transcriptPieces = transcriptPieces
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

/// Summary row for a persisted Burn Bar chat thread.
struct ChatThreadSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let preview: String
    let messageCount: Int
    let createdAt: Date
    let updatedAt: Date
    let lastMessageAt: Date?

    var lastActivityAt: Date {
        lastMessageAt ?? updatedAt
    }
}
