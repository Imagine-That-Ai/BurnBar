import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

private struct ConversationFetchFailure: Error {}

/// Covers the click-time resolver that turns an inbox evidence citation into a
/// Session Logs jump target: phrase highlighting with UTF-8-correct offsets,
/// the tail-window fallback, snippet capping, and the missing-record paths.
@MainActor
final class InboxConversationJumpResolverTests: XCTestCase {

    private func makeRecord(id: String = "conv-1", fullText: String) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: .claudeCode,
            sessionId: "sess-1",
            projectName: "BurnBar",
            startTime: nil,
            endTime: nil,
            messageCount: 3,
            userWordCount: 10,
            assistantWordCount: 20,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: "Task",
            lastAssistantMessage: "Done.",
            fullText: fullText,
            fileModifiedAt: nil
        )
    }

    // MARK: - Resolution

    func testJumpTargetIsNilWhenTheConversationIsNoLongerIndexed() async {
        let resolver = InboxConversationJumpResolver { _ in nil }
        let target = await resolver.jumpTarget(conversationID: "conv-gone")
        XCTAssertNil(target)
    }

    func testJumpTargetIsNilWhenTheFetchThrows() async {
        let resolver = InboxConversationJumpResolver { _ in throw ConversationFetchFailure() }
        let target = await resolver.jumpTarget(conversationID: "conv-1")
        XCTAssertNil(target)
    }

    func testJumpTargetHighlightsThePhraseAndUsesRetrievalSource() async throws {
        let text = "aaaa SHIPPED bbbb"
        let record = makeRecord(fullText: text)
        let resolver = InboxConversationJumpResolver { id in
            XCTAssertEqual(id, "conv-1")
            return record
        }

        let resolved = await resolver.jumpTarget(conversationID: "conv-1", highlighting: "shipped")

        let target = try XCTUnwrap(resolved)
        XCTAssertEqual(target.conversation.id, "conv-1")
        XCTAssertEqual(target.startOffset, 5)
        XCTAssertEqual(target.endOffset, 12)
        XCTAssertEqual(target.snippet, "SHIPPED")
        XCTAssertEqual(target.source, .retrieval)
    }

    func testJumpTargetFallsBackToTheTailWhenNoPhraseIsGiven() async throws {
        let text = "The agent explained its plan. The final answer landed here."
        let record = makeRecord(fullText: text)
        let resolver = InboxConversationJumpResolver { _ in record }

        let resolved = await resolver.jumpTarget(conversationID: "conv-1")

        let target = try XCTUnwrap(resolved)
        XCTAssertEqual(target.startOffset, 0, "a short transcript's tail window is the whole transcript")
        XCTAssertEqual(target.endOffset, text.utf8.count)
        XCTAssertEqual(target.snippet, text)
    }

    // MARK: - Range selection

    func testBestRangeUsesUTF8ByteOffsets() {
        // Two emoji and a space: 4 + 4 + 1 = 9 bytes before the phrase.
        let text = "\u{1F525}\u{1F525} shipped"
        let range = InboxConversationJumpResolver.bestRange(in: text, highlighting: "SHIPPED")
        XCTAssertEqual(range, 9..<16)
    }

    func testBestRangeFallsBackToTheTailWindowForLongTranscripts() {
        let text = String(repeating: "a", count: 2_000)
        let range = InboxConversationJumpResolver.bestRange(in: text, highlighting: nil)
        XCTAssertEqual(range, (2_000 - InboxConversationJumpResolver.tailWindowBytes)..<2_000)
    }

    func testBestRangeIgnoresAMissingPhraseAndUsesTheTail() {
        let text = String(repeating: "b", count: 100)
        let range = InboxConversationJumpResolver.bestRange(in: text, highlighting: "absent phrase")
        XCTAssertEqual(range, 0..<100)
    }

    func testBestRangeTreatsAnEmptyPhraseLikeNoPhrase() {
        let text = "outcome"
        let range = InboxConversationJumpResolver.bestRange(in: text, highlighting: "")
        XCTAssertEqual(range, 0..<text.utf8.count)
    }

    func testBestRangeOnEmptyTextIsEmpty() {
        XCTAssertEqual(InboxConversationJumpResolver.bestRange(in: "", highlighting: "anything"), 0..<0)
    }

    // MARK: - Snippets

    func testSnippetCapsAtTheMaximumByteBudget() {
        let text = String(repeating: "a", count: 2_000)
        let snippet = InboxConversationJumpResolver.snippet(from: text, range: 0..<2_000)
        XCTAssertEqual(snippet.utf8.count, InboxConversationJumpResolver.maxSnippetBytes)
    }

    func testSnippetTrimsSurroundingWhitespace() {
        let text = "  The outcome.  \n"
        let snippet = InboxConversationJumpResolver.snippet(from: text, range: 0..<text.utf8.count)
        XCTAssertEqual(snippet, "The outcome.")
    }

    func testSnippetClampsOutOfBoundsRanges() {
        XCTAssertEqual(InboxConversationJumpResolver.snippet(from: "abc", range: 10..<20), "")
        XCTAssertEqual(InboxConversationJumpResolver.snippet(from: "abc", range: 1..<99), "bc")
        XCTAssertEqual(InboxConversationJumpResolver.snippet(from: "", range: 0..<0), "")
    }
}
