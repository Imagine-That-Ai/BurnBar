import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore Cloud Sync

extension ConversationStore {
        // MARK: - Sync

        func fetchUnsyncedConversations(limit: Int = 400) throws -> [ConversationRecord] {
            try dbQueue.read { db in
                // Deliberately includes tombstones: a soft-delete clears
                // `conversationSyncedAt`, so the row resurfaces here and its
                // `deletedAt` is uploaded to Firestore — that upload is exactly how
                // the delete reaches device B.
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
                            indexedAt, workingDirectory, fileModifiedAt, sourceType,
                            sourceDeviceId, sourceDeviceName, isRemote, conversationSyncedAt,
                            deletedAt, version
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                        """,
                    arguments: [
                        record.id, record.provider.rawValue, record.sessionId,
                        record.projectName, record.startTime, record.endTime,
                        record.messageCount, record.userWordCount, record.assistantWordCount,
                        OpenBurnBarDatabase.encodeJSONStringArray(record.keyFiles),
                        OpenBurnBarDatabase.encodeJSONStringArray(record.keyCommands),
                        OpenBurnBarDatabase.encodeJSONStringArray(record.keyTools),
                        record.inferredTaskTitle, record.lastAssistantMessage, record.fullText,
                        record.indexedAt, record.workingDirectory, record.fileModifiedAt, record.sourceType.rawValue,
                        record.sourceDeviceId, record.sourceDeviceName, Date(),
                        record.deletedAt, record.version
                    ]
                )

                // Honor a remote tombstone even for a row that already exists
                // locally: `INSERT OR IGNORE` skips existing rows, so the delete
                // would otherwise never land. Mirror the remote `deletedAt`
                // (and advance `version`) only when the remote tombstone is newer,
                // so a delete on device A propagates to this device (B-DATA-2).
                if let deletedAt = record.deletedAt {
                    try db.execute(
                        sql: """
                        UPDATE conversations
                        SET deletedAt = ?, version = MAX(version, ?)
                        WHERE id = ? AND (deletedAt IS NULL OR version < ?)
                        """,
                        arguments: [deletedAt, record.version, record.id, record.version]
                    )
                }
            }
        }

        func fetchUnsyncedSessionLogs(limit: Int = 100) throws -> [ConversationRecord] {
            try dbQueue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM conversations
                    WHERE logSyncedAt IS NULL AND isRemote = 0 AND deletedAt IS NULL
                    ORDER BY COALESCE(endTime, startTime) ASC
                    LIMIT ?
                    """,
                    arguments: [limit]
                )
                return rows.compactMap { Self.conversation(from: $0) }
            }
        }

        func countUnsyncedSessionLogs() throws -> Int {
            try dbQueue.read { db in
                try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) FROM conversations
                    WHERE logSyncedAt IS NULL AND isRemote = 0 AND deletedAt IS NULL
                    """
                ) ?? 0
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

        /// Clears the encrypted-backup dirty flag for every local conversation so a facet-schema
        /// bump re-enqueues each one through `SessionLogSyncService` exactly once.
        @discardableResult
        func markAllSessionLogsUnsynced() throws -> Int {
            try dbQueue.write { db in
                try db.execute(sql: "UPDATE conversations SET logSyncedAt = NULL WHERE isRemote = 0 AND deletedAt IS NULL")
                return db.changesCount
            }
        }

        func countConversations() throws -> Int {
            try dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations WHERE deletedAt IS NULL") ?? 0
            }
        }
}
