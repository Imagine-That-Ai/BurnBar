import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

final class BurnBarChatThreadServiceTests: XCTestCase {
    func testExactThreadsPersistInCanonicalOrderAndSearchRealContent() async throws {
        let service = try makeService()
        let first = try await service.appendMessage(
            append(
                threadID: "thread-a",
                messageID: "a-user",
                role: .user,
                content: "How much did Codex cost?",
                timestamp: "2026-07-10T12:00:00.000Z",
                backendID: "codex"
            )
        )
        XCTAssertTrue(first.inserted)
        _ = try await service.appendMessage(
            append(
                threadID: "thread-a",
                messageID: "a-assistant",
                role: .assistant,
                content: "Codex cost twelve dollars.",
                timestamp: "2026-07-10T12:00:01.000Z",
                backendID: "codex"
            )
        )
        _ = try await service.appendMessage(
            append(
                threadID: "thread-b",
                messageID: "b-user",
                role: .user,
                content: "Literal 100% underscore_value search",
                timestamp: "2026-07-10T12:01:00.000Z",
                backendID: "claude"
            )
        )

        let list = try await service.listThreads(.init(limit: 40))
        XCTAssertEqual(list.threads.map(\.id), ["thread-b", "thread-a"])
        XCTAssertEqual(list.threads[1].title, "How much did Codex cost?")
        XCTAssertEqual(list.threads[1].preview, "Codex cost twelve dollars.")
        XCTAssertEqual(list.threads[1].messageCount, 2)
        XCTAssertEqual(list.threads[1].backendID, "codex")

        let percentSearch = try await service.listThreads(.init(query: "100%", limit: 40))
        XCTAssertEqual(percentSearch.threads.map(\.id), ["thread-b"])
        let underscoreSearch = try await service.listThreads(.init(query: "underscore_", limit: 40))
        XCTAssertEqual(underscoreSearch.threads.map(\.id), ["thread-b"])

        let threadA = try await service.getThread(.init(threadID: "thread-a", maxMessages: 20))
        XCTAssertEqual(threadA.thread?.id, "thread-a")
        XCTAssertEqual(threadA.messages.map(\.id), ["a-user", "a-assistant"])
        XCTAssertTrue(threadA.messages.allSatisfy { $0.threadID == "thread-a" })
        XCTAssertFalse(threadA.hasMoreBefore)

        let bounded = try await service.getThread(.init(threadID: "thread-a", maxMessages: 1))
        XCTAssertEqual(bounded.messages.map(\.id), ["a-assistant"])
        XCTAssertTrue(bounded.hasMoreBefore)
        let olderPage = try await service.getThread(
            .init(
                threadID: "thread-a",
                maxMessages: 1,
                beforeTimestamp: bounded.messages[0].timestamp,
                beforeMessageID: bounded.messages[0].id
            )
        )
        XCTAssertEqual(olderPage.messages.map(\.id), ["a-user"])
        XCTAssertFalse(olderPage.hasMoreBefore)
        let missing = try await service.getThread(.init(threadID: "thread-missing", maxMessages: 20))
        XCTAssertNil(missing.thread)
        XCTAssertEqual(missing.messages, [])
    }

    func testAppendRetryIsIdempotentAndConflictingReuseFails() async throws {
        let service = try makeService()
        let request = append(
            threadID: "thread-a",
            messageID: "stable-message-id",
            role: .user,
            content: "Persist this once",
            timestamp: "2026-07-10T12:00:00Z",
            backendID: "hermes"
        )
        let initial = try await service.appendMessage(request)
        XCTAssertTrue(initial.inserted)
        let retry = try await service.appendMessage(request)
        XCTAssertFalse(retry.inserted)
        XCTAssertEqual(retry.message.id, "stable-message-id")

        do {
            _ = try await service.appendMessage(
                append(
                    threadID: "thread-b",
                    messageID: "stable-message-id",
                    role: .user,
                    content: "Different message",
                    timestamp: "2026-07-10T12:00:00Z",
                    backendID: "hermes"
                )
            )
            XCTFail("Conflicting message IDs must fail instead of overwriting history")
        } catch BurnBarChatThreadServiceError.conflict {
            // Expected.
        }

        let threadA = try await service.getThread(.init(threadID: "thread-a"))
        XCTAssertEqual(threadA.messages.map(\.content), ["Persist this once"])
        let threadB = try await service.getThread(.init(threadID: "thread-b"))
        XCTAssertNil(threadB.thread)
    }

