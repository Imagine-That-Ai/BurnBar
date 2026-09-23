import Foundation
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
import OpenBurnBarData

// MARK: - Local chat history writer (test double)
//
// Wave 2.1: production chat writes go through the daemon (single writer,
// ADR-005). Tests that need a working chat store without a live daemon inject
// this double, which performs the exact pre-cutover local semantics — upsert
// the thread row, then `INSERT OR REPLACE` the message row — against the test
// queue. Test files are exempt from the dual-writer grep, so the legacy SQL
// lives here and only here.

final class LocalChatHistoryWriter: ChatHistoryWriter {
    private let dbQueue: any DatabaseWriter

    init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    func appendMessage(_ request: BurnBarChatMessageAppendRequest) async throws {
        let timestamp = try Self.parseISO8601(request.timestamp)
        let piecesJSON = try Self.encodePieces(request.transcriptPieces)
        let attachmentsJSON = try Self.encodeAttachments(
            typed: request.attachments,
            passthrough: request.appAttachmentsJSON
        )
        try await dbQueue.write { db in
            try Self.upsertThread(request.threadID, at: timestamp, db: db)
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO chat_messages (id, threadId, role, content, timestamp, cliUsed, transcriptPiecesJSON, attachmentsJSON)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    request.messageID,
                    request.threadID,
                    request.role.rawValue,
                    request.content,
                    timestamp,
                    request.backendID,
                    piecesJSON,
                    attachmentsJSON
                ]
            )
        }
    }

    func createThread(_ request: BurnBarChatThreadCreateRequest) async throws {
        let createdAt = try Self.parseISO8601(request.createdAt)
        try await dbQueue.write { db in
            try Self.upsertThread(request.threadID, at: createdAt, db: db)
        }
    }

    // MARK: - Legacy local semantics (pre-cutover `upsertChatThread` + encoders)

    private static func upsertThread(_ threadID: String, at timestamp: Date, db: Database) throws {
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

    private static func parseISO8601(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) {
            return date
        }
        throw LocalChatHistoryWriterError.invalidTimestamp(raw)
    }

    /// Map back to the app piece type and reuse the production encoder, so the
    /// stored JSON is byte-identical to the pre-cutover local path.
    private static func encodePieces(_ pieces: [BurnBarChatTranscriptPiece]?) throws -> String? {
        guard let pieces, pieces.isEmpty == false else { return nil }
        let appPieces = pieces.map { piece in
            ChatTranscriptPiece(
                id: piece.id,
                kind: ChatTranscriptPiece.Kind(rawValue: piece.kind.rawValue) ?? .text,
                value: piece.value,
                detail: piece.detail
            )
        }
        return try OpenBurnBarDatabase.encodeTranscriptPieces(appPieces)
    }

    /// The daemon stores the app blob verbatim when present and JSON-encodes
    /// typed metadata otherwise; mirror both so gateway-shaped requests round
    /// through the double the same way.
    private static func encodeAttachments(
        typed: [BurnBarChatAttachmentMetadata]?,
        passthrough: String?
    ) throws -> String? {
        if let passthrough {
            return passthrough
        }
        guard let typed, typed.isEmpty == false else { return nil }
        let data = try JSONEncoder().encode(typed)
        return String(data: data, encoding: .utf8)
    }
}

enum LocalChatHistoryWriterError: Error {
    case invalidTimestamp(String)
}

/// Stands in for a daemon that is unreachable: every write throws, proving the
/// store fails closed (no local write, no extraction enqueue).
struct ThrowingChatHistoryWriter: ChatHistoryWriter {
    struct Boom: Error {}

    func appendMessage(_ request: BurnBarChatMessageAppendRequest) async throws {
        throw Boom()
    }

    func createThread(_ request: BurnBarChatThreadCreateRequest) async throws {
        throw Boom()
    }
}

/// Records the RPC requests the store issues, so cutover tests can assert the
/// exact app→daemon mapping without a live socket.
final class RecordingChatHistoryWriter: ChatHistoryWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var _appends: [BurnBarChatMessageAppendRequest] = []
    private var _creates: [BurnBarChatThreadCreateRequest] = []

    var appends: [BurnBarChatMessageAppendRequest] {
        lock.withLock { _appends }
    }

    var creates: [BurnBarChatThreadCreateRequest] {
        lock.withLock { _creates }
    }

    func appendMessage(_ request: BurnBarChatMessageAppendRequest) async throws {
        lock.withLock { _appends.append(request) }
    }

    func createThread(_ request: BurnBarChatThreadCreateRequest) async throws {
        lock.withLock { _creates.append(request) }
    }
}
