import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class ProjectMemoryDetailSheetTests: XCTestCase {

    // MARK: - streamingTick reactivity

    func test_streamingTick_initiallyZero() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "pm-tick-initial")
        defer { harness.cleanup() }

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )

        XCTAssertEqual(controller.streamingTick, 0)
    }

    func test_streamingTick_supportsManualBump_forViewSignaling() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "pm-tick-bump")
        defer { harness.cleanup() }

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )

        XCTAssertEqual(controller.streamingTick, 0)
        controller.streamingTick &+= 1
        XCTAssertEqual(controller.streamingTick, 1)
        controller.streamingTick &+= 1
        XCTAssertEqual(controller.streamingTick, 2)
    }

    // MARK: - ProjectMemoryInsightController state machine

    func test_insightController_isIdle_onInit() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "pm-insight-idle")
        defer { harness.cleanup() }

        let chat = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
        let controller = ProjectMemoryInsightController(chatController: chat)

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.streamingContent, "")
    }

    func test_insightController_observe_mirrorsAssistantContent_whileStreaming() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "pm-insight-mirror")
        defer { harness.cleanup() }

        let chat = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
        let controller = ProjectMemoryInsightController(chatController: chat)

        controller.generate(prompt: "Summarize the project")

        let assistantMsg = ChatMessageRecord(
            id: "assist-1",
            role: .assistant,
            content: "Hermes is reading..."
        )
        let messages = [
            ChatMessageRecord(id: "user-1", role: .user, content: "Summarize the project"),
            assistantMsg
        ]

        controller.observeStreamingTick(
            messages: messages,
            activeID: "assist-1",
            isStreaming: true
        )

        XCTAssertEqual(controller.streamingContent, "Hermes is reading...")
        XCTAssertEqual(controller.state, .streaming)
    }

    func test_insightController_transitionsToComplete_whenStreamStops_withContent() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "pm-insight-complete")
        defer { harness.cleanup() }

        let chat = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
        let controller = ProjectMemoryInsightController(chatController: chat)

        controller.generate(prompt: "Summarize")

        let assistantMsg = ChatMessageRecord(
            id: "assist-2",
            role: .assistant,
            content: "Final summary delivered."
        )
        let messages = [
            ChatMessageRecord(id: "user-2", role: .user, content: "Summarize"),
            assistantMsg
        ]

        controller.observeStreamingTick(
            messages: messages,
            activeID: "assist-2",
            isStreaming: true
        )
        XCTAssertEqual(controller.state, .streaming)

        controller.observeStreamingTick(
            messages: messages,
            activeID: nil,
            isStreaming: false
        )

        XCTAssertEqual(controller.state, .complete)
        XCTAssertEqual(controller.streamingContent, "Final summary delivered.")
    }

    func test_insightController_transitionsToFailed_whenStreamStops_withEmptyContent() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "pm-insight-failed")
        defer { harness.cleanup() }

        let chat = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
        let controller = ProjectMemoryInsightController(chatController: chat)

        controller.generate(prompt: "Summarize")

        controller.observeStreamingTick(
            messages: [
                ChatMessageRecord(id: "user-3", role: .user, content: "Summarize")
            ],
            activeID: nil,
            isStreaming: false
        )

        if case .failed(let message) = controller.state {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("Expected .failed state, got \(controller.state)")
        }
    }

    func test_insightController_cancel_clearsTrackedAssistantID() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "pm-insight-cancel")
        defer { harness.cleanup() }

        let chat = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: ControlledChatSessionSearchProvider(responses: [:])
        )
        let controller = ProjectMemoryInsightController(chatController: chat)

        controller.generate(prompt: "Hello")
        controller.cancel()

        // After cancel, state stays at whatever it was; controller is reusable.
        // A subsequent generate() resets to .streaming and empties streamingContent.
        controller.generate(prompt: "Second attempt")
        XCTAssertEqual(controller.state, .streaming)
        XCTAssertEqual(controller.streamingContent, "")
    }

    // MARK: - CitationWrapper round-trip

    func test_citationWrapper_singleConvenience_wrapsExactlyOneCitation() {
        let cite = ProjectMemoryCitation(
            id: "cite-1",
            sourceID: "conv-A",
            sourceKind: .conversation,
            title: "Sample",
            snippet: "Excerpt body",
            createdAt: Date(timeIntervalSince1970: 1_742_000_000)
        )

        let wrapper = CitationWrapper.single(cite)
        XCTAssertEqual(wrapper.citations.count, 1)
        XCTAssertEqual(wrapper.citations.first?.id, "cite-1")
    }

    func test_citationWrapper_freshIdentityPerInit_allowsRepresentingSameCitation() {
        let cite = ProjectMemoryCitation(
            id: "cite-shared",
            sourceID: "conv-B",
            sourceKind: .conversation,
            title: "Repeat",
            snippet: "Same evidence",
            createdAt: nil
        )

        let w1 = CitationWrapper.single(cite)
        let w2 = CitationWrapper.single(cite)
        XCTAssertNotEqual(w1.id, w2.id,
                          "Each wrapper must own a unique id so re-tapping the same chip re-presents the sheet.")
        XCTAssertEqual(w1.citations.first?.id, w2.citations.first?.id)
    }

    func test_citationWrapper_groupConstructor_preservesOrder() {
        let a = ProjectMemoryCitation(id: "a", sourceID: "1", title: "A", snippet: "alpha", createdAt: nil)
        let b = ProjectMemoryCitation(id: "b", sourceID: "2", title: "B", snippet: "beta", createdAt: nil)
        let c = ProjectMemoryCitation(id: "c", sourceID: "3", title: "C", snippet: "gamma", createdAt: nil)

        let wrapper = CitationWrapper(citations: [a, b, c])
        XCTAssertEqual(wrapper.citations.map(\.id), ["a", "b", "c"])
    }
}