    func testCursorPaginationUsesMessageIDAsTieBreaker() async throws {
        let service = try makeService()
        let timestamp = "2026-07-10T12:00:00.000Z"
        _ = try await service.appendMessage(
            append(
                threadID: "thread-tied",
                messageID: "message-a",
                role: .user,
                content: "First at the same instant",
                timestamp: timestamp
            )
        )
        _ = try await service.appendMessage(
            append(
                threadID: "thread-tied",
                messageID: "message-b",
                role: .assistant,
                content: "Second at the same instant",
                timestamp: timestamp
            )
        )

        let newest = try await service.getThread(.init(threadID: "thread-tied", maxMessages: 1))
        XCTAssertEqual(newest.messages.map(\.id), ["message-b"])
        let previous = try await service.getThread(
            .init(
                threadID: "thread-tied",
                maxMessages: 1,
                beforeTimestamp: timestamp,
                beforeMessageID: "message-b"
            )
        )
        XCTAssertEqual(previous.messages.map(\.id), ["message-a"])
        XCTAssertFalse(previous.hasMoreBefore)
    }

    func testValidationRejectsUnboundedOrMalformedInputs() async throws {
        let service = try makeService()
        await assertInvalidRequest {
            _ = try await service.listThreads(.init(limit: 0))
        }
        await assertInvalidRequest {
            _ = try await service.getThread(.init(threadID: " thread-a"))
        }
        await assertInvalidRequest {
            _ = try await service.getThread(
                .init(
                    threadID: "thread-a",
                    beforeTimestamp: "2026-07-10T12:00:00Z"
                )
            )
        }
        await assertInvalidRequest {
            _ = try await service.appendMessage(
                self.append(
                    threadID: "thread-a",
                    messageID: "message-a",
                    role: .user,
                    content: "   ",
                    timestamp: "2026-07-10T12:00:00Z"
                )
            )
        }
        await assertInvalidRequest {
            _ = try await service.appendMessage(
                self.append(
                    threadID: "thread-a",
                    messageID: "message-a",
                    role: .user,
                    content: "valid",
                    timestamp: "not-a-date"
                )
            )
        }
        await assertInvalidRequest {
            _ = try await service.appendMessage(
                self.append(
                    threadID: "thread-a",
                    messageID: "message-a",
                    role: .user,
                    content: String(repeating: "x", count: BurnBarChatThreadService.maxAppendContentBytes + 1),
                    timestamp: "2026-07-10T12:00:00Z"
                )
            )
        }
    }

