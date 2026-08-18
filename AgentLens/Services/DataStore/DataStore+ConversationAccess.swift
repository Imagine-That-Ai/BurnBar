import Foundation
import OpenBurnBarCore

extension DataStore {
    func fetchUnsyncedConversations(limit: Int = 400) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchUnsyncedConversations(limit: limit)
    }

    func markConversationsSynced(ids: [String]) async throws {
        try await actor.conversationStore.markConversationsSynced(ids: ids)
    }

    func upsertConversation(_ record: OpenBurnBarCore.ConversationRecord) async throws {
        try await actor.conversationStore.upsertConversation(record)
    }

    /// Upserts changed conversations and enqueues their projection jobs in one
    /// SQLite write. Returns how many live rows actually received a job.
    @discardableResult
    func persistIndexedConversations(
        _ items: [IndexedConversationWrite],
        now: Date = Date()
    ) async throws -> Int {
        try await actor.persistIndexedConversations(items, now: now)
    }

    func fileModifiedAtForConversation(id: String) async throws -> Date? {
        try await actor.conversationStore.fileModifiedAtForConversation(id: id)
    }

    func fetchConversation(id: String) async throws -> OpenBurnBarCore.ConversationRecord? {
        try await actor.conversationStore.fetchConversation(id: id)
    }

    nonisolated func fetchConversationSynchronously(id: String) throws -> OpenBurnBarCore.ConversationRecord? {
        try actor.conversationStore.fetchConversationSynchronously(id: id)
    }

    func fetchConversations(limit: Int = 500) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchConversations(limit: limit)
    }

    func fetchConversationActivitySummaries(limit: Int) async throws -> [ConversationActivitySummary] {
        try await actor.conversationStore.fetchConversationActivitySummaries(limit: limit)
    }

    nonisolated func fetchConversationsSynchronously(limit: Int = 500) throws -> [OpenBurnBarCore.ConversationRecord] {
        try actor.conversationStore.fetchConversationsSynchronously(limit: limit)
    }

    /// Paginated conversation fetch using offset-based cursor.
    func fetchConversations(limit: Int, offset: Int) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchConversations(limit: limit, offset: offset)
    }

    /// Fetches multiple conversations by their IDs.
    /// Used by gap repair to check if indexed content is stale.
    func fetchConversations(ids: [String]) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchConversations(ids: ids)
    }

    /// Lightweight first stage for projection gap repair. Full transcript rows
    /// are fetched only for revisions that may be newer than their document.
    func fetchConversationProjectionRevisions(
        ids: [String]
    ) async throws -> [ConversationProjectionRevision] {
        try await actor.conversationStore.fetchConversationProjectionRevisions(ids: ids)
    }

    func cacheConversationProjectionHashesIfMissing(
        _ contentHashesByID: [String: String],
        updatedAt: Date
    ) async throws {
        try await actor.conversationStore.cacheConversationProjectionHashesIfMissing(
            contentHashesByID,
            updatedAt: updatedAt
        )
    }

    /// Returns the set of IDs (from `ids`) that already exist in the
    /// conversations table. Used by incremental indexing to preserve
    /// newly discovered sessions whose file mtime may predate the
    /// checkpoint watermark.
    func fetchExistingConversationIDs(ids: [String]) async throws -> Set<String> {
        try await actor.conversationStore.fetchExistingConversationIDs(ids: ids)
    }

    func updateConversationSummary(
        id: String,
        title: String?,
        summary: String?,
        provider: String?,
        model: String?,
        updatedAt: Date = Date(),
        runCostUSD: Double = 0
    ) async throws {
        try await actor.conversationStore.updateConversationSummary(
            id: id,
            title: title,
            summary: summary,
            provider: provider,
            model: model,
            updatedAt: updatedAt,
            runCostUSD: runCostUSD
        )
    }

    func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) async throws {
        try await actor.conversationStore.markConversationSummaryAttempt(id: id, attemptedAt: attemptedAt)
    }

    func fetchConversationsNeedingSummary(
        limit: Int = 80,
        staleAfter: TimeInterval = 30 * 60,
        now: Date = Date(),
        retryCooldown: TimeInterval? = nil,
        indexedAfter: Date? = nil
    ) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchConversationsNeedingSummary(
            limit: limit,
            now: now,
            retryCooldown: retryCooldown ?? staleAfter,
            indexedAfter: indexedAfter
        )
    }

    func countConversationsNeedingSummary(
        staleAfter: TimeInterval = 30 * 60,
        now: Date = Date(),
        retryCooldown: TimeInterval? = nil,
        indexedAfter: Date? = nil
    ) async throws -> Int {
        try await actor.conversationStore.countConversationsNeedingSummary(
            now: now,
            retryCooldown: retryCooldown ?? staleAfter,
            indexedAfter: indexedAfter
        )
    }

    func summarySpendToday(now: Date = Date()) async throws -> Double {
        try await actor.conversationStore.summarySpendToday(now: now)
    }

    func deleteAllIndexedConversations() async throws {
        try await actor.conversationStore.deleteAllIndexedConversations()
    }

    /// Deletes a single conversation by ID. Used for testing delete-event miss recovery.
    func deleteConversation(id: String) async throws {
        try await actor.conversationStore.deleteConversation(id: id)
    }

    /// Tombstones a conversation so the delete propagates across devices (B-DATA-2).
    func softDeleteConversation(id: String, at date: Date = Date()) async throws {
        try await actor.conversationStore.softDeleteConversation(id: id, at: date)
    }

    /// Local tombstones older than `before`, eligible for retention-window GC.
    func fetchExpiredConversationTombstones(before: Date, limit: Int = 200) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchExpiredConversationTombstones(before: before, limit: limit)
    }

    func approximateConversationStorageBytes() async throws -> Int64 {
        try await actor.conversationStore.approximateConversationStorageBytes()
    }

    func backupUsageSnapshot(
        limits: CloudBackupPlanLimits = .standard
    ) async throws -> CloudBackupUsageSnapshot {
        try await actor.conversationStore.backupUsageSnapshot(limits: limits)
    }

    func saveChatMessage(_ message: ChatMessageRecord) async throws {
        try await actor.conversationStore.saveChatMessage(message, threadID: Self.legacyChatThreadID)
    }

    func saveChatMessage(
        _ message: ChatMessageRecord,
        threadID: String,
        isTerminalAssistantCommit: Bool = false,
        memoryService: (any MemoryServing)? = nil,
        extractionContext: MemoryExtractionContext? = nil
    ) async throws {
        try await actor.conversationStore.saveChatMessage(
            message,
            threadID: threadID,
            isTerminalAssistantCommit: isTerminalAssistantCommit,
            memoryService: memoryService,
            extractionContext: extractionContext
        )
    }

    func createChatThread(id: String = UUID().uuidString, at date: Date = Date()) async throws -> String {
        try await actor.conversationStore.createChatThread(id: id, at: date)
    }

    func chatThreadExists(id: String) async throws -> Bool {
        try await actor.conversationStore.chatThreadExists(id: id)
    }

    func fetchMostRecentChatThreadID() async throws -> String? {
        try await actor.conversationStore.fetchMostRecentChatThreadID()
    }

    func fetchChatThreadSummaries(searchQuery: String = "", limit: Int = 80) async throws -> [ChatThreadSummary] {
        try await actor.conversationStore.fetchChatThreadSummaries(searchQuery: searchQuery, limit: limit)
    }

    func fetchChatMessages() async throws -> [ChatMessageRecord] {
        try await actor.conversationStore.fetchChatMessages()
    }

    func fetchChatMessages(threadID: String) async throws -> [ChatMessageRecord] {
        try await actor.conversationStore.fetchChatMessages(threadID: threadID)
    }

    /// E1 (citation jump): resolve the owning thread for a `chat_messages.id`.
    /// Memory recall is app-wide, so a cited message often lives in a thread other
    /// than the one currently open; the chat view opens this thread, then scrolls.
    func threadID(forChatMessageID messageID: String) async throws -> String? {
        try await actor.conversationStore.threadID(forChatMessageID: messageID)
    }

    func deleteAllChatMessages() async throws {
        try await actor.conversationStore.deleteAllChatMessages()
    }

    func searchConversationsFTS(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) async throws -> [SearchResult] {
        try await actor.conversationStore.searchConversationsFTS(
            query: query,
            provider: provider,
            projectName: projectName,
            dateRange: dateRange
        )
    }

    func fetchAllSessionLogs(limit: Int = 1000) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchAllSessionLogs(limit: limit)
    }

    func fetchSessionLogSummaries(limit: Int = 1000) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchSessionLogSummaries(limit: limit)
    }

    func fetchUnsyncedSessionLogs(limit: Int = 100) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchUnsyncedSessionLogs(limit: limit)
    }

    func countUnsyncedSessionLogs() async throws -> Int {
        try await actor.conversationStore.countUnsyncedSessionLogs()
    }

    func markSessionLogsSynced(ids: [String]) async throws {
        try await actor.conversationStore.markSessionLogsSynced(ids: ids)
    }

    @discardableResult
    func markAllSessionLogsUnsynced() async throws -> Int {
        try await actor.conversationStore.markAllSessionLogsUnsynced()
    }

    func countConversations() async throws -> Int {
        try await actor.conversationStore.countConversations()
    }

    func insertRemoteConversation(_ record: OpenBurnBarCore.ConversationRecord) async throws {
        try await actor.conversationStore.insertRemoteConversation(record)
    }

    func updateConversationFullText(id: String, fullText: String) async throws {
        try await actor.conversationStore.updateConversationFullText(id: id, fullText: fullText)
    }

    /// Synthesizes a single `cliAssistant` OpenBurnBarCore.ConversationRecord from persisted chat messages
    /// and upserts it so the Session Logs center and cloud sync treat it like any other session.
    func upsertCLIConversation(from messages: [ChatMessageRecord]) async throws {
        guard messages.isEmpty == false else { return }

        let start = messages.first?.timestamp
        let end = messages.last?.timestamp

        let assistantWords = messages
            .filter { $0.role == .assistant }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }
        let userWords = messages
            .filter { $0.role == .user }
            .reduce(0) { $0 + $1.content.split(separator: " ").count }

        let markdown = OpenBurnBarCore.SessionLogMarkdownFormatter.cliMarkdown(from: messages)
        let lastAssistant = messages.last(where: { $0.role == .assistant })?.content ?? ""

        let record = OpenBurnBarCore.ConversationRecord(
            id: OpenBurnBarCore.ConversationRecord.cliAssistantId,
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
        try await upsertConversation(record)
        try await enqueueConversationProjectionJob(conversationID: record.id, jobType: .reproject)
    }

    /// Fetches conversations suitable for transcript scan / context pack assembly.
    /// Filters by optional provider, project name, date range, and source types.
    func fetchConversationsForTranscriptScan(
        provider: AgentProvider?,
        projectName: String?,
        dateRange: ClosedRange<Date>?,
        conversationSources: Set<OpenBurnBarCore.ConversationSourceType>?,
        limit: Int = 500
    ) async throws -> [OpenBurnBarCore.ConversationRecord] {
        try await actor.conversationStore.fetchConversationsForTranscriptScan(
            provider: provider,
            projectName: projectName,
            dateRange: dateRange,
            conversationSources: conversationSources,
            limit: limit
        )
    }
}
