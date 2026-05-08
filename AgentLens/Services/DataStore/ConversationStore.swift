import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore

/// Conversations, chat messages, FTS search, session logs, and CLI conversation helpers.
final class ConversationStore: Sendable {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    // MARK: - Conversation CRUD

    func upsertConversation(_ record: ConversationRecord) throws {
        let keyFilesJSON = try OpenBurnBarDatabase.encodeJSON(record.keyFiles)
        let keyCommandsJSON = try OpenBurnBarDatabase.encodeJSON(record.keyCommands)
        let keyToolsJSON = try OpenBurnBarDatabase.encodeJSON(record.keyTools)

        try dbQueue.write { db in
            let existing = try Self.fetchConversationRow(db, id: record.id)
            let priorSyncedAt: Date? = try Date.fetchOne(
                db,
                sql: "SELECT conversationSyncedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )
            let priorLogSyncedAt: Date? = try Date.fetchOne(
                db,
                sql: "SELECT logSyncedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )

            var summaryOut = record.summary
            if summaryOut == nil {
                summaryOut = try String.fetchOne(db, sql: "SELECT summary FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryTitleOut = record.summaryTitle
            if summaryTitleOut == nil {
                summaryTitleOut = try String.fetchOne(db, sql: "SELECT summaryTitle FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryUpdatedAtOut = record.summaryUpdatedAt
            if summaryUpdatedAtOut == nil {
                summaryUpdatedAtOut = try Date.fetchOne(db, sql: "SELECT summaryUpdatedAt FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryAttemptedAtOut: Date? = try Date.fetchOne(
                db,
                sql: "SELECT summaryAttemptedAt FROM conversations WHERE id = ?",
                arguments: [record.id]
            )
            if summaryUpdatedAtOut != nil, summaryAttemptedAtOut == nil {
                summaryAttemptedAtOut = summaryUpdatedAtOut
            }
            var summaryProviderOut = record.summaryProvider
            if summaryProviderOut == nil {
                summaryProviderOut = try String.fetchOne(db, sql: "SELECT summaryProvider FROM conversations WHERE id = ?", arguments: [record.id])
            }
            var summaryModelOut = record.summaryModel
            if summaryModelOut == nil {
                summaryModelOut = try String.fetchOne(db, sql: "SELECT summaryModel FROM conversations WHERE id = ?", arguments: [record.id])
            }

            let preserve = existing.map {
                Self.shouldPreserveConversationSyncedAt(
                    existing: $0,
                    incoming: record,
                    resolvedSummary: summaryOut,
                    resolvedSummaryTitle: summaryTitleOut,
                    resolvedSummaryUpdatedAt: summaryUpdatedAtOut,
                    resolvedSummaryProvider: summaryProviderOut,
                    resolvedSummaryModel: summaryModelOut
                )
            } ?? false

            let conversationSyncedAt: Date? = preserve ? priorSyncedAt : nil
            let logSyncedAt: Date? = preserve ? priorLogSyncedAt : nil

            try db.execute(
                sql: """
                INSERT OR REPLACE INTO conversations (
                    id, provider, sessionId, projectName, startTime, endTime,
                    messageCount, userWordCount, assistantWordCount,
                    keyFiles, keyCommands, keyTools,
                    inferredTaskTitle, lastAssistantMessage, fullText,
                    indexedAt, fileModifiedAt, summary, conversationSyncedAt,
                    sourceType, logSyncedAt, summaryTitle, summaryUpdatedAt, summaryAttemptedAt,
                    summaryProvider, summaryModel
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    record.id,
                    record.provider.rawValue,
                    record.sessionId,
                    record.projectName,
                    record.startTime,
                    record.endTime,
                    record.messageCount,
                    record.userWordCount,
                    record.assistantWordCount,
                    keyFilesJSON,
                    keyCommandsJSON,
                    keyToolsJSON,
                    record.inferredTaskTitle,
                    record.lastAssistantMessage,
                    record.fullText,
                    record.indexedAt,
                    record.fileModifiedAt,
                    summaryOut,
                    conversationSyncedAt,
                    record.sourceType.rawValue,
                    logSyncedAt,
                    summaryTitleOut,
                    summaryUpdatedAtOut,
                    summaryAttemptedAtOut,
                    summaryProviderOut,
                    summaryModelOut
                ]
            )
        }
    }

    func fileModifiedAtForConversation(id: String) throws -> Date? {
        try dbQueue.read { db in
            try Date.fetchOne(
                db,
                sql: "SELECT fileModifiedAt FROM conversations WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func fetchConversation(id: String) throws -> ConversationRecord? {
        try dbQueue.read { db in
            try Self.fetchConversationRow(db, id: id)
        }
    }

    func fetchConversations(limit: Int = 500) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    /// Paginated conversation fetch using offset-based cursor.
    /// Returns conversations ordered by endTime/startTime for stable pagination.
    func fetchConversations(limit: Int, offset: Int) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                ORDER BY COALESCE(endTime, startTime, indexedAt) DESC, id ASC
                LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func fetchConversations(ids: [String]) throws -> [ConversationRecord] {
        guard ids.isEmpty == false else { return [] }
        let uniqueIDs = Array(Set(ids)).sorted()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE id IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: uniqueIDs.count)))
                """,
                arguments: StatementArguments(uniqueIDs)
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func fetchAllSessionLogs(limit: Int = 1000) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM conversations ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func fetchSessionLogSummaries(limit: Int = 1000) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT
                    id, provider, sessionId, projectName, startTime, endTime,
                    messageCount, userWordCount, assistantWordCount,
                    keyFiles, keyCommands, keyTools,
                    inferredTaskTitle, lastAssistantMessage,
                    '' AS fullText,
                    indexedAt, fileModifiedAt, summary, summaryTitle, summaryUpdatedAt,
                    summaryProvider, summaryModel, sourceType, sourceDeviceId, sourceDeviceName, isRemote
                FROM conversations
                ORDER BY COALESCE(endTime, startTime, indexedAt) DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
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
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE conversations
                SET summary = ?, summaryTitle = ?, summaryUpdatedAt = ?, summaryAttemptedAt = ?, summaryProvider = ?, summaryModel = ?,
                    conversationSyncedAt = NULL, logSyncedAt = NULL
                WHERE id = ?
                """,
                arguments: [summary, title, updatedAt, updatedAt, provider, model, id]
            )

            try db.execute(
                sql: """
                INSERT INTO summary_runs (id, conversationId, provider, model, costUSD, createdAt)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    UUID().uuidString,
                    id,
                    provider ?? "unknown",
                    model ?? "unknown",
                    max(runCostUSD, 0),
                    updatedAt
                ]
            )
        }
    }

    func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE conversations
                SET summaryAttemptedAt = ?
                WHERE id = ?
                """,
                arguments: [attemptedAt, id]
            )
        }
    }

    func fetchConversationsNeedingSummary(
        limit: Int = 25,
        now: Date = Date(),
        retryCooldown: TimeInterval = 60 * 60,
        indexedAfter: Date? = nil
    ) throws -> [ConversationRecord] {
        let cutoff = now.addingTimeInterval(-max(retryCooldown, 0))
        return try dbQueue.read { db in
            let (whereSQL, whereArguments) = summaryCandidateWhereClause(
                cutoff: cutoff,
                indexedAfter: indexedAfter
            )
            var arguments = whereArguments
            let sql = """
                SELECT * FROM conversations
                \(whereSQL)
                ORDER BY COALESCE(endTime, startTime, indexedAt) DESC
                LIMIT ?
                """
            arguments.append(limit)

            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(arguments)
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func countConversationsNeedingSummary(
        now: Date = Date(),
        retryCooldown: TimeInterval = 60 * 60,
        indexedAfter: Date? = nil
    ) throws -> Int {
        let cutoff = now.addingTimeInterval(-max(retryCooldown, 0))
        return try dbQueue.read { db in
            let (whereSQL, arguments) = summaryCandidateWhereClause(
                cutoff: cutoff,
                indexedAfter: indexedAfter
            )
            return try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*)
                FROM conversations
                \(whereSQL)
                """,
                arguments: StatementArguments(arguments)
            ) ?? 0
        }
    }

    func summarySpendToday(now: Date = Date()) throws -> Double {
        try dbQueue.read { db in
            let calendar = Calendar.current
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
            return try Double.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(costUSD), 0)
                FROM summary_runs
                WHERE createdAt >= ? AND createdAt < ?
                """,
                arguments: [start, end]
            ) ?? 0
        }
    }

    private func summaryCandidateWhereClause(
        cutoff: Date,
        indexedAfter: Date?
    ) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var sql = """
        WHERE messageCount > 0
        AND (
            summary IS NULL
            OR summaryTitle IS NULL
            OR summaryUpdatedAt IS NULL
            OR summaryUpdatedAt < indexedAt
        )
        AND (
            summaryAttemptedAt IS NULL
            OR summaryAttemptedAt <= ?
            OR indexedAt > summaryAttemptedAt
        )
        """
        var arguments: [any DatabaseValueConvertible] = [cutoff]

        if let indexedAfter {
            sql += """

            AND indexedAt >= ?
            """
            arguments.append(indexedAfter)
        }

        return (sql, arguments)
    }

    func deleteAllIndexedConversations() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM conversations")
            try db.execute(sql: "DELETE FROM summary_runs")
        }
    }

    /// Deletes a single conversation by ID. Used for testing delete-event miss recovery.
    func deleteConversation(id: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
        }
    }

    func approximateConversationStorageBytes() throws -> Int64 {
        try dbQueue.read { db in
            let text: Int64 = try Int64.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(LENGTH(fullText)), 0) + COALESCE(SUM(LENGTH(inferredTaskTitle)), 0)
                + COALESCE(SUM(LENGTH(lastAssistantMessage)), 0) FROM conversations
                """
            ) ?? 0
            return text
        }
    }

    func updateConversationFullText(id: String, fullText: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET fullText = ? WHERE id = ?",
                arguments: [fullText, id]
            )
        }
    }

    // MARK: - Sync

    func fetchUnsyncedConversations(limit: Int = 400) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE conversationSyncedAt IS NULL AND isRemote = 0
                ORDER BY COALESCE(endTime, startTime) ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func markConversationsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(ids)
            try db.execute(
                sql: "UPDATE conversations SET conversationSyncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    func insertRemoteConversation(_ record: ConversationRecord) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO conversations (
                        id, provider, sessionId, projectName, startTime, endTime,
                        messageCount, userWordCount, assistantWordCount,
                        keyFiles, keyCommands, keyTools,
                        inferredTaskTitle, lastAssistantMessage, fullText,
                        indexedAt, fileModifiedAt, sourceType,
                        sourceDeviceId, sourceDeviceName, isRemote, conversationSyncedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                    """,
                arguments: [
                    record.id, record.provider.rawValue, record.sessionId,
                    record.projectName, record.startTime, record.endTime,
                    record.messageCount, record.userWordCount, record.assistantWordCount,
                    OpenBurnBarDatabase.encodeJSONStringArray(record.keyFiles),
                    OpenBurnBarDatabase.encodeJSONStringArray(record.keyCommands),
                    OpenBurnBarDatabase.encodeJSONStringArray(record.keyTools),
                    record.inferredTaskTitle, record.lastAssistantMessage, record.fullText,
                    record.indexedAt, record.fileModifiedAt, record.sourceType.rawValue,
                    record.sourceDeviceId, record.sourceDeviceName, Date()
                ]
            )
        }
    }

    func fetchUnsyncedSessionLogs(limit: Int = 100) throws -> [ConversationRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM conversations
                WHERE logSyncedAt IS NULL AND isRemote = 0
                ORDER BY COALESCE(endTime, startTime) ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { Self.conversation(from: $0) }
        }
    }

    func markSessionLogsSynced(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
        try dbQueue.write { db in
            var args = StatementArguments([Date()])
            args += StatementArguments(ids)
            try db.execute(
                sql: "UPDATE conversations SET logSyncedAt = ? WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
    }

    func countConversations() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
        }
    }

    // MARK: - Chat Messages

    func saveChatMessage(_ message: ChatMessageRecord, threadID: String) throws {
        let piecesJSON: String?
        if message.transcriptPieces.isEmpty {
            piecesJSON = nil
        } else {
            piecesJSON = try OpenBurnBarDatabase.encodeTranscriptPieces(message.transcriptPieces)
        }

        let attachmentsJSON: String?
        if message.attachments.isEmpty {
            attachmentsJSON = nil
        } else {
            attachmentsJSON = try OpenBurnBarDatabase.encodeChatAttachments(message.attachments)
        }

        try dbQueue.write { db in
            try Self.upsertChatThread(threadID, at: message.timestamp, db: db)
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO chat_messages (id, threadId, role, content, timestamp, cliUsed, transcriptPiecesJSON, attachmentsJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    message.id,
                    threadID,
                    message.role.rawValue,
                    message.content,
                    message.timestamp,
                    message.cliUsed,
                    piecesJSON,
                    attachmentsJSON
                ]
            )
        }
    }

    func createChatThread(id: String, at date: Date) throws -> String {
        try dbQueue.write { db in
            try Self.upsertChatThread(id, at: date, db: db)
        }
        return id
    }

    func chatThreadExists(id: String) throws -> Bool {
        try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(1) FROM chat_threads WHERE id = ?",
                arguments: [id]
            ) ?? 0
            return count > 0
        }
    }

    func fetchMostRecentChatThreadID() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT t.id
                FROM chat_threads t
                LEFT JOIN chat_messages m ON m.threadId = t.id
                GROUP BY t.id, t.createdAt, t.updatedAt
                ORDER BY COALESCE(MAX(m.timestamp), t.updatedAt, t.createdAt) DESC
                LIMIT 1
                """
            )
        }
    }

    func fetchChatThreadSummaries(searchQuery: String = "", limit: Int = 80) throws -> [ChatThreadSummary] {
        let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return try dbQueue.read { db in
            var sql = """
            SELECT
                t.id AS threadID,
                t.createdAt AS createdAt,
                t.updatedAt AS updatedAt,
                COUNT(m.id) AS messageCount,
                MAX(m.timestamp) AS lastMessageAt,
                (
                    SELECT um.content
                    FROM chat_messages um
                    WHERE um.threadId = t.id
                      AND um.role = 'user'
                      AND TRIM(um.content) != ''
                    ORDER BY um.timestamp ASC
                    LIMIT 1
                ) AS firstUserMessage,
                (
                    SELECT lm.content
                    FROM chat_messages lm
                    WHERE lm.threadId = t.id
                      AND TRIM(lm.content) != ''
                    ORDER BY lm.timestamp DESC
                    LIMIT 1
                ) AS lastMessageContent
            FROM chat_threads t
            LEFT JOIN chat_messages m ON m.threadId = t.id
            """
            var args: [any DatabaseValueConvertible] = []

            if !normalizedQuery.isEmpty {
                sql += """
                 WHERE EXISTS (
                    SELECT 1
                    FROM chat_messages sm
                    WHERE sm.threadId = t.id
                      AND lower(sm.content) LIKE ?
                )
                """
                args.append("%\(normalizedQuery)%")
            }

            sql += """
             GROUP BY t.id, t.createdAt, t.updatedAt
             HAVING COUNT(m.id) > 0
             ORDER BY COALESCE(MAX(m.timestamp), t.updatedAt, t.createdAt) DESC
             LIMIT ?
            """
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row -> ChatThreadSummary? in
                guard let id = row["threadID"] as? String,
                      let createdAt = OpenBurnBarDatabase.parseDateValue(row["createdAt"]),
                      let updatedAt = OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) else {
                    return nil
                }

                let messageCount = row["messageCount"] as? Int
                    ?? Int((row["messageCount"] as? Int64) ?? 0)
                let lastMessageAt = OpenBurnBarDatabase.parseDateValue(row["lastMessageAt"])
                let firstUserMessage = (row["firstUserMessage"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let lastMessageContent = (row["lastMessageContent"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let titleSource = (firstUserMessage?.isEmpty == false) ? firstUserMessage! : "Burn Bar Chat"
                let previewSource = (lastMessageContent?.isEmpty == false) ? lastMessageContent! : titleSource

                return ChatThreadSummary(
                    id: id,
                    title: Self.compactChatSnippet(titleSource, limit: 84),
                    preview: Self.compactChatSnippet(previewSource, limit: 180),
                    messageCount: messageCount,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    lastMessageAt: lastMessageAt
                )
            }
        }
    }

    func fetchChatMessages(threadID: String? = nil) throws -> [ChatMessageRecord] {
        try dbQueue.read { db in
            let rows: [Row]
            if let threadID {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM chat_messages WHERE threadId = ? ORDER BY timestamp ASC",
                    arguments: [threadID]
                )
            } else {
                rows = try Row.fetchAll(db, sql: "SELECT * FROM chat_messages ORDER BY timestamp ASC")
            }
            return rows.compactMap { Self.chatMessage(from: $0) }
        }
    }

    func deleteAllChatMessages() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM chat_messages")
            try db.execute(sql: "DELETE FROM chat_threads")
            let now = Date()
            try db.execute(
                sql: "INSERT INTO chat_threads (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [DataStore.legacyChatThreadID, now, now]
            )
        }
    }

    // MARK: - Full-text Search

    func searchConversationsFTS(
        query: String,
        provider: AgentProvider? = nil,
        projectName: String? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let ftsQuery = BurnBarFTSQueryBuilder.naturalLanguage(from: trimmed)
        guard !ftsQuery.isEmpty else { return [] }

        return try dbQueue.read { db -> [SearchResult] in
            var sql = """
            SELECT c.*, bm25(conversations_fts) AS rank,
            snippet(conversations_fts, 1, '<b>', '</b>', '…', 10) AS snip
            FROM conversations_fts
            JOIN conversations AS c ON c.rowid = conversations_fts.rowid
            WHERE conversations_fts MATCH ?
            """
            var args: [any DatabaseValueConvertible] = [ftsQuery]

            if let provider {
                sql += " AND c.provider = ?"
                args.append(provider.rawValue)
            }
            if let projectName {
                sql += " AND c.projectName = ?"
                args.append(projectName)
            }
            if let range = dateRange {
                sql += " AND c.startTime >= ? AND c.startTime <= ?"
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }

            sql += " ORDER BY rank ASC LIMIT 50"

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            var results = rows.compactMap { row -> SearchResult? in
                guard let conv = Self.conversation(from: row) else { return nil }
                let rank = (row["rank"] as? Double) ?? Double(row["rank"] as? Int64 ?? 0)
                let snip = (row["snip"] as? String) ?? ""
                return SearchResult(conversation: conv, snippet: snip, rank: rank)
            }

            if results.count < 50 {
                var fallbackSQL = """
                SELECT c.*
                FROM conversations AS c
                WHERE (
                    LOWER(COALESCE(c.summaryTitle, '')) LIKE ?
                    OR LOWER(COALESCE(c.summary, '')) LIKE ?
                )
                """
                var fallbackArgs: [any DatabaseValueConvertible] = [
                    "%\(trimmed.lowercased())%",
                    "%\(trimmed.lowercased())%"
                ]

                if let provider {
                    fallbackSQL += " AND c.provider = ?"
                    fallbackArgs.append(provider.rawValue)
                }
                if let projectName {
                    fallbackSQL += " AND c.projectName = ?"
                    fallbackArgs.append(projectName)
                }
                if let range = dateRange {
                    fallbackSQL += " AND c.startTime >= ? AND c.startTime <= ?"
                    fallbackArgs.append(range.lowerBound)
                    fallbackArgs.append(range.upperBound)
                }

                fallbackSQL += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT 50"
                let fallbackRows = try Row.fetchAll(db, sql: fallbackSQL, arguments: StatementArguments(fallbackArgs))
                var seen = Set(results.map { $0.conversation.id })
                for row in fallbackRows {
                    guard let conv = Self.conversation(from: row), !seen.contains(conv.id) else { continue }
                    seen.insert(conv.id)
                    let fallbackSnippet = conv.summary ?? conv.summaryTitle ?? conv.inferredTaskTitle
                    results.append(
                        SearchResult(
                            conversation: conv,
                            snippet: fallbackSnippet,
                            rank: (results.last?.rank ?? 0) + 100
                        )
                    )
                    if results.count >= 50 { break }
                }
            }

            return results
        }
    }

    // MARK: - Transcript Scan Helpers

    func fetchConversationsForTranscriptScan(
        provider: AgentProvider?,
        projectName: String?,
        dateRange: ClosedRange<Date>?,
        conversationSources: Set<ConversationSourceType>?,
        limit: Int = 500
    ) throws -> [ConversationRecord] {
        try dbQueue.read { db -> [ConversationRecord] in
            var sql = """
            SELECT *
            FROM conversations AS c
            WHERE 1 = 1
            """
            var args: [any DatabaseValueConvertible] = []
            if let provider {
                sql += " AND c.provider = ?"
                args.append(provider.rawValue)
            }
            if let projectName {
                sql += " AND c.projectName = ?"
                args.append(projectName)
            }
            if let range = dateRange {
                sql += """
                 AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                 AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                """
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }
            if let sources = conversationSources, sources.isEmpty == false {
                let rawVals = sources.map(\.rawValue)
                let placeholders = Array(repeating: "?", count: rawVals.count).joined(separator: ", ")
                sql += " AND c.sourceType IN (\(placeholders))"
                args.append(contentsOf: rawVals)
            }
            sql += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap(Self.conversation(from:))
        }
    }

    /// Lightweight batched fetch for transcript scanning.
    /// Returns only `id` and `fullText` to bound transient heap usage.
    func fetchTranscriptScanBatch(
        provider: AgentProvider?,
        projectName: String?,
        dateRange: ClosedRange<Date>?,
        conversationSources: Set<ConversationSourceType>?,
        limit: Int,
        offset: Int
    ) throws -> [(id: String, fullText: String)] {
        try dbQueue.read { db -> [(id: String, fullText: String)] in
            var sql = """
            SELECT c.id, c.fullText
            FROM conversations AS c
            WHERE 1 = 1
            """
            var args: [any DatabaseValueConvertible] = []
            if let provider {
                sql += " AND c.provider = ?"
                args.append(provider.rawValue)
            }
            if let projectName {
                sql += " AND c.projectName = ?"
                args.append(projectName)
            }
            if let range = dateRange {
                sql += """
                 AND COALESCE(c.endTime, c.startTime, c.fileModifiedAt, c.indexedAt) >= ?
                 AND COALESCE(c.startTime, c.endTime, c.fileModifiedAt, c.indexedAt) <= ?
                """
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }
            if let sources = conversationSources, sources.isEmpty == false {
                let rawVals = sources.map(\.rawValue)
                let placeholders = Array(repeating: "?", count: rawVals.count).joined(separator: ", ")
                sql += " AND c.sourceType IN (\(placeholders))"
                args.append(contentsOf: rawVals)
            }
            sql += " ORDER BY COALESCE(c.endTime, c.startTime, c.indexedAt) DESC LIMIT ? OFFSET ?"
            args.append(limit)
            args.append(offset)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                let fullText = (row["fullText"] as? String) ?? ""
                return (id: id, fullText: fullText)
            }
        }
    }

    // MARK: - Row Decoding

    static func fetchConversationRow(_ db: Database, id: String) throws -> ConversationRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM conversations WHERE id = ?", arguments: [id]) else {
            return nil
        }
        return conversation(from: row)
    }

    static func conversation(from row: Row) -> ConversationRecord? {
        guard let id = row["id"] as? String,
              let providerRaw = row["provider"] as? String,
              let provider = AgentProvider(rawValue: providerRaw),
              let sessionId = row["sessionId"] as? String,
              let projectName = row["projectName"] as? String else {
            return nil
        }
        let messageCount = (row["messageCount"] as? Int) ?? Int(row["messageCount"] as? Int64 ?? 0)
        let userWordCount = (row["userWordCount"] as? Int) ?? Int(row["userWordCount"] as? Int64 ?? 0)
        let assistantWordCount = (row["assistantWordCount"] as? Int) ?? Int(row["assistantWordCount"] as? Int64 ?? 0)
        let inferredTaskTitle = (row["inferredTaskTitle"] as? String) ?? ""
        let lastAssistantMessage = (row["lastAssistantMessage"] as? String) ?? ""
        let fullText = (row["fullText"] as? String) ?? ""

        let keyFiles = OpenBurnBarDatabase.decodeJSONStringArray(row["keyFiles"] as? String)
        let keyCommands = OpenBurnBarDatabase.decodeJSONStringArray(row["keyCommands"] as? String)
        let keyTools = OpenBurnBarDatabase.decodeJSONStringArray(row["keyTools"] as? String)

        let startTime = OpenBurnBarDatabase.parseDateValue(row["startTime"])
        let endTime = OpenBurnBarDatabase.parseDateValue(row["endTime"])
        let indexedAt = OpenBurnBarDatabase.parseDateValue(row["indexedAt"]) ?? Date()
        let fileModifiedAt = OpenBurnBarDatabase.parseDateValue(row["fileModifiedAt"])

        let sourceTypeRaw = (row["sourceType"] as? String) ?? "provider_log"
        let sourceType = ConversationSourceType(rawValue: sourceTypeRaw) ?? .providerLog

        return ConversationRecord(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            startTime: startTime,
            endTime: endTime,
            messageCount: messageCount,
            userWordCount: userWordCount,
            assistantWordCount: assistantWordCount,
            keyFiles: keyFiles,
            keyCommands: keyCommands,
            keyTools: keyTools,
            inferredTaskTitle: inferredTaskTitle,
            lastAssistantMessage: lastAssistantMessage,
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: fileModifiedAt,
            summary: row["summary"] as? String,
            summaryTitle: row["summaryTitle"] as? String,
            summaryUpdatedAt: OpenBurnBarDatabase.parseDateValue(row["summaryUpdatedAt"]),
            summaryProvider: row["summaryProvider"] as? String,
            summaryModel: row["summaryModel"] as? String,
            sourceType: sourceType,
            sourceDeviceId: row["sourceDeviceId"] as? String,
            sourceDeviceName: row["sourceDeviceName"] as? String,
            isRemote: ((row["isRemote"] as? Int) ?? Int(row["isRemote"] as? Int64 ?? 0)) != 0
        )
    }

    static func chatMessage(from row: Row) -> ChatMessageRecord? {
        guard let id = row["id"] as? String,
              let roleRaw = row["role"] as? String,
              let role = ChatMessageRole(rawValue: roleRaw),
              let content = row["content"] as? String,
              let ts = OpenBurnBarDatabase.parseDateValue(row["timestamp"]) else {
            return nil
        }

        let pieces = OpenBurnBarDatabase.decodeTranscriptPieces(row["transcriptPiecesJSON"] as? String) ?? []
        let attachments = OpenBurnBarDatabase.decodeChatAttachments(row["attachmentsJSON"] as? String) ?? []
        return ChatMessageRecord(
            id: id,
            role: role,
            content: content,
            timestamp: ts,
            cliUsed: row["cliUsed"] as? String,
            transcriptPieces: pieces,
            attachments: attachments
        )
    }

    // MARK: - Private Helpers

    private static func upsertChatThread(_ threadID: String, at timestamp: Date, db: Database) throws {
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt)
            VALUES (?, ?, ?)
            """,
            arguments: [threadID, timestamp, timestamp]
        )
        try db.execute(
            sql: """
            UPDATE chat_threads
            SET updatedAt = CASE WHEN updatedAt > ? THEN updatedAt ELSE ? END
            WHERE id = ?
            """,
            arguments: [timestamp, timestamp, threadID]
        )
    }

    static func compactChatSnippet(_ source: String, limit: Int) -> String {
        let compact = source
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func aggregateMatchSnippet(text: NSString, matchRange: NSRange, radius: Int = 120) -> String {
        let start = max(0, matchRange.location - radius)
        let end = min(text.length, matchRange.location + matchRange.length + radius)
        let snippetRange = NSRange(location: start, length: max(0, end - start))
        let raw = text.substring(with: snippetRange)
        let compact = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var prefix = ""
        var suffix = ""
        if start > 0 { prefix = "..." }
        if end < text.length { suffix = "..." }
        return prefix + compact + suffix
    }

    private static func shouldPreserveConversationSyncedAt(
        existing: ConversationRecord,
        incoming: ConversationRecord,
        resolvedSummary: String?,
        resolvedSummaryTitle: String?,
        resolvedSummaryUpdatedAt: Date?,
        resolvedSummaryProvider: String?,
        resolvedSummaryModel: String?
    ) -> Bool {
        let identityMatch =
            existing.provider == incoming.provider
            && existing.sessionId == incoming.sessionId
            && existing.projectName == incoming.projectName
        let timingMatch =
            existing.startTime == incoming.startTime
            && existing.endTime == incoming.endTime
        let countsMatch =
            existing.messageCount == incoming.messageCount
            && existing.userWordCount == incoming.userWordCount
            && existing.assistantWordCount == incoming.assistantWordCount
        let keysMatch =
            existing.keyFiles == incoming.keyFiles
            && existing.keyCommands == incoming.keyCommands
            && existing.keyTools == incoming.keyTools
        let textMatch =
            existing.inferredTaskTitle == incoming.inferredTaskTitle
            && existing.lastAssistantMessage == incoming.lastAssistantMessage
            && existing.fullText == incoming.fullText
        let coreUnchanged =
            identityMatch && timingMatch && countsMatch && keysMatch && textMatch

        let summaryUnchanged =
            existing.summary == resolvedSummary
            && existing.summaryTitle == resolvedSummaryTitle
            && existing.summaryUpdatedAt == resolvedSummaryUpdatedAt
            && existing.summaryProvider == resolvedSummaryProvider
            && existing.summaryModel == resolvedSummaryModel

        return coreUnchanged && summaryUnchanged
    }

    static let credentialExposureRegexes: [NSRegularExpression] = {
        let patterns = [
            #"(?i)\b[A-Z0-9_]*(?:API[_-]?KEY|ACCESS[_-]?TOKEN|TOKEN|SECRET|PASSWORD)\b\s*[:=]\s*["']?[A-Za-z0-9_\-./+=]{8,}"#,
            #"\bsk-[A-Za-z0-9]{16,}\b"#,
            #"\bAIza[0-9A-Za-z\-_]{16,}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func looksLikePlaceholderCredential(_ text: String) -> Bool {
        let lower = text.lowercased()
        let placeholders = [
            "your-key", "your_key", "your key", "key-here", "placeholder",
            "example", "dummy", "changeme", "replace-me", "***", "<", "test"
        ]
        return placeholders.contains { lower.contains($0) }
    }

    static func nonOverlappingOccurrenceCount(of pattern: String, in lowercasedText: String) -> Int {
        guard pattern.isEmpty == false, lowercasedText.isEmpty == false else { return 0 }
        var count = 0
        var searchStart = lowercasedText.startIndex
        while searchStart < lowercasedText.endIndex,
              let range = lowercasedText.range(of: pattern, range: searchStart..<lowercasedText.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
