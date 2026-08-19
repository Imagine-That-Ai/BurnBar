import Foundation
import GRDB
import CryptoKit
import OpenBurnBarCore

// MARK: - Memory extraction trigger context (G3)
//
// The terminal assistant-commit event fires from the `saveChatMessage` chokepoint
// (persistence), never from UI streaming state, so it survives the planned
// `send()` de-godding. The controller builds this context at the terminal commit
// sites and passes it through; the store constructs the `ExtractionIntent` and
// calls `MemoryServing.enqueueExtraction` (idempotent on `idempotencyKey`).

/// Scope + identity needed to build an `ExtractionIntent` at the persistence seam.
struct MemoryExtractionContext: Sendable {
    let scope: MemoryScope
    /// Content-derived, cross-device stable thread id. v1 uses the device-local
    /// `activeThreadID` (same-device); a content-addressed id is a backend/F-3 refinement.
    let threadLogicalID: String
    /// System-prompt assembly version; re-extraction under a new prompt version is a
    /// distinct event (keeps the idempotency key honest when injection changes).
    let promptVersion: String
}

protocol TransactionalMemoryExtractionServing: MemoryServing {
    func enqueueExtraction(_ intent: ExtractionIntent, in db: Database) throws
}

enum MemoryExtraction {
    /// `idempotency_key = HMAC-SHA256(threadLogicalID | messageID | promptVersion)`, hex.
    /// Deterministic so a replayed commit (e.g. re-save) collapses to one backend
    /// outbox event. The key scopes idempotency (not auth), so a stable app-wide
    /// HMAC key is sufficient.
    static func idempotencyKey(threadLogicalID: String, messageID: String, promptVersion: String) -> String {
        let payload = Data("\(threadLogicalID)|\(messageID)|\(promptVersion)".utf8)
        let key = SymmetricKey(data: Data("openburnbar-memory-extraction-v1".utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ConversationStore Chat

extension ConversationStore {
        // MARK: - Chat Messages

        func saveChatMessage(
            _ message: ChatMessageRecord,
            threadID: String,
            isTerminalAssistantCommit: Bool = false,
            memoryService: (any MemoryServing)? = nil,
            extractionContext: MemoryExtractionContext? = nil
        ) async throws {
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

            let extractionIntent = Self.makeMemoryExtractionIntent(
                message,
                threadID: threadID,
                isTerminalAssistantCommit: isTerminalAssistantCommit,
                memoryService: memoryService,
                extractionContext: extractionContext
            )
            let transactionalMemoryService = memoryService as? any TransactionalMemoryExtractionServing

            try await dbQueue.write { db in
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

                if let extractionIntent, let transactionalMemoryService {
                    do {
                        try transactionalMemoryService.enqueueExtraction(extractionIntent, in: db)
                    } catch {
                        AppLogger.chat.silentFailure("memory enqueueExtraction (transactional)", error: error)
                    }
                }
            }

            // G3: emit the extraction trigger from the persistence chokepoint, not
            // UI streaming state. Fires only for a terminal, non-empty assistant
            // commit, and only when a memory service is wired. Until the backend
            // (PR-5) lands, production wires no service, so this is a no-op in app
            // builds; tests inject `FakeMemoryService` to assert it fires.
            // Extraction failure must never fail the chat save or block the caller.
            if let extractionIntent, let memoryService, transactionalMemoryService == nil {
                do {
                    try await memoryService.enqueueExtraction(extractionIntent)
                } catch {
                    AppLogger.chat.silentFailure("memory enqueueExtraction", error: error)
                }
            }
        }

        private static func makeMemoryExtractionIntent(
            _ message: ChatMessageRecord,
            threadID: String,
            isTerminalAssistantCommit: Bool,
            memoryService: (any MemoryServing)?,
            extractionContext: MemoryExtractionContext?
        ) -> ExtractionIntent? {
            guard isTerminalAssistantCommit,
                  message.role == .assistant,
                  !message.content.isEmpty,
                  memoryService != nil,
                  let extractionContext else {
                return nil
            }
            return ExtractionIntent(
                threadID: threadID,
                threadLogicalID: extractionContext.threadLogicalID,
                messageID: message.id,
                scope: extractionContext.scope,
                promptVersion: extractionContext.promptVersion,
                idempotencyKey: MemoryExtraction.idempotencyKey(
                    threadLogicalID: extractionContext.threadLogicalID,
                    messageID: message.id,
                    promptVersion: extractionContext.promptVersion
                )
            )
        }

        func createChatThread(id: String, at date: Date) async throws -> String {
            try await dbQueue.write { db in
                try Self.upsertChatThread(id, at: date, db: db)
            }
            return id
        }

        func chatThreadExists(id: String) async throws -> Bool {
            try await dbQueue.read { db in
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(1) FROM chat_threads WHERE id = ?",
                    arguments: [id]
                ) ?? 0
                return count > 0
            }
        }

        func fetchMostRecentChatThreadID() async throws -> String? {
            try await dbQueue.read { db in
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

        func fetchChatThreadSummaries(searchQuery: String = "", limit: Int = 80) async throws -> [ChatThreadSummary] {
            let normalizedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            return try await dbQueue.read { db in
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

                    let messageCount: Int = row["messageCount"] ?? 0
                    let lastMessageAt = OpenBurnBarDatabase.parseDateValue(row["lastMessageAt"])
                    let firstUserMessage = (row["firstUserMessage"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let lastMessageContent = (row["lastMessageContent"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    let titleSource = (firstUserMessage?.isEmpty == false) ? firstUserMessage! : "BurnBar Chat"
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

        func fetchChatMessages(threadID: String? = nil) async throws -> [ChatMessageRecord] {
            try await dbQueue.read { db in
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

        /// E1 (citation jump): resolve the owning thread for a `chat_messages.id`.
        ///
        /// Memory recall is app-wide (no thread predicate, `recallChatMemorySnippets`),
        /// so a citation's `messageID` very often points at a row in a *different*
        /// thread than the one currently open. The chat UI uses this to open the
        /// owning thread before scrolling to the cited row. Returns `nil` when the
        /// id is unknown (e.g. the source was hard-deleted), so the caller can fail
        /// closed rather than navigate to nothing.
        func threadID(forChatMessageID messageID: String) async throws -> String? {
            try await dbQueue.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT threadId FROM chat_messages WHERE id = ?",
                    arguments: [messageID]
                )
            }
        }

        func deleteAllChatMessages() async throws {
            try await dbQueue.write { db in
                try db.execute(sql: "DELETE FROM chat_messages")
                try db.execute(sql: "DELETE FROM chat_threads")
                let now = Date()
                try db.execute(
                    sql: "INSERT INTO chat_threads (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                    arguments: [OpenBurnBarDatabase.legacyChatThreadID, now, now]
                )
            }
        }
}
