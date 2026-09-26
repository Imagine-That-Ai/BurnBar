import Foundation

public enum BurnBarChatMessageRole: String, Codable, CaseIterable, Hashable, Sendable {
    case user
    case assistant
    case system
}

/// Metadata for a chat attachment that has been accepted by the daemon.
///
/// The record is intentionally content-addressed and path-free. Attachment
/// bytes stay in the daemon's short-lived upload registry; persisted history
/// can safely display what was attached without exposing a local filesystem
/// path or attempting to replay a consumed upload handle after restart.
public struct BurnBarChatAttachmentMetadata: Codable, Equatable, Sendable {
    public let attachmentID: String
    public let fileName: String
    public let mimeType: String
    public let byteSize: Int
    public let sha256: String

    public init(
        attachmentID: String,
        fileName: String,
        mimeType: String,
        byteSize: Int,
        sha256: String
    ) {
        self.attachmentID = attachmentID
        self.fileName = fileName
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case attachmentID = "attachmentId"
        case fileName
        case mimeType
        case byteSize
        case sha256
    }
}

/// One ordered transcript segment for an assistant message (text interleaved
/// with tool calls), mirroring the app's `ChatTranscriptPiece` field for
/// field (`id`, `kind`, `value`, `detail`) so the daemon persists
/// byte-compatible `transcriptPiecesJSON`.
public struct BurnBarChatTranscriptPiece: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case text
        case reasoning
        case refusal
        case toolUse
        case toolResult
    }

    public let id: String
    public let kind: Kind
    public let value: String
    public let detail: String?

    public init(
        id: String,
        kind: Kind,
        value: String,
        detail: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.detail = detail
    }
}

public struct BurnBarChatMessage: Codable, Equatable, Sendable {
    public let id: String
    public let threadID: String
    public let role: BurnBarChatMessageRole
    public let content: String
    public let timestamp: String
    public let backendID: String?
    public let attachments: [BurnBarChatAttachmentMetadata]?
    public let transcriptPieces: [BurnBarChatTranscriptPiece]?

    public init(
        id: String,
        threadID: String,
        role: BurnBarChatMessageRole,
        content: String,
        timestamp: String,
        backendID: String? = nil,
        attachments: [BurnBarChatAttachmentMetadata]? = nil,
        transcriptPieces: [BurnBarChatTranscriptPiece]? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.backendID = backendID
        self.attachments = attachments
        self.transcriptPieces = transcriptPieces
    }
}

public struct BurnBarChatThreadSummary: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let preview: String
    public let messageCount: Int
    public let createdAt: String
    public let updatedAt: String
    public let lastMessageAt: String?
    public let backendID: String?

    public init(
        id: String,
        title: String,
        preview: String,
        messageCount: Int,
        createdAt: String,
        updatedAt: String,
        lastMessageAt: String? = nil,
        backendID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.preview = preview
        self.messageCount = messageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastMessageAt = lastMessageAt
        self.backendID = backendID
    }
}

public struct BurnBarChatThreadListRequest: Codable, Equatable, Sendable {
    public let query: String?
    public let limit: Int

    public init(query: String? = nil, limit: Int = 40) {
        self.query = query
        self.limit = limit
    }
}

public struct BurnBarChatThreadListResponse: Codable, Equatable, Sendable {
    public let threads: [BurnBarChatThreadSummary]

    public init(threads: [BurnBarChatThreadSummary]) {
        self.threads = threads
    }
}

public struct BurnBarChatThreadGetRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let maxMessages: Int
    /// Fetch the page immediately before this stable `(timestamp, messageID)` cursor.
    /// Both values must be supplied together; omitting them keeps the existing
    /// newest-page behavior for older clients.
    public let beforeTimestamp: String?
    public let beforeMessageID: String?

    public init(
        threadID: String,
        maxMessages: Int = 200,
        beforeTimestamp: String? = nil,
        beforeMessageID: String? = nil
    ) {
        self.threadID = threadID
        self.maxMessages = maxMessages
        self.beforeTimestamp = beforeTimestamp
        self.beforeMessageID = beforeMessageID
    }
}

public struct BurnBarChatThreadGetResponse: Codable, Equatable, Sendable {
    public let thread: BurnBarChatThreadSummary?
    public let messages: [BurnBarChatMessage]
    public let hasMoreBefore: Bool

