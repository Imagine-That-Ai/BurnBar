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

/// The human decision on a directive proposal (M4). Persisted as its raw
/// value (`"approved"`/`"dismissed"`) so a pending proposal survives app
/// relaunch and is re-presented — never auto-approved (VAL-ORCH-032).
enum ChatProposalDecision: String, Codable {
    case approved
    case dismissed
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
    /// True when the assistant stream was cancelled mid-generation (M4,
    /// VAL-ORCH-023): the partial message is marked cancelled honestly and
    /// the thread stays consistent.
    let cancelled: Bool
    /// Canonical directive-proposal JSON carried by this assistant message
    /// (M4). When non-nil, the message renders a proposal card with
    /// approve/dismiss actions (VAL-ORCH-011).
    let proposalJSON: String?
    /// The human decision on the proposal, or nil while pending
    /// (VAL-ORCH-012/013). Persisted so a pending proposal survives app
    /// relaunch and is re-presented — never auto-approved (VAL-ORCH-032).
    let proposalDecision: ChatProposalDecision?
    /// The daemon-recorded decision timestamp of the proposal (M4). Set when
    /// the decision is recorded; preserved across delivery retries so a
    /// retried terminal record never regresses `decidedAt` (VAL-ORCH-030).
    let proposalDecidedAt: Date?
    /// The delivery state of an approved proposal (M4). nil while pending or
    /// undecided; `delivering` while the channel call is in flight; then a
    /// typed terminal state (`delivered`, `failed(reason)`, or
    /// `unsupported(reason)`) — never a fabricated delivery
    /// (VAL-ORCH-014/030/037). Persisted so the card's outcome survives app
    /// relaunch.
    let deliveryState: ChatDeliveryState?
    /// A visible card-level typed error (M4 scrutiny round 1): set when an
    /// Approve/Dismiss decision could not be recorded (daemon down), when
    /// the decision/delivery state could not be persisted locally, or when a
    /// stream-finalize save of a proposal failed. The pending proposal is
    /// preserved so the card stays actionable — never a silent no-op.
    let proposalError: String?

    init(
        id: String = UUID().uuidString,
        role: ChatMessageRole,
        content: String,
        timestamp: Date = Date(),
        cliUsed: String? = nil,
        transcriptPieces: [ChatTranscriptPiece] = [],
        cancelled: Bool = false,
        proposalJSON: String? = nil,
        proposalDecision: ChatProposalDecision? = nil,
        proposalDecidedAt: Date? = nil,
        deliveryState: ChatDeliveryState? = nil,
        proposalError: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.cliUsed = cliUsed
        self.transcriptPieces = transcriptPieces
        self.cancelled = cancelled
        self.proposalJSON = proposalJSON
        self.proposalDecision = proposalDecision
        self.proposalDecidedAt = proposalDecidedAt
        self.deliveryState = deliveryState
        self.proposalError = proposalError
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

    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, cliUsed, transcriptPieces,
             cancelled, proposalJSON, proposalDecision, proposalDecidedAt,
             deliveryState, proposalError
    }

    /// Tolerant decoding: the M4 fields (`cancelled`, `proposalJSON`,
    /// `proposalDecision`, `proposalDecidedAt`, `deliveryState`, and the
    /// scrutiny-round-1 `proposalError`) default when absent so pre-M4
    /// persisted payloads still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(ChatMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        cliUsed = try container.decodeIfPresent(String.self, forKey: .cliUsed)
        transcriptPieces = try container.decodeIfPresent([ChatTranscriptPiece].self, forKey: .transcriptPieces) ?? []
        cancelled = try container.decodeIfPresent(Bool.self, forKey: .cancelled) ?? false
        proposalJSON = try container.decodeIfPresent(String.self, forKey: .proposalJSON)
        proposalDecision = try container.decodeIfPresent(ChatProposalDecision.self, forKey: .proposalDecision)
        proposalDecidedAt = try container.decodeIfPresent(Date.self, forKey: .proposalDecidedAt)
        deliveryState = try container.decodeIfPresent(ChatDeliveryState.self, forKey: .deliveryState)
        proposalError = try container.decodeIfPresent(String.self, forKey: .proposalError)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(cliUsed, forKey: .cliUsed)
        try container.encode(transcriptPieces, forKey: .transcriptPieces)
        try container.encode(cancelled, forKey: .cancelled)
        try container.encodeIfPresent(proposalJSON, forKey: .proposalJSON)
        try container.encodeIfPresent(proposalDecision, forKey: .proposalDecision)
        try container.encodeIfPresent(proposalDecidedAt, forKey: .proposalDecidedAt)
        try container.encodeIfPresent(deliveryState, forKey: .deliveryState)
        try container.encodeIfPresent(proposalError, forKey: .proposalError)
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
