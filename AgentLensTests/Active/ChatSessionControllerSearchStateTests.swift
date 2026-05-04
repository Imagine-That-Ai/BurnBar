import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class ChatSessionControllerSearchStateTests: XCTestCase {
    func test_performSearch_ignoresStaleOutOfOrderResults() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-search-state-order")
        defer { harness.cleanup() }

        let alpha = makeSearchResult(id: "alpha", title: "Alpha result")
        let beta = makeSearchResult(id: "beta", title: "Beta result")
        let provider = ControlledChatSessionSearchProvider(
            responses: [
                "alpha": .init(delaySeconds: 0.05, results: [alpha]),
                "beta": .init(delaySeconds: 0.18, results: [beta])
            ]
        )

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: provider
        )

        controller.searchQuery = "alpha"
        controller.performSearch()
        XCTAssertTrue(controller.isSearching)

        try await Task.sleep(nanoseconds: 20_000_000)
        controller.searchQuery = "beta"
        XCTAssertTrue(controller.isSearching)
        XCTAssertTrue(controller.searchResults.isEmpty)

        controller.performSearch()
        XCTAssertTrue(controller.isSearching)

        try await Task.sleep(nanoseconds: 90_000_000)
        XCTAssertTrue(controller.isSearching)
        XCTAssertTrue(controller.searchResults.isEmpty)

        let completed = await waitForSearchState(
            timeoutSeconds: 1.0,
            pollIntervalNanoseconds: 20_000_000
        ) {
            controller.searchResults.map(\.conversation.id) == ["beta"] && controller.isSearching == false
        }
        XCTAssertTrue(completed)
        XCTAssertEqual(controller.searchResults.map(\.conversation.id), ["beta"])
        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(provider.requestedQueries, ["alpha", "beta"])
    }

    func test_clearingSearchQuery_cancelsInFlightSearchAndPreventsBackfill() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-search-state-clear")
        defer { harness.cleanup() }

        let alpha = makeSearchResult(id: "alpha", title: "Alpha result")
        let provider = ControlledChatSessionSearchProvider(
            responses: [
                "alpha": .init(delaySeconds: 0.12, results: [alpha])
            ]
        )

        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: provider
        )

        controller.searchQuery = "alpha"
        controller.performSearch()
        XCTAssertTrue(controller.isSearching)

        try await Task.sleep(nanoseconds: 20_000_000)
        controller.searchQuery = ""
        XCTAssertFalse(controller.isSearching)
        XCTAssertTrue(controller.searchResults.isEmpty)

        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertFalse(controller.isSearching)
        XCTAssertTrue(controller.searchResults.isEmpty)
        XCTAssertEqual(provider.requestedQueries, ["alpha"])
    }

    func test_send_hermesIndexQuery_usesLocalIndexOracleResponse() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-hermes-index-oracle")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-api-key-index-oracle",
            fullText: "I entered an api key in the test env file and then rotated it."
        )
        try harness.dataStore.upsertConversation(conversation)
        try harness.dataStore.enqueueConversationProjectionJob(
            conversationID: conversation.id,
            jobType: .project,
            now: harness.clock.now()
        )
        _ = try await harness.runProjectionSweep(maxJobs: 20)

        let searchService = harness.makeSearchService(semanticEnabled: false)
        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: searchService
        )
        controller.startNewChatThread()
        controller.chatBackend = .hermes
        controller.hermesAvailable = true
        controller.inputText = "can you find an instance where ive enterd an api key"

        await controller.send()

        XCTAssertFalse(controller.isStreaming)
        XCTAssertFalse(controller.conversationJumpTargets.isEmpty)
        XCTAssertEqual(controller.conversationJumpTargets.first?.conversation.id, conversation.id)
        let response = controller.messages.last?.content ?? ""
        XCTAssertFalse(response.isEmpty)
        XCTAssertFalse(response.contains("Patterns counted:"))
        XCTAssertTrue(response.localizedCaseInsensitiveContains("api key") || response.localizedCaseInsensitiveContains("credential"))
    }

    func test_send_hermesCredentialLeakQuery_usesCredentialExposureScan() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-hermes-credential-scan")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-api-key-exposure",
            fullText: "I fixed the env by running export OPENAI_API_KEY=TEST_KEY_PLACEHOLDER and then retried."
        )
        try harness.dataStore.upsertConversation(conversation)
        try harness.dataStore.enqueueConversationProjectionJob(
            conversationID: conversation.id,
            jobType: .project,
            now: harness.clock.now()
        )
        _ = try await harness.runProjectionSweep(maxJobs: 20)

        let searchService = harness.makeSearchService(semanticEnabled: false)
        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: searchService
        )
        controller.startNewChatThread()
        controller.chatBackend = .hermes
        controller.hermesAvailable = true
        controller.inputText = "how many times have i dropped api keys in the chat in the last week?"

        await controller.send()

        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.conversationJumpTargets.first?.conversation.id, conversation.id)
        let response = controller.messages.last?.content ?? ""
        XCTAssertFalse(response.isEmpty)
        XCTAssertFalse(response.contains("Patterns counted:"))
        XCTAssertTrue(response.localizedCaseInsensitiveContains("credential") || response.localizedCaseInsensitiveContains("api key"))
    }

    func test_send_hermesQuotedExactMatchQuery_top3_returnsExactlyThreeJumpTargets() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "chat-hermes-top3-exact")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-top3-refactor",
            fullText: """
            We should refactor the parser before lunch.
            The next step is to refactor the parser tests.
            I will refactor the parser again after the build finishes.
            Maybe we refactor the parser docs too.
            """
        )
        try harness.dataStore.upsertConversation(conversation)
        try harness.dataStore.enqueueConversationProjectionJob(
            conversationID: conversation.id,
            jobType: .project,
            now: harness.clock.now()
        )
        _ = try await harness.runProjectionSweep(maxJobs: 20)

        let searchService = harness.makeSearchService(semanticEnabled: false)
        let controller = ChatSessionController(
            dataStore: harness.dataStore,
            searchService: searchService
        )
        controller.startNewChatThread()
        controller.chatBackend = .hermes
        controller.hermesAvailable = true
        controller.inputText = #"show me the top 3 exact jump targets for "refactor the parser""#

        await controller.send()

        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.conversationJumpTargets.count, 3)
        XCTAssertTrue(controller.conversationJumpTargets.allSatisfy { $0.conversation.id == conversation.id })
        let response = controller.messages.last?.content ?? ""
        XCTAssertFalse(response.isEmpty)
        XCTAssertTrue(response.localizedCaseInsensitiveContains("exact spot"))
    }

    func test_indexedQueryResponseStrategy_generalPrompt_prefersLLM() {
        let query = "help me write a better landing page headline"
        let plan = BurnBarSearchPlan.plan(userText: query)

        let strategy = ChatSessionController.indexedQueryResponseStrategy(
            queryText: query,
            plan: plan,
            hasJumpTargets: true,
            retrievalResultCount: 8
        )

        XCTAssertEqual(strategy, ChatSessionController.IndexedQueryResponseStrategy.llmOnly)
    }

    func test_indexedQueryResponseStrategy_compoundMemoryPrompt_usesHybrid() {
        let query = "which agent do i curse at the most and why"
        let plan = BurnBarSearchPlan.plan(userText: query)

        let strategy = ChatSessionController.indexedQueryResponseStrategy(
            queryText: query,
            plan: plan,
            hasJumpTargets: true,
            retrievalResultCount: 5
        )

        XCTAssertEqual(strategy, ChatSessionController.IndexedQueryResponseStrategy.hybridIndexThenLLM)
    }

    func test_indexedQueryResponseStrategy_providerRankingPrompt_usesLocalOracle() {
        let query = "which agent do i curse at the most"
        let plan = BurnBarSearchPlan.plan(userText: query)

        let strategy = ChatSessionController.indexedQueryResponseStrategy(
            queryText: query,
            plan: plan,
            hasJumpTargets: true,
            retrievalResultCount: 5
        )

        XCTAssertEqual(strategy, ChatSessionController.IndexedQueryResponseStrategy.localOracle)
    }
}

