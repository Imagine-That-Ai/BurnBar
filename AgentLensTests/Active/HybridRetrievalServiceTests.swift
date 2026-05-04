import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
private final class StubSemanticCandidateProvider: SemanticCandidateProviding {
    enum StubError: Error {
        case forced
    }

    var responses: [String: [SemanticCandidate]]
    var shouldThrow = false

    init(responses: [String: [SemanticCandidate]] = [:]) {
        self.responses = responses
    }

    func semanticCandidates(for query: String, filters _: RetrievalFilters, limit: Int) async throws -> [SemanticCandidate] {
        if shouldThrow {
            throw StubError.forced
        }
        return Array((responses[query] ?? []).prefix(max(0, limit)))
    }
}

@MainActor
final class HybridRetrievalServiceTests: XCTestCase {
    func test_retrieval_lexicalWinsAgainstSemanticOnlyCandidate() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-lexical-wins")
        let base = Date(timeIntervalSince1970: 1_742_700_000)

        let lexicalConversation = makeConversation(
            id: "conv-lexical",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Discussion about quartzwind rollout and release hardening.",
            indexedAt: base.addingTimeInterval(-120),
            sourceType: .providerLog
        )
        let semanticConversation = makeConversation(
            id: "conv-semantic",
            provider: .codex,
            projectName: "Beta",
            fullText: "This thread focuses on runtime migration and queue tuning.",
            indexedAt: base.addingTimeInterval(-60),
            sourceType: .providerLog
        )

