import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

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

    func testValidationRejectsUnboundedOrMalformedInputs() async throws {
        let service = try makeService()
        await assertInvalidRequest {
            _ = try await service.listThreads(.init(limit: 0))
        }
        await assertInvalidRequest {
            _ = try await service.getThread(.init(threadID: " thread-a"))
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

    private func makeService() throws -> BurnBarChatThreadService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-chat-thread-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try BurnBarChatThreadService(
            databasePath: directory.appendingPathComponent("openburnbar.sqlite").path
        )
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
