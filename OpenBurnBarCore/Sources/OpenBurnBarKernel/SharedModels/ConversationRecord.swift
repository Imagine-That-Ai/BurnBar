import Foundation

// MARK: - Conversation Source Type
//
// Windows-port Phase-2 (G2 parser lift). The parsing-relevant `ConversationRecord`
// + `ConversationSourceType` are lifted into the Engine so the lifted log parsers
// (which construct `ConversationRecord` values) compile off the macOS app. The
// chat/UI transcript types that shared the original app file (`ChatMessageRecord`,
// `TranscriptGroup`, `ChatThreadSummary`, …) stay in the macOS app — they are not
// part of the parser output contract and carry AppKit/UI coupling.

/// Discriminates between indexed provider transcripts and the in-app CLI assistant log.
public enum ConversationSourceType: String, Codable, Sendable {
    case providerLog  = "provider_log"
    case cliAssistant = "cli_assistant"
}

// MARK: - Conversation Record

/// Indexed session transcript and metadata for local search and context.
public struct ConversationRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let provider: AgentProvider
    public let sessionId: String
    public let projectName: String
    public let startTime: Date?
    public let endTime: Date?
    public let messageCount: Int
    public let userWordCount: Int
    public let assistantWordCount: Int
    public let keyFiles: [String]
    public let keyCommands: [String]
    public let keyTools: [String]
    public let inferredTaskTitle: String
    public let lastAssistantMessage: String
    public let fullText: String
    public let indexedAt: Date
    /// Best-effort workspace directory used by resume and handoff surfaces.
    public let workingDirectory: String?
    /// Source log file modification time; used to skip unchanged files.
    public let fileModifiedAt: Date?
    /// Populated after on-demand CLI summarization in Session detail.
    public let summary: String?
    /// Short generated session name for list/search usability.
    public let summaryTitle: String?
    /// Last time summary/title were generated.
    public let summaryUpdatedAt: Date?
    /// Provider/model provenance for generated summary.
    public let summaryProvider: String?
    public let summaryModel: String?
    /// Whether this record comes from a provider log file or the in-app CLI assistant thread.
    public let sourceType: ConversationSourceType
    /// Non-nil for conversations downloaded from another device via cloud sync.
    public let sourceDeviceId: String?
    /// Human-readable name of the source device.
    public let sourceDeviceName: String?
    /// True for rows downloaded from Firestore; excluded from upload sync.
    public let isRemote: Bool
    /// Non-nil once the conversation is tombstoned (cross-device soft-delete,
    /// B-DATA-2). A tombstoned record is excluded from every user-facing read and
    /// is collected by `ConversationTombstoneGCService` after the retention window.
    public let deletedAt: Date?
    /// Monotonic mutation counter. Bumped on every soft-delete (and reserved for
    /// Phase-2 conflict convergence). Defaults to 1 for legacy/live rows.
    public let version: Int

    public init(
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
        workingDirectory: String? = nil,
        fileModifiedAt: Date?,
        summary: String? = nil,
        summaryTitle: String? = nil,
        summaryUpdatedAt: Date? = nil,
        summaryProvider: String? = nil,
        summaryModel: String? = nil,
        sourceType: ConversationSourceType = .providerLog,
        sourceDeviceId: String? = nil,
        sourceDeviceName: String? = nil,
        isRemote: Bool = false,
        deletedAt: Date? = nil,
        version: Int = 1
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
        self.workingDirectory = workingDirectory
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
        self.deletedAt = deletedAt
        self.version = version
    }

    /// Stable synthetic ID for the in-app CLI assistant conversation.
    public static let cliAssistantId = "cli_assistant:local"

    public static func stableId(provider: AgentProvider, sessionId: String) -> String {
        "\(provider.rawValue):\(sessionId)"
    }
}
