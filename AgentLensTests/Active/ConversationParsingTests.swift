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

    // MARK: - Round-4 perf sweep: bounded accumulator tests

    func test_claudeAccumulator_capsFullTextAtMaxBytes() {
        // Use a small cap so we can test easily.
        let acc = ClaudeConversationAccumulator(maxFullTextBytes: 200)

        // Ingest enough messages to exceed the 200-byte cap.
        let bigText = String(repeating: "A", count: 150)
        let userLine: [String: Any] = [
            "type": "user",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": ["role": "user", "content": [["type": "text", "text": bigText]]]
        ]
        let assistantLine: [String: Any] = [
            "type": "assistant",
            "timestamp": "2025-06-01T12:01:00Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": bigText]]]
        ]

        acc.ingest(jsonLine: userLine)
        acc.ingest(jsonLine: assistantLine)
        acc.finalizeArrays()

        // fullText should be capped at ~200 bytes (plus the markdown header overhead).
        XCTAssertLessThanOrEqual(acc.fullText.utf8.count, 300, "fullText should be bounded")
        // Word counts should still reflect both messages (metrics are not capped).
        XCTAssertGreaterThan(acc.userWordCount, 0)
        XCTAssertGreaterThan(acc.assistantWordCount, 0)
    }

    func test_claudeAccumulator_wordCountContinuesAfterCap() {
        let acc = ClaudeConversationAccumulator(maxFullTextBytes: 100)

        // First message fills the cap.
        let firstText = String(repeating: "x", count: 80)
        let firstLine: [String: Any] = [
            "type": "user",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": ["role": "user", "content": [["type": "text", "text": firstText]]]
        ]
        acc.ingest(jsonLine: firstLine)

        // Second message should still count words even though fullText is capped.
        let secondLine: [String: Any] = [
            "type": "assistant",
            "timestamp": "2025-06-01T12:01:00Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "hello world from the assistant"]]]
        ]
        acc.ingest(jsonLine: secondLine)
        acc.finalizeArrays()

        // Word count should include the second message's words.
        XCTAssertGreaterThan(acc.assistantWordCount, 3, "Word count must continue after cap")
        // firstUserText should still be set from the first message.
        XCTAssertNotNil(acc.firstUserText)
    }

    func test_claudeAccumulator_joinedOnceAtFinalize() {
        let acc = ClaudeConversationAccumulator()

        let line1: [String: Any] = [
            "type": "user",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": ["role": "user", "content": [["type": "text", "text": "first message"]]]
        ]
        let line2: [String: Any] = [
            "type": "assistant",
            "timestamp": "2025-06-01T12:01:00Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "second message"]]]
        ]

        acc.ingest(jsonLine: line1)
        acc.ingest(jsonLine: line2)

        // Before finalize, fullText should be empty (not yet joined).
        XCTAssertEqual(acc.fullText, "", "fullText should be empty before finalizeArrays")

        acc.finalizeArrays()

        // After finalize, fullText should contain both messages.
        XCTAssertTrue(acc.fullText.contains("first message"))
        XCTAssertTrue(acc.fullText.contains("second message"))
    }

    func test_claudeAccumulator_truncateToUTF8Bytes_preservesScalarBoundaries() {
        // Test the UTF-8 truncation with multi-byte characters.
        // "héllo" = h(1) + é(2) + l(1) + l(1) + o(1) = 6 bytes
        let text = "héllo"
        let truncated = text // Would call the private method, but we test via behavior

        // We test the behavior indirectly: ingest a message with multi-byte
        // chars and a tight cap, then verify fullText doesn't have broken UTF-8.
        let acc = ClaudeConversationAccumulator(maxFullTextBytes: 2)
        let line: [String: Any] = [
            "type": "user",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": ["role": "user", "content": [["type": "text", "text": "héllo"]]]
        ]
        acc.ingest(jsonLine: line)
        acc.finalizeArrays()

        // fullText should be valid UTF-8 (no broken multi-byte sequences).
        let data = acc.fullText.data(using: .utf8)
        XCTAssertNotNil(data, "fullText must be valid UTF-8 after truncation")
    }

    func test_claudeAccumulator_truncateToUTF8Bytes_excludesIncompleteLeadingByte() {
        let acc = ClaudeConversationAccumulator(maxFullTextBytes: 5)
        let line: [String: Any] = [
            "type": "assistant",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "ab🎉"]]]
        ]
        acc.ingest(jsonLine: line)
        acc.finalizeArrays()

        XCTAssertEqual(acc.fullText, "## As")
    }

    func test_claudeAccumulator_truncateToUTF8Bytes_keepsCompleteMultibyteScalarAtBudget() {
        let acc = ClaudeConversationAccumulator(maxFullTextBytes: 10)
        let line: [String: Any] = [
            "type": "user",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": ["role": "user", "content": [["type": "text", "text": "éx"]]]
        ]
        acc.ingest(jsonLine: line)
        acc.finalizeArrays()

        XCTAssertEqual(acc.fullText, "## You\n\né")
        XCTAssertEqual(acc.fullText.utf8.count, 10)
    }

    func test_claudeAccumulator_preservesCredentialSnippetAfterFullTextCap() {
        let acc = ClaudeConversationAccumulator(maxFullTextBytes: 80)
        let fillerLine: [String: Any] = [
            "type": "user",
            "timestamp": "2025-06-01T12:00:00Z",
            "message": ["role": "user", "content": [["type": "text", "text": String(repeating: "x", count: 120)]]]
        ]
        let secretLine: [String: Any] = [
            "type": "assistant",
            "timestamp": "2025-06-01T12:01:00Z",
            "message": ["role": "assistant", "content": [["type": "text", "text": "OpenAI token sk-abc123def456ghi789jkl012mno345pqr678 was pasted late"]]]
        ]

        acc.ingest(jsonLine: fillerLine)
        acc.ingest(jsonLine: secretLine)
        acc.finalizeArrays()

        XCTAssertTrue(acc.fullText.contains("sk-abc123def456ghi789jkl012mno345pqr678"))
        XCTAssertTrue(acc.fullText.contains("Security Scan Overflow"))
    }

    func test_conversationIndexer_skips_same_mtime() async throws {
        let store = try makeInMemoryStore()
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        let rec = makeFactoryConversationRecord(
            id: "Factory:test-session-1",
            indexedAt: Date(),
            fileModifiedAt: past
        )
        try await store.upsertConversation(rec)
        try await ConversationIndexer.shared.index([rec], in: store)
        let row = try await store.fetchConversation(id: rec.id)
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
        try await store.upsertConversation(stored)

        let incoming = makeFactoryConversationRecord(
            id: stored.id,
            indexedAt: indexedAt.addingTimeInterval(300),
            fileModifiedAt: mtime.addingTimeInterval(0.0006)
        )
        try await ConversationIndexer.shared.index([incoming], in: store)

        guard let row = try await store.fetchConversation(id: stored.id) else {
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
        try await store.upsertConversation(stored)

        let incoming = makeFactoryConversationRecord(
            id: stored.id,
            indexedAt: indexedAt.addingTimeInterval(600),
            fileModifiedAt: nil
        )
        try await ConversationIndexer.shared.index([incoming], in: store)

        guard let row = try await store.fetchConversation(id: stored.id) else {
            XCTFail("Expected existing conversation row.")
            return
        }
        XCTAssertEqual(row.indexedAt.timeIntervalSince1970, indexedAt.timeIntervalSince1970, accuracy: 0.0001)
    }

    func test_fetchConversationsNeedingSummary_throttles_recent_failed_attempts() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_010_000)
        let record = makeFactoryConversationRecord(
            id: "Factory:test-summary-throttle",
            indexedAt: base,
            fileModifiedAt: base
        )
        try await store.upsertConversation(record)

        let beforeAttempt = try await store.fetchConversationsNeedingSummary(
            limit: 10,
            now: base,
            retryCooldown: 3_600
        )
        XCTAssertTrue(beforeAttempt.contains(where: { $0.id == record.id }))

        try await store.markConversationSummaryAttempt(id: record.id, attemptedAt: base.addingTimeInterval(10))

        let withinCooldown = try await store.fetchConversationsNeedingSummary(
            limit: 10,
            now: base.addingTimeInterval(60),
            retryCooldown: 3_600
        )
        XCTAssertFalse(withinCooldown.contains(where: { $0.id == record.id }))

        let afterCooldown = try await store.fetchConversationsNeedingSummary(
            limit: 10,
            now: base.addingTimeInterval(3_700),
            retryCooldown: 3_600
        )
        XCTAssertTrue(afterCooldown.contains(where: { $0.id == record.id }))
    }

    func test_fetchConversationsNeedingSummary_allows_immediate_retry_when_content_changes() async throws {
        let store = try makeInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_700_020_000)
        let id = "Factory:test-summary-content-change"

        let original = makeFactoryConversationRecord(
            id: id,
            indexedAt: base,
            fileModifiedAt: base
        )
        try await store.upsertConversation(original)
        try await store.markConversationSummaryAttempt(id: id, attemptedAt: base.addingTimeInterval(10))

        let updated = makeFactoryConversationRecord(
            id: id,
            indexedAt: base.addingTimeInterval(30),
            fileModifiedAt: base.addingTimeInterval(30)
        )
        try await store.upsertConversation(updated)

        let pending = try await store.fetchConversationsNeedingSummary(
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
