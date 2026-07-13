import Foundation

public enum BurnBarChatMessageRole: String, Codable, CaseIterable, Hashable, Sendable {
    case user
    case assistant
    case system
}

public struct BurnBarChatMessage: Codable, Equatable, Sendable {
    public let id: String
    public let threadID: String
    public let role: BurnBarChatMessageRole
    public let content: String
    public let timestamp: String
    public let backendID: String?

    public init(
        id: String,
        threadID: String,
        role: BurnBarChatMessageRole,
        content: String,
        timestamp: String,
        backendID: String? = nil
    ) {
        self.id = id
        self.threadID = threadID
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.backendID = backendID
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

    public init(
        threadID: String,
        messageID: String,
        role: BurnBarChatMessageRole,
        content: String,
        timestamp: String,
        backendID: String? = nil
    ) {
        self.threadID = threadID
        self.messageID = messageID
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.backendID = backendID
    }
}

public struct BurnBarChatMessageAppendResponse: Codable, Equatable, Sendable {
    public let message: BurnBarChatMessage
    public let inserted: Bool

    public init(message: BurnBarChatMessage, inserted: Bool) {
        self.message = message
        self.inserted = inserted
    }
}
