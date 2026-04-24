import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar
@MainActor
final class OpenBurnBarRetrievalReplayGoldenTests: XCTestCase {
    func test_replayGolden_lexicalWin() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "replay-lexical-win")
        defer { harness.cleanup() }

        let lexicalConversation = harness.makeConversationFixture(
            id: "conv-replay-lexical",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Discussion about quartzwind rollout and release hardening."
        )
        let semanticConversation = harness.makeConversationFixture(
            id: "conv-replay-semantic",
            provider: .codex,
            projectName: "Beta",
            fullText: "This thread focuses on runtime migration and queue tuning."
        )

        try harness.dataStore.upsertConversation(lexicalConversation)
        try harness.dataStore.upsertConversation(semanticConversation)
        _ = try harness.enqueueConversationProjection(conversationID: lexicalConversation.id, jobType: .project)
        _ = try harness.enqueueConversationProjection(conversationID: semanticConversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 6, maxJobsPerSweep: 32, advanceClockBy: 1)

        let semanticDoc = try XCTUnwrap(
            try harness.dataStore.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == semanticConversation.id })
        )
        let semanticChunk = try XCTUnwrap(try harness.dataStore.fetchSearchChunks(documentID: semanticDoc.id).first)

        let semanticProvider = ReplayStubSemanticCandidateProvider(
            responses: [
                "quartzwind": [SemanticCandidate(chunkID: semanticChunk.id, score: 0.99)]
            ]
        )
        let retrieval = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: semanticProvider,
            sharedArtifactAccessContextProvider: { harness.sharedAccessContext },
            nowProvider: { harness.clock.now() }
        )

        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "quartzwind",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        let snapshot = RetrievalReplayGoldenSnapshot(
            scenario: "lexical-win",
            query: "quartzwind",
            resultSourceIDs: results.map(\.sourceID),
            topResults: summarize(results, limit: 4)
        )
        try OpenBurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-lexical-win.json")
    }

    func test_replayGolden_semanticRescue() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "replay-semantic-rescue")
        defer { harness.cleanup() }

        let artifact = harness.makeSkillArtifactFixture(
            id: "artifact-semantic-rescue",
            relativePath: "skills/BOOTSTRAP.md",
            title: "Bootstrap skill",
            body: "Workstation bootstrap checklist for new machine setup."
        )

        _ = try harness.dataStore.upsertSourceArtifact(artifact)
        _ = try harness.enqueueArtifactProjection(artifact, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 6, maxJobsPerSweep: 32, advanceClockBy: 1)

        let document = try XCTUnwrap(
            try harness.dataStore.fetchSearchDocuments(limit: 20).first(where: { $0.sourceID == artifact.id })
        )
        let chunk = try XCTUnwrap(try harness.dataStore.fetchSearchChunks(documentID: document.id).first)

        let semanticProvider = ReplayStubSemanticCandidateProvider(
            responses: [
                "onboarding runbook": [SemanticCandidate(chunkID: chunk.id, score: 0.92)]
            ]
        )
        let retrieval = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: semanticProvider,
            sharedArtifactAccessContextProvider: { harness.sharedAccessContext },
            nowProvider: { harness.clock.now() }
        )
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "onboarding runbook",
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 10
            )
        )

        let snapshot = RetrievalReplayGoldenSnapshot(
            scenario: "semantic-rescue",
            query: "onboarding runbook",
            resultSourceIDs: results.map(\.sourceID),
            topResults: summarize(results, limit: 4)
        )
        try OpenBurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-semantic-rescue.json")
    }

    func test_replayGolden_degradedModeFallback() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "replay-degraded-fallback")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-semantic-fallback",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "Rollout hardening checklist for lexical fallback coverage."
        )
        try harness.dataStore.upsertConversation(conversation)
        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 6, maxJobsPerSweep: 32, advanceClockBy: 1)

        let semanticProvider = ReplayStubSemanticCandidateProvider()
        semanticProvider.shouldThrow = true
        let retrieval = SearchService(
            dataStore: harness.dataStore,
            semanticProvider: semanticProvider,
            sharedArtifactAccessContextProvider: { harness.sharedAccessContext },
            nowProvider: { harness.clock.now() }
        )
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "hardening checklist",
                filters: RetrievalFilters(artifactTypes: [.conversation]),
                resultLimit: 10
            )
        )

        let lexicalHealth = try harness.retrievalHealthRecord(for: .lexical)
        let semanticHealth = try harness.retrievalHealthRecord(for: .semantic)
        let degradedModes = harness
            .healthSnapshot(indexingEnabled: true, sharedFeaturesAvailable: true)
            .degradedModes
            .map(\.mode.rawValue)
            .sorted()

        let snapshot = RetrievalDegradedFallbackGoldenSnapshot(
            scenario: "degraded-fallback",
            query: "hardening checklist",
            resultSourceIDs: results.map(\.sourceID),
            lexicalHealthStatus: lexicalHealth?.status.rawValue,
            lexicalErrorCode: lexicalHealth?.errorCode,
            semanticHealthStatus: semanticHealth?.status.rawValue,
            semanticErrorCode: semanticHealth?.errorCode,
            degradedModes: degradedModes
        )
        try OpenBurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-degraded-fallback.json")
    }

    func test_replayGolden_filterCorrectness() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "replay-filter-correctness")
        defer { harness.cleanup() }

        let base = Date(timeIntervalSince1970: 1_742_720_000)

        _ = harness.clock.set(base.addingTimeInterval(-86_400))
        let convClaude = harness.makeConversationFixture(
            id: "conv-filter-claude-alpha",
            provider: .claudeCode,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            sourceType: .providerLog
        )
        _ = harness.clock.set(base.addingTimeInterval(-40 * 86_400))
        let convCodex = harness.makeConversationFixture(
            id: "conv-filter-codex-beta",
            provider: .codex,
            projectName: "Beta",
            fullText: "filterneedle task continuity and release notes",
            sourceType: .providerLog
        )
        _ = harness.clock.set(base.addingTimeInterval(-2 * 86_400))
        let convCLI = harness.makeConversationFixture(
            id: "conv-filter-cli-alpha",
            provider: .factory,
            projectName: "Alpha",
            fullText: "filterneedle task continuity and release notes",
            sourceType: .cliAssistant
        )
        _ = harness.clock.set(base)

        try harness.dataStore.upsertConversation(convClaude)
        try harness.dataStore.upsertConversation(convCodex)
        try harness.dataStore.upsertConversation(convCLI)
        _ = try harness.enqueueConversationProjection(conversationID: convClaude.id, jobType: .project)
        _ = try harness.enqueueConversationProjection(conversationID: convCodex.id, jobType: .project)
        _ = try harness.enqueueConversationProjection(conversationID: convCLI.id, jobType: .project)

        _ = harness.clock.set(base.addingTimeInterval(-3 * 86_400))
        let skillArtifact = harness.makeSkillArtifactFixture(
            id: "artifact-filter-skill",
            relativePath: "SKILL.md",
            title: "Skill Alpha",
            body: "filterneedle task continuity and release notes"
        )
        _ = harness.clock.set(base.addingTimeInterval(-4 * 86_400))
        let sharedArtifact = harness.makeSharedArtifactFixture(
            id: "artifact-filter-shared",
            relativePath: "SHARED.md",
            title: "Shared Alpha",
            body: "filterneedle task continuity and release notes"
        )
        _ = harness.clock.set(base)

        _ = try harness.dataStore.upsertSourceArtifact(skillArtifact)
        _ = try harness.dataStore.upsertSourceArtifact(sharedArtifact)
        _ = try harness.grantSharedReadAccess(to: sharedArtifact.id)
        _ = try harness.enqueueArtifactProjection(skillArtifact, jobType: .project)
        _ = try harness.enqueueArtifactProjection(sharedArtifact, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 8, maxJobsPerSweep: 64, advanceClockBy: 1)

        let retrieval = harness.makeSearchService(semanticEnabled: false)
        let query = "filterneedle"

        let providerFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(provider: .claudeCode, artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        let projectFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(projectName: "Alpha", artifactTypes: [.conversation]),
                resultLimit: 20
            )
        )
        let artifactTypeFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(artifactTypes: [.skillDoc]),
                resultLimit: 20
            )
        )
        let dateRangeFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(
                    artifactTypes: [.conversation],
                    dateRange: base.addingTimeInterval(-7 * 86_400)...base
                ),
                resultLimit: 20
            )
        )
        let sharedOnly = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(ownership: .shared),
                resultLimit: 20
            )
        )
        let sourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(sourceIDs: [skillArtifact.id]),
                resultLimit: 20
            )
        )
        let conversationSourceFiltered = await retrieval.retrieve(
            RetrievalQuery(
                text: query,
                filters: RetrievalFilters(artifactTypes: [.conversation], conversationSources: [.cliAssistant]),
                resultLimit: 20
            )
        )

        let snapshot = RetrievalFilterGoldenSnapshot(
            scenario: "filter-correctness",
            query: query,
            cases: [
                RetrievalFilterCaseSnapshot(
                    name: "provider_claude_conversation",
                    sourceIDs: sortedUnique(providerFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "project_alpha_conversation",
                    sourceIDs: sortedUnique(projectFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "artifact_type_skill_doc",
                    sourceIDs: sortedUnique(artifactTypeFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "date_range_recent_conversation",
                    sourceIDs: sortedUnique(dateRangeFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "ownership_shared_only",
                    sourceIDs: sortedUnique(sharedOnly.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "explicit_source_id",
                    sourceIDs: sortedUnique(sourceFiltered.map(\.sourceID))
                ),
                RetrievalFilterCaseSnapshot(
                    name: "conversation_source_cli_assistant",
                    sourceIDs: sortedUnique(conversationSourceFiltered.map(\.sourceID))
                )
            ]
        )
        try OpenBurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-filter-correctness.json")
    }

    func test_replayGolden_annMatchesExactRerankBaseline() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "replay-ann-baseline")
        defer { harness.cleanup() }

        for index in 0..<48 {
            _ = harness.clock.advance(seconds: 1)
            let body: String
            if index % 9 == 0 {
                body = "reliability hardening checklist rollout runbook \(index)"
            } else {
                body = "generic notes \(index) queue metrics stabilization tracking"
            }
            let artifact = harness.makeSkillArtifactFixture(
                id: "artifact-ann-\(index)",
                relativePath: "skills/ann-\(index).md",
                title: "ANN Candidate \(index)",
                body: body
            )
            _ = try harness.dataStore.upsertSourceArtifact(artifact)
            _ = try harness.enqueueArtifactProjection(artifact, jobType: .project)
        }
        _ = try await harness.drainProjectionQueue(maxSweeps: 12, maxJobsPerSweep: 128, advanceClockBy: 1)

        let annProvider = VectorSemanticCandidateProvider(
            dataStore: harness.dataStore,
            queryEmbedder: harness.queryEmbedder,
            backend: .ann,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            nowProvider: { harness.clock.now() }
        )
        let exactProvider = VectorSemanticCandidateProvider(
            dataStore: harness.dataStore,
            queryEmbedder: harness.queryEmbedder,
            backend: .exact,
            exactRerankEnabled: true,
            exactRerankLimit: 256,
            nowProvider: { harness.clock.now() }
        )

        let query = "reliability hardening checklist rollout"
        let annCandidates = try await annProvider.semanticCandidates(
            for: query,
            filters: RetrievalFilters(artifactTypes: [.skillDoc]),
            limit: 20
        )
        let exactCandidates = try await exactProvider.semanticCandidates(
            for: query,
            filters: RetrievalFilters(artifactTypes: [.skillDoc]),
            limit: 20
        )

        XCTAssertEqual(annCandidates.map(\SemanticCandidate.chunkID), exactCandidates.map(\SemanticCandidate.chunkID))

        let snapshot = RetrievalANNBaselineGoldenSnapshot(
            scenario: "ann-vs-exact-rerank",
            query: query,
            annTopCandidates: try summarizeSemantic(annCandidates, limit: 12, dataStore: harness.dataStore),
            exactTopCandidates: try summarizeSemantic(exactCandidates, limit: 12, dataStore: harness.dataStore)
        )
        try OpenBurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "retrieval-ann-vs-exact-baseline.json")
    }

    private func summarize(_ results: [RetrievalResult], limit: Int) -> [ReplayResultShape] {
        Array(results.prefix(limit)).enumerated().map { index, result in
            ReplayResultShape(
                rank: index + 1,
                sourceID: result.sourceID,
                sourceKind: result.sourceKind.rawValue,
                title: result.title,
                hasLexicalSignal: result.lexicalRank != nil,
                hasSemanticSignal: result.semanticScore != nil
            )
        }
    }

    private func summarizeSemantic(
        _ candidates: [SemanticCandidate],
        limit: Int,
        dataStore: DataStore
    ) throws -> [SemanticCandidateSnapshot] {
        let boundedCandidates = Array(candidates.prefix(limit))
        let chunkIDs = Array(Set(boundedCandidates.map(\.chunkID)))
        let chunks = try dataStore.fetchSearchChunks(ids: chunkIDs)
        let chunkByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
        let documentIDs = Array(Set(chunks.map(\.documentID)))
        let documents = try dataStore.fetchSearchDocuments(ids: documentIDs)
        let documentByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

        return boundedCandidates.map { candidate in
            let sourceID = chunkByID[candidate.chunkID]
                .flatMap { documentByID[$0.documentID]?.sourceID } ?? "missing-source"
            return SemanticCandidateSnapshot(
                sourceID: sourceID,
                score: rounded(candidate.score)
            )
        }
    }

    private func rounded(_ value: Double, precision: Double = 1_000_000) -> Double {
        (value * precision).rounded() / precision
    }

    private func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}