@MainActor
private final class ControlledChatSessionSearchProvider: ChatSessionSearchProviding {
    struct Response {
        let delaySeconds: TimeInterval
        let results: [SearchResult]
    }

    private let responses: [String: Response]
    private(set) var requestedQueries: [String] = []

    init(responses: [String: Response]) {
        self.responses = responses
    }

    func search(query: String) async -> [SearchResult] {
        requestedQueries.append(query)
        guard let response = responses[query] else {
            return []
        }

        if response.delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(response.delaySeconds * 1_000_000_000))
        }

        return response.results
    }
}

private func makeSearchResult(id: String, title: String) -> SearchResult {
    let now = Date(timeIntervalSince1970: 1_742_000_000)
    let conversation = ConversationRecord(
        id: id,
        provider: .claudeCode,
        sessionId: "session-\(id)",
        projectName: "Chat Search",
        startTime: now.addingTimeInterval(-120),
        endTime: now,
        messageCount: 4,
        userWordCount: 12,
        assistantWordCount: 34,
        keyFiles: [],
        keyCommands: [],
        keyTools: [],
        inferredTaskTitle: title,
        lastAssistantMessage: "Done",
        fullText: "Conversation \(id)",
        indexedAt: now,
        fileModifiedAt: now,
        sourceType: .providerLog
    )

    return SearchResult(conversation: conversation, snippet: "snippet-\(id)", rank: 1.0)
}

@MainActor
private func waitForSearchState(
    timeoutSeconds: TimeInterval,
    pollIntervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }
    return condition()
}

// MARK: - Dashboard chat evidence pack
