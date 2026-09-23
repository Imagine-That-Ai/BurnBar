import XCTest
import GRDB
import OpenBurnBarAssistantModels
import OpenBurnBarCore
@testable import OpenBurnBar
import OpenBurnBarData

/// Wave 2.1 chat single-writer cutover: the app builds typed daemon RPC
/// requests instead of writing `chat_threads` / `chat_messages` directly.
///
/// These tests pin the exact app→daemon mapping (roles, transcript pieces,
/// attachment passthrough, ISO timestamps, `replace: true` re-save
/// semantics), prove the local test double round-trips records identically to
/// the old local path, and prove a failed write leaves no local rows behind.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
@MainActor
final class ChatSingleWriterCutoverTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(writer: any ChatHistoryWriter) throws -> DataStoreCoordinator {
        let queue = try DatabaseQueue()
        return try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            chatWriter: writer
        )
    }

    private func parseISO8601(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return try XCTUnwrap(formatter.date(from: raw), "store must emit ISO 8601 timestamps the daemon can parse")
    }

    // MARK: - Append mapping

    func testSaveMapsRecordToAppendRequest() async throws {
        let writer = RecordingChatHistoryWriter()
        let store = try makeStore(writer: writer)
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000.123)
        let message = ChatMessageRecord(
            id: "msg-map-1",
            role: .assistant,
            content: "Mapped content.",
            timestamp: timestamp,
            cliUsed: "claude",
            transcriptPieces: [
                ChatTranscriptPiece(id: "p1", kind: .text, value: "Hello ", detail: nil),
                ChatTranscriptPiece(id: "p2", kind: .toolUse, value: "Read", detail: "{\"path\":\"a.ts\"}")
            ],
            attachments: [
                OpenBurnBarAssistantModels.HermesAttachment(
                    id: "att-1",
                    kind: .image,
                    displayName: "shot.png",
                    mimeType: "image/png",
                    byteSize: 42,
                    workspaceRelativePath: "shots/shot.png",
                    extractedTextPreview: "preview"
                )
            ]
        )

        try await store.saveChatMessage(message, threadID: "thread-map-1")

        let request = try XCTUnwrap(writer.appends.first, "save must issue exactly one append")
        XCTAssertEqual(writer.appends.count, 1)
        XCTAssertEqual(request.threadID, "thread-map-1")
        XCTAssertEqual(request.messageID, "msg-map-1")
        XCTAssertEqual(request.role, .assistant)
        XCTAssertEqual(request.content, "Mapped content.")
        XCTAssertEqual(request.backendID, "claude", "cliUsed rides the backendID field into the daemon's cliUsed column")
        XCTAssertTrue(request.replace, "app saves always set replace (INSERT OR REPLACE re-save semantics)")
        XCTAssertNil(request.attachments, "the app never sends typed attachments — only the opaque blob")
        XCTAssertEqual(
            try parseISO8601(request.timestamp).timeIntervalSince1970,
            timestamp.timeIntervalSince1970,
            accuracy: 0.001,
            "ISO timestamp must round-trip to the same millisecond"
        )

        let pieces = try XCTUnwrap(request.transcriptPieces)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0], BurnBarChatTranscriptPiece(id: "p1", kind: .text, value: "Hello ", detail: nil))
        XCTAssertEqual(pieces[1], BurnBarChatTranscriptPiece(id: "p2", kind: .toolUse, value: "Read", detail: "{\"path\":\"a.ts\"}"))

        // The blob is opaque to the daemon (stored verbatim), so the contract is
        // semantic round-trip, not byte equality — JSONEncoder key order is
        // not stable across calls.
        let roundTripped = try XCTUnwrap(
            OpenBurnBarDatabase.decodeChatAttachments(request.appAttachmentsJSON),
            "passthrough blob must decode with the production decoder"
        )
        XCTAssertEqual(roundTripped, message.attachments, "attachments ride the opaque passthrough unchanged")
    }

    func testAllRolesAndPieceKindsMap() async throws {
        let writer = RecordingChatHistoryWriter()
        let store = try makeStore(writer: writer)

        for role in [ChatMessageRole.user, .assistant, .system] {
            try await store.saveChatMessage(
                ChatMessageRecord(id: "msg-\(role)", role: role, content: "x"),
                threadID: "t"
            )
        }
        try await store.saveChatMessage(
            ChatMessageRecord(
                id: "msg-pieces",
                role: .assistant,
                content: "tools",
                transcriptPieces: [
                    ChatTranscriptPiece(id: "k1", kind: .text, value: "a"),
                    ChatTranscriptPiece(id: "k2", kind: .reasoning, value: "b"),
                    ChatTranscriptPiece(id: "k3", kind: .refusal, value: "c"),
                    ChatTranscriptPiece(id: "k4", kind: .toolUse, value: "d"),
                    ChatTranscriptPiece(id: "k5", kind: .toolResult, value: "e")
                ]
            ),
            threadID: "t"
        )

        XCTAssertEqual(writer.appends.map(\.role), [.user, .assistant, .system, .assistant])
        let kinds = try XCTUnwrap(writer.appends.last?.transcriptPieces).map(\.kind)
        XCTAssertEqual(kinds, [.text, .reasoning, .refusal, .toolUse, .toolResult])
    }

    func testEmptyPiecesAndAttachmentsEncodeAsNil() async throws {
        let writer = RecordingChatHistoryWriter()
        let store = try makeStore(writer: writer)

        try await store.saveChatMessage(
            ChatMessageRecord(role: .user, content: "plain"),
            threadID: "t"
        )

        let request = try XCTUnwrap(writer.appends.first)
        XCTAssertNil(request.transcriptPieces, "empty pieces must stay NULL, matching the old local path")
        XCTAssertNil(request.appAttachmentsJSON, "empty attachments must stay NULL, matching the old local path")
    }

    // MARK: - Create mapping

    func testCreateThreadIssuesCreateRequest() async throws {
        let writer = RecordingChatHistoryWriter()
        let store = try makeStore(writer: writer)
        let date = Date(timeIntervalSince1970: 1_750_000_100.456)

        let returned = try await store.createChatThread(id: "thread-new-1", at: date)

        XCTAssertEqual(returned, "thread-new-1")
        let request = try XCTUnwrap(writer.creates.first)
        XCTAssertEqual(request.threadID, "thread-new-1")
        XCTAssertEqual(
            try parseISO8601(request.createdAt).timeIntervalSince1970,
            date.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    // MARK: - Local double equivalence

    func testLocalDoubleRoundTripsRecord() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            chatWriter: LocalChatHistoryWriter(dbQueue: queue)
        )
        let timestamp = Date(timeIntervalSince1970: 1_750_000_200.789)
        let message = ChatMessageRecord(
            id: "msg-rt-1",
            role: .assistant,
            content: "Round trip.",
            timestamp: timestamp,
            cliUsed: "codex",
            transcriptPieces: [ChatTranscriptPiece(id: "p1", kind: .toolResult, value: "out", detail: "d")],
            attachments: [
                OpenBurnBarAssistantModels.HermesAttachment(
                    id: "att-rt",
                    kind: .textDocument,
                    displayName: "notes.md",
                    mimeType: "text/markdown",
                    byteSize: 7,
                    workspaceRelativePath: "notes.md"
                )
            ]
        )

        _ = try await store.createChatThread(id: "thread-rt-1", at: timestamp)
        try await store.saveChatMessage(message, threadID: "thread-rt-1")
        // Re-save under the same ID (streaming placeholder → final shape).
        var evolved = message
        evolved.content = "Round trip, final."
        try await store.saveChatMessage(evolved, threadID: "thread-rt-1")

        let fetched = try await store.fetchChatMessages(threadID: "thread-rt-1")
        XCTAssertEqual(fetched.count, 1, "re-save under one ID must replace, not duplicate")
        let row = try XCTUnwrap(fetched.first)
        XCTAssertEqual(row.id, message.id)
        XCTAssertEqual(row.role, .assistant)
        XCTAssertEqual(row.content, "Round trip, final.")
        XCTAssertEqual(row.timestamp.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(row.cliUsed, "codex")
        XCTAssertEqual(row.transcriptPieces.count, 1)
        XCTAssertEqual(row.transcriptPieces.first?.kind, .toolResult)
        XCTAssertEqual(row.attachments.count, 1)
        XCTAssertEqual(row.attachments.first?.displayName, "notes.md")
        let threadExists = try await store.chatThreadExists(id: "thread-rt-1")
        XCTAssertTrue(threadExists)
    }

    // MARK: - Fail closed

    func testFailedWriteLeavesNoLocalRows() async throws {
        let queue = try DatabaseQueue()
        let store = try DataStoreCoordinator(
            databaseQueue: queue,
            runMigrations: true,
            chatWriter: ThrowingChatHistoryWriter()
        )

        do {
            try await store.saveChatMessage(ChatMessageRecord(role: .user, content: "x"), threadID: "t")
            XCTFail("a throwing writer must propagate the failure")
        } catch is ThrowingChatHistoryWriter.Boom {
        }
        do {
            _ = try await store.createChatThread(id: "t")
            XCTFail("a throwing writer must propagate the failure")
        } catch is ThrowingChatHistoryWriter.Boom {
        }

        let counts = try await queue.read { db -> (Int, Int) in
            let messages = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM chat_messages") ?? -1
            let threads = try Int.fetchOne(db, sql: "SELECT COUNT(1) FROM chat_threads") ?? -1
            return (messages, threads)
        }
        // The migrator seeds the legacy thread row; the failed writes must add nothing.
        XCTAssertEqual(counts.0, 0, "no message row may land when the write fails")
        XCTAssertEqual(counts.1, 1, "only the migrator-seeded legacy thread may exist")
    }
}
