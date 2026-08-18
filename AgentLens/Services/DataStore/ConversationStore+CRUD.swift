import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore CRUD

extension ConversationStore {
        // MARK: - Conversation CRUD

        func upsertConversation(_ record: OpenBurnBarCore.ConversationRecord) async throws {
            try await dbQueue.write { [self] db in
                _ = try upsertConversation(record, db: db)
            }
        }

        /// Upserts inside an already-open write. Returns whether the row is
        /// live (`deletedAt == nil`) after the statement — tombstones stay
        /// buried because `deletedAt` is omitted from the SET clause.
        @discardableResult
        func upsertConversation(_ record: OpenBurnBarCore.ConversationRecord, db: Database) throws -> Bool {
            let keyFilesJSON = try OpenBurnBarDatabase.encodeJSON(record.keyFiles)
            let keyCommandsJSON = try OpenBurnBarDatabase.encodeJSON(record.keyCommands)
            let keyToolsJSON = try OpenBurnBarDatabase.encodeJSON(record.keyTools)

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
                try Self.upsertProjectionContentHash(
                    conversationID: record.id,
                    contentHash: ProjectionIdentity.conversationContentHash(for: record),
                    updatedAt: record.indexedAt,
                    db: db
                )
            return existing?.deletedAt == nil
        }

        func fileModifiedAtForConversation(id: String) async throws -> Date? {
            try await dbQueue.read { db in
                try Date.fetchOne(
                    db,
                    sql: "SELECT fileModifiedAt FROM conversations WHERE id = ?",
                    arguments: [id]
                )
            }
        }

        func fetchConversation(id: String) async throws -> OpenBurnBarCore.ConversationRecord? {
            try await dbQueue.read { db in
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

        func fetchConversationSynchronously(id: String) throws -> OpenBurnBarCore.ConversationRecord? {
            try dbQueue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: "SELECT * FROM conversations WHERE id = ? AND deletedAt IS NULL",
                    arguments: [id]
                ) else { return nil }
                return Self.conversation(from: row)
            }
        }

