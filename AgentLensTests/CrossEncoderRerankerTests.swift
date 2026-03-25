import XCTest
@testable import BurnBar

// MARK: - Mock Retrieval Reranker

/// A mock reranker for testing that tracks invocations and returns configurable results.
@MainActor
final class MockRetrievalReranker: RetrievalRerankProviding {
    struct Invocation: Sendable {
        let query: String
        let candidates: [RetrievalResult]
        let limit: Int
    }

    /// Results to return on the next call. If nil, returns candidates unchanged.
    var nextResult: [RetrievalResult]?

    /// Error to throw on the next call. If nil, succeeds.
    var nextError: Error?

    /// Whether to reverse the order of candidates (for testing reordering).
    var reverseOnNextCall: Bool = false

    /// Whether to return fewer candidates than requested.
    var truncateOnNextCall: Bool = false

    /// All recorded invocations.
    private(set) var invocations: [Invocation] = []

    /// Number of times rerank was called.
    var callCount: Int { invocations.count }

    func rerank(
        query: String,
        candidates: [RetrievalResult],
        limit: Int
    ) async throws -> [RetrievalResult] {
        let invocation = Invocation(query: query, candidates: candidates, limit: limit)
        invocations.append(invocation)

        if let error = nextError {
            nextError = nil
            throw error
        }

        if let result = nextResult {
            nextResult = nil
            return result
        }

        if reverseOnNextCall {
            reverseOnNextCall = false
            return Array(candidates.reversed().prefix(limit))
        }

        if truncateOnNextCall {
            truncateOnNextCall = false
            return Array(candidates.prefix(max(1, limit / 2)))
        }

        return Array(candidates.prefix(limit))
    }

    func reset() {
        invocations = []
        nextResult = nil
        nextError = nil
        reverseOnNextCall = false
        truncateOnNextCall = false
    }
}

// MARK: - Test Helpers

extension CrossEncoderRerankerTests {
    /// Creates a minimal RetrievalResult for testing.
    func makeRetrievalResult(
        chunkID: String = "chunk-1",
        documentID: String = "doc-1",
        title: String = "Test Document",
        snippet: String = "This is a test snippet about Swift programming."
    ) -> RetrievalResult {
        RetrievalResult(
            chunkID: chunkID,
            documentID: documentID,
            sourceKind: .conversation,
            sourceID: "conv-1",
            provider: .claudeCode,
            providerRawValue: nil,
            projectName: "TestProject",
            title: title,
            subtitle: nil,
            snippet: snippet,
            sectionPath: nil,
            startOffset: 0,
            endOffset: snippet.count,
            sourceUpdatedAt: nil,
            indexedAt: Date(),
            lexicalRank: 0.5,
            semanticScore: 0.7,
            rerankScore: 1.0,
            conversation: nil
        )
    }

    /// Creates multiple RetrievalResults for testing.
    func makeRetrievalResults(count: Int) -> [RetrievalResult] {
        (1...count).map { i in
            makeRetrievalResult(
                chunkID: "chunk-\(i)",
                documentID: "doc-\(i)",
                title: "Document \(i)",
                snippet: "Snippet for document \(i) with relevant content."
            )
        }
    }
}

// MARK: - Tests

@MainActor
final class CrossEncoderRerankerTests: XCTestCase {

    // MARK: - NoOpRetrievalReranker Tests

