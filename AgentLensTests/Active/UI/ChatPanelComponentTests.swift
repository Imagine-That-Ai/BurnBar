import XCTest
import SwiftUI
import ViewInspector
import GRDB
@testable import OpenBurnBar

// MARK: - ChatPanelComponentTests

@MainActor
final class ChatPanelComponentTests: XCTestCase {

    // MARK: - ChatSearchResultsList

    func test_searchResultsList_rendersEmptyWhenNoResults() throws {
        let view = ChatSearchResultsList(results: [], onSelect: { _ in })
        let sut = try view.inspect()
        let buttons = try? sut.findAll(ViewType.Button.self)
        XCTAssertTrue(buttons?.isEmpty ?? true, "Should not render buttons when no results")
    }

    func test_searchResultsList_rendersResults() throws {
        let conversation = makeConversationRecord(id: "s-1", provider: .factory, title: "Refactor auth")
        let result = SearchResult(
            conversation: conversation,
            snippet: "Authentication logic needs <b>cleanup</b>",
            rank: 0.95
        )
        let view = ChatSearchResultsList(results: [result], onSelect: { _ in })
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 1, "Should render one button per result")
    }

    // MARK: - ChatConversationJumpSection

    func test_conversationJumpSection_rendersEmptyWhenNoTargets() throws {
        let view = ChatConversationJumpSection(targets: [], onJump: { _ in })
        let sut = try view.inspect()
        let buttons = try? sut.findAll(ViewType.Button.self)
        XCTAssertTrue(buttons?.isEmpty ?? true, "Should not render buttons when no targets")
    }

    func test_conversationJumpSection_rendersTargets() throws {
        let conversation = makeConversationRecord(id: "s-2", provider: .claudeCode, title: "Fix routing")
        let target = ConversationJumpTarget(
            conversation: conversation,
            snippet: "Routing bug in main module",
            startOffset: 0,
            endOffset: 10,
            source: .retrieval
        )
        let view = ChatConversationJumpSection(targets: [target], onJump: { _ in })
        let sut = try view.inspect()
        let buttons = try sut.findAll(ViewType.Button.self)
        XCTAssertEqual(buttons.count, 1, "Should render one button per target")
    }

    // MARK: - ChatInlineContextRibbon

    func test_inlineContextRibbon_rendersWhereLeftOff() throws {
        let controller = try makeMinimalChatController()
        let brief = ViewTestFixtures.makeInsightBrief(whereLeftOff: "Working on auth module")
        let view = ChatInlineContextRibbon(controller: controller, brief: brief)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_inlineContextRibbon_rendersHeaviestTask() throws {
        let controller = try makeMinimalChatController()
        let brief = ViewTestFixtures.makeInsightBrief(
            heaviestTaskTitle: "Auth refactor",
            heaviestTaskCost: 2.50,
            heaviestTaskProject: "OpenBurnBar"
        )
        let view = ChatInlineContextRibbon(controller: controller, brief: brief)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_chatMessagesStream_rendersRowsWithStreamingLengthObservation() throws {
        let controller = try makeMinimalChatController()
        let settingsManager = makeSettingsManager()
        settingsManager.conversationIndexingEnabled = false
        controller.messages = [
            ViewTestFixtures.makeUserMessage(content: "Question"),
            ViewTestFixtures.makeAssistantMessage(content: "Answer")
        ]
        let view = ChatMessagesStream(
            controller: controller,
            settingsManager: settingsManager,
            maxContentWidth: 760,
            onJumpToConversation: { _ in }
        )

        XCTAssertNoThrow(try view.inspect())
    }

    func test_chatMessagesStream_rendersEmptySearchState() throws {
        let controller = try makeMinimalChatController()
        let settingsManager = makeSettingsManager()
        controller.searchQuery = "missing"
        controller.searchResults = []
        controller.isSearching = false
        let view = ChatMessagesStream(
            controller: controller,
            settingsManager: settingsManager,
            maxContentWidth: 760,
            onJumpToConversation: { _ in }
        )

        let sut = try view.inspect()
        XCTAssertNoThrow(try sut.find(textWhere: { value, _ in value.contains("No indexed sessions matched") }))
    }

    // MARK: - Helpers

    private func makeConversationRecord(id: String, provider: AgentProvider, title: String) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: id,
            projectName: "TestProject",
            startTime: Date(),
            endTime: Date(),
            messageCount: 10,
            userWordCount: 50,
            assistantWordCount: 100,
            keyFiles: [],
            keyCommands: [],
            keyTools: [],
            inferredTaskTitle: title,
            lastAssistantMessage: "Test message",
            fullText: "Full conversation text",
            fileModifiedAt: Date()
        )
    }

    private func makeMinimalChatController() throws -> ChatSessionController {
        let store = try XCTUnwrap(try? DataStoreCoordinator(databaseQueue: DatabaseQueue(), refreshOnInit: false))
        return ChatSessionController(dataStore: store)
    }

    // MARK: - ChatTranscriptLayout (transcript render hoists)

    /// The trailing-assistant scan was hoisted out of `ForEach` because running
    /// it per row made rendering O(n^2). Pin the result so the hoist cannot
    /// silently change which row gets the trailing affordances.
    func test_latestAssistantID_picksTheTrailingAssistantMessage() {
        let messages = [
            ChatMessageRecord(role: .user, content: "first"),
            ChatMessageRecord(role: .assistant, content: "older reply"),
            ChatMessageRecord(role: .user, content: "second"),
            ChatMessageRecord(role: .assistant, content: "newest reply")
        ]
        XCTAssertEqual(
            ChatTranscriptLayout.latestAssistantID(in: messages, isStreaming: false),
            messages[3].id
        )
    }

    /// While a reply is streaming no row is "the latest assistant" — the
    /// affordances must stay suppressed until the reply settles.
    func test_latestAssistantID_isNilWhileStreaming() {
        let messages = [
            ChatMessageRecord(role: .user, content: "q"),
            ChatMessageRecord(role: .assistant, content: "partial")
        ]
        XCTAssertNil(ChatTranscriptLayout.latestAssistantID(in: messages, isStreaming: true))
    }

    func test_latestAssistantID_isNilWithNoAssistantMessages() {
        let messages = [ChatMessageRecord(role: .user, content: "only user")]
        XCTAssertNil(ChatTranscriptLayout.latestAssistantID(in: messages, isStreaming: false))
        XCTAssertNil(ChatTranscriptLayout.latestAssistantID(in: [], isStreaming: false))
    }

    /// Swapping `String.count` for `utf8.count` is only safe because both grow
    /// monotonically as text is appended, so the tail-scroll notification fires
    /// on exactly the same appends. Assert that on multi-byte and grapheme-cluster
    /// content, where the two counts differ in value but must agree in direction.
    func test_tailScrollTriggerKey_growsMonotonicallyOnAppendLikeCharacterCount() {
        let appends = ["", "h", "hi", "hi ", "hi 👋", "hi 👋 é", "hi 👋 é 家", "hi 👋 é 家!"]
        var previousKey = -1
        var previousCount = -1
        for text in appends {
            let key = ChatTranscriptLayout.tailScrollTriggerKey(for: text)
            let count = text.count
            XCTAssertGreaterThanOrEqual(key, previousKey, "utf8 trigger key must never shrink on append: \(text)")
            XCTAssertGreaterThanOrEqual(count, previousCount)
            if count > previousCount {
                XCTAssertGreaterThan(key, previousKey, "an appended grapheme must still move the trigger: \(text)")
            }
            previousKey = key
            previousCount = count
        }
        XCTAssertEqual(ChatTranscriptLayout.tailScrollTriggerKey(for: nil), 0)
    }

}