        func fetchConversations(limit: Int = 500) async throws -> [OpenBurnBarCore.ConversationRecord] {
            try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM conversations WHERE deletedAt IS NULL ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                    arguments: [limit]
                )
                return rows.compactMap { Self.conversation(from: $0) }
            }
        }

        /// Metadata-only activity feed for the daemon controller snapshot.
        ///
        /// Do not widen this projection to `SELECT *`: `fullText` and
        /// `lastAssistantMessage` can live on thousands of encrypted overflow
        /// pages. The controller snapshot does not consume those fields, and
        /// loading them caused startup to decrypt the multi-gigabyte transcript
        /// corpus into memory.
        func fetchConversationActivitySummaries(limit: Int) async throws -> [ConversationActivitySummary] {
            guard limit > 0 else { return [] }
            return try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT
                        id,
                        sessionId,
                        projectName,
                        startTime,
                        endTime,
                        indexedAt,
                        inferredTaskTitle,
                        summary,
                        summaryTitle
                    FROM conversations
                    WHERE deletedAt IS NULL
                    ORDER BY COALESCE(endTime, startTime, indexedAt) DESC
                    LIMIT ?
                    """,
                    arguments: [limit]
                )
                return rows.compactMap { row in
                    guard let id = row["id"] as? String,
                          let sessionId = row["sessionId"] as? String,
                          let projectName = row["projectName"] as? String else {
                        return nil
                    }
                    return ConversationActivitySummary(
                        id: id,
                        sessionId: sessionId,
                        projectName: projectName,
                        startTime: OpenBurnBarDatabase.parseDateValue(row["startTime"]),
                        endTime: OpenBurnBarDatabase.parseDateValue(row["endTime"]),
                        indexedAt: OpenBurnBarDatabase.parseDateValue(row["indexedAt"]) ?? .distantPast,
                        inferredTaskTitle: (row["inferredTaskTitle"] as? String) ?? "",
                        summary: row["summary"] as? String,
                        summaryTitle: row["summaryTitle"] as? String
                    )
                }
            }
        }

        func fetchConversationsSynchronously(limit: Int = 500) throws -> [OpenBurnBarCore.ConversationRecord] {
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
        func fetchConversations(limit: Int, offset: Int) async throws -> [OpenBurnBarCore.ConversationRecord] {
            try await dbQueue.read { db in
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

        func fetchConversations(ids: [String]) async throws -> [OpenBurnBarCore.ConversationRecord] {
            guard ids.isEmpty == false else { return [] }
            let uniqueIDs = Array(Set(ids)).sorted()
            return try await dbQueue.read { db in
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

        /// Fetches only revision columns, never transcript payloads.
        ///
        /// Chunking keeps each `IN` clause below SQLite's conservative
        /// parameter limit while the enclosing read preserves one snapshot.
        func fetchConversationProjectionRevisions(
            ids: [String]
        ) async throws -> [ConversationProjectionRevision] {
            guard ids.isEmpty == false else { return [] }
            let uniqueIDs = Array(Set(ids)).sorted()
            let chunkSize = 500
            return try await dbQueue.read { db in
                var revisions: [ConversationProjectionRevision] = []
                revisions.reserveCapacity(uniqueIDs.count)
                for chunkStart in stride(from: 0, to: uniqueIDs.count, by: chunkSize) {
                    let chunkEnd = min(chunkStart + chunkSize, uniqueIDs.count)
                    let chunk = Array(uniqueIDs[chunkStart..<chunkEnd])
                    var arguments = StatementArguments([Self.projectionHashCacheKeyPrefix])
                    arguments += StatementArguments(chunk)
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                        SELECT
                            c.id AS id,
                            c.startTime AS startTime,
                            c.endTime AS endTime,
                            c.indexedAt AS indexedAt,
                            c.fileModifiedAt AS fileModifiedAt,
                            r.payloadJSON AS projectionHashJSON
                        FROM conversations c
                        LEFT JOIN controller_runtime_cache r
                          ON r.cacheKey = ? || c.id
                        WHERE c.id IN (\(OpenBurnBarDatabase.sqlPlaceholders(count: chunk.count)))
                          AND c.deletedAt IS NULL
                        """,
                        arguments: arguments
                    )
                    revisions.append(contentsOf: rows.compactMap { row in
                        guard let id = row["id"] as? String,
                              let indexedAt = OpenBurnBarDatabase.parseDateValue(row["indexedAt"]) else {
                            return nil
                        }
                        return ConversationProjectionRevision(
                            id: id,
                            startTime: OpenBurnBarDatabase.parseDateValue(row["startTime"]),
                            endTime: OpenBurnBarDatabase.parseDateValue(row["endTime"]),
                            indexedAt: indexedAt,
                            fileModifiedAt: OpenBurnBarDatabase.parseDateValue(row["fileModifiedAt"]),
                            contentHash: Self.decodeProjectionContentHash(row["projectionHashJSON"] as? String)
                        )
                    })
                }
                return revisions
            }
        }

        /// Seeds projection hashes for rows created before the lightweight
        /// revision cache existed. `DO NOTHING` is deliberate: a concurrent
        /// conversation upsert may already have stored a newer authoritative
        /// hash, and a legacy search-document baseline must never overwrite it.
        func cacheConversationProjectionHashesIfMissing(
            _ contentHashesByID: [String: String],
            updatedAt: Date
        ) async throws {
            guard contentHashesByID.isEmpty == false else { return }
            try await dbQueue.write { db in
                for conversationID in contentHashesByID.keys.sorted() {
                    guard let contentHash = contentHashesByID[conversationID] else { continue }
                    try db.execute(
                        sql: """
                        INSERT INTO controller_runtime_cache (cacheKey, payloadJSON, updatedAt)
                        VALUES (?, ?, ?)
                        ON CONFLICT(cacheKey) DO NOTHING
                        """,
                        arguments: [
                            Self.projectionHashCacheKey(conversationID: conversationID),
                            try Self.encodeProjectionContentHash(contentHash),
                            updatedAt
                        ]
                    )
                }
            }
        }

        /// Returns the set of IDs (from `ids`) that already exist in the
        /// conversations table. Used by incremental indexing to detect
        /// newly discovered sessions whose `fileModifiedAt` may be older
        /// than the checkpoint watermark — those must be indexed regardless
        /// of mtime since the DB row doesn't exist yet.
        ///
        /// P-PERF-2: chunked to stay below SQLite's parameter limit.
        func fetchExistingConversationIDs(ids: [String]) async throws -> Set<String> {
            guard ids.isEmpty == false else { return [] }
            let uniqueIDs = Array(Set(ids))
            var existing: Set<String> = []
            existing.reserveCapacity(uniqueIDs.count)
            let chunkSize = 500
            for chunkStart in stride(from: 0, to: uniqueIDs.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, uniqueIDs.count)
                let chunk = Array(uniqueIDs[chunkStart..<chunkEnd])
                let placeholders = OpenBurnBarDatabase.sqlPlaceholders(count: chunk.count)
                let found = try await dbQueue.read { db in
                    try String.fetchAll(
                        db,
                        sql: "SELECT id FROM conversations WHERE id IN (\(placeholders)) AND deletedAt IS NULL",
                        arguments: StatementArguments(chunk)
                    )
                }
                existing.formUnion(found)
            }
            return existing
        }

        func fetchAllSessionLogs(limit: Int = 1000) async throws -> [OpenBurnBarCore.ConversationRecord] {
            try await dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM conversations WHERE deletedAt IS NULL ORDER BY COALESCE(endTime, startTime, indexedAt) DESC LIMIT ?",
                    arguments: [limit]
                )
                return rows.compactMap { Self.conversation(from: $0) }
            }
        }

        func fetchSessionLogSummaries(limit: Int = 1000) async throws -> [OpenBurnBarCore.ConversationRecord] {
            try await dbQueue.read { db in
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
        ) async throws {
            try await dbQueue.write { db in
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

        func markConversationSummaryAttempt(id: String, attemptedAt: Date = Date()) async throws {
            try await dbQueue.write { db in
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
        ) async throws -> [OpenBurnBarCore.ConversationRecord] {
            let cutoff = now.addingTimeInterval(-max(retryCooldown, 0))
            return try await dbQueue.read { db in
                let (whereSQL, whereArguments) = self.summaryCandidateWhereClause(
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
        ) async throws -> Int {
            let cutoff = now.addingTimeInterval(-max(retryCooldown, 0))
            return try await dbQueue.read { db in
                let (whereSQL, arguments) = self.summaryCandidateWhereClause(
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

        func summarySpendToday(now: Date = Date()) async throws -> Double {
            try await dbQueue.read { db in
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

        func deleteAllIndexedConversations() async throws {
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM conversations")
                try db.execute(sql: "DELETE FROM summary_runs")
                try db.execute(sql: "DELETE FROM project_memory_snapshots")
                try db.execute(
                    sql: """
                    DELETE FROM chunk_embeddings
                    WHERE chunkID IN (
                        SELECT id FROM search_chunks WHERE sourceKind = 'conversation'
                    )
                    """
                )
                try db.execute(
                    sql: """
                    DELETE FROM search_chunks_fts
                    WHERE chunkID IN (
                        SELECT id FROM search_chunks WHERE sourceKind = 'conversation'
                    )
                    """
                )
                try db.execute(sql: "DELETE FROM search_chunks WHERE sourceKind = 'conversation'")
                try db.execute(sql: "DELETE FROM search_documents WHERE sourceKind = 'conversation'")
            }
        }

        /// Hard-deletes a single conversation row. This is the "the source log
        /// vanished" recovery path used by gap repair and tests; the projection
        /// pipeline relies on the row disappearing so it can purge orphaned
        /// projections. User-initiated deletes go through `softDeleteConversation`
        /// so the tombstone propagates across devices before the row is collected.
        func deleteConversation(id: String) async throws {
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
                try db.execute(
                    sql: "DELETE FROM controller_runtime_cache WHERE cacheKey = ?",
                    arguments: [Self.projectionHashCacheKey(conversationID: id)]
                )
            }
        }

        /// Tombstones a conversation so the delete propagates to other devices
        /// (B-DATA-2). Mirrors `TextExpansionSnippetStore.delete`: sets `deletedAt`,
        /// bumps `version`, and clears the sync flags so the tombstone re-enqueues
        /// through `ConversationSyncService`/`SessionLogSyncService`. The row stays
        /// on disk until `ConversationTombstoneGCService` collects it after the
        /// retention window, which is what lets device B observe the deletion.
        func softDeleteConversation(id: String, at date: Date = Date()) async throws {
            try await dbQueue.write { db in
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
        func fetchExpiredConversationTombstones(before: Date, limit: Int = 200) async throws -> [OpenBurnBarCore.ConversationRecord] {
            try await dbQueue.read { db in
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

        func approximateConversationStorageBytes() async throws -> Int64 {
            try await dbQueue.read { db in
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

        func backupUsageSnapshot(limits: CloudBackupPlanLimits = .standard) async throws -> CloudBackupUsageSnapshot {
            try await dbQueue.read { db in
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

        func updateConversationFullText(id: String, fullText: String) async throws {
            try await dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE conversations SET fullText = ? WHERE id = ?",
                    arguments: [fullText, id]
                )
                guard db.changesCount > 0,
                      let conversation = try Self.fetchConversationRow(db, id: id) else {
                    return
                }
                try Self.upsertProjectionContentHash(
                    conversationID: id,
                    contentHash: ProjectionIdentity.conversationContentHash(for: conversation),
                    updatedAt: conversation.indexedAt,
                    db: db
                )
            }
        }
}
