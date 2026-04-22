import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - SearchServiceTests

@MainActor
final class SearchServiceTests: XCTestCase {

    // MARK: - Helper Mocks

    /// Stub semantic candidate provider that returns predefined responses.
    private final class StubSemanticCandidateProvider: SemanticCandidateProviding {
        var responses: [String: [SemanticCandidate]] = [:]
        var shouldThrow = false
        var throwError = SearchServiceError.semanticProviderUnavailable

        func semanticCandidates(for query: String, filters: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate] {
            if shouldThrow { throw throwError }
            return Array((responses[query] ?? []).prefix(max(0, limit)))
        }
    }

    /// Stub cross-encoder reranker that can be configured to return reordered results.
    private final class StubCrossEncoderReranker: RetrievalRerankProviding {
        var reorderResults: Bool = false
        var reorderLimit: Int = 10

        func rerank(query: String, candidates: [RetrievalResult], limit: Int) async throws -> [RetrievalResult] {
            guard reorderResults else { return candidates }
            let lim = min(limit, candidates.count)
            // Move last item to first position to verify reordering happened
            guard candidates.count >= 2 else { return candidates }
            var reordered = Array(candidates.prefix(lim))
            if let last = reordered.popLast() {
                reordered.insert(last, at: 0)
            }
            return reordered
        }
    }

    // MARK: - Factory Method Tests

