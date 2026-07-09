import Foundation
import OpenBurnBarCore

// `OpenBurnBarCore.ConversationSourceType` + `OpenBurnBarCore.ConversationRecord` moved to OpenBurnBarCore
// (SharedModels/OpenBurnBarCore.ConversationRecord.swift) for the Windows-port G2 parser lift.
// The chat/transcript types below stay in the app; both resolve via `import OpenBurnBarCore`.

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
        case reasoning
        case refusal
        case toolUse
        case toolResult
    }

    let id: String
    let kind: Kind
    /// Prose for `.text` / `.reasoning` / `.refusal`; tool label (e.g. Read, Bash) for tool events.
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
    /// `var` so the streaming hot path can mutate content in-place via
    /// `messages[idx].content = ...` instead of allocating a fresh
    /// `ChatMessageRecord` per token chunk. Strings are copy-on-write, so
    /// the per-chunk cost drops from a full struct + array reallocation to
    /// just the new bytes of the content string.
    var content: String
    let timestamp: Date
    let cliUsed: String?
    /// Populated for assistant streams that emit tool events; empty means
    /// treat `content` as plain text. Mutable for the same hot-path reason
    /// as `content`.
    var transcriptPieces: [ChatTranscriptPiece]
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

    /// Joined answer text for persistence / search parity. Reasoning and
    /// refusal chunks remain labeled transcript pieces instead of becoming
    /// anonymous assistant answer text.
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
    /// become `.toolGroup`, individual prose/safety-labeled pieces become `.single`.
    static func group(_ transcript: [ChatTranscriptPiece]) -> [TranscriptGroup] {
        var groups: [TranscriptGroup] = []
        var pendingTools: [ChatTranscriptPiece] = []

        for piece in transcript {
            switch piece.kind {
            case .toolUse, .toolResult:
                pendingTools.append(piece)
            case .text, .reasoning, .refusal:
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
    let conversation: OpenBurnBarCore.ConversationRecord
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
