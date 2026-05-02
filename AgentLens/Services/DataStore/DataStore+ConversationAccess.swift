import Foundation
import OpenBurnBarCore

extension DataStore {
    nonisolated func fetchUnsyncedConversations(limit: Int = 400) throws -> [ConversationRecord] {
        try conversationStore.fetchUnsyncedConversations(limit: limit)
    }

    nonisolated func markConversationsSynced(ids: [String]) throws {
        try conversationStore.markConversationsSynced(ids: ids)
    }

    nonisolated func upsertConversation(_ record: ConversationRecord) throws {
        try conversationStore.upsertConversation(record)
    }

    nonisolated func fileModifiedAtForConversation(id: String) throws -> Date? {
        try conversationStore.fileModifiedAtForConversation(id: id)
    }

    nonisolated func fetchConversation(id: String) throws -> ConversationRecord? {
        try conversationStore.fetchConversation(id: id)
    }

    nonisolated func fetchConversations(limit: Int = 500) throws -> [ConversationRecord] {
        try conversationStore.fetchConversations(limit: limit)
    }

    /// Paginated conversation fetch using offset-based cursor.
    nonisolated func fetchConversations(limit: Int, offset: Int) throws -> [ConversationRecord] {
        try conversationStore.fetchConversations(limit: limit, offset: offset)
    }

    /// Fetches multiple conversations by their IDs.
    /// Used by gap repair to check if indexed content is stale.
    nonisolated func fetchConversations(ids: [String]) throws -> [ConversationRecord] {
        try conversationStore.fetchConversations(ids: ids)
    }

    nonisolated func updateConversationSummary(
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

    nonisolated func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) throws {
        try conversationStore.markConversationSummaryAttempt(id: id, attemptedAt: attemptedAt)
    }

    nonisolated func fetchConversationsNeedingSummary(
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

    nonisolated func countConversationsNeedingSummary(
        staleAfter: TimeInterval = 30 * 60,
        now: Date = Date(),
        retryCooldown: TimeInterval? = nil,
        indexedAfter: Date? = nil
    ) throws -> Int {
        try conversationStore.countConversationsNeedingSummary(
            now: now,
            retryCooldown: retryCooldown ?? staleAfter,
            indexedAfter: indexedAfter
        )
    }

    nonisolated func summarySpendToday(now: Date = Date()) throws -> Double {
        try conversationStore.summarySpendToday(now: now)
    }

    nonisolated func deleteAllIndexedConversations() throws {
        try conversationStore.deleteAllIndexedConversations()
    }

    /// Deletes a single conversation by ID. Used for testing delete-event miss recovery.
    nonisolated func deleteConversation(id: String) throws {
        try conversationStore.deleteConversation(id: id)
    }

    nonisolated func approximateConversationStorageBytes() throws -> Int64 {
        try conversationStore.approximateConversationStorageBytes()
    }

    nonisolated func saveChatMessage(_ message: ChatMessageRecord) throws {
        try conversationStore.saveChatMessage(message, threadID: Self.legacyChatThreadID)
    }

    nonisolated func saveChatMessage(_ message: ChatMessageRecord, threadID: String) throws {
        try conversationStore.saveChatMessage(message, threadID: threadID)
    }

    nonisolated func createChatThread(id: String = UUID().uuidString, at date: Date = Date()) throws -> String {
        try conversationStore.createChatThread(id: id, at: date)
    }

    nonisolated func chatThreadExists(id: String) throws -> Bool {
        try conversationStore.chatThreadExists(id: id)
    }

    nonisolated func fetchMostRecentChatThreadID() throws -> String? {
        try conversationStore.fetchMostRecentChatThreadID()
    }

    nonisolated func fetchChatThreadSummaries(searchQuery: String = "", limit: Int = 80) throws -> [ChatThreadSummary] {
        try conversationStore.fetchChatThreadSummaries(searchQuery: searchQuery, limit: limit)
    }

    nonisolated func fetchChatMessages() throws -> [ChatMessageRecord] {
        try conversationStore.fetchChatMessages()
    }

    nonisolated func fetchChatMessages(threadID: String) throws -> [ChatMessageRecord] {
        try conversationStore.fetchChatMessages(threadID: threadID)
    }

    nonisolated func deleteAllChatMessages() throws {
        try conversationStore.deleteAllChatMessages()
    }

    nonisolated func searchConversationsFTS(
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

    nonisolated func fetchAllSessionLogs(limit: Int = 1000) throws -> [ConversationRecord] {
        try conversationStore.fetchAllSessionLogs(limit: limit)
    }

    nonisolated func fetchSessionLogSummaries(limit: Int = 1000) throws -> [ConversationRecord] {
        try conversationStore.fetchSessionLogSummaries(limit: limit)
    }

    nonisolated func fetchUnsyncedSessionLogs(limit: Int = 100) throws -> [ConversationRecord] {
        try conversationStore.fetchUnsyncedSessionLogs(limit: limit)
    }

    nonisolated func markSessionLogsSynced(ids: [String]) throws {
        try conversationStore.markSessionLogsSynced(ids: ids)
    }

    nonisolated func countConversations() throws -> Int {
        try conversationStore.countConversations()
    }

    nonisolated func insertRemoteConversation(_ record: ConversationRecord) throws {
        try conversationStore.insertRemoteConversation(record)
    }

    nonisolated func updateConversationFullText(id: String, fullText: String) throws {
        try conversationStore.updateConversationFullText(id: id, fullText: fullText)
    }

    /// Synthesizes a single `cliAssistant` ConversationRecord from persisted chat messages
    /// and upserts it so the Session Logs center and cloud sync treat it like any other session.
    nonisolated func upsertCLIConversation(from messages: [ChatMessageRecord]) throws {
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

    /// Fetches conversations suitable for transcript scan / context pack assembly.
    /// Filters by optional provider, project name, date range, and source types.
    nonisolated func fetchConversationsForTranscriptScan(
        provider: AgentProvider?,
        projectName: String?,
        dateRange: ClosedRange<Date>?,
        conversationSources: Set<ConversationSourceType>?,
        limit: Int = 500
    ) throws -> [ConversationRecord] {
        try conversationStore.fetchConversationsForTranscriptScan(
            provider: provider,
            projectName: projectName,
            dateRange: dateRange,
            conversationSources: conversationSources,
            limit: limit
        )
    }
}
