import Foundation
import GRDB
import OpenBurnBarCore

// MARK: - ConversationStore Chat

extension ConversationStore {
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
                    ) AS lastMessageContent,
                    (
                        SELECT am.attachmentsJSON
                        FROM chat_messages am
                        WHERE am.threadId = t.id
                          AND am.attachmentsJSON IS NOT NULL
                          AND TRIM(am.attachmentsJSON) != ''
                        ORDER BY am.timestamp DESC
                        LIMIT 1
                    ) AS latestAttachmentsJSON
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
                        attachments: Array((OpenBurnBarDatabase.decodeChatAttachments(row["latestAttachmentsJSON"] as? String) ?? []).prefix(3)),
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
}
