import Foundation
import OpenBurnBarCore
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

private let chatSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class BurnBarChatSQLiteConnection {
    let raw: OpaquePointer

    init(raw: OpaquePointer) {
        self.raw = raw
    }

    deinit {
        sqlite3_close_v2(raw)
    }
}

public protocol BurnBarChatThreadServing: Sendable {
    func listThreads(_ request: BurnBarChatThreadListRequest) async throws -> BurnBarChatThreadListResponse
    func getThread(_ request: BurnBarChatThreadGetRequest) async throws -> BurnBarChatThreadGetResponse
    func appendMessage(_ request: BurnBarChatMessageAppendRequest) async throws -> BurnBarChatMessageAppendResponse
}

enum BurnBarChatThreadServiceError: Error, LocalizedError {
    case invalidRequest(String)
    case conflict(String)
    case unavailable(String)
    case corruptData(String)
    case database(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let detail):
            return "Invalid chat request: \(detail)"
        case .conflict(let detail):
            return "Chat history conflict: \(detail)"
        case .unavailable(let detail):
            return "Chat history unavailable: \(detail)"
        case .corruptData(let detail):
            return "Chat history contains invalid data: \(detail)"
        case .database(let detail):
            return "Chat history database failed: \(detail)"
        }
    }
}

actor BurnBarChatThreadService: BurnBarChatThreadServing {
    static let maxListLimit = 100
    static let maxGetMessages = 500
    static let maxIdentifierBytes = 256
    static let maxQueryBytes = 512
    static let maxAppendContentBytes = 48 * 1024
    static let maxStoredContentBytes = 256 * 1024
    static let maxResponseContentBytes = 2 * 1024 * 1024
    static let maxBackendIDBytes = 64
    static let maxAttachmentCount = 8
    static let maxAttachmentIDBytes = 128

    private enum BindValue {
        case text(String)
        case integer(Int64)
        case double(Double)
        case null
    }

    private let connection: BurnBarChatSQLiteConnection
    private let logger: BurnBarDaemonLogger
    private var db: OpaquePointer { connection.raw }

    init(databasePath: String, logger: BurnBarDaemonLogger = BurnBarDaemonLogger(category: "chat-thread-store")) throws {
        let path = databasePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.isEmpty == false else {
            throw BurnBarChatThreadServiceError.unavailable("the database path is empty")
        }

        let databaseURL = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw BurnBarChatThreadServiceError.unavailable(
                "database directory could not be created: \(error.localizedDescription)"
            )
        }

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let detail = opened.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:))
                ?? "SQLite open returned code \(result)"
            if let opened { sqlite3_close_v2(opened) }
            throw BurnBarChatThreadServiceError.unavailable(detail)
        }

        do {
            try BurnBarDaemonDatabaseCipher.applyKeyIfAvailable(to: opened)
            guard sqlite3_busy_timeout(opened, 5_000) == SQLITE_OK else {
                throw Self.sqliteError(db: opened, operation: "configure busy timeout")
            }
            try Self.ensureCanonicalSchema(db: opened)
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }

        self.connection = BurnBarChatSQLiteConnection(raw: opened)
        self.logger = logger
    }

    func listThreads(_ request: BurnBarChatThreadListRequest) throws -> BurnBarChatThreadListResponse {
        guard (1...Self.maxListLimit).contains(request.limit) else {
            throw BurnBarChatThreadServiceError.invalidRequest(
                "limit must be between 1 and \(Self.maxListLimit)"
            )
        }
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard query.utf8.count <= Self.maxQueryBytes else {
            throw BurnBarChatThreadServiceError.invalidRequest(
                "query exceeds \(Self.maxQueryBytes) UTF-8 bytes"
            )
        }

        var sql = Self.threadSummarySelect
        var bindings: [BindValue] = []
        if query.isEmpty == false {
            sql += """

             WHERE EXISTS (
                SELECT 1
                FROM chat_messages sm
                WHERE sm.threadId = t.id
                  AND lower(sm.content) LIKE ? ESCAPE '\\'
            )
            """
            bindings.append(.text("%\(Self.escapeLike(query.lowercased()))%"))
        }
        sql += """

         GROUP BY t.id, t.createdAt, t.updatedAt
         HAVING COUNT(m.id) > 0
         ORDER BY COALESCE(MAX(m.timestamp), t.updatedAt, t.createdAt) DESC
         LIMIT ?
        """
        bindings.append(.integer(Int64(request.limit)))

        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var threads: [BurnBarChatThreadSummary] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw sqliteError(operation: "list chat threads")
            }
            threads.append(try summary(from: statement))
        }
        return BurnBarChatThreadListResponse(threads: threads)
    }

    func getThread(_ request: BurnBarChatThreadGetRequest) throws -> BurnBarChatThreadGetResponse {
        let threadID = try Self.validatedIdentifier(request.threadID, field: "threadID")
        guard (1...Self.maxGetMessages).contains(request.maxMessages) else {
            throw BurnBarChatThreadServiceError.invalidRequest(
                "maxMessages must be between 1 and \(Self.maxGetMessages)"
            )
        }
        let cursor: (timestamp: String, messageID: String)?
        switch (request.beforeTimestamp, request.beforeMessageID) {
        case (nil, nil):
            cursor = nil
        case let (timestamp?, messageID?):
            let parsedTimestamp = try Self.parseRequestTimestamp(timestamp)
            cursor = (
                timestamp: Self.grdbStorageTimestamp(parsedTimestamp),
                messageID: try Self.validatedIdentifier(messageID, field: "beforeMessageID")
            )
        default:
            throw BurnBarChatThreadServiceError.invalidRequest(
                "beforeTimestamp and beforeMessageID must be supplied together"
            )
        }
        guard let thread = try fetchSummary(threadID: threadID) else {
            return BurnBarChatThreadGetResponse(thread: nil, messages: [], hasMoreBefore: false)
        }

        let pagePredicate: String
        var pageBindings: [BindValue] = [.text(threadID)]
        if let cursor {
            pagePredicate = "threadId = ? AND (timestamp < ? OR (timestamp = ? AND id < ?))"
            pageBindings += [.text(cursor.timestamp), .text(cursor.timestamp), .text(cursor.messageID)]
        } else {
            pagePredicate = "threadId = ?"
        }

        let countStatement = try prepare(
            "SELECT COUNT(1) FROM chat_messages WHERE \(pagePredicate)",
            bindings: pageBindings
        )
        defer { sqlite3_finalize(countStatement) }
        guard sqlite3_step(countStatement) == SQLITE_ROW else {
            throw sqliteError(operation: "count chat messages")
        }
        let totalCount = Int(sqlite3_column_int64(countStatement, 0))

        let statement = try prepare(
            """
            SELECT id, threadId, role, content, timestamp, cliUsed, attachmentsJSON
            FROM (
                SELECT id, threadId, role, content, timestamp, cliUsed, attachmentsJSON
                FROM chat_messages
                WHERE \(pagePredicate)
                ORDER BY timestamp DESC, id DESC
                LIMIT ?
            )
            ORDER BY timestamp ASC, id ASC
            """,
            bindings: pageBindings + [.integer(Int64(request.maxMessages))]
        )
        defer { sqlite3_finalize(statement) }

        var messages: [BurnBarChatMessage] = []
        var responseContentBytes = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw sqliteError(operation: "load chat messages")
            }
            let message = try message(from: statement)
            let contentBytes = message.content.utf8.count
            guard contentBytes <= Self.maxStoredContentBytes else {
                throw BurnBarChatThreadServiceError.corruptData(
                    "message '\(message.id)' exceeds \(Self.maxStoredContentBytes) UTF-8 bytes"
                )
            }
            responseContentBytes += contentBytes
            guard responseContentBytes <= Self.maxResponseContentBytes else {
                throw BurnBarChatThreadServiceError.corruptData(
                    "thread '\(threadID)' exceeds the bounded response budget"
                )
            }
            messages.append(message)
        }

        return BurnBarChatThreadGetResponse(
            thread: thread,
            messages: messages,
            hasMoreBefore: totalCount > messages.count
        )
    }

    func appendMessage(_ request: BurnBarChatMessageAppendRequest) throws -> BurnBarChatMessageAppendResponse {
        let threadID = try Self.validatedIdentifier(request.threadID, field: "threadID")
        let messageID = try Self.validatedIdentifier(request.messageID, field: "messageID")
        guard request.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BurnBarChatThreadServiceError.invalidRequest("content must not be blank")
        }
        guard request.content.utf8.count <= Self.maxAppendContentBytes else {
            throw BurnBarChatThreadServiceError.invalidRequest(
                "content exceeds \(Self.maxAppendContentBytes) UTF-8 bytes"
            )
        }
        let timestamp = try Self.parseRequestTimestamp(request.timestamp)
        let backendID = try Self.validatedBackendID(request.backendID)
        let attachments = try Self.validatedAttachments(request.attachments)
        let canonicalMessage = BurnBarChatMessage(
            id: messageID,
            threadID: threadID,
            role: request.role,
            content: request.content,
            timestamp: Self.iso8601(timestamp),
            backendID: backendID,
            attachments: attachments
        )

        try execute("BEGIN IMMEDIATE")
        var committed = false
        defer {
            if committed == false {
                try? execute("ROLLBACK")
            }
        }

        if let existing = try fetchMessage(messageID: messageID) {
            guard Self.messagesAreEquivalent(existing, canonicalMessage) else {
                throw BurnBarChatThreadServiceError.conflict(
                    "messageID '\(messageID)' already belongs to different content or thread"
                )
            }
            try execute("COMMIT")
            committed = true
            return BurnBarChatMessageAppendResponse(message: existing, inserted: false)
        }

        // Store timestamps in GRDB's default `Date` text representation
        // ("yyyy-MM-dd HH:mm:ss.SSS", UTC) — the exact format the macOS app
        // writes through GRDB. SQLite orders storage classes before values,
        // so writing REAL here would rank every Linux row after (or before)
        // all macOS TEXT rows in `ORDER BY timestamp` / `MAX(timestamp)`,
        // scrambling mixed macOS/Linux threads. Lexicographic order of this
        // fixed-width format is chronological, so text comparisons stay valid.
        let storedTimestamp = Self.grdbStorageTimestamp(timestamp)
        try execute(
            """
            INSERT INTO chat_threads (id, createdAt, updatedAt)
            VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                updatedAt = CASE
                    WHEN excluded.updatedAt > chat_threads.updatedAt THEN excluded.updatedAt
                    ELSE chat_threads.updatedAt
                END
            """,
            bindings: [.text(threadID), .text(storedTimestamp), .text(storedTimestamp)]
        )
        try execute(
            """
            INSERT INTO chat_messages (id, role, content, timestamp, cliUsed, threadId, attachmentsJSON)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(messageID),
                .text(request.role.rawValue),
                .text(request.content),
                .text(storedTimestamp),
                backendID.map(BindValue.text) ?? .null,
                .text(threadID),
                try Self.encodeAttachments(attachments).map(BindValue.text) ?? .null
            ]
        )
        try execute("COMMIT")
        committed = true
        logger.debug(
            "chat_message_appended",
            metadata: ["thread_id": threadID, "message_id": messageID, "role": request.role.rawValue]
        )
        return BurnBarChatMessageAppendResponse(message: canonicalMessage, inserted: true)
    }

    private func fetchSummary(threadID: String) throws -> BurnBarChatThreadSummary? {
        let statement = try prepare(
            Self.threadSummarySelect + """

             WHERE t.id = ?
             GROUP BY t.id, t.createdAt, t.updatedAt
             LIMIT 1
            """,
            bindings: [.text(threadID)]
        )
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw sqliteError(operation: "load chat thread summary")
        }
        return try summary(from: statement)
    }

    private func fetchMessage(messageID: String) throws -> BurnBarChatMessage? {
        let statement = try prepare(
            "SELECT id, threadId, role, content, timestamp, cliUsed, attachmentsJSON FROM chat_messages WHERE id = ? LIMIT 1",
            bindings: [.text(messageID)]
        )
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw sqliteError(operation: "load existing chat message")
        }
        return try message(from: statement)
    }

    private func summary(from statement: OpaquePointer) throws -> BurnBarChatThreadSummary {
        let id = try requiredText(statement, column: 0, field: "thread.id")
        let createdAt = try requiredDate(statement, column: 1, field: "thread.createdAt")
        let updatedAt = try requiredDate(statement, column: 2, field: "thread.updatedAt")
        let messageCount = Int(sqlite3_column_int64(statement, 3))
        let lastMessageAt = try optionalDate(statement, column: 4, field: "thread.lastMessageAt")
        let firstUserMessage = optionalText(statement, column: 5)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let lastMessageContent = optionalText(statement, column: 6)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let backendID = optionalText(statement, column: 7)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleSource = firstUserMessage?.isEmpty == false ? firstUserMessage! : "Burn Bar Chat"
        let previewSource = lastMessageContent?.isEmpty == false ? lastMessageContent! : titleSource
        return BurnBarChatThreadSummary(
            id: id,
            title: Self.compactSnippet(titleSource, limit: 84),
            preview: Self.compactSnippet(previewSource, limit: 180),
            messageCount: messageCount,
            createdAt: Self.iso8601(createdAt),
            updatedAt: Self.iso8601(updatedAt),
            lastMessageAt: lastMessageAt.map(Self.iso8601),
            backendID: backendID?.isEmpty == false ? backendID : nil
        )
    }

    private func message(from statement: OpaquePointer) throws -> BurnBarChatMessage {
        let id = try requiredText(statement, column: 0, field: "message.id")
        let threadID = try requiredText(statement, column: 1, field: "message.threadID")
        let rawRole = try requiredText(statement, column: 2, field: "message.role")
        guard let role = BurnBarChatMessageRole(rawValue: rawRole) else {
            throw BurnBarChatThreadServiceError.corruptData(
                "message '\(id)' has unsupported role '\(rawRole)'"
            )
        }
        let content = try requiredText(statement, column: 3, field: "message.content")
        let timestamp = try requiredDate(statement, column: 4, field: "message.timestamp")
        let backendID = optionalText(statement, column: 5)
        let attachments = try Self.decodeAttachments(
            optionalText(statement, column: 6),
            messageID: id
        )
        return BurnBarChatMessage(
            id: id,
            threadID: threadID,
            role: role,
            content: content,
            timestamp: Self.iso8601(timestamp),
            backendID: backendID,
            attachments: attachments
        )
    }

    private func prepare(_ sql: String, bindings: [BindValue] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw sqliteError(operation: "prepare chat query")
        }
        do {
            try bind(bindings, to: statement)
        } catch {
            sqlite3_finalize(statement)
            throw error
        }
        return statement
    }

    private func bind(_ values: [BindValue], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, chatSQLiteTransient)
            case .integer(let integer):
                result = sqlite3_bind_int64(statement, index, integer)
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw sqliteError(operation: "bind chat query")
            }
        }
    }

    private func execute(_ sql: String, bindings: [BindValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError(operation: "execute chat statement")
        }
    }

    private func requiredText(_ statement: OpaquePointer, column: Int32, field: String) throws -> String {
        guard let value = optionalText(statement, column: column) else {
            throw BurnBarChatThreadServiceError.corruptData("\(field) is null")
        }
        return value
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(cString: text)
    }

    private func requiredDate(_ statement: OpaquePointer, column: Int32, field: String) throws -> Date {
        guard let date = try optionalDate(statement, column: column, field: field) else {
            throw BurnBarChatThreadServiceError.corruptData("\(field) is null")
        }
        return date
    }

    private func optionalDate(_ statement: OpaquePointer, column: Int32, field: String) throws -> Date? {
        let type = sqlite3_column_type(statement, column)
        if type == SQLITE_NULL { return nil }
        if type == SQLITE_INTEGER || type == SQLITE_FLOAT {
            let raw = sqlite3_column_double(statement, column)
            guard raw.isFinite else {
                throw BurnBarChatThreadServiceError.corruptData("\(field) is not finite")
            }
            return raw > 1_200_000_000
                ? Date(timeIntervalSince1970: raw)
                : Date(timeIntervalSinceReferenceDate: raw)
        }
        guard let raw = optionalText(statement, column: column),
              let parsed = Self.parseStoredTimestamp(raw) else {
            throw BurnBarChatThreadServiceError.corruptData("\(field) is not a recognized timestamp")
        }
        return parsed
    }

    private func sqliteError(operation: String) -> BurnBarChatThreadServiceError {
        Self.sqliteError(db: db, operation: operation)
    }

    private static func ensureCanonicalSchema(db: OpaquePointer) throws {
        try execute(db: db, sql: "BEGIN IMMEDIATE")
        var committed = false
        defer {
            if committed == false {
                try? execute(db: db, sql: "ROLLBACK")
            }
        }
        try execute(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS chat_messages (
                id TEXT PRIMARY KEY,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                timestamp DATETIME NOT NULL,
                cliUsed TEXT,
                transcriptPiecesJSON TEXT,
                threadId TEXT NOT NULL,
                attachmentsJSON TEXT
            )
            """
        )
        try execute(
            db: db,
            sql: """
            CREATE TABLE IF NOT EXISTS chat_threads (
                id TEXT PRIMARY KEY,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            )
            """
        )

        var messageColumns = try tableColumns(db: db, table: "chat_messages")
        if messageColumns.contains("attachmentsJSON") == false {
            try execute(
                db: db,
                sql: "ALTER TABLE chat_messages ADD COLUMN attachmentsJSON TEXT"
            )
            messageColumns.insert("attachmentsJSON")
        }
        let requiredMessageColumns: Set<String> = ["id", "role", "content", "timestamp", "cliUsed", "threadId", "attachmentsJSON"]
        let missingMessageColumns = requiredMessageColumns.subtracting(messageColumns)
        guard missingMessageColumns.isEmpty else {
            throw BurnBarChatThreadServiceError.unavailable(
                "chat_messages schema is missing: \(missingMessageColumns.sorted().joined(separator: ", "))"
            )
        }
        let threadColumns = try tableColumns(db: db, table: "chat_threads")
        let requiredThreadColumns: Set<String> = ["id", "createdAt", "updatedAt"]
        let missingThreadColumns = requiredThreadColumns.subtracting(threadColumns)
        guard missingThreadColumns.isEmpty else {
            throw BurnBarChatThreadServiceError.unavailable(
                "chat_threads schema is missing: \(missingThreadColumns.sorted().joined(separator: ", "))"
            )
        }

        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS chat_messages_thread_time_idx ON chat_messages(threadId, timestamp)"
        )
        try execute(
            db: db,
            sql: "CREATE INDEX IF NOT EXISTS chat_threads_updated_idx ON chat_threads(updatedAt DESC)"
        )
        // Earlier Linux daemon builds wrote REAL Unix timestamps while the
        // macOS app writes GRDB TEXT ("yyyy-MM-dd HH:mm:ss.SSS" UTC). SQLite
        // orders storage classes before values, so normalize any numeric rows
        // to the GRDB text format once, before the thread backfill below reads
        // MIN/MAX. `> 1200000000` mirrors the read-path heuristic separating
        // Unix-epoch values from timeIntervalSinceReferenceDate values.
        // No-op on macOS-written databases (already TEXT).
        for (table, columns) in [
            ("chat_messages", ["timestamp"]),
            ("chat_threads", ["createdAt", "updatedAt"])
        ] {
            for column in columns {
                try execute(
                    db: db,
                    sql: """
                    UPDATE \(table)
                    SET \(column) = strftime(
                        '%Y-%m-%d %H:%M:%f',
                        CASE WHEN \(column) > 1200000000 THEN \(column) ELSE \(column) + 978307200 END,
                        'unixepoch'
                    )
                    WHERE typeof(\(column)) IN ('integer', 'real')
                    """
                )
            }
        }
        try execute(
            db: db,
            sql: """
            INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt)
            SELECT threadId, MIN(timestamp), MAX(timestamp)
            FROM chat_messages
            GROUP BY threadId
            """
        )
        try execute(db: db, sql: "COMMIT")
        committed = true
    }

    private static func tableColumns(db: OpaquePointer, table: String) throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw sqliteError(db: db, operation: "inspect \(table) schema")
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw sqliteError(db: db, operation: "inspect \(table) schema")
            }
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    private static func execute(db: OpaquePointer, sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        if let errorPointer { sqlite3_free(errorPointer) }
        guard result == SQLITE_OK else {
            throw sqliteError(db: db, operation: "initialize chat schema")
        }
    }

    private static func sqliteError(db: OpaquePointer, operation: String) -> BurnBarChatThreadServiceError {
        let code = sqlite3_errcode(db)
        let detail = sqlite3_errmsg(db).map(String.init(cString:)) ?? "SQLite error \(code)"
        if code == SQLITE_BUSY || code == SQLITE_LOCKED {
            return .unavailable("\(operation) could not acquire the database lock")
        }
        return .database("\(operation) (SQLite \(code)): \(detail)")
    }

    private static func validatedIdentifier(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed == raw else {
            throw BurnBarChatThreadServiceError.invalidRequest("\(field) must be nonblank and trimmed")
        }
        guard raw.utf8.count <= maxIdentifierBytes else {
            throw BurnBarChatThreadServiceError.invalidRequest(
                "\(field) exceeds \(maxIdentifierBytes) UTF-8 bytes"
            )
        }
        guard raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw BurnBarChatThreadServiceError.invalidRequest("\(field) contains control characters")
        }
        return raw
    }

    private static func validatedBackendID(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard trimmed.utf8.count <= maxBackendIDBytes else {
            throw BurnBarChatThreadServiceError.invalidRequest(
                "backendID exceeds \(maxBackendIDBytes) UTF-8 bytes"
            )
        }
        guard trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) == false else {
            throw BurnBarChatThreadServiceError.invalidRequest("backendID contains control characters")
        }
        return trimmed
    }

    private static func validatedAttachments(
        _ raw: [BurnBarChatAttachmentMetadata]?
    ) throws -> [BurnBarChatAttachmentMetadata]? {
        guard let raw, raw.isEmpty == false else { return nil }
        guard raw.count <= maxAttachmentCount else {
            throw BurnBarChatThreadServiceError.invalidRequest(
                "attachments exceeds \(maxAttachmentCount) entries"
            )
        }

        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        var normalized: [BurnBarChatAttachmentMetadata] = []
        normalized.reserveCapacity(raw.count)
        for (index, attachment) in raw.enumerated() {
            let field = "attachments[\(index)]"
            let attachmentID = try validatedIdentifier(
                attachment.attachmentID,
                field: "\(field).attachmentId"
            )
            guard attachmentID.utf8.count <= maxAttachmentIDBytes else {
                throw BurnBarChatThreadServiceError.invalidRequest(
                    "\(field).attachmentId exceeds \(maxAttachmentIDBytes) UTF-8 bytes"
                )
            }

            let fileName = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard fileName == attachment.fileName,
                  BurnBarChatAttachmentPolicy.isSafeFileName(fileName) else {
                throw BurnBarChatThreadServiceError.invalidRequest(
                    "\(field).fileName is not a safe file name"
                )
            }
            guard attachment.byteSize > 0,
                  attachment.byteSize <= BurnBarChatAttachmentPolicy.maxBytes else {
                throw BurnBarChatThreadServiceError.invalidRequest(
                    "\(field).byteSize must be between 1 and \(BurnBarChatAttachmentPolicy.maxBytes)"
                )
            }

            let suppliedMimeType = attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let mimeType = BurnBarChatAttachmentPolicy.canonicalMimeType(
                fileName: fileName,
                mimeType: suppliedMimeType
            ) else {
                throw BurnBarChatThreadServiceError.invalidRequest(
                    "\(field).mimeType does not match the supported file type"
                )
            }

            let sha256 = attachment.sha256.lowercased()
            guard sha256.utf8.count == 64,
                  sha256.unicodeScalars.allSatisfy({ hexCharacters.contains($0) }) else {
                throw BurnBarChatThreadServiceError.invalidRequest(
                    "\(field).sha256 must be a SHA-256 hex digest"
                )
            }
            normalized.append(
                BurnBarChatAttachmentMetadata(
                    attachmentID: attachmentID,
                    fileName: fileName,
                    mimeType: mimeType,
                    byteSize: attachment.byteSize,
                    sha256: sha256
                )
            )
        }
        return normalized
    }

    private static func encodeAttachments(
        _ attachments: [BurnBarChatAttachmentMetadata]?
    ) throws -> String? {
        guard let attachments, attachments.isEmpty == false else { return nil }
        do {
            let data = try JSONEncoder().encode(attachments)
            guard let json = String(data: data, encoding: .utf8) else {
                throw BurnBarChatThreadServiceError.database("attachment metadata JSON is not UTF-8")
            }
            return json
        } catch let error as BurnBarChatThreadServiceError {
            throw error
        } catch {
            throw BurnBarChatThreadServiceError.database(
                "attachment metadata could not be encoded: \(error.localizedDescription)"
            )
        }
    }

    private static func decodeAttachments(
        _ raw: String?,
        messageID: String
    ) throws -> [BurnBarChatAttachmentMetadata]? {
        guard let raw else { return nil }
        guard raw.isEmpty == false,
              let data = raw.data(using: .utf8) else {
            throw BurnBarChatThreadServiceError.corruptData(
                "message '\(messageID)' has invalid attachment metadata"
            )
        }
        do {
            let decoded = try JSONDecoder().decode([BurnBarChatAttachmentMetadata].self, from: data)
            return try validatedAttachments(decoded)
        } catch let error as BurnBarChatThreadServiceError {
            switch error {
            case .invalidRequest(let detail):
                throw BurnBarChatThreadServiceError.corruptData(
                    "message '\(messageID)' has invalid attachment metadata: \(detail)"
                )
            default:
                throw error
            }
        } catch {
            throw BurnBarChatThreadServiceError.corruptData(
                "message '\(messageID)' has invalid attachment metadata: \(error.localizedDescription)"
            )
        }
    }

    private static func parseRequestTimestamp(_ raw: String) throws -> Date {
        guard let date = parseISO8601(raw) else {
            throw BurnBarChatThreadServiceError.invalidRequest("timestamp must be ISO 8601")
        }
        let earliest = Date(timeIntervalSince1970: 946_684_800)
        let latest = Date(timeIntervalSince1970: 4_102_444_800)
        guard date >= earliest, date <= latest else {
            throw BurnBarChatThreadServiceError.invalidRequest("timestamp must be between 2000 and 2100")
        }
        return date
    }

    private static func parseStoredTimestamp(_ raw: String) -> Date? {
        if let numeric = Double(raw), numeric.isFinite {
            return numeric > 1_200_000_000
                ? Date(timeIntervalSince1970: numeric)
                : Date(timeIntervalSinceReferenceDate: numeric)
        }
        if let iso = parseISO8601(raw) { return iso }
        for format in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }

    /// Mirrors GRDB's default `Date` storage representation (see the vendored
    /// `GRDB/Core/Support/Foundation/Date.swift` `storageDateFormatter`):
    /// "yyyy-MM-dd HH:mm:ss.SSS" in UTC, en_US_POSIX. The macOS app persists
    /// chat rows through GRDB, so Linux appends must write byte-compatible
    /// TEXT for mixed threads to sort as one storage class.
    private static let grdbStorageDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func grdbStorageTimestamp(_ date: Date) -> String {
        grdbStorageDateFormatter.string(from: date)
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func messagesAreEquivalent(_ lhs: BurnBarChatMessage, _ rhs: BurnBarChatMessage) -> Bool {
        guard let lhsDate = parseISO8601(lhs.timestamp), let rhsDate = parseISO8601(rhs.timestamp) else {
            return false
        }
        return lhs.id == rhs.id
            && lhs.threadID == rhs.threadID
            && lhs.role == rhs.role
            && lhs.content == rhs.content
            && lhs.backendID == rhs.backendID
            && lhs.attachments == rhs.attachments
            && abs(lhsDate.timeIntervalSince1970 - rhsDate.timeIntervalSince1970) < 0.001
    }

    private static func escapeLike(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func compactSnippet(_ raw: String, limit: Int) -> String {
        let compact = raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit - 1)) + "…"
    }

    private static let threadSummarySelect = """
    SELECT
        t.id,
        t.createdAt,
        t.updatedAt,
        COUNT(m.id),
        MAX(m.timestamp),
        (
            SELECT um.content
            FROM chat_messages um
            WHERE um.threadId = t.id
              AND um.role = 'user'
              AND TRIM(um.content) != ''
            ORDER BY um.timestamp ASC, um.id ASC
            LIMIT 1
        ),
        (
            SELECT lm.content
            FROM chat_messages lm
            WHERE lm.threadId = t.id
              AND TRIM(lm.content) != ''
            ORDER BY lm.timestamp DESC, lm.id DESC
            LIMIT 1
        ),
        (
            SELECT bm.cliUsed
            FROM chat_messages bm
            WHERE bm.threadId = t.id
              AND bm.cliUsed IS NOT NULL
              AND TRIM(bm.cliUsed) != ''
            ORDER BY bm.timestamp DESC, bm.id DESC
            LIMIT 1
        )
    FROM chat_threads t
    LEFT JOIN chat_messages m ON m.threadId = t.id
    """
}
