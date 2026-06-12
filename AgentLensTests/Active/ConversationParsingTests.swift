import XCTest
import GRDB
@testable import OpenBurnBar

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

    func test_claudeAccumulator_handles_plain_string_message_content() {
        let acc = ClaudeConversationAccumulator()
        let userLine: [String: Any] = [
            "type": "user",
            "timestamp": "2026-03-24T21:31:40.365Z",
            "message": [
                "role": "user",
                "content": "hey fuck face if it isnt obvious your job is to go look"
            ]
        ]
        let assistantLine: [String: Any] = [
            "type": "assistant",
            "timestamp": "2026-03-24T21:32:00.000Z",
            "message": [
                "role": "assistant",
                "content": "I checked the logs and found the issue.",
                "usage": [
                    "input_tokens": 12,
                    "output_tokens": 9
                ]
            ]
        ]

        acc.ingest(jsonLine: userLine)
        acc.ingest(jsonLine: assistantLine)
        acc.finalizeArrays()

        XCTAssertTrue(acc.fullText.contains("hey fuck face"))
        XCTAssertTrue(acc.lastAssistantText.contains("found the issue"))
        XCTAssertEqual(acc.messageCount, 2)
        XCTAssertGreaterThan(acc.userWordCount, 5)
        XCTAssertGreaterThan(acc.assistantWordCount, 3)
        XCTAssertTrue(acc.fullText.contains("## You"))
        XCTAssertTrue(acc.fullText.contains("## Assistant"))
        let blocks = TranscriptBlockParser.parse(acc.fullText)
        XCTAssertEqual(blocks.filter { $0.kind == .userMessage }.count, 1)
        XCTAssertEqual(blocks.filter { $0.kind == .assistantMessage }.count, 1)
    }

    func test_conversationIndexer_skips_same_mtime() async throws {
        let store = try makeInMemoryStore()
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = makeFactoryConversationRecord(
            id: "Factory:test-session-1",
            indexedAt: Date(),
            fileModifiedAt: past
        )
        try store.upsertConversation(rec)
        try await ConversationIndexer.shared.index([rec], in: store)
        let row = try store.fetchConversation(id: rec.id)
        XCTAssertNotNil(row)
    }

    func test_conversationIndexer_skips_mtime_precision_drift_underOneMillisecond() async throws {
        let store = try makeInMemoryStore()
        let indexedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000.123)
        let stored = makeFactoryConversationRecord(
            id: "Factory:test-session-precision",
            indexedAt: indexedAt,
            fileModifiedAt: mtime
        )
        try store.upsertConversation(stored)

        let incoming = makeFactoryConversationRecord(
            id: stored.id,
            indexedAt: indexedAt.addingTimeInterval(300),
            fileModifiedAt: mtime.addingTimeInterval(0.0006)
        )
        try await ConversationIndexer.shared.index([incoming], in: store)

        guard let row = try store.fetchConversation(id: stored.id) else {
            XCTFail("Expected existing conversation row.")
            return
        }
        XCTAssertEqual(row.indexedAt.timeIntervalSince1970, indexedAt.timeIntervalSince1970, accuracy: 0.0001)
    }

    func test_conversationIndexer_skips_unchanged_payload_when_fileModifiedAt_nil() async throws {
        let store = try makeInMemoryStore()
        let indexedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let stored = makeFactoryConversationRecord(
            id: "Factory:test-session-nil-mtime",
            indexedAt: indexedAt,
            fileModifiedAt: nil
        )
        try store.upsertConversation(stored)

        let incoming = makeFactoryConversationRecord(
            id: stored.id,
            indexedAt: indexedAt.addingTimeInterval(600),
            fileModifiedAt: nil
        )
        try await ConversationIndexer.shared.index([incoming], in: store)

        guard let row = try store.fetchConversation(id: stored.id) else {
            XCTFail("Expected existing conversation row.")
            return
        }
        XCTAssertEqual(row.indexedAt.timeIntervalSince1970, indexedAt.timeIntervalSince1970, accuracy: 0.0001)
    }

    func test_fetchConversationsNeedingSummary_throttles_recent_failed_attempts() throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_010_000)
        let record = makeFactoryConversationRecord(
            id: "Factory:test-summary-throttle",
            indexedAt: base,
            fileModifiedAt: base
        )
        try store.upsertConversation(record)

        let beforeAttempt = try store.fetchConversationsNeedingSummary(
            limit: 10,
            now: base,
            retryCooldown: 3_600
        )
        XCTAssertTrue(beforeAttempt.contains(where: { $0.id == record.id }))

        try store.markConversationSummaryAttempt(id: record.id, attemptedAt: base.addingTimeInterval(10))

        let withinCooldown = try store.fetchConversationsNeedingSummary(
            limit: 10,
            now: base.addingTimeInterval(60),
            retryCooldown: 3_600
        )
        XCTAssertFalse(withinCooldown.contains(where: { $0.id == record.id }))

        let afterCooldown = try store.fetchConversationsNeedingSummary(
            limit: 10,
            now: base.addingTimeInterval(3_700),
            retryCooldown: 3_600
        )
        XCTAssertTrue(afterCooldown.contains(where: { $0.id == record.id }))
    }

    func test_fetchConversationsNeedingSummary_allows_immediate_retry_when_content_changes() throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_020_000)
        let id = "Factory:test-summary-content-change"

        let original = makeFactoryConversationRecord(
            id: id,
            indexedAt: base,
            fileModifiedAt: base
        )
        try store.upsertConversation(original)
        try store.markConversationSummaryAttempt(id: id, attemptedAt: base.addingTimeInterval(10))

        let updated = makeFactoryConversationRecord(
            id: id,
            indexedAt: base.addingTimeInterval(30),
            fileModifiedAt: base.addingTimeInterval(30)
        )
        try store.upsertConversation(updated)

        let pending = try store.fetchConversationsNeedingSummary(
            limit: 10,
            now: base.addingTimeInterval(40),
            retryCooldown: 3_600
        )
        XCTAssertTrue(pending.contains(where: { $0.id == id }))
    }

    private func makeInMemoryStore() throws -> DataStore {
        let queue = try DatabaseQueue(path: ":memory:")
        return try DataStore(databaseQueue: queue, runMigrations: true, refreshOnInit: false)
    }

    private func makeFactoryConversationRecord(
        id: String,
        indexedAt: Date,
        fileModifiedAt: Date?
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .factory,
            sessionId: "test-session-1",
            projectName: "Demo",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_000),
            messageCount: 2,
            userWordCount: 3,
            assistantWordCount: 4,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Hello",
            lastAssistantMessage: "Done",
            fullText: "Hello\n\nDone",
            indexedAt: indexedAt,
            fileModifiedAt: fileModifiedAt,
            summary: nil
        )
    }

}
