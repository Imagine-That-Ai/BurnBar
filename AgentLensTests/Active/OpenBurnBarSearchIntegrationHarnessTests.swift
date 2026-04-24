import XCTest
import Dispatch
import Darwin
import OpenBurnBarCore
@testable import OpenBurnBar

@MainActor
final class OpenBurnBarSearchIntegrationHarnessTests: XCTestCase {
    func test_harnessClockAndEmbedder_areDeterministic() async throws {
        let base = Date(timeIntervalSince1970: 1_742_800_000)
        let harness = try OpenBurnBarSearchIntegrationHarness(
            name: "determinism",
            initialTime: base,
            embedderSeed: "determinism-seed-v1",
            embedderVersionTag: "determinism-v1"
        )
        defer { harness.cleanup() }

        XCTAssertEqual(harness.clock.now(), base)

        let chunkVectorA = try await harness.embedder.embedding(for: "deterministic harness prompt")
        let chunkVectorB = try await harness.embedder.embedding(for: "deterministic harness prompt")
        let queryVector = try await harness.queryEmbedder.embedding(for: "deterministic harness prompt")

        XCTAssertEqual(chunkVectorA, chunkVectorB)
        XCTAssertEqual(chunkVectorA, queryVector)
        XCTAssertEqual(chunkVectorA.count, harness.embedder.descriptor.dimensions)

        _ = harness.clock.advance(seconds: 120)
        XCTAssertEqual(
            harness.clock.now().timeIntervalSince1970,
            base.addingTimeInterval(120).timeIntervalSince1970,
            accuracy: 0.0001
        )
    }