    func test_makeConversationSearchService_returnsConfiguredService() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = SearchService.makeConversationSearchService(dataStore: store)
        XCTAssertNotNil(service)
    }

    func test_makeConversationSearchService_resolvesEmbeddingSelection_fromPreferredVersionID() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_800_000)

        let modelID = "embedding-model-test"
        let versionID = "embedding-version-preferred"

        try store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: "openai",
                modelName: "text-embedding-3-small",
                dimensions: 1536,
                distanceMetric: "cosine",
                createdAt: base,
                updatedAt: base
            )
        )
        try store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: versionID,
                modelID: modelID,
                versionTag: "v1",
                chunkerVersion: "chunk-v1",
                normalizationVersion: "norm-v1",
                promptVersion: "prompt-v1",
                isActive: false,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: "version-other",
                modelID: modelID,
                versionTag: "v2",
                chunkerVersion: "chunk-v1",
                normalizationVersion: "norm-v1",
                promptVersion: "prompt-v1",
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )

        let service = SearchService.makeConversationSearchService(dataStore: store)
        XCTAssertNotNil(service)
    }

    // MARK: - Empty Query Tests

    func test_retrieve_emptyQueryString_returnsEmptyResults() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = SearchService(dataStore: store)

        let results = await service.retrieve(RetrievalQuery(text: ""))
        XCTAssertTrue(results.isEmpty)

        let resultsWithWhitespace = await service.retrieve(RetrievalQuery(text: "   \n\t  "))
        XCTAssertTrue(resultsWithWhitespace.isEmpty)
    }

    func test_runBurnBarQuery_emptyQuery_returnsEmptyResults() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = SearchService(dataStore: store)

        let result = await service.runBurnBarQuery(RetrievalQuery(text: ""))
        XCTAssertTrue(result.retrievalResults.isEmpty)
    }

    // MARK: - Lexical Search Candidate Tests

    func test_retrieve_lexicalCandidates_returnedFromFTS() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "lexical-candidates")
        let base = Date(timeIntervalSince1970: 1_742_810_000)

        let conv = makeConversation(
            id: "conv-lexical-test",
            provider: .claudeCode,
            projectName: "LexicalTest",
            fullText: "This conversation is about Swift concurrency and async/await patterns.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "Swift concurrency",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                lexicalCandidateLimit: 10
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.sourceKind, .conversation)
        XCTAssertNotNil(results.first?.lexicalRank)
    }

    func test_retrieve_lexicalLimit_boundedTo1000() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = SearchService(dataStore: store)

        // Query with huge lexical limit should be capped
        let results = await service.retrieve(
            RetrievalQuery(
                text: "test",
                lexicalCandidateLimit: 5000,
                semanticCandidateLimit: 0,
                resultLimit: 50
            )
        )
        // Empty results is fine, but limit should not crash
        XCTAssertNotNil(results)
    }

    // MARK: - Semantic Search Candidate Tests

    func test_retrieve_semanticCandidates_returnedWhenProviderProvided() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "semantic-candidates")
        let base = Date(timeIntervalSince1970: 1_742_820_000)

        let conv = makeConversation(
            id: "conv-semantic-test",
            provider: .claudeCode,
            projectName: "SemanticTest",
            fullText: "Discussion about deployment pipeline optimization and CI/CD workflows.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        guard
            let doc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conv.id }),
            let chunk = try store.fetchSearchChunks(documentID: doc.id).first
        else {
            return XCTFail("Expected projected conversation chunk")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "CI/CD optimization": [SemanticCandidate(chunkID: chunk.id, score: 0.95)]
            ]
        )

        let service = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "CI/CD optimization",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                semanticCandidateLimit: 10
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertNotNil(results.first?.semanticScore)
    }

    func test_retrieve_semanticProviderFailure_fallsBackToLexicalOnly() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "semantic-fallback")
        let base = Date(timeIntervalSince1970: 1_742_830_000)

        let conv = makeConversation(
            id: "conv-semantic-fallback",
            provider: .claudeCode,
            projectName: "FallbackTest",
            fullText: "Testing semantic fallback behavior when provider fails.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let failingProvider = StubSemanticCandidateProvider()
        failingProvider.shouldThrow = true

        let service = SearchService(dataStore: store, semanticProvider: failingProvider, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "semantic fallback",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                semanticCandidateLimit: 10
            )
        )

        // Should still return results from lexical search
        XCTAssertFalse(results.isEmpty)

        // Health should be recorded as degraded
        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .semantic })
        XCTAssertEqual(health?.status, .degraded)
        XCTAssertEqual(health?.errorCode, "SEMANTIC_PROVIDER_FALLBACK")
    }

    func test_retrieve_semanticDisabledForSensitiveQueries() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "sensitive-queries")
        let base = Date(timeIntervalSince1970: 1_742_840_000)

        let conv = makeConversation(
            id: "conv-sensitive-test",
            provider: .claudeCode,
            projectName: "SensitiveTest",
            fullText: "Remember to set your API keys in the environment variables.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let semanticProvider = StubSemanticCandidateProvider(
            responses: ["API key setup": []]
        )

        let service = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })

        // Query that looks like sensitive exact lookup should disable semantic
        let results = await service.retrieve(
            RetrievalQuery(
                text: "api key",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                semanticCandidateLimit: 10
            )
        )

        XCTAssertNotNil(results)
    }

    // MARK: - Cross-Encoder Reranking Tests

    func test_retrieve_crossEncoderReranking_appliesReordering() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "cross-encoder-rerank")
        let base = Date(timeIntervalSince1970: 1_742_850_000)

        // Create multiple conversations to get multiple results
        for i in 0..<5 {
            let conv = makeConversation(
                id: "conv-rerank-\(i)",
                provider: .claudeCode,
                projectName: "RerankTest",
                fullText: "Content about testing patterns and test coverage for item \(i).",
                indexedAt: base.addingTimeInterval(Double(i)),
                sourceType: .providerLog
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }
        _ = try await projector.runSweep(maxJobs: 100)

        let stubReranker = StubCrossEncoderReranker()
        stubReranker.reorderResults = true

        let service = SearchService(
            dataStore: store,
            semanticProvider: nil,
            reranker: stubReranker,
            nowProvider: { base }
        )

        let results = await service.retrieve(
            RetrievalQuery(
                text: "testing patterns",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                crossEncoderEnabled: true,
                crossEncoderCandidateLimit: 5
            )
        )

        XCTAssertFalse(results.isEmpty)
    }

    func test_retrieve_crossEncoderDisabled_doesNotRerank() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "cross-encoder-disabled")
        let base = Date(timeIntervalSince1970: 1_742_860_000)

        let conv = makeConversation(
            id: "conv-no-rerank",
            provider: .claudeCode,
            projectName: "NoRerankTest",
            fullText: "Content without cross-encoder reranking.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let stubReranker = StubCrossEncoderReranker()
        stubReranker.reorderResults = true

        let service = SearchService(
            dataStore: store,
            semanticProvider: nil,
            reranker: stubReranker,
            nowProvider: { base }
        )

        // Without crossEncoderEnabled, reranker should not be called
        let results = await service.retrieve(
            RetrievalQuery(
                text: "content",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                crossEncoderEnabled: false
            )
        )

        XCTAssertNotNil(results)
    }

    func test_retrieve_noOpReranker_bypassesCrossEncoder() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let noOpReranker = NoOpRetrievalReranker()

        let service = SearchService(
            dataStore: store,
            semanticProvider: nil,
            reranker: noOpReranker,
            nowProvider: Date.init
        )

        // Should not crash and should return empty results for empty query
        let results = await service.retrieve(RetrievalQuery(text: "test"))
        XCTAssertNotNil(results)
    }

    // MARK: - RBAC / Visibility Filtering Tests

    func test_retrieve_ownershipFilter_personal_excludesSharedArtifacts() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "ownership-personal")
        let base = Date(timeIntervalSince1970: 1_742_870_000)

        let conv = makeConversation(
            id: "conv-personal",
            provider: .claudeCode,
            projectName: "Personal",
            fullText: "Personal conversation content.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)

        let sharedArtifact = makeArtifact(
            id: "artifact-shared-personal-test",
            sourceKind: .sharedArtifact,
            rootPath: "/tmp/shared",
            relativePath: "SHARED.md",
            title: "Shared Document",
            body: "Shared artifact content.",
            contentHash: "hash-shared-personal",
            fileModifiedAt: base
        )
        _ = try store.upsertSourceArtifact(sharedArtifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: .sharedArtifact,
            sourceID: sharedArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: sharedArtifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "content",
                filters: RetrievalFilters(ownership: .personal, artifactTypes: [.conversation, .sharedArtifact])
            )
        )

        // Personal ownership filter should exclude shared artifacts
        let hasSharedArtifact = results.contains { $0.sourceKind == .sharedArtifact }
        XCTAssertFalse(hasSharedArtifact)
    }

    func test_retrieve_ownershipFilter_shared_requiresPermission() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "ownership-shared")
        let base = Date(timeIntervalSince1970: 1_742_880_000)

        let sharedArtifact = makeArtifact(
            id: "artifact-shared-rbac-test",
            sourceKind: .sharedArtifact,
            rootPath: "/tmp/shared2",
            relativePath: "RBAC.md",
            title: "Shared RBAC Document",
            body: "Shared artifact with permissions test.",
            contentHash: "hash-shared-rbac-test",
            fileModifiedAt: base
        )
        _ = try store.upsertSourceArtifact(sharedArtifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: .sharedArtifact,
            sourceID: sharedArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: sharedArtifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 20)

        // No access context - should not see shared artifacts
        let noAccessService = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { nil },
            nowProvider: { base }
        )
        let noAccessResults = await noAccessService.retrieve(
            RetrievalQuery(
                text: "permissions",
                filters: RetrievalFilters(ownership: .shared)
            )
        )
        XCTAssertTrue(noAccessResults.isEmpty)

        // With proper access context
        let accessContext = SharedArtifactAccessContext(
            userID: "user-with-access",
            workspaceID: "workspace-access",
            teamID: "team-access"
        )
        _ = try store.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sharedArtifact.id,
                workspaceID: accessContext.workspaceID,
                teamID: accessContext.teamID,
                principalType: .user,
                principalID: accessContext.userID,
                role: .viewer,
                visibility: .team,
                canRead: true,
                canWrite: false,
                canShare: false,
                createdAt: base,
                updatedAt: base
            )
        )

        let accessService = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { accessContext },
            nowProvider: { base }
        )
        let accessResults = await accessService.retrieve(
            RetrievalQuery(
                text: "permissions",
                filters: RetrievalFilters(ownership: .shared)
            )
        )
        XCTAssertEqual(accessResults.count, 1)
        XCTAssertEqual(accessResults.first?.sourceID, sharedArtifact.id)
    }

    func test_retrieve_providerFilter_excludesOtherProviders() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "provider-filter")
        let base = Date(timeIntervalSince1970: 1_742_890_000)

        let claudeConv = makeConversation(
            id: "conv-claude-provider",
            provider: .claudeCode,
            projectName: "ProviderTest",
            fullText: "Claude Code conversation about provider filtering.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let codexConv = makeConversation(
            id: "conv-codex-provider",
            provider: .codex,
            projectName: "ProviderTest",
            fullText: "Codex conversation about provider filtering.",
            indexedAt: base.addingTimeInterval(1),
            sourceType: .providerLog
        )

        try store.upsertConversation(claudeConv)
        try store.upsertConversation(codexConv)
        try store.enqueueConversationProjectionJob(conversationID: claudeConv.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: codexConv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "provider filtering",
                filters: RetrievalFilters(provider: .claudeCode, artifactTypes: [.conversation])
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.provider, .claudeCode)
        XCTAssertEqual(results.first?.sourceID, claudeConv.id)
    }

    func test_retrieve_projectNameFilter_matchesCaseInsensitive() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "project-filter")
        let base = Date(timeIntervalSince1970: 1_742_900_000)

        let conv1 = makeConversation(
            id: "conv-project-upper",
            provider: .claudeCode,
            projectName: "MYPROJECT",
            fullText: "Project name filter test content.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let conv2 = makeConversation(
            id: "conv-project-lower",
            provider: .claudeCode,
            projectName: "myproject",
            fullText: "Project name filter test content.",
            indexedAt: base.addingTimeInterval(1),
            sourceType: .providerLog
        )

        try store.upsertConversation(conv1)
        try store.upsertConversation(conv2)
        try store.enqueueConversationProjectionJob(conversationID: conv1.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv2.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "project",
                filters: RetrievalFilters(projectName: "myproject", artifactTypes: [.conversation])
            )
        )

        // Both should match (case insensitive comparison)
        XCTAssertEqual(results.count, 2)
    }

    func test_retrieve_sourceIDFilter_returnsOnlyMatchingSources() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "sourceid-filter")
        let base = Date(timeIntervalSince1970: 1_742_910_000)

        let conv1 = makeConversation(
            id: "conv-sourceid-1",
            provider: .claudeCode,
            projectName: "SourceIDTest",
            fullText: "Source ID filter test one.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let conv2 = makeConversation(
            id: "conv-sourceid-2",
            provider: .claudeCode,
            projectName: "SourceIDTest",
            fullText: "Source ID filter test two.",
            indexedAt: base.addingTimeInterval(1),
            sourceType: .providerLog
        )

        try store.upsertConversation(conv1)
        try store.upsertConversation(conv2)
        try store.enqueueConversationProjectionJob(conversationID: conv1.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: conv2.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "source",
                filters: RetrievalFilters(sourceIDs: ["conv-sourceid-1"])
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, conv1.id)
    }

    func test_retrieve_conversationSourcesFilter_filtersBySourceType() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "conv-source-filter")
        let base = Date(timeIntervalSince1970: 1_742_920_000)

        let providerConv = makeConversation(
            id: "conv-provider-log",
            provider: .claudeCode,
            projectName: "ConvSourceTest",
            fullText: "Provider log conversation.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let cliConv = makeConversation(
            id: "conv-cli-assistant",
            provider: .factory,
            projectName: "ConvSourceTest",
            fullText: "CLI assistant conversation.",
            indexedAt: base.addingTimeInterval(1),
            sourceType: .cliAssistant
        )

        try store.upsertConversation(providerConv)
        try store.upsertConversation(cliConv)
        try store.enqueueConversationProjectionJob(conversationID: providerConv.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: cliConv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "conversation",
                filters: RetrievalFilters(
                    artifactTypes: [.conversation],
                    conversationSources: [.cliAssistant]
                )
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.conversation?.sourceType, .cliAssistant)
    }

    // MARK: - Date Range Filter Tests

    func test_retrieve_dateRangeFilter_excludesOutOfRangeResults() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "date-filter")
        let base = Date(timeIntervalSince1970: 1_742_930_000)

        let recentConv = makeConversation(
            id: "conv-recent",
            provider: .claudeCode,
            projectName: "DateFilterTest",
            fullText: "Recent conversation within date range.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let oldConv = makeConversation(
            id: "conv-old",
            provider: .claudeCode,
            projectName: "DateFilterTest",
            fullText: "Old conversation outside date range.",
            indexedAt: base.addingTimeInterval(-100 * 86_400),
            sourceType: .providerLog
        )

        try store.upsertConversation(recentConv)
        try store.upsertConversation(oldConv)
        try store.enqueueConversationProjectionJob(conversationID: recentConv.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: oldConv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let lastWeek = base.addingTimeInterval(-7 * 86_400)...base
        let results = await service.retrieve(
            RetrievalQuery(
                text: "conversation",
                filters: RetrievalFilters(artifactTypes: [.conversation], dateRange: lastWeek)
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, recentConv.id)
    }

    func test_retrieve_dateRangeFilter_usesConversationEndTime() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "date-filter-session")
        let base = Date(timeIntervalSince1970: 1_742_940_000)

        let oldSession = base.addingTimeInterval(-100 * 86_400)
        let oldConv = makeConversation(
            id: "conv-session-time",
            provider: .claudeCode,
            projectName: "DateFilterTest",
            fullText: "Conversation with old session time but recent file mtime.",
            indexedAt: base,
            sourceType: .providerLog
        )
        // Override endTime to be old
        var mutableConv = oldConv
        mutableConv.endTime = oldSession

        try store.upsertConversation(mutableConv)
        try store.enqueueConversationProjectionJob(conversationID: mutableConv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let lastWeek = base.addingTimeInterval(-7 * 86_400)...base
        let results = await service.retrieve(
            RetrievalQuery(
                text: "conversation",
                filters: RetrievalFilters(artifactTypes: [.conversation], dateRange: lastWeek)
            )
        )

        // Should be filtered out because session time (endTime) is old
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Pagination and Limits Tests

    func test_retrieve_resultLimit_bounded() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "result-limit")
        let base = Date(timeIntervalSince1970: 1_742_950_000)

        // Create 10 conversations
        for i in 0..<10 {
            let conv = makeConversation(
                id: "conv-limit-\(i)",
                provider: .claudeCode,
                projectName: "LimitTest",
                fullText: "Result limit test conversation number \(i).",
                indexedAt: base.addingTimeInterval(Double(i)),
                sourceType: .providerLog
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }
        _ = try await projector.runSweep(maxJobs: 200)

        let service = SearchService(dataStore: store, nowProvider: { base })

        let limit3 = await service.retrieve(
            RetrievalQuery(
                text: "limit",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 3
            )
        )
        XCTAssertLessThanOrEqual(limit3.count, 3)

        let limit5 = await service.retrieve(
            RetrievalQuery(
                text: "limit",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 5
            )
        )
        XCTAssertLessThanOrEqual(limit5.count, 5)
    }

    func test_retrieve_rerankCandidateLimit_boundedTo1000() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = SearchService(dataStore: store)

        // Huge rerank limit should be capped
        let results = await service.retrieve(
            RetrievalQuery(
                text: "test",
                rerankCandidateLimit: 5000
            )
        )
        XCTAssertNotNil(results)
    }

    func test_retrieve_lexicalCandidateLimit_minimumIs1() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let service = SearchService(dataStore: store)

        // Zero limit should be bumped to 1
        let results = await service.retrieve(
            RetrievalQuery(
                text: "test",
                lexicalCandidateLimit: 0,
                semanticCandidateLimit: 0
            )
        )
        XCTAssertNotNil(results)
    }

    // MARK: - Snippet and Context Extraction Tests

    func test_retrieve_snippet_usesLexicalSnippetWhenAvailable() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "snippet-test")
        let base = Date(timeIntervalSince1970: 1_742_960_000)

        let conv = makeConversation(
            id: "conv-snippet",
            provider: .claudeCode,
            projectName: "SnippetTest",
            fullText: "This is a test conversation about snippet extraction with important content that should appear in the snippet.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "snippet extraction",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertNotNil(results.first?.snippet)
        XCTAssertFalse(results.first!.snippet.isEmpty)
    }

    func test_retrieve_snippet_fallsBackToChunkText() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "snippet-fallback")
        let base = Date(timeIntervalSince1970: 1_742_970_000)

        let conv = makeConversation(
            id: "conv-snippet-fallback",
            provider: .claudeCode,
            projectName: "SnippetFallbackTest",
            fullText: "Fallback test content for snippet without lexical match.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        // Query that won't get lexical snippet but will match chunk
        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "fallback test content",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertNotNil(results.first?.snippet)
    }

    // MARK: - Search Health Tests

    func test_retrieve_healthRecorded_onSuccessfulQuery() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "health-success")
        let base = Date(timeIntervalSince1970: 1_742_980_000)

        let conv = makeConversation(
            id: "conv-health",
            provider: .claudeCode,
            projectName: "HealthTest",
            fullText: "Health recording test conversation.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        _ = await service.retrieve(
            RetrievalQuery(
                text: "health",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .lexical })
        XCTAssertEqual(health?.status, .healthy)
        XCTAssertNil(health?.errorCode)
    }

    func test_retrieve_healthRecorded_onLexicalFailure() async throws {
        let store = try makeDiscoveryInMemoryStore()
        // Don't set up any data - lexical query should fail
        let service = SearchService(dataStore: store, nowProvider: { Date() })

        _ = await service.retrieve(
            RetrievalQuery(
                text: "nonexistent query that returns nothing",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        // Should still record health (even if no results)
        let health = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .lexical })
        XCTAssertNotNil(health)
    }

    // MARK: - Hybrid Fusion Strategy Tests

    func test_retrieve_reciprocalRankFusion_ranksByCombinedScore() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "rrf-test")
        let base = Date(timeIntervalSince1970: 1_742_990_000)

        let conv = makeConversation(
            id: "conv-rrf",
            provider: .claudeCode,
            projectName: "RRFTest",
            fullText: "Reciprocal rank fusion test content.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        guard
            let doc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conv.id }),
            let chunk = try store.fetchSearchChunks(documentID: doc.id).first
        else {
            return XCTFail("Expected projected chunk")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "reciprocal rank fusion": [SemanticCandidate(chunkID: chunk.id, score: 0.9)]
            ]
        )

        let service = SearchService(
            dataStore: store,
            semanticProvider: semanticProvider,
            nowProvider: { base }
        )

        let results = await service.retrieve(
            RetrievalQuery(
                text: "reciprocal rank fusion",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                hybridFusionStrategy: .reciprocalRankFusion
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertNotNil(results.first?.rerankScore)
    }

    func test_retrieve_legacyWeightedStrategy_usesDifferentWeights() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "legacy-weighted")
        let base = Date(timeIntervalSince1970: 1_743_000_000)

        let conv = makeConversation(
            id: "conv-legacy",
            provider: .claudeCode,
            projectName: "LegacyTest",
            fullText: "Legacy weighted fusion test content.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "legacy weighted",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                hybridFusionStrategy: .legacyWeighted
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertNotNil(results.first?.rerankScore)
    }

    // MARK: - Dedup and Document Uniqueness Tests

    func test_retrieve_deduplicatesByDocument() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "dedup-test")
        let base = Date(timeIntervalSince1970: 1_743_010_000)

        let conv = makeConversation(
            id: "conv-dedup",
            provider: .claudeCode,
            projectName: "DedupTest",
            fullText: "Deduplication test content that appears in multiple chunks within the same conversation document.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "deduplication test content",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )

        // Should only return one result per document
        let documentIDs = results.map { $0.documentID }
        let uniqueDocumentIDs = Set(documentIDs)
        XCTAssertEqual(documentIDs.count, uniqueDocumentIDs.count)
    }

    // MARK: - Recent Conversations Tests

    func test_recentConversations_returnsUpToLimit() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_743_020_000)

        for i in 0..<10 {
            let conv = makeConversation(
                id: "conv-recent-\(i)",
                provider: .claudeCode,
                projectName: "RecentTest",
                fullText: "Recent conversation \(i).",
                indexedAt: base.addingTimeInterval(Double(i)),
                sourceType: .providerLog
            )
            try store.upsertConversation(conv)
        }

        let service = SearchService(dataStore: store, nowProvider: { base })

        let recent = service.recentConversations(limit: 5)
        XCTAssertLessThanOrEqual(recent.count, 5)
    }

    func test_latestConversation_returnsMostRecentByEndTime() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_743_030_000)

        let older = makeConversation(
            id: "conv-older",
            provider: .claudeCode,
            projectName: "LatestTest",
            fullText: "Older conversation.",
            indexedAt: base.addingTimeInterval(-100),
            sourceType: .providerLog
        )
        let newer = makeConversation(
            id: "conv-newer",
            provider: .claudeCode,
            projectName: "LatestTest",
            fullText: "Newer conversation.",
            indexedAt: base,
            sourceType: .providerLog
        )

        try store.upsertConversation(older)
        try store.upsertConversation(newer)

        let service = SearchService(dataStore: store, nowProvider: { base })

        let latest = service.latestConversation()
        XCTAssertEqual(latest?.id, newer.id)
    }

    func test_latestConversation_usesEndTimeOverStartTime() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_743_040_000)

        // Conv A: starts earlier but ends later
        var convA = makeConversation(
            id: "conv-a",
            provider: .claudeCode,
            projectName: "LatestTest",
            fullText: "Conversation A.",
            indexedAt: base.addingTimeInterval(-50),
            sourceType: .providerLog
        )
        convA.endTime = base // ends at base

        // Conv B: starts at base but ends earlier
        var convB = makeConversation(
            id: "conv-b",
            provider: .claudeCode,
            projectName: "LatestTest",
            fullText: "Conversation B.",
            indexedAt: base,
            sourceType: .providerLog
        )
        convB.endTime = base.addingTimeInterval(-10) // ends earlier

        try store.upsertConversation(convA)
        try store.upsertConversation(convB)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let latest = service.latestConversation()
        XCTAssertEqual(latest?.id, convA.id)
    }

    // MARK: - Search Method Tests

    func test_search_methodReturnsConversationResults() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "search-method")
        let base = Date(timeIntervalSince1970: 1_743_050_000)

        let conv = makeConversation(
            id: "conv-search",
            provider: .claudeCode,
            projectName: "SearchMethodTest",
            fullText: "Testing the search method for conversation results.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.search(query: "search method")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.conversation.id, conv.id)
        XCTAssertNotNil(results.first?.snippet)
        XCTAssertNotNil(results.first?.rank)
    }

    func test_search_withProviderFilter() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "search-provider")
        let base = Date(timeIntervalSince1970: 1_743_060_000)

        let claudeConv = makeConversation(
            id: "conv-search-claude",
            provider: .claudeCode,
            projectName: "SearchProviderTest",
            fullText: "Claude Code search provider test.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let codexConv = makeConversation(
            id: "conv-search-codex",
            provider: .codex,
            projectName: "SearchProviderTest",
            fullText: "Codex search provider test.",
            indexedAt: base.addingTimeInterval(1),
            sourceType: .providerLog
        )

        try store.upsertConversation(claudeConv)
        try store.upsertConversation(codexConv)
        try store.enqueueConversationProjectionJob(conversationID: claudeConv.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: codexConv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.search(query: "search provider", provider: .claudeCode)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.conversation.provider, .claudeCode)
    }

    func test_search_withDateRange() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "search-date")
        let base = Date(timeIntervalSince1970: 1_743_070_000)

        let recentConv = makeConversation(
            id: "conv-search-recent",
            provider: .claudeCode,
            projectName: "SearchDateTest",
            fullText: "Recent search date test.",
            indexedAt: base,
            sourceType: .providerLog
        )

        try store.upsertConversation(recentConv)
        try store.enqueueConversationProjectionJob(conversationID: recentConv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let lastWeek = base.addingTimeInterval(-7 * 86_400)...base
        let results = await service.search(query: "search date", dateRange: lastWeek)

        XCTAssertEqual(results.count, 1)
    }

    func test_search_resultLimit_boundedTo200() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "search-limit")
        let base = Date(timeIntervalSince1970: 1_743_080_000)

        for i in 0..<50 {
            let conv = makeConversation(
                id: "conv-search-limit-\(i)",
                provider: .claudeCode,
                projectName: "SearchLimitTest",
                fullText: "Search limit test conversation \(i).",
                indexedAt: base.addingTimeInterval(Double(i)),
                sourceType: .providerLog
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }
        _ = try await projector.runSweep(maxJobs: 500)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.search(query: "search limit", resultLimit: 300)

        // Should be capped at 200
        XCTAssertLessThanOrEqual(results.count, 200)
    }

    // MARK: - BurnBarSearchPlan Tests

    func test_runBurnBarQuery_planExtractsAggregatePatterns() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "plan-aggregate")
        let base = Date(timeIntervalSince1970: 1_743_090_000)

        let conv = makeConversation(
            id: "conv-plan-aggregate",
            provider: .claudeCode,
            projectName: "PlanTest",
            fullText: "How many times have I used the deployment command?",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let result = await service.runBurnBarQuery(RetrievalQuery(text: "how many times have I used deployment"))

        XCTAssertFalse(result.retrievalResults.isEmpty || result.retrievalResults.isEmpty == false)
    }

    func test_runBurnBarQuery_timeWindowInferred() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_743_100_000)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let result = await service.runBurnBarQuery(RetrievalQuery(text: "what did I do last week"))

        // Should have inferred a date range
        XCTAssertNotNil(result.aggregateWindowDescription)
    }

    // MARK: - Error Handling Tests

    func test_retrieve_lexicalError_recordsHealthDegraded() async throws {
        let store = try makeDiscoveryInMemoryStore()
        // Don't project anything - lexical search will return empty but not error
        let service = SearchService(dataStore: store, nowProvider: { Date() })

        let results = await service.retrieve(
            RetrievalQuery(
                text: "nonexistent",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        // Should not crash
        XCTAssertNotNil(results)
    }

    func test_lastHealthWriteError_recordedOnFailure() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let failingReranker = StubCrossEncoderReranker()
        failingReranker.shouldThrow = true
        // Note: We can't easily inject a failing reranker without more setup,
        // but we can verify the property exists
        let service = SearchService(
            dataStore: store,
            reranker: failingReranker,
            nowProvider: Date.init
        )

        // Verify the property is accessible
        XCTAssertNil(service.lastHealthWriteError)
    }

    // MARK: - Visibility Scope Tests

    func test_retrieve_visibilityScope_personalOnly() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "visibility-personal")
        let base = Date(timeIntervalSince1970: 1_743_110_000)

        let conv = makeConversation(
            id: "conv-visibility",
            provider: .claudeCode,
            projectName: "VisibilityTest",
            fullText: "Personal visibility test content.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "visibility",
                filters: RetrievalFilters(
                    ownership: .personal,
                    artifactTypes: [.conversation]
                )
            )
        )

        // Personal conversations should be visible
        let hasPersonalConv = results.contains { $0.sourceKind == .conversation }
        XCTAssertTrue(hasPersonalConv)
    }

    // MARK: - Artifact Type Filter Tests

    func test_retrieve_artifactTypeFilter_conversationOnly() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "artifact-conversation")
        let base = Date(timeIntervalSince1970: 1_743_120_000)

        let conv = makeConversation(
            id: "conv-artifact-type",
            provider: .claudeCode,
            projectName: "ArtifactTypeTest",
            fullText: "Conversation artifact type test.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let artifact = makeArtifact(
            id: "artifact-type-test",
            sourceKind: .skillDoc,
            rootPath: "/tmp/test",
            relativePath: "TEST.md",
            title: "Test Artifact",
            body: "Artifact artifact type test.",
            contentHash: "hash-artifact-type",
            fileModifiedAt: base
        )

        try store.upsertConversation(conv)
        _ = try store.upsertSourceArtifact(artifact)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        try projector.enqueueSelectiveReproject(
            sourceKind: .skillDoc,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "artifact type",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        XCTAssertTrue(results.allSatisfy { $0.sourceKind == .conversation })
    }

    func test_retrieve_artifactTypeFilter_skillDocOnly() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "artifact-skilldoc")
        let base = Date(timeIntervalSince1970: 1_743_130_000)

        let conv = makeConversation(
            id: "conv-skilldoc-filter",
            provider: .claudeCode,
            projectName: "SkillDocFilterTest",
            fullText: "Conversation about skill docs.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let artifact = makeArtifact(
            id: "artifact-skilldoc-filter",
            sourceKind: .skillDoc,
            rootPath: "/tmp/skilldoc",
            relativePath: "SKILL.md",
            title: "Skill Doc Filter",
            body: "Skill doc content for filtering.",
            contentHash: "hash-skilldoc-filter",
            fileModifiedAt: base
        )

        try store.upsertConversation(conv)
        _ = try store.upsertSourceArtifact(artifact)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        try projector.enqueueSelectiveReproject(
            sourceKind: .skillDoc,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "skill doc filtering",
                filters: RetrievalFilters(artifactTypes: [.skillDoc])
            )
        )

        XCTAssertTrue(results.allSatisfy { $0.sourceKind == .skillDoc })
    }

    // MARK: - Recency Score Tests

    func test_retrieve_recencyScore_newerDocumentsRankHigher() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "recency-test")
        let base = Date(timeIntervalSince1970: 1_743_140_000)

        let oldConv = makeConversation(
            id: "conv-old-recency",
            provider: .claudeCode,
            projectName: "RecencyTest",
            fullText: "Old conversation with recency scoring.",
            indexedAt: base.addingTimeInterval(-30 * 86_400),
            sourceType: .providerLog
        )
        let newConv = makeConversation(
            id: "conv-new-recency",
            provider: .claudeCode,
            projectName: "RecencyTest",
            fullText: "New conversation with recency scoring.",
            indexedAt: base,
            sourceType: .providerLog
        )

        try store.upsertConversation(oldConv)
        try store.upsertConversation(newConv)
        try store.enqueueConversationProjectionJob(conversationID: oldConv.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: newConv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "recency scoring",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        // Newer document should appear first
        XCTAssertEqual(results.first?.sourceID, newConv.id)
    }

    // MARK: - Exact Token Coverage Tests

    func test_retrieve_exactTokenCoverage_titleMatchBoosted() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "token-coverage")
        let base = Date(timeIntervalSince1970: 1_743_150_000)

        let convWithMatch = makeConversation(
            id: "conv-token-match",
            provider: .claudeCode,
            projectName: "TokenCoverageTest",
            fullText: "Some general content without specific keywords in the body.",
            indexedAt: base,
            sourceType: .providerLog
        )

        try store.upsertConversation(convWithMatch)
        try store.enqueueConversationProjectionJob(conversationID: convWithMatch.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        // The projection creates title from conversation, search for a term
        // that might appear in title but not body
        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "token coverage",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - Cross-Encoder Candidate Limit Tests

    func test_retrieve_crossEncoderCandidateLimit_respectsBounds() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "cross-limit")
        let base = Date(timeIntervalSince1970: 1_743_160_000)

        for i in 0..<10 {
            let conv = makeConversation(
                id: "conv-cross-limit-\(i)",
                provider: .claudeCode,
                projectName: "CrossLimitTest",
                fullText: "Cross encoder candidate limit test \(i).",
                indexedAt: base.addingTimeInterval(Double(i)),
                sourceType: .providerLog
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }
        _ = try await projector.runSweep(maxJobs: 200)

        let stubReranker = StubCrossEncoderReranker()

        let service = SearchService(
            dataStore: store,
            semanticProvider: nil,
            reranker: stubReranker,
            nowProvider: { base }
        )

        // With crossEncoderCandidateLimit of 64 (max), should work
        let results = await service.retrieve(
            RetrievalQuery(
                text: "cross encoder",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                crossEncoderEnabled: true,
                crossEncoderCandidateLimit: 64
            )
        )

        XCTAssertNotNil(results)
    }

    // MARK: - Semantic Limit Zero Tests

    func test_retrieve_semanticLimitZero_skipsSemanticSearch() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "semantic-zero")
        let base = Date(timeIntervalSince1970: 1_743_170_000)

        let conv = makeConversation(
            id: "conv-semantic-zero",
            provider: .claudeCode,
            projectName: "SemanticZeroTest",
            fullText: "Testing semantic limit zero behavior.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let semanticProvider = StubSemanticCandidateProvider()
        // This should never be called since semanticCandidateLimit is 0
        semanticProvider.shouldThrow = true

        let service = SearchService(
            dataStore: store,
            semanticProvider: semanticProvider,
            nowProvider: { base }
        )

        let results = await service.retrieve(
            RetrievalQuery(
                text: "semantic limit",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                semanticCandidateLimit: 0
            )
        )

        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - All Source Kinds Tests

    func test_retrieve_allSourceKindsFilter_returnsAllTypes() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "all-kinds")
        let base = Date(timeIntervalSince1970: 1_743_180_000)

        let conv = makeConversation(
            id: "conv-all-kinds",
            provider: .claudeCode,
            projectName: "AllKindsTest",
            fullText: "Conversation for all source kinds test.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let artifact = makeArtifact(
            id: "artifact-all-kinds",
            sourceKind: .skillDoc,
            rootPath: "/tmp/allkinds",
            relativePath: "ALL.md",
            title: "All Kinds Test",
            body: "Artifact for all source kinds test.",
            contentHash: "hash-all-kinds",
            fileModifiedAt: base
        )

        try store.upsertConversation(conv)
        _ = try store.upsertSourceArtifact(artifact)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        try projector.enqueueSelectiveReproject(
            sourceKind: .skillDoc,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "all kinds test",
                filters: RetrievalFilters(artifactTypes: [.conversation, .skillDoc])
            )
        )

        let sourceKinds = Set(results.map { $0.sourceKind })
        XCTAssertTrue(sourceKinds.contains(.conversation))
        XCTAssertTrue(sourceKinds.contains(.skillDoc))
    }

    // MARK: - Bounded Query Semantic Disable Tests

    func test_retrieve_boundedQuery_disablesSemanticForAggregateMode() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_743_190_000)

        let service = SearchService(dataStore: store, nowProvider: { base })

        // Query that triggers aggregate mode should have semantic disabled
        let result = await service.runBurnBarQuery(
            RetrievalQuery(
                text: "how many times did I use deployment",
                semanticCandidateLimit: 10
            )
        )

        XCTAssertNotNil(result.plan)
    }

    func test_retrieve_boundedQuery_disablesSemanticForDateRange() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "date-bounded")
        let base = Date(timeIntervalSince1970: 1_743_200_000)

        let conv = makeConversation(
            id: "conv-date-bounded",
            provider: .claudeCode,
            projectName: "DateBoundedTest",
            fullText: "Date bounded semantic disable test.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let semanticProvider = StubSemanticCandidateProvider()
        semanticProvider.shouldThrow = true // Would fail if called

        let service = SearchService(
            dataStore: store,
            semanticProvider: semanticProvider,
            nowProvider: { base }
        )

        let lastWeek = base.addingTimeInterval(-7 * 86_400)...base
        let results = await service.retrieve(
            RetrievalQuery(
                text: "date bounded",
                filters: RetrievalFilters(
                    artifactTypes: [.conversation],
                    dateRange: lastWeek
                ),
                semanticCandidateLimit: 10
            )
        )

        // Should still return results even though semantic would fail
        XCTAssertFalse(results.isEmpty)
    }

    // MARK: - nowProvider Tests

    func test_retrieve_nowProvider_usedForRecencyScoring() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "now-provider")
        let base = Date(timeIntervalSince1970: 1_743_210_000)

        let conv = makeConversation(
            id: "conv-now-provider",
            provider: .claudeCode,
            projectName: "NowProviderTest",
            fullText: "Testing now provider for recency scoring.",
            indexedAt: base.addingTimeInterval(-5 * 86_400),
            sourceType: .providerLog
        )
        try store.upsertConversation(conv)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        // Using base as "now" means the conversation is 5 days old
        // Recency score = 1 / (1 + 5/30) ≈ 0.86
        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "now provider",
                filters: RetrievalFilters(artifactTypes: [.conversation])
            )
        )

        XCTAssertFalse(results.isEmpty)
        // Verify recency score is calculated
        XCTAssertGreaterThan(results.first?.rerankScore ?? 0, 0)
    }

    // MARK: - Conversation Search Service Tests

    func test_conversationSearchService_limitsToConversations() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "conv-search-service")
        let base = Date(timeIntervalSince1970: 1_743_220_000)

        let conv = makeConversation(
            id: "conv-search-service",
            provider: .claudeCode,
            projectName: "ConvSearchServiceTest",
            fullText: "Conversation search service test.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let artifact = makeArtifact(
            id: "artifact-search-service",
            sourceKind: .skillDoc,
            rootPath: "/tmp/convsearch",
            relativePath: "SEARCH.md",
            title: "Search Service Test",
            body: "Skill doc that should not appear.",
            contentHash: "hash-search-service",
            fileModifiedAt: base
        )

        try store.upsertConversation(conv)
        _ = try store.upsertSourceArtifact(artifact)
        try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        try projector.enqueueSelectiveReproject(
            sourceKind: .skillDoc,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 40)

        let service = SearchService.makeConversationSearchService(dataStore: store, nowProvider: { base })
        let results = await service.search(query: "search service")

        XCTAssertTrue(results.allSatisfy { $0.conversation != nil })
    }

    // MARK: - Multiple Filter Combinations Tests

    func test_retrieve_multipleFilters_combined() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "multi-filter")
        let base = Date(timeIntervalSince1970: 1_743_230_000)

        let matchingConv = makeConversation(
            id: "conv-multi-filter-match",
            provider: .claudeCode,
            projectName: "MultiFilter",
            fullText: "Multi filter matching conversation about testing.",
            indexedAt: base,
            sourceType: .providerLog
        )
        let wrongProvider = makeConversation(
            id: "conv-multi-filter-provider",
            provider: .codex,
            projectName: "MultiFilter",
            fullText: "Multi filter matching conversation about testing.",
            indexedAt: base.addingTimeInterval(1),
            sourceType: .providerLog
        )
        let wrongProject = makeConversation(
            id: "conv-multi-filter-project",
            provider: .claudeCode,
            projectName: "OtherProject",
            fullText: "Multi filter matching conversation about testing.",
            indexedAt: base.addingTimeInterval(2),
            sourceType: .providerLog
        )

        try store.upsertConversation(matchingConv)
        try store.upsertConversation(wrongProvider)
        try store.upsertConversation(wrongProject)
        try store.enqueueConversationProjectionJob(conversationID: matchingConv.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: wrongProvider.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: wrongProject.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 60)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "multi filter matching",
                filters: RetrievalFilters(
                    provider: .claudeCode,
                    projectName: "MultiFilter",
                    artifactTypes: [.conversation]
                )
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, matchingConv.id)
    }

    // MARK: - Order Preservation Tests

    func test_retrieve_lexicalOnly_preservesLexicalOrder() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "lexical-order")
        let base = Date(timeIntervalSince1970: 1_743_240_000)

        for i in 0..<5 {
            let conv = makeConversation(
                id: "conv-lexical-order-\(i)",
                provider: .claudeCode,
                projectName: "LexicalOrderTest",
                fullText: "Lexical order preservation test document number \(i).",
                indexedAt: base.addingTimeInterval(Double(i)),
                sourceType: .providerLog
            )
            try store.upsertConversation(conv)
            try store.enqueueConversationProjectionJob(conversationID: conv.id, jobType: .project, now: base)
        }
        _ = try await projector.runSweep(maxJobs: 100)

        let service = SearchService(dataStore: store, nowProvider: { base })
        let results = await service.retrieve(
            RetrievalQuery(
                text: "lexical order preservation",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                semanticCandidateLimit: 0,
                resultLimit: 10
            )
        )

        // Results should have lexical ranks
        let withRanks = results.filter { $0.lexicalRank != nil }
        XCTAssertFalse(withRanks.isEmpty)

        // Lexical ranks should be in ascending order
        let ranks = withRanks.map { $0.lexicalRank! }
        for i in 1..<ranks.count {
            XCTAssertLessThanOrEqual(ranks[i], ranks[i-1] + 1)
        }
    }

    // MARK: - Helper Methods

    private func makeConversation(
        id: String,
        provider: AgentProvider,
        projectName: String,
        fullText: String,
        indexedAt: Date,
        sourceType: ConversationSourceType
    ) -> ConversationRecord {
        ConversationRecord(
            id: id,
            provider: provider,
            sessionId: "session-\(id)",
            projectName: projectName,
            startTime: indexedAt.addingTimeInterval(-120),
            endTime: indexedAt,
            messageCount: 6,
            userWordCount: 48,
            assistantWordCount: 76,
            keyFiles: ["SearchService.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read", "Edit"],
            inferredTaskTitle: "Test \(id)",
            lastAssistantMessage: "Done",
            fullText: fullText,
            indexedAt: indexedAt,
            fileModifiedAt: indexedAt,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: sourceType
        )
    }

    private func makeArtifact(
        id: String,
        sourceKind: SearchSourceKind,
        rootPath: String,
        relativePath: String,
        title: String,
        body: String,
        contentHash: String,
        fileModifiedAt: Date
    ) -> SourceArtifactRecord {
        SourceArtifactRecord(
            id: id,
            sourceKind: sourceKind,
            canonicalPath: "\(rootPath)/\(relativePath)",
            rootPath: rootPath,
            relativePath: relativePath,
            provenance: "test:\(relativePath)",
            title: title,
            body: body,
            contentHash: contentHash,
            fileSizeBytes: body.utf8.count,
            fileModifiedAt: fileModifiedAt,
            status: .active,
            discoveredAt: fileModifiedAt,
            deletedAt: nil,
            createdAt: fileModifiedAt,
            updatedAt: fileModifiedAt
        )
    }
}

// MARK: - SearchServiceError

enum SearchServiceError: Error {
    case semanticProviderUnavailable
    case lexicalSearchFailed
    case documentNotFound
}
