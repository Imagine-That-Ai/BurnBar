import XCTest
@testable import BurnBar

@MainActor
final class ConversationParsingTests: XCTestCase {

    func test_claudeAccumulator_userTitle_and_assistantText() {
        let acc = ClaudeConversationAccumulator()
        let userLine: [String: Any] = [
            "type": "user",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": [
                "role": "user",
                "content": [
                    ["type": "text", "text": "Refactor the AuthService token refresh flow to use async/await."]
                ]
            ]
        ]
        let assistantLine: [String: Any] = [
            "type": "assistant",
            "timestamp": "2025-06-01T12:01:00Z",
            "message": [
                "role": "assistant",
                "content": [
                    ["type": "text", "text": "Here is the updated implementation with proper error boundaries."]
                ],
                "usage": [
                    "input_tokens": 100,
                    "output_tokens": 50
                ]
            ]
        ]
        acc.ingest(jsonLine: userLine)
        acc.ingest(jsonLine: assistantLine)
        acc.finalizeArrays()

        XCTAssertEqual(acc.firstUserText?.prefix(20), "Refactor the AuthSer")
        XCTAssertTrue(acc.lastAssistantText.contains("updated implementation"))
        XCTAssertGreaterThan(acc.userWordCount, 5)
        XCTAssertGreaterThan(acc.assistantWordCount, 3)
    }

    func test_claudeAccumulator_toolUse_paths_and_bash() {
        let acc = ClaudeConversationAccumulator()
        let toolLine: [String: Any] = [
            "type": "assistant",
            "timestamp": "2025-06-01T12:02:00Z",
            "message": [
                "role": "assistant",
                "content": [
                    [
                        "type": "tool_use",
                        "name": "Read",
                        "input": ["file_path": "/Users/dev/AuthService.swift"]
                    ],
                    [
                        "type": "tool_use",
                        "name": "Bash",
                        "input": ["command": "swift build"]
                    ]
                ],
                "usage": ["input_tokens": 1, "output_tokens": 1]
            ]
        ]
        acc.ingest(jsonLine: toolLine)
        acc.finalizeArrays()

        XCTAssertTrue(acc.keyFiles.contains("/Users/dev/AuthService.swift"))
        XCTAssertTrue(acc.keyCommands.contains("swift build"))
        XCTAssertTrue(acc.keyTools.contains("Read"))
        XCTAssertTrue(acc.keyTools.contains("Bash"))
    }

    func test_conversationIndexer_skips_same_mtime() throws {
        let store = DataStore()
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = ConversationRecord(
            id: "Factory:test-session-1",
            provider: .factory,
            sessionId: "test-session-1",
            projectName: "Demo",
            startTime: past,
            endTime: past,
            messageCount: 2,
            userWordCount: 3,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Hello",
            lastAssistantMessage: "Done",
            fullText: "Hello\n\nDone",
            indexedAt: Date(),
            fileModifiedAt: past,
            summary: nil
        )
        try store.upsertConversation(rec)
        try ConversationIndexer.shared.index([rec], in: store)
        let row = try store.fetchConversation(id: rec.id)
        XCTAssertNotNil(row)
    }
}
