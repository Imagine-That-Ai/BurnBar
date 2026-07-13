import XCTest
@testable import OpenBurnBarCore

final class BurnBarChatThreadContractsTests: XCTestCase {
    func testExactThreadContractsRoundTripWithStableWireKeys() throws {
        let message = BurnBarChatMessage(
            id: "message-a",
            threadID: "thread-a",
            role: .assistant,
            content: "Durable reply",
            timestamp: "2026-07-10T12:00:00.000Z",
            backendID: "codex"
        )
        let response = BurnBarChatThreadGetResponse(
            thread: BurnBarChatThreadSummary(
                id: "thread-a",
                title: "Question",
                preview: "Durable reply",
                messageCount: 2,
                createdAt: "2026-07-10T11:59:00.000Z",
                updatedAt: "2026-07-10T12:00:00.000Z",
                lastMessageAt: "2026-07-10T12:00:00.000Z",
                backendID: "codex"
            ),
            messages: [message],
            hasMoreBefore: true
        )

        let data = try JSONEncoder().encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["threadID"] as? String, "thread-a")
        XCTAssertEqual(messages.first?["backendID"] as? String, "codex")
        XCTAssertEqual(object["hasMoreBefore"] as? Bool, true)
        XCTAssertEqual(try JSONDecoder().decode(BurnBarChatThreadGetResponse.self, from: data), response)
    }

    func testAppendRequestPinsCallerGeneratedIdempotencyKey() throws {
        let request = BurnBarChatMessageAppendRequest(
            threadID: "thread-b",
            messageID: "message-b",
            role: .user,
            content: "Keep this on thread B",
            timestamp: "2026-07-10T12:01:00Z",
            backendID: "claude"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(BurnBarChatMessageAppendRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(BurnBarRPCMethod.chatMessageAppend.rawValue, "daemon.chat.message.append")
    }

    func testAttachmentMetadataUsesPathFreeStableWireKeys() throws {
        let metadata = BurnBarChatAttachmentMetadata(
            attachmentID: "upload-1",
            fileName: "notes.md",
            mimeType: "text/markdown",
            byteSize: 42,
            sha256: String(repeating: "a", count: 64)
        )
        let request = BurnBarChatMessageAppendRequest(
            threadID: "thread-attachments",
            messageID: "message-attachments",
            role: .user,
            content: "See attached notes",
            timestamp: "2026-07-10T12:01:00Z",
            attachments: [metadata]
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let attachments = try XCTUnwrap(object["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.first?["attachmentId"] as? String, "upload-1")
        XCTAssertNil(attachments.first?["path"])
        XCTAssertEqual(try JSONDecoder().decode(BurnBarChatMessageAppendRequest.self, from: data), request)
    }

    func testThreadGetCursorRoundTripsWithStableWireKeys() throws {
        let request = BurnBarChatThreadGetRequest(
            threadID: "thread-c",
            maxMessages: 50,
            beforeTimestamp: "2026-07-10T12:00:00.000Z",
            beforeMessageID: "message-c"
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["threadID"] as? String, "thread-c")
        XCTAssertEqual(object["maxMessages"] as? Int, 50)
        XCTAssertEqual(object["beforeTimestamp"] as? String, "2026-07-10T12:00:00.000Z")
        XCTAssertEqual(object["beforeMessageID"] as? String, "message-c")
        XCTAssertEqual(try JSONDecoder().decode(BurnBarChatThreadGetRequest.self, from: data), request)
    }
}
