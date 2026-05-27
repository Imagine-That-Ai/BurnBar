import XCTest
@testable import OpenBurnBar

final class ChatStreamingMessageMutationTests: XCTestCase {

    func testChatMessageRecord_contentIsMutable() {
        var record = ChatMessageRecord(role: .assistant, content: "Hello")
        record.content.append(", world")
        XCTAssertEqual(record.content, "Hello, world")
    }

    func testChatMessageRecord_transcriptPiecesIsMutable() {
        var record = ChatMessageRecord(role: .assistant, content: "")
        record.transcriptPieces.append(ChatTranscriptPiece(kind: .text, value: "first"))
        record.transcriptPieces.append(ChatTranscriptPiece(kind: .text, value: " second"))
        XCTAssertEqual(record.transcriptPieces.count, 2)
    }

    func testChatMessageRecord_arrayMutationInPlace() {
        var records: [ChatMessageRecord] = [
            ChatMessageRecord(role: .user, content: "Q"),
            ChatMessageRecord(role: .assistant, content: "")
        ]
        records[1].content.append("partial answer")
        records[1].content.append(" more")
        XCTAssertEqual(records[1].content, "partial answer more")
    }

    func testChatMessageRecord_idsAreStableUnderContentMutation() {
        let originalID = "stable-id"
        var record = ChatMessageRecord(id: originalID, role: .assistant, content: "")
        record.content.append("chunk-1")
        record.content.append("chunk-2")
        XCTAssertEqual(record.id, originalID)
        XCTAssertEqual(record.content, "chunk-1chunk-2")
    }

    func testChatMessageRecord_otherFieldsRemainImmutable() {
        let timestamp = Date()
        var record = ChatMessageRecord(
            id: "x",
            role: .assistant,
            content: "",
            timestamp: timestamp,
            cliUsed: "claude",
            attachments: []
        )
        record.content = "streamed"
        XCTAssertEqual(record.role, .assistant)
        XCTAssertEqual(record.cliUsed, "claude")
        XCTAssertEqual(record.timestamp, timestamp)
    }
}