    func testChatRPCUsesTypedContractsAndUnavailableCode() async throws {
        let service = try makeService()
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            ),
            chatThreadService: service
        )
        let appendData = try await server.handleChatRPC(
            method: .chatMessageAppend,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"append-1","method":"daemon.chat.message.append","params":{"threadID":"thread-b","messageID":"message-b","role":"user","content":"Exact thread B","timestamp":"2026-07-10T12:00:00Z","backendID":"codex"}}"#.utf8
            )
        )
        let appendResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarChatMessageAppendResponse>.self,
            from: appendData
        )
        XCTAssertEqual(appendResponse.result?.message.threadID, "thread-b")
        XCTAssertEqual(appendResponse.result?.inserted, true)

        let unavailableServer = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                startsMissionControlBackgroundLoops: false
            )
        )
        let unavailableData = try await unavailableServer.handleChatRPC(
            method: .chatThreadList,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"list-1","method":"daemon.chat.thread.list","params":{"limit":40}}"#.utf8
            )
        )
        let unavailable = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarChatThreadListResponse>.self,
            from: unavailableData
        )
        XCTAssertNil(unavailable.result)
        XCTAssertEqual(unavailable.error?.code, BurnBarRPCErrorCode.unavailable)
    }

    func testChatMethodsHaveDedicatedCapabilityAndSocketDomain() {
        for method in [
            BurnBarRPCMethod.chatThreadList,
            .chatThreadGet,
            .chatMessageAppend
        ] {
            XCTAssertEqual(BurnBarRPCCapability.capability(for: method), .chat)
            XCTAssertEqual(BurnBarDaemonSocketRPCCoverage.domain(for: method), "chat")
        }
    }

    func testAppendedTimestampsUseGRDBTextFormatForMixedMacOSThreads() async throws {
        let databasePath = try makeDatabasePath()
        // Seed a macOS-written thread: the app persists chat rows through GRDB,
        // which stores `Date` as TEXT "yyyy-MM-dd HH:mm:ss.SSS" in UTC.
        try rawExecute(at: databasePath, Self.canonicalSchemaSQL + [
            """
            INSERT INTO chat_threads (id, createdAt, updatedAt)
            VALUES ('thread-mixed', '2026-07-10 12:00:00.000', '2026-07-10 12:00:00.000')
            """,
            """
            INSERT INTO chat_messages (id, role, content, timestamp, cliUsed, threadId)
            VALUES ('mac-user', 'user', 'From macOS', '2026-07-10 12:00:00.000', 'piAgent', 'thread-mixed')
            """
        ])

        let service = try BurnBarChatThreadService(databasePath: databasePath)
        _ = try await service.appendMessage(
            append(
                threadID: "thread-mixed",
                messageID: "linux-assistant",
                role: .assistant,
                content: "From Linux",
                timestamp: "2026-07-10T12:00:05.000Z",
                backendID: "hermes"
            )
        )

        // The appended row must land in GRDB's TEXT storage class; a REAL Unix
        // value would rank in a separate storage class from every macOS row in
        // ORDER BY / MAX(timestamp).
        let stored = try rawQuerySingle(
            at: databasePath,
            "SELECT typeof(timestamp) || '|' || timestamp FROM chat_messages WHERE id = 'linux-assistant'"
        )
        XCTAssertEqual(stored, "text|2026-07-10 12:00:05.000")

        let mixed = try await service.getThread(.init(threadID: "thread-mixed", maxMessages: 20))
        XCTAssertEqual(mixed.messages.map(\.id), ["mac-user", "linux-assistant"])
        let list = try await service.listThreads(.init(limit: 10))
        XCTAssertEqual(list.threads.first?.preview, "From Linux")
        XCTAssertEqual(
            try rawQuerySingle(
                at: databasePath,
                "SELECT typeof(updatedAt) || '|' || updatedAt FROM chat_threads WHERE id = 'thread-mixed'"
            ),
            "text|2026-07-10 12:00:05.000"
        )
    }

    func testLegacyNumericTimestampsAreNormalizedToGRDBText() async throws {
        let databasePath = try makeDatabasePath()
        // An earlier Linux build wrote REAL Unix timestamps; a macOS row in the
        // same thread is TEXT. 1783684800.0 == 2026-07-10T12:00:00Z.
        try rawExecute(at: databasePath, Self.canonicalSchemaSQL + [
            """
            INSERT INTO chat_messages (id, role, content, timestamp, cliUsed, threadId)
            VALUES ('legacy-numeric', 'user', 'Numeric row', 1783684800.0, NULL, 'thread-legacy')
            """,
            """
            INSERT INTO chat_messages (id, role, content, timestamp, cliUsed, threadId)
            VALUES ('text-later', 'assistant', 'Text row', '2026-07-10 12:00:05.000', NULL, 'thread-legacy')
            """
        ])

        let service = try BurnBarChatThreadService(databasePath: databasePath)
        XCTAssertEqual(
            try rawQuerySingle(
                at: databasePath,
                "SELECT COUNT(1) FROM chat_messages WHERE typeof(timestamp) != 'text'"
            ),
            "0"
        )
        XCTAssertEqual(
            try rawQuerySingle(
                at: databasePath,
                "SELECT timestamp FROM chat_messages WHERE id = 'legacy-numeric'"
            ),
            "2026-07-10 12:00:00.000"
        )
        let thread = try await service.getThread(.init(threadID: "thread-legacy", maxMessages: 20))
        XCTAssertEqual(thread.messages.map(\.id), ["legacy-numeric", "text-later"])
    }

    func testChatServiceCreatesDatabaseOnFreshProfile() async throws {
        let directory = try makeTemporaryDirectory()
        let databasePath = directory.appendingPathComponent("openburnbar.sqlite").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath))

        // A fresh profile has a configured index database path but no file yet.
        // The chat store opens with SQLITE_OPEN_CREATE, so the first chat must
        // create the database instead of returning unavailable forever.
        let server = BurnBarDaemonServer(
            configuration: BurnBarDaemonConfiguration(
                socketAuthToken: "test-token",
                indexDatabasePath: databasePath,
                startsMissionControlBackgroundLoops: false
            )
        )
        let appendData = try await server.handleChatRPC(
            method: .chatMessageAppend,
            decoder: JSONDecoder(),
            requestData: Data(
                #"{"id":"append-fresh","method":"daemon.chat.message.append","params":{"threadID":"thread-fresh","messageID":"message-fresh","role":"user","content":"First chat on a fresh profile","timestamp":"2026-07-10T12:00:00Z","backendID":"hermes"}}"#.utf8
            )
        )
        let appendResponse = try JSONDecoder().decode(
            BurnBarRPCResponseEnvelope<BurnBarChatMessageAppendResponse>.self,
            from: appendData
        )
        XCTAssertNil(appendResponse.error)
        XCTAssertEqual(appendResponse.result?.inserted, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath))
    }

    private static let canonicalSchemaSQL: [String] = [
        """
        CREATE TABLE chat_messages (
            id TEXT PRIMARY KEY,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp DATETIME NOT NULL,
            cliUsed TEXT,
            transcriptPiecesJSON TEXT,
            threadId TEXT NOT NULL,
            attachmentsJSON TEXT
        )
        """,
        """
        CREATE TABLE chat_threads (
            id TEXT PRIMARY KEY,
            createdAt DATETIME NOT NULL,
            updatedAt DATETIME NOT NULL
        )
        """
    ]

    private func makeService() throws -> BurnBarChatThreadService {
        try BurnBarChatThreadService(databasePath: try makeDatabasePath())
    }

    private func makeDatabasePath() throws -> String {
        try makeTemporaryDirectory().appendingPathComponent("openburnbar.sqlite").path
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-chat-thread-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func withRawConnection<T>(at path: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw BurnBarChatThreadServiceError.unavailable("test raw open failed for \(path)")
        }
        defer { sqlite3_close_v2(handle) }
        return try body(handle)
    }

    private func rawExecute(at path: String, _ statements: [String]) throws {
        try withRawConnection(at: path) { handle in
            for sql in statements {
                var errorPointer: UnsafeMutablePointer<CChar>?
                let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
                let detail = errorPointer.map { String(cString: $0) }
                if let errorPointer { sqlite3_free(errorPointer) }
                guard result == SQLITE_OK else {
                    throw BurnBarChatThreadServiceError.database(detail ?? "SQLite error \(result)")
                }
            }
        }
    }

    private func rawQuerySingle(at path: String, _ sql: String) throws -> String? {
        try withRawConnection(at: path) { handle in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw BurnBarChatThreadServiceError.database("test raw prepare failed: \(sql)")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let text = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: text)
        }
    }

    private func append(
        threadID: String,
        messageID: String,
        role: BurnBarChatMessageRole,
        content: String,
        timestamp: String,
        backendID: String? = nil
    ) -> BurnBarChatMessageAppendRequest {
        BurnBarChatMessageAppendRequest(
            threadID: threadID,
            messageID: messageID,
            role: role,
            content: content,
            timestamp: timestamp,
            backendID: backendID
        )
    }

    private func assertInvalidRequest(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected invalid request", file: file, line: line)
        } catch BurnBarChatThreadServiceError.invalidRequest {
            // Expected.
        } catch {
            XCTFail("Expected invalid request, got \(error)", file: file, line: line)
        }
    }
}