    func test_noOpReranker_returnsCandidatesUnchanged() async throws {
        let reranker = NoOpRetrievalReranker()
        let candidates = makeRetrievalResults(count: 5)
        let query = "test query"

        let result = try await reranker.rerank(query: query, candidates: candidates, limit: 3)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].chunkID, "chunk-1")
        XCTAssertEqual(result[1].chunkID, "chunk-2")
        XCTAssertEqual(result[2].chunkID, "chunk-3")
    }

    func test_noOpReranker_respectsLimit() async throws {
        let reranker = NoOpRetrievalReranker()
        let candidates = makeRetrievalResults(count: 10)

        let result = try await reranker.rerank(query: "query", candidates: candidates, limit: 3)

        XCTAssertEqual(result.count, 3)
    }

    func test_noOpReranker_handlesEmptyCandidates() async throws {
        let reranker = NoOpRetrievalReranker()

        let result = try await reranker.rerank(query: "query", candidates: [], limit: 5)

        XCTAssertEqual(result.count, 0)
    }

    func test_noOpReranker_handlesLimitGreaterThanCount() async throws {
        let reranker = NoOpRetrievalReranker()
        let candidates = makeRetrievalResults(count: 3)

        let result = try await reranker.rerank(query: "query", candidates: candidates, limit: 10)

        XCTAssertEqual(result.count, 3)
    }

    // MARK: - MockRetrievalReranker Tests

    func test_mockReranker_tracksInvocations() async throws {
        let mock = MockRetrievalReranker()
        let candidates = makeRetrievalResults(count: 3)
        let query = "tracked query"

        _ = try await mock.rerank(query: query, candidates: candidates, limit: 2)

        XCTAssertEqual(mock.callCount, 1)
        XCTAssertEqual(mock.invocations[0].query, query)
        XCTAssertEqual(mock.invocations[0].candidates.count, 3)
        XCTAssertEqual(mock.invocations[0].limit, 2)
    }

    func test_mockReranker_returnsConfiguredResults() async throws {
        let mock = MockRetrievalReranker()
        let expectedResults = makeRetrievalResults(count: 2)
        mock.nextResult = expectedResults

        let result = try await mock.rerank(query: "query", candidates: [], limit: 5)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].chunkID, "chunk-1")
        XCTAssertEqual(result[1].chunkID, "chunk-2")
    }

    func test_mockReranker_throwsConfiguredError() async throws {
        let mock = MockRetrievalReranker()
        let expectedError = CrossEncoderRerankerError.missingAPIKey
        mock.nextError = expectedError

        do {
            _ = try await mock.rerank(query: "query", candidates: [], limit: 5)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertTrue(error is CrossEncoderRerankerError)
        }

        // Error should be cleared after use
        let result = try await mock.rerank(query: "query", candidates: [], limit: 5)
        XCTAssertEqual(result.count, 0)
    }

    func test_mockReranker_reversesOrderWhenConfigured() async throws {
        let mock = MockRetrievalReranker()
        mock.reverseOnNextCall = true
        let candidates = makeRetrievalResults(count: 4)

        let result = try await mock.rerank(query: "query", candidates: candidates, limit: 4)

        XCTAssertEqual(result[0].chunkID, "chunk-4")
        XCTAssertEqual(result[3].chunkID, "chunk-1")
    }

    func test_mockReranker_truncatesWhenConfigured() async throws {
        let mock = MockRetrievalReranker()
        mock.truncateOnNextCall = true
        let candidates = makeRetrievalResults(count: 10)

        let result = try await mock.rerank(query: "query", candidates: candidates, limit: 8)

        // Should return half (8 / 2 = 4)
        XCTAssertEqual(result.count, 4)
    }

    func test_mockReranker_resetClearsState() async throws {
        let mock = MockRetrievalReranker()
        _ = try await mock.rerank(query: "query1", candidates: [], limit: 1)
        mock.nextResult = [makeRetrievalResult(chunkID: "special")]
        mock.nextError = CrossEncoderRerankerError.invalidResponse

        mock.reset()

        XCTAssertEqual(mock.callCount, 0)
        XCTAssertNil(mock.nextResult)
        XCTAssertNil(mock.nextError)

        let result = try await mock.rerank(query: "query2", candidates: [], limit: 1)
        XCTAssertEqual(result.count, 0) // No nextResult, so returns empty prefix
    }

    func test_mockReranker_accumulatesMultipleInvocations() async throws {
        let mock = MockRetrievalReranker()

        _ = try await mock.rerank(query: "query1", candidates: [makeRetrievalResult(chunkID: "a")], limit: 1)
        _ = try await mock.rerank(query: "query2", candidates: [makeRetrievalResult(chunkID: "b")], limit: 1)
        _ = try await mock.rerank(query: "query3", candidates: [makeRetrievalResult(chunkID: "c")], limit: 1)

        XCTAssertEqual(mock.callCount, 3)
        XCTAssertEqual(mock.invocations[0].query, "query1")
        XCTAssertEqual(mock.invocations[1].query, "query2")
        XCTAssertEqual(mock.invocations[2].query, "query3")
    }

    // MARK: - SearchService Integration Tests

    func test_searchService_withNoOpReranker_retrievesWithoutCrossEncoder() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "search-noop-rerank")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-crossencoder-test",
            fullText: "cross encoder test conversation about Swift"
        )
        try harness.dataStore.upsertConversation(conversation)

        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 3, maxJobsPerSweep: 10, advanceClockBy: 1)

        let reranker = NoOpRetrievalReranker()
        let searchService = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: nil,
            reranker: reranker,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: { harness.clock.now() }
        )

        // Query with crossEncoderEnabled = false (default)
        let results = await searchService.retrieve(
            RetrievalQuery(
                text: "swift",
                resultLimit: 10,
                crossEncoderEnabled: false
            )
        )

        XCTAssertFalse(results.isEmpty)
    }

    func test_searchService_withMockReranker_invokedWhenEnabled() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "search-mock-rerank")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-mock-rerank-test",
            fullText: "mock rerank test about programming"
        )
        try harness.dataStore.upsertConversation(conversation)

        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 3, maxJobsPerSweep: 10, advanceClockBy: 1)

        let mock = MockRetrievalReranker()
        let searchService = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: nil,
            reranker: mock,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: { harness.clock.now() }
        )

        // Query with crossEncoderEnabled = true
        let results = await searchService.retrieve(
            RetrievalQuery(
                text: "programming",
                resultLimit: 10,
                crossEncoderEnabled: true,
                crossEncoderCandidateLimit: 5
            )
        )

        // Mock should have been invoked
        XCTAssertEqual(mock.callCount, 1)
        XCTAssertEqual(mock.invocations[0].query, "programming")
        XCTAssertFalse(results.isEmpty)
    }

    func test_searchService_crossEncoderSkippedWhenDisabled() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "search-rerank-disabled")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-rerank-disabled",
            fullText: "rerank disabled test content"
        )
        try harness.dataStore.upsertConversation(conversation)

        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 3, maxJobsPerSweep: 10, advanceClockBy: 1)

        let mock = MockRetrievalReranker()
        let searchService = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: nil,
            reranker: mock,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: { harness.clock.now() }
        )

        // Query with crossEncoderEnabled = false (even with reranker available)
        let results = await searchService.retrieve(
            RetrievalQuery(
                text: "test",
                resultLimit: 10,
                crossEncoderEnabled: false
            )
        )

        // Mock should NOT have been invoked
        XCTAssertEqual(mock.callCount, 0)
        XCTAssertFalse(results.isEmpty)
    }

    func test_searchService_crossEncoderSkippedWhenNoReranker() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "search-no-reranker")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-no-reranker",
            fullText: "no reranker available test"
        )
        try harness.dataStore.upsertConversation(conversation)

        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 3, maxJobsPerSweep: 10, advanceClockBy: 1)

        // No reranker passed
        let searchService = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: nil,
            reranker: nil,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: { harness.clock.now() }
        )

        // Query with crossEncoderEnabled = true but no reranker available
        let results = await searchService.retrieve(
            RetrievalQuery(
                text: "test",
                resultLimit: 10,
                crossEncoderEnabled: true
            )
        )

        // Should still return results (no reranker just means skip)
        XCTAssertFalse(results.isEmpty)
    }

    func test_searchService_crossEncoderCandidateLimitCapped() async throws {
        let harness = try BurnBarSearchIntegrationHarness(name: "search-rerank-limit")
        defer { harness.cleanup() }

        // Insert multiple conversations
        for i in 1...20 {
            let conversation = harness.makeConversationFixture(
                id: "conv-limit-\(i)",
                fullText: "conversation number \(i) about various topics"
            )
            try harness.dataStore.upsertConversation(conversation)
            _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        }
        _ = try await harness.drainProjectionQueue(maxSweeps: 10, maxJobsPerSweep: 20, advanceClockBy: 1)

        let mock = MockRetrievalReranker()
        let searchService = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: nil,
            reranker: mock,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: { harness.clock.now() }
        )

        // Query with a specific limit
        _ = await searchService.retrieve(
            RetrievalQuery(
                text: "topics",
                resultLimit: 10,
                crossEncoderEnabled: true,
                crossEncoderCandidateLimit: 10
            )
        )

        // Verify the mock received at most 10 candidates
        if let invocation = mock.invocations.first {
            XCTAssertLessThanOrEqual(invocation.candidates.count, 10)
        }
    }

    // MARK: - OpenAICrossEncoderReranker Error Cases

    func test_openAICrossEncoderReranker_errorDescription() {
        XCTAssertEqual(
            CrossEncoderRerankerError.missingAPIKey.localizedDescription,
            "Cross-encoder reranking requires an API key."
        )
        XCTAssertEqual(
            CrossEncoderRerankerError.invalidBaseURL.localizedDescription,
            "The cross-encoder API URL is invalid."
        )
        XCTAssertTrue(
            CrossEncoderRerankerError.unexpectedResponse(statusCode: 500, message: nil)
                .localizedDescription
                .contains("500")
        )
        XCTAssertTrue(
            CrossEncoderRerankerError.unexpectedResponse(statusCode: 403, message: "Forbidden")
                .localizedDescription
                .contains("Forbidden")
        )
        XCTAssertEqual(
            CrossEncoderRerankerError.invalidResponse.localizedDescription,
            "Cross-encoder returned an invalid response."
        )
        XCTAssertTrue(
            CrossEncoderRerankerError.parseError("test").localizedDescription
                .contains("test")
        )
    }
}
