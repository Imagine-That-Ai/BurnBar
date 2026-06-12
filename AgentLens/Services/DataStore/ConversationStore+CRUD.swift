import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore CRUD

extension ConversationStore {
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

                // Use ON CONFLICT(id) DO UPDATE instead of INSERT OR REPLACE so the
                // conversations rowid stays stable on re-upsert. INSERT OR REPLACE
                // deletes and re-inserts the row, which (with recursive_triggers OFF,
                // the SQLite default) suppresses the conversations_ad delete trigger
                // and leaks an orphaned full-text copy into conversations_fts on every
                // 60s refresh tick. ON CONFLICT performs an UPDATE in place, so the
                // existing conversations_au AFTER UPDATE trigger maintains the FTS index
                // (delete-then-insert for the same rowid). This matches the established
                // upsert idiom in BudgetRulesStore, ProjectionStore, UsageStore, and
                // ProviderAccountStore. Columns absent from the SET clause (deletedAt,
                // version) intentionally retain their existing values, preserving
                // tombstones across re-indexing rather than resurrecting them.
                try db.execute(
                    sql: """
                    INSERT INTO conversations (
                        id, provider, sessionId, projectName, startTime, endTime,
                        messageCount, userWordCount, assistantWordCount,
                        keyFiles, keyCommands, keyTools,
                        inferredTaskTitle, lastAssistantMessage, fullText,
                        indexedAt, workingDirectory, fileModifiedAt, summary, conversationSyncedAt,
                        sourceType, logSyncedAt, summaryTitle, summaryUpdatedAt, summaryAttemptedAt,
                        summaryProvider, summaryModel
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        provider = excluded.provider,
                        sessionId = excluded.sessionId,
                        projectName = excluded.projectName,
                        startTime = excluded.startTime,
                        endTime = excluded.endTime,
                        messageCount = excluded.messageCount,
                        userWordCount = excluded.userWordCount,
                        assistantWordCount = excluded.assistantWordCount,
                        keyFiles = excluded.keyFiles,
                        keyCommands = excluded.keyCommands,
                        keyTools = excluded.keyTools,
                        inferredTaskTitle = excluded.inferredTaskTitle,
                        lastAssistantMessage = excluded.lastAssistantMessage,
                        fullText = excluded.fullText,
                        indexedAt = excluded.indexedAt,
                        workingDirectory = excluded.workingDirectory,
                        fileModifiedAt = excluded.fileModifiedAt,
                        summary = excluded.summary,
                        conversationSyncedAt = excluded.conversationSyncedAt,
                        sourceType = excluded.sourceType,
                        logSyncedAt = excluded.logSyncedAt,
                        summaryTitle = excluded.summaryTitle,
                        summaryUpdatedAt = excluded.summaryUpdatedAt,
                        summaryAttemptedAt = excluded.summaryAttemptedAt,
                        summaryProvider = excluded.summaryProvider,
                        summaryModel = excluded.summaryModel
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
                        record.workingDirectory,
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
                // User-facing read: a tombstoned conversation reads as absent.
                // Internal callers (upsert sync-preservation) use the unfiltered
                // `fetchConversationRow` so re-indexing a transcript cannot
                // silently resurrect a tombstone.
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM conversations WHERE id = ? AND deletedAt IS NULL",
                    arguments: [id]
                ) else { return nil }
                return Self.conversation(from: row)
            }
        }

        func fetchConversations(limit: Int = 500) throws -> [ConversationRecord] {
            try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM conversations WHERE deletedAt IS NULL ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
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
                    WHERE deletedAt IS NULL
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
                      AND deletedAt IS NULL
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
                    sql: "SELECT * FROM conversations WHERE deletedAt IS NULL ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
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
                        indexedAt, workingDirectory, fileModifiedAt, summary, summaryTitle, summaryUpdatedAt,
                        summaryProvider, summaryModel, sourceType, sourceDeviceId, sourceDeviceName, isRemote
                    FROM conversations
                    WHERE deletedAt IS NULL
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
            AND deletedAt IS NULL
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

        /// Hard-deletes a single conversation row. This is the "the source log
        /// vanished" recovery path used by gap repair and tests; the projection
        /// pipeline relies on the row disappearing so it can purge orphaned
        /// projections. User-initiated deletes go through `softDeleteConversation`
        /// so the tombstone propagates across devices before the row is collected.
        func deleteConversation(id: String) throws {
            try dbQueue.write { db in
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
            }
        }

        /// Tombstones a conversation so the delete propagates to other devices
        /// (B-DATA-2). Mirrors `TextExpansionSnippetStore.delete`: sets `deletedAt`,
        /// bumps `version`, and clears the sync flags so the tombstone re-enqueues
        /// through `ConversationSyncService`/`SessionLogSyncService`. The row stays
        /// on disk until `ConversationTombstoneGCService` collects it after the
        /// retention window, which is what lets device B observe the deletion.
        func softDeleteConversation(id: String, at date: Date = Date()) throws {
            try dbQueue.write { db in
                try db.execute(
                    sql: """
                    UPDATE conversations
                    SET deletedAt = ?, version = version + 1,
                        conversationSyncedAt = NULL, logSyncedAt = NULL
                    WHERE id = ? AND deletedAt IS NULL
                    """,
                    arguments: [date, id]
                )
            }
        }

        /// Local tombstones whose `deletedAt` is older than `before`. The GC sweep
        /// uses this to find conversations eligible for purge after the retention
        /// window, then deletes their cloud bodies/manifests before hard-deleting.
        func fetchExpiredConversationTombstones(before: Date, limit: Int = 200) throws -> [ConversationRecord] {
            try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM conversations
                    WHERE deletedAt IS NOT NULL AND deletedAt < ?
                    ORDER BY deletedAt ASC
                    LIMIT ?
                    """,
                    arguments: [before, limit]
                )
                return rows.compactMap { Self.conversation(from: $0) }
            }
        }

        func approximateConversationStorageBytes() throws -> Int64 {
            try dbQueue.read { db in
                let text: Int64 = try Int64.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(LENGTH(fullText)), 0) + COALESCE(SUM(LENGTH(inferredTaskTitle)), 0)
                    + COALESCE(SUM(LENGTH(lastAssistantMessage)), 0) FROM conversations
                    WHERE deletedAt IS NULL
                    """
                ) ?? 0
                return text
            }
        }

        func backupUsageSnapshot(limits: CloudBackupPlanLimits = .standard) throws -> CloudBackupUsageSnapshot {
            try dbQueue.read { db in
                func aggregate(whereClause: String) throws -> (conversationCount: Int, rawBytes: Int64, searchChunks: Int) {
                    let payloadBytes = """
                    COALESCE(LENGTH(CAST(fullText AS BLOB)), 0)
                    + COALESCE(LENGTH(CAST(summary AS BLOB)), 0)
                    + COALESCE(LENGTH(CAST(summaryTitle AS BLOB)), 0)
                    + COALESCE(LENGTH(CAST(inferredTaskTitle AS BLOB)), 0)
                    + COALESCE(LENGTH(CAST(lastAssistantMessage AS BLOB)), 0)
                    + COALESCE(LENGTH(CAST(projectName AS BLOB)), 0)
                    """
                    let row = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT
                            COUNT(*) AS conversationCount,
                            COALESCE(SUM(payloadBytes + ?), 0) AS rawBytes,
                            COALESCE(SUM(
                                CASE
                                    WHEN payloadBytes <= 0 THEN 1
                                    ELSE ((payloadBytes + ? - 1) / ?)
                                END
                            ), 0) AS searchChunks
                        FROM (
                            SELECT \(payloadBytes) AS payloadBytes
                            FROM conversations
                            WHERE \(whereClause)
                        )
                        """,
                        arguments: [
                            CloudBackupUsageSnapshot.perConversationEnvelopeBytes,
                            CloudBackupUsageSnapshot.searchChunkMaxBytes,
                            CloudBackupUsageSnapshot.searchChunkMaxBytes
                        ]
                    )
                    return (
                        conversationCount: row?["conversationCount"] ?? 0,
                        rawBytes: row?["rawBytes"] ?? 0,
                        searchChunks: row?["searchChunks"] ?? 0
                    )
                }

                let total = try aggregate(whereClause: "isRemote = 0 AND deletedAt IS NULL")
                let pending = try aggregate(whereClause: "isRemote = 0 AND deletedAt IS NULL AND logSyncedAt IS NULL")
                let estimatedIndex = CloudBackupUsageSnapshot.estimateSearchIndexBytes(
                    rawTranscriptBytes: total.rawBytes,
                    searchChunkCount: total.searchChunks
                )
                let estimatedPendingIndex = CloudBackupUsageSnapshot.estimateSearchIndexBytes(
                    rawTranscriptBytes: pending.rawBytes,
                    searchChunkCount: pending.searchChunks
                )
                return CloudBackupUsageSnapshot(
                    conversationCount: total.conversationCount,
                    pendingConversationCount: pending.conversationCount,
                    rawTranscriptBytes: total.rawBytes,
                    pendingRawTranscriptBytes: pending.rawBytes,
                    estimatedSearchIndexBytes: estimatedIndex,
                    pendingEstimatedSearchIndexBytes: estimatedPendingIndex,
                    searchChunkCount: total.searchChunks,
                    pendingSearchChunkCount: pending.searchChunks,
                    limits: limits
                )
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
}