    public init(
        thread: BurnBarChatThreadSummary?,
        messages: [BurnBarChatMessage],
        hasMoreBefore: Bool
    ) {
        self.thread = thread
        self.messages = messages
        self.hasMoreBefore = hasMoreBefore
    }
}

public struct BurnBarChatMessageAppendRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let messageID: String
    public let role: BurnBarChatMessageRole
    public let content: String
    public let timestamp: String
    public let backendID: String?
    public let attachments: [BurnBarChatAttachmentMetadata]?
    /// Ordered transcript segments (tool-call interleavings). Persisted to
    /// `transcriptPiecesJSON`; without this the daemon would silently drop
    /// tool-call transcripts on the app cutover (Wave 2.1).
    public let transcriptPieces: [BurnBarChatTranscriptPiece]?
    /// Streaming re-save: the same message ID re-committed with evolved
    /// content (placeholder → final). When false (gateway default) a
    /// differing re-append is a `conflict`; when true the daemon replaces
    /// the row, matching the app's historical `INSERT OR REPLACE`.
    public let replace: Bool
    /// Opaque app-encoded attachment JSON (`[HermesAttachment]`), stored
    /// verbatim in `attachmentsJSON` when present. The typed `attachments`
    /// metadata cannot represent app display fields (workspace path,
    /// thumbnail, text preview); converging the two column formats is
    /// follow-up work — until then the daemon must not re-encode this blob.
    /// Mutually exclusive with `attachments`: setting both is invalid.
    public let appAttachmentsJSON: String?

    public init(
        threadID: String,
        messageID: String,
        role: BurnBarChatMessageRole,
        content: String,
        timestamp: String,
        backendID: String? = nil,
        attachments: [BurnBarChatAttachmentMetadata]? = nil,
        transcriptPieces: [BurnBarChatTranscriptPiece]? = nil,
        replace: Bool = false,
        appAttachmentsJSON: String? = nil
    ) {
        self.threadID = threadID
        self.messageID = messageID
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.backendID = backendID
        self.attachments = attachments
        self.transcriptPieces = transcriptPieces
        self.replace = replace
        self.appAttachmentsJSON = appAttachmentsJSON
    }

    private enum CodingKeys: String, CodingKey {
        case threadID, messageID, role, content, timestamp, backendID
        case attachments, transcriptPieces, replace, appAttachmentsJSON
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        threadID = try container.decode(String.self, forKey: .threadID)
        messageID = try container.decode(String.self, forKey: .messageID)
        role = try container.decode(BurnBarChatMessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        backendID = try container.decodeIfPresent(String.self, forKey: .backendID)
        attachments = try container.decodeIfPresent([BurnBarChatAttachmentMetadata].self, forKey: .attachments)
        transcriptPieces = try container.decodeIfPresent([BurnBarChatTranscriptPiece].self, forKey: .transcriptPieces)
        replace = try container.decodeIfPresent(Bool.self, forKey: .replace) ?? false
        appAttachmentsJSON = try container.decodeIfPresent(String.self, forKey: .appAttachmentsJSON)
    }
}

public struct BurnBarChatMessageAppendResponse: Codable, Equatable, Sendable {
    public let message: BurnBarChatMessage
    public let inserted: Bool
    /// True when an existing row was replaced (`replace: true` re-save).
    /// Leniently decoded so older daemons' responses (without the key) still
    /// decode.
    public let replaced: Bool

    public init(message: BurnBarChatMessage, inserted: Bool, replaced: Bool = false) {
        self.message = message
        self.inserted = inserted
        self.replaced = replaced
    }

    private enum CodingKeys: String, CodingKey {
        case message, inserted, replaced
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = try container.decode(BurnBarChatMessage.self, forKey: .message)
        inserted = try container.decode(Bool.self, forKey: .inserted)
        replaced = try container.decodeIfPresent(Bool.self, forKey: .replaced) ?? false
    }
}

public struct BurnBarChatThreadCreateRequest: Codable, Equatable, Sendable {
    public let threadID: String
    public let createdAt: String

    public init(threadID: String, createdAt: String) {
        self.threadID = threadID
        self.createdAt = createdAt
    }
}

public struct BurnBarChatThreadCreateResponse: Codable, Equatable, Sendable {
    public let threadID: String
    public let created: Bool

    public init(threadID: String, created: Bool) {
        self.threadID = threadID
        self.created = created
    }
}
