import Foundation
import OpenBurnBarCore

extension DataStore {
    func fetchUnsyncedConversations(limit: Int = 400) throws -> [ConversationRecord] {
        try conversationStore.fetchUnsyncedConversations(limit: limit)
    }

    func markConversationsSynced(ids: [String]) throws {
        try conversationStore.markConversationsSynced(ids: ids)
    }

    func upsertConversation(_ record: ConversationRecord) throws {
        try conversationStore.upsertConversation(record)
    }

    func fileModifiedAtForConversation(id: String) throws -> Date? {
        try conversationStore.fileModifiedAtForConversation(id: id)
    }

    func fetchConversation(id: String) throws -> ConversationRecord? {
        try conversationStore.fetchConversation(id: id)
    }

    func fetchConversations(limit: Int = 500) throws -> [ConversationRecord] {
        try conversationStore.fetchConversations(limit: limit)
    }

    /// Fetches multiple conversations by their IDs.
    /// Used by gap repair to check if indexed content is stale.
    func fetchConversations(ids: [String]) throws -> [ConversationRecord] {
        try conversationStore.fetchConversations(ids: ids)
    }

    func updateConversationSummary(
        id: String,
        title: String?,
        summary: String?,
        provider: String?,
        model: String?,
        updatedAt: Date = Date(),
        runCostUSD: Double = 0
    ) throws {
        try conversationStore.updateConversationSummary(
            id: id,
            title: title,
            summary: summary,
            provider: provider,
            model: model,
            updatedAt: updatedAt,
            runCostUSD: runCostUSD
        )
    }

    func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) throws {
        try conversationStore.markConversationSummaryAttempt(id: id, attemptedAt: attemptedAt)
    }

    func fetchConversationsNeedingSummary(
        limit: Int = 80,
        staleAfter: TimeInterval = 30 * 60,
        now: Date = Date(),
        retryCooldown: TimeInterval? = nil,
        indexedAfter: Date? = nil
    ) throws -> [ConversationRecord] {
        try conversationStore.fetchConversationsNeedingSummary(
            limit: limit,
            now: now,
            retryCooldown: retryCooldown ?? staleAfter,
            indexedAfter: indexedAfter
        )
    }

    func summarySpendToday(now: Date = Date()) throws -> Double {
        try conversationStore.summarySpendToday(now: now)
    }

    func deleteAllIndexedConversations() throws {
        try conversationStore.deleteAllIndexedConversations()
    }

    func approximateConversationStorageBytes() throws -> Int64 {
        try conversationStore.approximateConversationStorageBytes()
    }

    func saveChatMessage(_ message: ChatMessageRecord) throws {
        try conversationStore.saveChatMessage(message, threadID: Self.legacyChatThreadID)
    }

    func saveChatMessage(_ message: ChatMessageRecord, threadID: String) throws {
        try conversationStore.saveChatMessage(message, threadID: threadID)
    }

    func createChatThread(id: String = UUID().uuidString, at date: Date = Date()) throws -> String {
        try conversationStore.createChatThread(id: id, at: date)
    }

    func chatThreadExists(id: String) throws -> Bool {
        try conversationStore.chatThreadExists(id: id)
    }

    func fetchMostRecentChatThreadID() throws -> String? {
        try conversationStore.fetchMostRecentChatThreadID()
    }

    func fetchChatThreadSummaries(searchQuery: String = "", limit: Int = 80) throws -> [ChatThreadSummary] {
        try conversationStore.fetchChatThreadSummaries(searchQuery: searchQuery, limit: limit)
    }

    func fetchChatMessages() throws -> [ChatMessageRecord] {
        try conversationStore.fetchChatMessages()
    }

    func fetchChatMessages(threadID: String) throws -> [ChatMessageRecord] {
        try conversationStore.fetchChatMessages(threadID: threadID)
    }

    func deleteAllChatMessages() throws {
        try conversationStore.deleteAllChatMessages()
    }

    func searchConversationsFTS(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> [SearchResult] {
        try conversationStore.searchConversationsFTS(
            query: query,
            provider: provider,
            projectName: projectName,
            dateRange: dateRange
        )
    }

    func fetchAllSessionLogs(limit: Int = 1000) throws -> [ConversationRecord] {
        try conversationStore.fetchAllSessionLogs(limit: limit)
    }

    func fetchSessionLogSummaries(limit: Int = 1000) throws -> [ConversationRecord] {
        try conversationStore.fetchSessionLogSummaries(limit: limit)
    }

    func fetchUnsyncedSessionLogs(limit: Int = 100) throws -> [ConversationRecord] {
        try conversationStore.fetchUnsyncedSessionLogs(limit: limit)
    }

    func markSessionLogsSynced(ids: [String]) throws {
        try conversationStore.markSessionLogsSynced(ids: ids)
    }

    func countConversations() throws -> Int {
        try conversationStore.countConversations()
    }

    func insertRemoteConversation(_ record: ConversationRecord) throws {
        try conversationStore.insertRemoteConversation(record)
    }

    func updateConversationFullText(id: String, fullText: String) throws {
        try conversationStore.updateConversationFullText(id: id, fullText: fullText)
    }

    /// Synthesizes a single `cliAssistant` ConversationRecord from persisted chat messages
    /// and upserts it so the Session Logs center and cloud sync treat it like any other session.
    func upsertCLIConversation(from messages: [ChatMessageRecord]) throws {
        guard messages.isEmpty == false else { return }

        let start = messages.first?.timestamp
        let end = messages.last?.timestamp

        let assistantWords = messages
            .filter { $0.role == .assistant }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }
        let userWords = messages
            .filter { $0.role == .user }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }

        let markdown = SessionLogMarkdownFormatter.cliMarkdown(from: messages)
        let lastAssistant = messages.last(where: { $0.role == .assistant })?.content ?? ""

        let record = ConversationRecord(
            id: ConversationRecord.cliAssistantId,
            provider: .claudeCode,
            sessionId: "cli-assistant-local",
            projectName: "OpenBurnBar",
            startTime: start,
            endTime: end,
            messageCount: messages.count,
            userWordCount: userWords,
            assistantWordCount: assistantWords,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "OpenBurnBar Assistant",
            lastAssistantMessage: String(lastAssistant.prefix(500)),
            fullText: markdown,
            indexedAt: Date(),
            fileModifiedAt: nil,
            summary: nil,
            sourceType: .cliAssistant
        )
        try upsertConversation(record)
        try enqueueConversationProjectionJob(conversationID: record.id, jobType: .reproject)
    }
}
