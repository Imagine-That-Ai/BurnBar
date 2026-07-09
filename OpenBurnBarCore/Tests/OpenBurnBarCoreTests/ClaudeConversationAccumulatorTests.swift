import XCTest
@testable import OpenBurnBarCore

final class ClaudeConversationAccumulatorTests: XCTestCase {
    func test_truncatesFormattedTranscriptAtByteCap() {
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

    func test_preservesCredentialSnippetAfterFullTextCap() {
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
        XCTAssertGreaterThan(acc.assistantWordCount, 0)
    }
}
