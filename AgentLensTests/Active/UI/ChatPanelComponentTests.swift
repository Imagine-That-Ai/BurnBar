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
        let controller = makeMinimalChatController()
        let brief = ViewTestFixtures.makeInsightBrief(whereLeftOff: "Working on auth module")
        let view = ChatInlineContextRibbon(controller: controller, brief: brief)
        XCTAssertNoThrow(try view.inspect())
    }

    func test_inlineContextRibbon_rendersHeaviestTask() throws {
        let controller = makeMinimalChatController()
        let brief = ViewTestFixtures.makeInsightBrief(
            heaviestTaskTitle: "Auth refactor",
            heaviestTaskCost: 2.50,
            heaviestTaskProject: "OpenBurnBar"
        )
        let view = ChatInlineContextRibbon(controller: controller, brief: brief)
        XCTAssertNoThrow(try view.inspect())
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

    private func makeMinimalChatController() -> ChatSessionController {
        let store = try! DataStoreCoordinator(databaseQueue: DatabaseQueue(), refreshOnInit: false)
        return ChatSessionController(dataStore: store)
    }
}