    func test_fileRootFixtures_discoverOnlyRegisteredRoots() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "discovery-fixtures")
        defer { harness.cleanup() }

        try harness.writeSkillFixture(relativePath: "SKILL.md", body: "# Skill\nHarness skill fixture")
        try harness.writeAgentFixture(relativePath: "docs/AGENTS.md", body: "# Agent\nHarness agent fixture")
        try harness.writeAgentFixture(
            relativePath: "AGENTS.md",
            body: "# Outside\nShould not be discovered",
            rootURL: harness.fileRoots.outsideRootURL
        )

        let (service, _) = harness.makeDiscoveryService(
            registeredRoots: [harness.fileRoots.registeredProjectRootURL]
        )
        let report = try service.discoverAndIngest()

        XCTAssertEqual(report.discoveredArtifacts, 2)
        XCTAssertEqual(report.insertedArtifacts, 2)
        XCTAssertEqual(report.issues.count, 0)

        let artifacts = try harness.dataStore.fetchSourceArtifacts(
            includeDeleted: false,
            rootPaths: nil,
            sourceKinds: [.skillDoc, .agentDoc]
        )
        XCTAssertEqual(artifacts.count, 2)
        XCTAssertTrue(
            artifacts.allSatisfy { $0.rootPath == harness.fileRoots.registeredProjectRootURL.path }
        )

        let queuedJobs = try harness.dataStore.fetchProjectionJobs(statuses: [.queued], limit: 20)
        XCTAssertEqual(queuedJobs.count, 2)
    }

    func test_queueHelpers_projectConversationSkillAndSharedArtifacts() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "queue-roundtrip")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-harness",
            fullText: "harnessneedle conversation retrieval coverage"
        )
        let skill = harness.makeSkillArtifactFixture(
            id: "artifact-skill-harness",
            body: "# Skill\nharnessneedle setup checklist"
        )
        let shared = harness.makeSharedArtifactFixture(
            id: "artifact-shared-harness",
            body: "# Shared\nharnessneedle collaborative runbook"
        )

        try harness.dataStore.upsertConversation(conversation)
        _ = try harness.dataStore.upsertSourceArtifact(skill)
        _ = try harness.dataStore.upsertSourceArtifact(shared)
        _ = try harness.grantSharedReadAccess(to: shared.id)

        _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        _ = try harness.enqueueArtifactProjection(skill, jobType: .project)
        _ = try harness.enqueueArtifactProjection(shared, jobType: .project)
        let report = try await harness.drainProjectionQueue(
            maxSweeps: 6,
            maxJobsPerSweep: 32,
            advanceClockBy: 2
        )
        XCTAssertGreaterThanOrEqual(report.completedJobs, 3)

        let retrieval = harness.makeSearchService(semanticEnabled: true)
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "harnessneedle",
                filters: RetrievalFilters(ownership: .any),
                resultLimit: 10
            )
        )

        let sourceIDs = Set(results.map(\.sourceID))
        XCTAssertTrue(sourceIDs.contains(conversation.id))
        XCTAssertTrue(sourceIDs.contains(skill.id))
        XCTAssertTrue(sourceIDs.contains(shared.id))
    }

    func test_rebuildHelper_enqueuesReprojectAndPurgeCandidates() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "rebuild-helper")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-rebuild-harness",
            fullText: "rebuild harness coverage"
        )
        let activeArtifact = harness.makeSkillArtifactFixture(
            id: "artifact-active-harness",
            body: "# Skill\nactive"
        )
        let deletedArtifact = harness.makeSharedArtifactFixture(
            id: "artifact-deleted-harness",
            body: "# Shared\ndeleted"
        )

        try harness.dataStore.upsertConversation(conversation)
        _ = try harness.dataStore.upsertSourceArtifact(activeArtifact)
        _ = try harness.dataStore.upsertSourceArtifact(deletedArtifact)
        XCTAssertTrue(try harness.dataStore.markSourceArtifactDeleted(id: deletedArtifact.id, deletedAt: harness.clock.now()))

        try harness.enqueueRebuild(reason: "harness-rebuild", priority: 1)
        let rebuildSweep = try await harness.runProjectionSweep(maxJobs: 1, leaseOwner: "rebuild-harness-worker")
        XCTAssertEqual(rebuildSweep.completedJobs, 1)

        let queued = try harness.dataStore.fetchProjectionJobs(statuses: [.queued], limit: 40)
        XCTAssertTrue(
            queued.contains(where: {
                $0.jobType == .reproject && $0.sourceKind == .conversation && $0.sourceID == conversation.id
            })
        )
        XCTAssertTrue(
            queued.contains(where: {
                $0.jobType == .reproject
                    && $0.sourceKind == activeArtifact.sourceKind
                    && $0.sourceID == activeArtifact.id
            })
        )
        XCTAssertTrue(
            queued.contains(where: {
                $0.jobType == .purge
                    && $0.sourceKind == deletedArtifact.sourceKind
                    && $0.sourceID == deletedArtifact.id
            })
        )
        XCTAssertTrue(queued.contains(where: { $0.jobType == .reembed }))
    }

    func test_degradedStateAssertions_detectSemanticFailures() throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "degraded-assertions")
        defer { harness.cleanup() }

        let now = harness.clock.now()
        try harness.dataStore.upsertRetrievalHealth(
            RetrievalHealthRecord(
                subsystem: .semantic,
                status: .degraded,
                errorCode: "SEMANTIC_EMBEDDING_INDEXING_FAILED",
                errorMessage: "Forced embedding failure in harness test.",
                detailsJSON: #"{"indexedVectorCount":0,"candidateCount":0}"#,
                observedAt: now,
                updatedAt: now
            )
        )

        try harness.assertDegraded(
            subsystem: .semantic,
            errorCode: "SEMANTIC_EMBEDDING_INDEXING_FAILED"
        )
        harness.assertDegradedModes(
            [.semanticUnavailable],
            indexingEnabled: true,
            sharedFeaturesAvailable: true
        )
    }

    func test_projectionPerf_queueLatencyAndThroughput_guardrails() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "projection-perf")
        defer { harness.cleanup() }

        let jobCount = 180
        for index in 0..<jobCount {
            let conversation = harness.makeConversationFixture(
                id: "conv-projection-perf-\(index)",
                fullText: String(
                    repeating: "Projection throughput guardrail payload \(index) with indexed search content. ",
                    count: 55
                )
            )
            try harness.dataStore.upsertConversation(conversation)
            _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        }

        let startedAt = monotonicNow()
        let report = try await harness.drainProjectionQueue(maxSweeps: 16, maxJobsPerSweep: 96, advanceClockBy: 1)
        let elapsedMs = elapsedMilliseconds(since: startedAt)
        let throughputJobsPerSecond = Double(report.completedJobs) / max(0.001, elapsedMs / 1_000)

        XCTAssertGreaterThanOrEqual(report.completedJobs, jobCount)
        XCTAssertLessThan(elapsedMs, 15_000)
        XCTAssertGreaterThanOrEqual(throughputJobsPerSecond, 15)
        XCTAssertTrue(
            try harness.dataStore.fetchProjectionJobs(statuses: [.queued, .failed, .leased, .running], limit: 1).isEmpty
        )

        let projectionHealth = try XCTUnwrap(harness.retrievalHealthRecord(for: .projection))
        let details = try XCTUnwrap(decodeJSONDictionary(projectionHealth.detailsJSON))
        let performance = try XCTUnwrap(details["performance"] as? [String: Any])
        XCTAssertNotNil(doubleValue(from: performance["sweepDurationMs"]))
        XCTAssertNotNil(doubleValue(from: performance["throughputJobsPerSecond"]))
        let latencySummary = try XCTUnwrap(details["latencySummary"] as? [String: Any])
        XCTAssertNotNil(intValue(from: latencySummary["sampledCompletedJobs"]))
    }

    func test_retrievalPerf_queryLatency_guardrails_withWarmCorpus() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "query-latency-perf")
        defer { harness.cleanup() }

        for index in 0..<140 {
            let conversation = harness.makeConversationFixture(
                id: "conv-query-perf-\(index)",
                fullText: """
                Reliability hardening rollout \(index). Queue stabilization and fallback planning.
                \(String(repeating: "token\(index) search ranking coverage. ", count: 36))
                """
            )
            try harness.dataStore.upsertConversation(conversation)
            _ = try harness.enqueueConversationProjection(conversationID: conversation.id, jobType: .project)
        }

        for index in 0..<90 {
            let artifact = harness.makeSkillArtifactFixture(
                id: "artifact-query-perf-\(index)",
                relativePath: "docs/SKILL-\(index).md",
                title: "Skill Query Perf \(index)",
                body: """
                # Skill \(index)
                Reliability hardening checklist and rollout runbook.
                \(String(repeating: "semantic candidate and lexical fallback validation. ", count: 30))
                """
            )
            _ = try harness.dataStore.upsertSourceArtifact(artifact)
            _ = try harness.enqueueArtifactProjection(artifact, jobType: .project)
        }

        _ = try await harness.drainProjectionQueue(maxSweeps: 24, maxJobsPerSweep: 96, advanceClockBy: 1)

        let retrieval = harness.makeSearchService(
            semanticEnabled: true,
            semanticBackend: .ann,
            exactRerankEnabled: true,
            exactRerankLimit: 320
        )

        _ = await retrieval.retrieve(
            RetrievalQuery(
                text: "reliability hardening rollout",
                filters: RetrievalFilters(ownership: .any),
                resultLimit: 20
            )
        )

        var latencies: [Double] = []
        for iteration in 0..<18 {
            let startedAt = monotonicNow()
            let results = await retrieval.retrieve(
                RetrievalQuery(
                    text: iteration.isMultiple(of: 2) ? "reliability hardening rollout" : "queue stabilization fallback",
                    filters: RetrievalFilters(ownership: .any),
                    resultLimit: 20
                )
            )
            latencies.append(elapsedMilliseconds(since: startedAt))
            XCTAssertFalse(results.isEmpty)
        }

        let p95LatencyMs = percentile(95, in: latencies)
        XCTAssertLessThan(p95LatencyMs, 900)

        let lexicalHealth = try XCTUnwrap(harness.retrievalHealthRecord(for: .lexical))
        let lexicalDetails = try XCTUnwrap(decodeJSONDictionary(lexicalHealth.detailsJSON))
        XCTAssertNotNil(doubleValue(from: lexicalDetails["totalQueryLatencyMs"]))
        XCTAssertNotNil(doubleValue(from: lexicalDetails["lexicalQueryLatencyMs"]))
        XCTAssertNotNil(doubleValue(from: lexicalDetails["semanticQueryLatencyMs"]))
        XCTAssertNotNil(doubleValue(from: lexicalDetails["rerankLatencyMs"]))
    }

    func test_semanticPerf_annCandidateGeneration_andExactRerank_metricsGuardrails() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "semantic-ann-perf")
        defer { harness.cleanup() }

        for index in 0..<220 {
            let artifact = harness.makeSkillArtifactFixture(
                id: "artifact-semantic-perf-\(index)",
                relativePath: "skill/ANN-\(index).md",
                title: "ANN Perf \(index)",
                body: index.isMultiple(of: 11)
                    ? "reliability hardening checklist rollout runbook \(index) \(String(repeating: "focus term ", count: 20))"
                    : "generic indexing payload \(index) \(String(repeating: "background term ", count: 20))"
            )
            _ = try harness.dataStore.upsertSourceArtifact(artifact)
            _ = try harness.enqueueArtifactProjection(artifact, jobType: .project)
        }
        _ = try await harness.drainProjectionQueue(maxSweeps: 24, maxJobsPerSweep: 96, advanceClockBy: 1)

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
        let annStartedAt = monotonicNow()
        let annCandidates = try await annProvider.semanticCandidates(
            for: query,
            filters: RetrievalFilters(),
            limit: 24
        )
        let annElapsedMs = elapsedMilliseconds(since: annStartedAt)
        XCTAssertFalse(annCandidates.isEmpty)

        let semanticHealth = try XCTUnwrap(harness.retrievalHealthRecord(for: .semantic))
        let semanticDetails = try XCTUnwrap(decodeJSONDictionary(semanticHealth.detailsJSON))
        XCTAssertEqual(boolValue(from: semanticDetails["fallbackToExact"]), false)
        XCTAssertLessThanOrEqual(intValue(from: semanticDetails["candidateCount"]) ?? Int.max, 24)
        XCTAssertNotNil(doubleValue(from: semanticDetails["annCandidateGenerationLatencyMs"]))
        XCTAssertNotNil(doubleValue(from: semanticDetails["exactRerankLatencyMs"]))
        XCTAssertLessThanOrEqual(doubleValue(from: semanticDetails["totalQueryLatencyMs"]) ?? .greatestFiniteMagnitude, 1_200)
        XCTAssertLessThan(annElapsedMs, 1_200)

        let exactCandidates = try await exactProvider.semanticCandidates(
            for: query,
            filters: RetrievalFilters(),
            limit: 24
        )
        XCTAssertEqual(annCandidates.map(\.chunkID), exactCandidates.map(\.chunkID))
    }

    func test_longArtifacts_memoryAndChunking_remainBounded() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "memory-long-artifacts")
        defer { harness.cleanup() }

        let longConversation = harness.makeConversationFixture(
            id: "conv-memory-long",
            fullText: String(
                repeating: "Long transcript memory guardrail content with search indexing payload. ",
                count: 26_000
            )
        )
        let longArtifact = harness.makeSkillArtifactFixture(
            id: "artifact-memory-long",
            relativePath: "docs/LONG-SKILL.md",
            title: "Long Skill Memory Guardrail",
            body: String(
                repeating: "Long artifact memory guardrail body with retrieval substrate content. ",
                count: 24_000
            )
        )

        let residentBefore = residentMemoryBytes()
        try harness.dataStore.upsertConversation(longConversation)
        _ = try harness.dataStore.upsertSourceArtifact(longArtifact)
        _ = try harness.enqueueConversationProjection(conversationID: longConversation.id, jobType: .project)
        _ = try harness.enqueueArtifactProjection(longArtifact, jobType: .project)
        _ = try await harness.drainProjectionQueue(maxSweeps: 20, maxJobsPerSweep: 64, advanceClockBy: 1)

        let retrieval = harness.makeSearchService(semanticEnabled: true)
        let results = await retrieval.retrieve(
            RetrievalQuery(
                text: "memory guardrail retrieval substrate",
                filters: RetrievalFilters(ownership: .any),
                resultLimit: 10
            )
        )
        XCTAssertFalse(results.isEmpty)

        let residentAfter = residentMemoryBytes()
        if residentBefore > 0, residentAfter >= residentBefore {
            XCTAssertLessThan(Double(residentAfter - residentBefore), 220 * 1_024 * 1_024)
        }

        let documents = try harness.dataStore.fetchSearchDocuments(limit: 100)
        let conversationDocument = try XCTUnwrap(documents.first(where: { $0.sourceID == longConversation.id }))
        let artifactDocument = try XCTUnwrap(documents.first(where: { $0.sourceID == longArtifact.id }))

        let conversationChunks = try harness.dataStore.fetchSearchChunks(documentID: conversationDocument.id)
        let artifactChunks = try harness.dataStore.fetchSearchChunks(documentID: artifactDocument.id)
        XCTAssertFalse(conversationChunks.isEmpty)
        XCTAssertFalse(artifactChunks.isEmpty)
        XCTAssertLessThanOrEqual(conversationChunks.count, 400)
        XCTAssertLessThanOrEqual(artifactChunks.count, 400)
        XCTAssertTrue(conversationChunks.allSatisfy { $0.endOffset > $0.startOffset })
        XCTAssertTrue(artifactChunks.allSatisfy { $0.endOffset > $0.startOffset })
    }

    func test_runBurnBarQuery_aggregateCountsQuotedPhrase() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "aggregate-mixed")
        defer { harness.cleanup() }

        let conversation = harness.makeConversationFixture(
            id: "conv-agg-hello",
            fullText: "hello hello world"
        )
        try harness.dataStore.upsertConversation(conversation)

        let retrieval = harness.makeSearchService(semanticEnabled: false)
        let run = await retrieval.runBurnBarQuery(
            RetrievalQuery(
                text: #"How many times did I say "hello"?"#,
                filters: RetrievalFilters(ownership: .any),
                resultLimit: 10
            )
        )

        XCTAssertEqual(run.plan.mode, .mixed)
        XCTAssertEqual(Set(run.plan.aggregatePatterns), ["hello"])
        XCTAssertEqual(run.aggregateOccurrenceCount, 2)
    }

    func test_runBurnBarQuery_aggregateCountsExplicitProfanityWithinLastWeek() async throws {
        let base = Date(timeIntervalSince1970: 1_742_000_000)
        let harness = try OpenBurnBarSearchIntegrationHarness(
            name: "aggregate-profanity-last-week",
            initialTime: base
        )
        defer { harness.cleanup() }

        let recentConversation = OpenBurnBarSearchFixtureBuilder.conversation(
            id: "conv-agg-fuck-recent",
            fullText: "fuck fuck week",
            indexedAt: base.addingTimeInterval(-2 * 86_400)
        )
        let oldConversation = OpenBurnBarSearchFixtureBuilder.conversation(
            id: "conv-agg-fuck-old",
            fullText: "fuck",
            indexedAt: base.addingTimeInterval(-10 * 86_400)
        )

        try harness.dataStore.upsertConversation(recentConversation)
        try harness.dataStore.upsertConversation(oldConversation)
        try harness.dataStore.enqueueConversationProjectionJob(
            conversationID: recentConversation.id,
            jobType: .project,
            now: base
        )
        try harness.dataStore.enqueueConversationProjectionJob(
            conversationID: oldConversation.id,
            jobType: .project,
            now: base
        )
        _ = try await harness.runProjectionSweep(maxJobs: 20)

        let lastWeek = try XCTUnwrap(
            BurnBarSearchTimeWindow.inferredDateRange(
                from: "how many times have i said fuck in the last week",
                now: base,
                calendar: .current
            )
        )
        let directCount = try harness.dataStore.countOccurrencesInConversationFullText(
            patterns: ["fuck"],
            dateRange: lastWeek
        )
        XCTAssertEqual(directCount, 2)

        let retrieval = harness.makeSearchService(semanticEnabled: false)
        let run = await retrieval.runBurnBarQuery(
            RetrievalQuery(
                text: "how many times have i said fuck in the last week",
                filters: RetrievalFilters(ownership: .any),
                resultLimit: 10
            )
        )

        XCTAssertEqual(run.plan.aggregatePatterns, ["fuck"])
        XCTAssertEqual(run.aggregateOccurrenceCount, 2)
        XCTAssertEqual(run.retrievalResults.compactMap(\.conversation?.id), [recentConversation.id])
    }

    private func monotonicNow() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private func elapsedMilliseconds(since start: UInt64) -> Double {
        let end = DispatchTime.now().uptimeNanoseconds
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    private func percentile(_ percentile: Double, in values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        let sorted = values.sorted()
        let boundedPercentile = max(0, min(100, percentile))
        let index = Int(round((boundedPercentile / 100) * Double(sorted.count - 1)))
        return sorted[max(0, min(sorted.count - 1, index))]
    }

    private func decodeJSONDictionary(_ json: String?) -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func doubleValue(from raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    private func intValue(from raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private func boolValue(from raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.lowercased() {
            case "true", "1", "yes":
                return true
            case "false", "0", "no":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