        try store.upsertConversation(lexicalConversation)
        try store.upsertConversation(semanticConversation)
        try store.enqueueConversationProjectionJob(conversationID: lexicalConversation.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: semanticConversation.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        guard
            let semanticDoc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == semanticConversation.id }),
            let semanticChunk = try store.fetchSearchChunks(documentID: semanticDoc.id).first
        else {
            return XCTFail("Expected projected semantic conversation chunk.")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "quartzwind": [SemanticCandidate(chunkID: semanticChunk.id, score: 0.99)]
            ]
        )
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "quartzwind",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.sourceID, lexicalConversation.id)
        XCTAssertEqual(results.first?.sourceKind, .conversation)
    }

    func test_retrieval_semanticRescueReturnsResultWhenLexicalIsEmpty() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-semantic-rescue")
        let base = Date(timeIntervalSince1970: 1_742_710_000)

        let artifact = makeArtifact(
            id: "artifact-semantic-rescue",
            sourceKind: .skillDoc,
            rootPath: "/tmp/alpha-repo",
            relativePath: "SKILL.md",
            title: "Bootstrap skill",
            body: "Workstation bootstrap checklist for new machine setup.",
            contentHash: "hash-semantic-rescue",
            fileModifiedAt: base
        )

        _ = try store.upsertSourceArtifact(artifact)
        try projector.enqueueSelectiveReproject(
            sourceKind: artifact.sourceKind,
            sourceID: artifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: artifact.contentHash),
            jobType: .project,
            priority: 5
        )
        _ = try await projector.runSweep(maxJobs: 10)

        guard
            let artifactDoc = try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == artifact.id }),
            let artifactChunk = try store.fetchSearchChunks(documentID: artifactDoc.id).first
        else {
            return XCTFail("Expected projected artifact chunk for semantic rescue.")
        }

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "onboarding runbook": [SemanticCandidate(chunkID: artifactChunk.id, score: 0.92)]
            ]
        )
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "onboarding runbook",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 10
            )
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.sourceID, artifact.id)
        XCTAssertEqual(results.first?.sourceKind, .skillDoc)
        XCTAssertNotNil(results.first?.semanticScore)
        XCTAssertNil(results.first?.lexicalRank)
    }

    func test_retrieval_emptyQueryReturnsNoResults() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let retrieval = SearchService(dataStore: store)

        let results = await retrieval.retrieve(RetrievalQuery(text: "   \n\t  "))
        XCTAssertTrue(results.isEmpty)
    }

    func test_retrieval_filters_applyProviderProjectArtifactDateOwnershipAndSource() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-filters")
        let base = Date(timeIntervalSince1970: 1_742_720_000)

        let convClaude = makeConversation(
            id: "conv-claude-alpha",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-86_400),
            sourceType: .providerLog
        )
        let convCodex = makeConversation(
            id: "conv-codex-beta",
            provider: .codex,
            projectName: "Beta",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-40 * 86_400),
            sourceType: .providerLog
        )
        let convCLI = makeConversation(
            id: "conv-cli-alpha",
            provider: .factory,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            indexedAt: base.addingTimeInterval(-2 * 86_400),
            sourceType: .cliAssistant
        )

        try store.upsertConversation(convClaude)
        try store.upsertConversation(convCodex)
        try store.upsertConversation(convCLI)
        try store.enqueueConversationProjectionJob(conversationID: convClaude.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convCodex.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: convCLI.id, jobType: .project, now: base)

        let skillArtifact = makeArtifact(
            id: "artifact-skill-alpha",
            sourceKind: .skillDoc,
            rootPath: "/tmp/AlphaRepo",
            relativePath: "SKILL.md",
            title: "Skill Alpha",
            body: "filterneedle task continuity and release notes",
            contentHash: "hash-skill-alpha",
            fileModifiedAt: base.addingTimeInterval(-3 * 86_400)
        )
        let sharedArtifact = makeArtifact(
            id: "artifact-shared-alpha",
            sourceKind: .sharedArtifact,
            rootPath: "/tmp/SharedRepo",
            relativePath: "SHARED.md",
            title: "Shared Alpha",
            body: "filterneedle task continuity and release notes",
            contentHash: "hash-shared-alpha",
            fileModifiedAt: base.addingTimeInterval(-4 * 86_400)
        )

        _ = try store.upsertSourceArtifact(skillArtifact)
        _ = try store.upsertSourceArtifact(sharedArtifact)
        let sharedAccess = SharedArtifactAccessContext(
            userID: "user-alpha",
            workspaceID: "workspace-alpha",
            teamID: "team-alpha"
        )
        _ = try store.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sharedArtifact.id,
                workspaceID: sharedAccess.workspaceID,
                teamID: sharedAccess.teamID,
                principalType: .user,
                principalID: sharedAccess.userID,
                role: .editor,
                visibility: .team,
                canRead: true,
                canWrite: true,
                canShare: false,
                createdAt: base,
                updatedAt: base
            )
        )
        try projector.enqueueSelectiveReproject(
            sourceKind: skillArtifact.sourceKind,
            sourceID: skillArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: skillArtifact.contentHash),
            jobType: .project,
            priority: 5
        )
        try projector.enqueueSelectiveReproject(
            sourceKind: sharedArtifact.sourceKind,
            sourceID: sharedArtifact.id,
            sourceVersionID: ProjectionIdentity.artifactSourceVersionID(contentHash: sharedArtifact.contentHash),
            jobType: .project,
            priority: 5
        )

        _ = try await projector.runSweep(maxJobs: 40)

        let retrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { sharedAccess },
            nowProvider: { base }
        )

        let providerFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(provider: .claudeCode, artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(providerFiltered.map(\.sourceID)), Set([convClaude.id]))

        let projectFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(projectName: "Alpha", artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(projectFiltered.map(\.sourceID)), Set([convClaude.id, convCLI.id]))

        let artifactTypeFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(artifactTypeFiltered.map(\.sourceID)), Set([skillArtifact.id]))

        let recentConversationRange = base.addingTimeInterval(-7 * 86_400)...base
        let dateFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(artifactTypes: [.conversation], dateRange: recentConversationRange),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(dateFiltered.map(\.sourceID)), Set([convClaude.id, convCLI.id]))

        let sharedOnly = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(sharedOnly.map(\.sourceID)), Set([sharedArtifact.id]))
        XCTAssertTrue(sharedOnly.allSatisfy { $0.sourceKind == .sharedArtifact })

        let sourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(sourceIDs: [skillArtifact.id]),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(sourceFiltered.map(\.sourceID)), Set([skillArtifact.id]))

        let conversationSourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: "filterneedle",
                filters: RetrievalFilters(
                    artifactTypes: [.conversation],
                    conversationSources: [.cliAssistant]
                ),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(conversationSourceFiltered.map(\.sourceID)), Set([convCLI.id]))
        XCTAssertTrue(conversationSourceFiltered.allSatisfy { $0.conversation?.sourceType == .cliAssistant })
    }

    func test_retrieval_dateFilter_usesConversationSessionTimeAheadOfFileModifiedAt() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-date-filter-session-time")
        let base = Date(timeIntervalSince1970: 1_742_720_000)

        let oldSessionTime = base.addingTimeInterval(-20 * 86_400)
        let conversation = ConversationRecord(
            id: "conv-date-filter-drift",
            provider: .claudeCode,
            sessionId: "session-conv-date-filter-drift",
            projectName: "Alpha",
            startTime: oldSessionTime.addingTimeInterval(-900),
            endTime: oldSessionTime,
            messageCount: 4,
            userWordCount: 12,
            assistantWordCount: 18,
            keyFiles: ["SearchService.swift"],
            keyCommands: ["swift test"],
            keyTools: ["Read"],
            inferredTaskTitle: "Old session with new mtime",
            lastAssistantMessage: "Done",
            fullText: "timefilterneedle appears in an old conversation",
            indexedAt: base,
            fileModifiedAt: base,
            summary: nil,
            summaryTitle: nil,
            summaryUpdatedAt: nil,
            summaryProvider: nil,
            summaryModel: nil,
            sourceType: .providerLog
        )

        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let retrieval = SearchService(dataStore: store, nowProvider: { base })
        let lastWeek = base.addingTimeInterval(-7 * 86_400)...base
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "timefilterneedle",
                filters: RetrievalFilters(artifactTypes: [.conversation], dateRange: lastWeek),
                resultLimit: 20
            )
        )

        XCTAssertTrue(results.isEmpty)
    }

    func test_retrieval_sharedArtifactVisibility_requiresReadablePermission() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-rbac")
        let base = Date(timeIntervalSince1970: 1_742_721_000)

        let sharedArtifact = makeArtifact(
            id: "artifact-shared-rbac",
            sourceKind: .sharedArtifact,
            rootPath: "/tmp/SharedRepo",
            relativePath: "RBAC.md",
            title: "Shared RBAC",
            body: "rbacneedle team visibility and permissions",
            contentHash: "hash-shared-rbac",
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

        let noAccess = SharedArtifactAccessContext(
            userID: "user-no-access",
            workspaceID: "workspace-a",
            teamID: "team-a"
        )
        let noAccessRetrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { noAccess },
            nowProvider: { base }
        )
        let hiddenResults = await noAccessRetrieval.retrieve(
            RetrievalQuery(
                text: "rbacneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertTrue(hiddenResults.isEmpty)

        _ = try store.upsertSharedArtifactPermission(
            SharedArtifactPermissionRecord(
                sourceArtifactID: sharedArtifact.id,
                workspaceID: "workspace-a",
                teamID: "team-a",
                principalType: .team,
                principalID: "team-a",
                role: .viewer,
                visibility: .team,
                canRead: true,
                canWrite: false,
                canShare: false,
                createdAt: base,
                updatedAt: base
            )
        )

        let teamMember = SharedArtifactAccessContext(
            userID: "user-team-member",
            workspaceID: "workspace-a",
            teamID: "team-a"
        )
        let teamRetrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { teamMember },
            nowProvider: { base }
        )
        let visibleResults = await teamRetrieval.retrieve(
            RetrievalQuery(
                text: "rbacneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertEqual(Set(visibleResults.map(\.sourceID)), Set([sharedArtifact.id]))

        let differentTeam = SharedArtifactAccessContext(
            userID: "user-other-team",
            workspaceID: "workspace-a",
            teamID: "team-b"
        )
        let blockedRetrieval = SearchService(
            dataStore: store,
            sharedArtifactAccessContextProvider: { differentTeam },
            nowProvider: { base }
        )
        let blockedResults = await blockedRetrieval.retrieve(
            RetrievalQuery(
                text: "rbacneedle",
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        XCTAssertTrue(blockedResults.isEmpty)
    }

    func test_conversationSearch_keepsParityBetweenChatAndSessionLogs() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "conversation-search-parity")
        let base = Date(timeIntervalSince1970: 1_742_725_000)

        let providerConversation = makeConversation(
            id: "conv-parity-provider",
            provider: .claudeCode,
            projectName: "Parity",
            fullText: "parityneedle release hardening and rollout checklist",
            indexedAt: base.addingTimeInterval(-120),
            sourceType: .providerLog
        )
        let assistantConversation = makeConversation(
            id: "conv-parity-assistant",
            provider: .factory,
            projectName: "Parity",
            fullText: "parityneedle follow-up in assistant context",
            indexedAt: base.addingTimeInterval(-60),
            sourceType: .cliAssistant
        )

        try store.upsertConversation(providerConversation)
        try store.upsertConversation(assistantConversation)
        try store.enqueueConversationProjectionJob(conversationID: providerConversation.id, jobType: .project, now: base)
        try store.enqueueConversationProjectionJob(conversationID: assistantConversation.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let chatSearch = SearchService.makeConversationSearchService(dataStore: store, nowProvider: { base })
        let sessionLogSearch = SearchService.makeConversationSearchService(dataStore: store, nowProvider: { base })
        let query = "parityneedle"

        let chatResults = await chatSearch.search(query: query)
        let sessionLogResults = await sessionLogSearch.search(query: query, conversationSources: nil)

        XCTAssertEqual(chatResults.map(\.conversation.id), sessionLogResults.map(\.conversation.id))

        let providerOnly = await sessionLogSearch.search(query: query, conversationSources: [.providerLog])
        XCTAssertEqual(Set(providerOnly.map(\.conversation.id)), Set([providerConversation.id]))

        let assistantOnly = await sessionLogSearch.search(query: query, conversationSources: [.cliAssistant])
        XCTAssertEqual(Set(assistantOnly.map(\.conversation.id)), Set([assistantConversation.id]))
    }

    func test_conversationSearch_singleWordQuerySkipsSemanticExpansion() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "conversation-search-single-word")
        let base = Date(timeIntervalSince1970: 1_742_726_000)

        let conversation = makeConversation(
            id: "conv-single-word-precision",
            provider: .claudeCode,
            projectName: "Precision",
            fullText: "Release hardening and rollout checklist for the next milestone.",
            indexedAt: base,
            sourceType: .providerLog
        )

        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let document = try XCTUnwrap(
            try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id })
        )
        let chunk = try XCTUnwrap(try store.fetchSearchChunks(documentID: document.id).first)

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "Xiomara": [SemanticCandidate(chunkID: chunk.id, score: 0.99)]
            ]
        )
        let searchService = SearchService(
            dataStore: store,
            semanticProvider: semanticProvider,
            nowProvider: { base }
        )

        let results = await searchService.search(query: "Xiomara")
        XCTAssertTrue(results.isEmpty)
    }

    func test_conversationSearch_broaderQueryAllowsSemanticRescue() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "conversation-search-broader")
        let base = Date(timeIntervalSince1970: 1_742_726_500)

        let conversation = makeConversation(
            id: "conv-broader-semantic",
            provider: .claudeCode,
            projectName: "Precision",
            fullText: "Bootstrap checklist for new machine provisioning and workstation bring-up.",
            indexedAt: base,
            sourceType: .providerLog
        )

        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let document = try XCTUnwrap(
            try store.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == conversation.id })
        )
        let chunk = try XCTUnwrap(try store.fetchSearchChunks(documentID: document.id).first)

        let semanticProvider = StubSemanticCandidateProvider(
            responses: [
                "employee onboarding playbook": [SemanticCandidate(chunkID: chunk.id, score: 0.92)]
            ]
        )
        let searchService = SearchService(
            dataStore: store,
            semanticProvider: semanticProvider,
            nowProvider: { base }
        )

        let results = await searchService.search(query: "employee onboarding playbook")
        XCTAssertEqual(results.map(\.conversation.id), [conversation.id])
    }

    func test_vectorSemanticCandidates_annAndExactMatch_whenExactRerankEnabled() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_730_000)
        let embedder = DeterministicFakeEmbeddingProvider(
            dimensions: 64,
            versionTag: "ann-parity-v1",
            seed: "ann-parity-seed-v1"
        )

        let modelID = EmbeddingIdentity.modelID(for: embedder.descriptor)
        let versionID = EmbeddingIdentity.versionID(for: embedder.descriptor)
        try store.upsertEmbeddingModel(
            EmbeddingModelRecord(
                id: modelID,
                provider: embedder.descriptor.provider,
                modelName: embedder.descriptor.modelName,
                dimensions: embedder.descriptor.dimensions,
                distanceMetric: embedder.descriptor.distanceMetric,
                createdAt: base,
                updatedAt: base
            )
        )
        try store.upsertEmbeddingVersion(
            EmbeddingVersionRecord(
                id: versionID,
                modelID: modelID,
                versionTag: embedder.descriptor.versionTag,
                chunkerVersion: embedder.descriptor.chunkerVersion,
                normalizationVersion: embedder.descriptor.normalizationVersion,
                promptVersion: embedder.descriptor.promptVersion,
                isActive: true,
                createdAt: base,
                updatedAt: base
            )
        )

        for index in 0..<96 {
            let docID = "doc-ann-\(index)"
            let sourceID = "artifact-ann-\(index)"
            let title = "ANN Candidate Document \(index)"
            let chunkText: String
            if index % 13 == 0 {
                chunkText = "reliability hardening checklist rollout runbook \(index)"
            } else {
                chunkText = "generic notes \(index) queue metrics stabilization tracking"
            }

            let document = SearchDocumentRecord(
                id: docID,
                sourceKind: .skillDoc,
                sourceID: sourceID,
                sourceVersionID: "v\(index)",
                provider: nil,
                projectName: "VectorParity",
                title: title,
                subtitle: "SKILL.md",
                bodyPreview: String(chunkText.prefix(120)),
                sourceUpdatedAt: base,
                indexedAt: base,
                contentHash: "hash-\(index)",
                createdAt: base,
                updatedAt: base
            )
            try store.upsertSearchDocument(document)

            let chunk = SearchChunkRecord(
                id: "chunk-ann-\(index)",
                documentID: docID,
                sourceKind: .skillDoc,
                sourceID: sourceID,
                sourceVersionID: "v\(index)",
                ordinal: 0,
                startOffset: 0,
                endOffset: chunkText.utf16.count,
                messageStartOffset: nil,
                messageEndOffset: nil,
                sectionPath: nil,
                text: chunkText,
                createdAt: base,
                updatedAt: base
            )
            try store.replaceSearchChunks(documentID: docID, title: title, chunks: [chunk])

            let vector = try await embedder.embedding(for: chunkText)
            try store.upsertChunkEmbedding(
                ChunkEmbeddingRecord(
                    chunkID: chunk.id,
                    embeddingVersionID: versionID,
                    vectorBlob: VectorBlobCodec.encode(vector),
                    createdAt: base,
                    updatedAt: base
                )
            )
        }

        let queryEmbedder = DeterministicQueryEmbeddingProvider(embedder: embedder)
        let vectorIndexRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenBurnBarHybridRetrievalVectorIndex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vectorIndexRootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vectorIndexRootURL) }
        let annProvider = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .ann,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            nowProvider: { base },
            storageRootURL: vectorIndexRootURL
        )
        let exactProvider = VectorSemanticCandidateProvider(
            dataStore: store,
            queryEmbedder: queryEmbedder,
            embeddingVersionID: versionID,
            backend: .exact,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            nowProvider: { base },
            storageRootURL: vectorIndexRootURL
        )

        let query = "reliability hardening checklist rollout"
        let annCandidates = try await annProvider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)
        let exactCandidates = try await exactProvider.semanticCandidates(for: query, filters: RetrievalFilters(), limit: 20)

        XCTAssertEqual(annCandidates.map(\SemanticCandidate.chunkID), exactCandidates.map(\SemanticCandidate.chunkID))
        XCTAssertEqual(annCandidates.count, exactCandidates.count)
        if let annTop = annCandidates.first?.score, let exactTop = exactCandidates.first?.score {
            XCTAssertEqual(annTop, exactTop, accuracy: 0.000001)
        }
    }

    func test_retrieval_semanticFallback_persistsDegradedSemanticHealth() async throws {
        let store = try makeDiscoveryInMemoryStore()
        let projector = ProjectionPipelineService(dataStore: store, leaseOwner: "retrieval-semantic-fallback-health")
        let base = Date(timeIntervalSince1970: 1_742_740_000)

        let conversation = makeConversation(
            id: "conv-semantic-fallback",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Rollout hardening checklist for lexical fallback coverage.",
            indexedAt: base,
            sourceType: .providerLog
        )
        try store.upsertConversation(conversation)
        try store.enqueueConversationProjectionJob(conversationID: conversation.id, jobType: .project, now: base)
        _ = try await projector.runSweep(maxJobs: 20)

        let semanticProvider = StubSemanticCandidateProvider()
        semanticProvider.shouldThrow = true
        let retrieval = SearchService(dataStore: store, semanticProvider: semanticProvider, nowProvider: { base })
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "hardening checklist",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        XCTAssertFalse(results.isEmpty)
        let semanticHealth = try store.fetchRetrievalHealth().first(where: { $0.subsystem == .semantic })
        XCTAssertEqual(semanticHealth?.status, .degraded)
        XCTAssertEqual(semanticHealth?.errorCode, "SEMANTIC_PROVIDER_FALLBACK")
    }

    func test_retrievalHealthService_reportsDegradedModes_forIndexSemanticRebuildAndCloud() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_750_000)

        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .degraded,
                errorCode: "PROJECTION_JOBS_DEGRADED",
                errorMessage: "Projection queue has pending jobs.",
                detailsJSON: #"{"queueDepth":3,"failedJobs":1}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
                status: .degraded,
                errorCode: "SEMANTIC_NO_EMBEDDINGS",
                errorMessage: "No embeddings indexed yet.",
                detailsJSON: #"{"backend":"ann","indexedVectorCount":0,"candidateCount":0}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "rebuild-job-1",
                jobType: .rebuild,
                sourceVersionID: "rebuild-v1",
                status: .queued,
                priority: 1,
                attempts: 0,
                maxAttempts: 3,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )

        let service = RetrievalHealthService(dataStore: store, nowProvider: { base })
        let snapshot = service.snapshot(indexingEnabled: true, sharedFeaturesAvailable: false)
        let modes = Set(snapshot.degradedModes.map(\.mode))

        XCTAssertTrue(modes.contains(.indexStale))
        XCTAssertTrue(modes.contains(.semanticUnavailable))
        XCTAssertTrue(modes.contains(.rebuildInProgress))
        XCTAssertTrue(modes.contains(.cloudSharedUnavailable))
    }

    func test_retrievalHealthService_hidesIndexModesWhenIndexingDisabled() throws {
        let store = try makeDiscoveryInMemoryStore()
        let base = Date(timeIntervalSince1970: 1_742_760_000)

        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .projection,
                status: .degraded,
                errorCode: "PROJECTION_JOBS_DEGRADED",
                errorMessage: "Projection queue has pending jobs.",
                detailsJSON: #"{"queueDepth":2,"failedJobs":0}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
                status: .failed,
                errorCode: "SEMANTIC_BACKEND_QUERY_FAILED",
                errorMessage: "Semantic backend failed.",
                detailsJSON: #"{"backend":"ann","indexedVectorCount":0,"candidateCount":0}"#,
                observedAt: base,
                updatedAt: base
            )
        )
        try store.enqueueProjectionJob(
            ProjectionJobRecord(
                id: "rebuild-job-2",
                jobType: .rebuild,
                sourceVersionID: "rebuild-v2",
                status: .queued,
                priority: 1,
                attempts: 0,
                maxAttempts: 3,
                scheduledAt: base,
                availableAt: base,
                createdAt: base,
                updatedAt: base
            )
        )

        let service = RetrievalHealthService(dataStore: store, nowProvider: { base })
        let snapshot = service.snapshot(indexingEnabled: false, sharedFeaturesAvailable: true)
        let modes = Set(snapshot.degradedModes.map(\.mode))

        XCTAssertFalse(modes.contains(.indexStale))
        XCTAssertFalse(modes.contains(.semanticUnavailable))
        XCTAssertFalse(modes.contains(.rebuildInProgress))
    }

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
            inferredTaskTitle: "Retrieval Test \(id)",
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

