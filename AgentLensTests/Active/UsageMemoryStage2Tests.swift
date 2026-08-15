import XCTest
import CryptoKit
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - PR7: usage-memory Stage-2 semantic write funnel
//
// Covers the Stage-2 decision table over the same engine/worker fixture
// `UsageMemoryStage1Tests` drains (fake local LLM via a URLProtocol stub,
// deterministic embedding fakes injected through the engine's
// `usageStage2:` seam):
//   * embedding-version registration is idempotent; a novel insert writes the
//     `memory_embedding_refs` row with the registered versionID/dimension and
//     seeds `memory_salience` {hint, hit 0, corroboration 1, policy trust};
//   * cosine ≥ duplicate (0.95): NOT novel — no new row, the winner's
//     corroboration bumps, ONE `near_duplicate` link records the suppressed
//     extraction id, the candidate is still consumed, and a
//     `memory.corroborated` audit event lands (ids/buckets only, no bodies);
//   * cosine in [novelty 0.92, duplicate 0.95): both rows exist plus ONE
//     directed near-dup link (from: new, to: neighbor);
//   * orthogonal vectors: plain insert, no links, per-kind policy trust
//     (0.5 agent_session / 0.7 safari_ask);
//   * exact bodyHash match in the chat partition: skip the usage insert,
//     corroborate the CHAT row (no link — the usage end never exists);
//   * nil embedding: semantic checks skipped — insert + salience seed, no ref.
// The chat lane's regression proof is `MemoryActivationEndToEndTests`, run
// alongside this suite.
@MainActor
final class UsageMemoryStage2Tests: XCTestCase {

    private let scope = MemoryScope(appID: "openburnbar")

    /// minBatch 1 so each test batches exactly the candidates it inserts —
    /// every other knob mirrors `.default`.
    private let singleBatchPolicy = UsageMemoryExtractionPolicy(
        minBatch: 1,
        maxBatch: 15,
        maxPromptChars: 12_000,
        maxOutputTokens: 512,
        maxJobsPerTick: 2,
        perJobWallClock: 60,
        staleBatchAge: 48 * 3600
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        UsageStage2OllamaStub.reset()
        URLProtocol.registerClass(UsageStage2OllamaStub.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(UsageStage2OllamaStub.self)
        UsageStage2OllamaStub.reset()
        try super.tearDownWithError()
    }

    // MARK: - Registration + novel insert

    func test_registrationIsIdempotent_andInsertWritesEmbeddingRefAndSalienceSeed() async throws {
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let provider = DeterministicUsageEmbeddingProvider()
        let service = UsageMemoryEmbeddingService(provider: provider, policy: .defaults)

        let reg1 = try await service.ensureRegistered(store: store)
        let reg2 = try await service.ensureRegistered(store: store)
        XCTAssertEqual(reg1, reg2, "the service caches one registration")
        XCTAssertEqual(reg1?.versionID, EmbeddingIdentity.versionID(for: provider.descriptor))
        XCTAssertEqual(reg1?.dimension, provider.descriptor.dimensions)

        // A separate service instance re-registering the same descriptor is an
        // upsert, never a duplicate row.
        _ = try await UsageMemoryEmbeddingService(provider: provider, policy: .defaults)
            .ensureRegistered(store: store)
        let modelCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_models") ?? -1
        }
        let versionCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embedding_versions") ?? -1
        }
        XCTAssertEqual(modelCount, 1)
        XCTAssertEqual(versionCount, 1)

        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: makeUsageSettings(),
            stage2: service
        )
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let candidate = makeCandidate(text: "Runs xcodegen before every app test pass.", salience: 0.8, now: now)
        let jobID = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [candidate],
            responseJSON: modelJSON(body: "Prefers running xcodegen before app tests.", candidateID: candidate.id),
            now: now
        )

        let memoryID = "memory-\(jobID)-0"
        let ref = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM memory_embedding_refs WHERE memory_id = ?",
                arguments: [memoryID]
            )
        }
        XCTAssertNotNil(ref, "a novel insert writes its embedding ref")
        XCTAssertEqual(ref?["embedding_version_id"] as String?, reg1?.versionID)
        XCTAssertEqual(ref?["dimension"] as Int?, provider.descriptor.dimensions)

        let salience = try await salienceRow(queue, id: memoryID)
        XCTAssertEqual(salience?["salience"] as Double?, 0.8, "seeded with the candidate's Stage-0 hint")
        XCTAssertEqual(salience?["hit_count"] as Int?, 0)
        XCTAssertEqual(salience?["corroboration"] as Int?, 1)
        XCTAssertEqual(salience?["source_trust"] as Double?, 0.5, "agent_session policy trust")
    }

    // MARK: - Duplicate path (cosine >= 0.95)

    func test_duplicateCosine_corroboratesWinnerInsteadOfInserting() async throws {
        let bodyA = "Prefers Swift for every new backend service."
        let bodyB = "Chooses Swift whenever a new backend service starts."
        let provider = ScriptedEmbeddingProvider(vectors: [
            bodyA: [1, 0, 0, 0],
            bodyB: [1, 0, 0, 0]
        ])
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: makeUsageSettings(),
            stage2: UsageMemoryEmbeddingService(provider: provider, policy: .defaults)
        )

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let cand1 = makeCandidate(text: "First sighting of the Swift service preference.", salience: 0.8, now: now)
        let job1 = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand1],
            responseJSON: modelJSON(body: bodyA, candidateID: cand1.id),
            now: now
        )
        let winnerID = "memory-\(job1)-0"

        let cand2 = makeCandidate(text: "Second sighting of the Swift service preference.", salience: 0.6, now: now)
        let job2 = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand2],
            responseJSON: modelJSON(body: bodyB, candidateID: cand2.id),
            now: now
        )
        let suppressedID = "memory-\(job2)-0"

        // NOT novel: no second row, in fact no row at the suppressed id at all.
        let usageCount = try await usageMemoryCount(queue)
        XCTAssertEqual(usageCount, 1)
        let suppressedRow = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM agent_memories WHERE id = ?", arguments: [suppressedID])
        }
        XCTAssertNil(suppressedRow)

        // The winner strengthened instead: corroboration 1 -> 2.
        let salience = try await salienceRow(queue, id: winnerID)
        XCTAssertEqual(salience?["corroboration"] as Int?, 2)
        XCTAssertEqual(salience?["salience"] as Double?, 0.8, "a bump never rewrites the winner's seed")

        // ONE near_duplicate link: from the suppressed extraction id to the winner.
        let links = try await linkRows(queue)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?["from_memory_id"] as String?, suppressedID)
        XCTAssertEqual(links.first?["to_memory_id"] as String?, winnerID)
        XCTAssertEqual(links.first?["link_kind"] as String?, "near_duplicate")
        XCTAssertEqual(links.first?["created_by"] as String?, "stage2")
        let linkScore = try XCTUnwrap(links.first?["score"] as Double?)
        XCTAssertGreaterThanOrEqual(linkScore, 0.99)

        // The suppressed candidate is still consumed by its batch.
        let statusCounts = try await candidateStatusCounts(queue)
        XCTAssertEqual(statusCounts["extracted"], 2)

        // Non-sensitive audit trail: winner id + corroborating kind + bucket.
        let auditLabels = try await corroboratedAuditLabels(queue)
        XCTAssertEqual(auditLabels.count, 1)
        XCTAssertTrue(auditLabels[0].contains("memory_id:\(winnerID)"))
        XCTAssertTrue(auditLabels[0].contains("source_kind:agent_session"))
        XCTAssertTrue(auditLabels[0].contains("score_bucket:1.00"))
    }

    // MARK: - Near-duplicate band [0.92, 0.95)

    func test_nearDuplicateBand_insertsBothAndLinksOnce() async throws {
        let bodyA = "Keeps release notes in the repository changelog."
        let bodyC = "Maintains the changelog inside the repository for releases."
        let bandY = Float((1.0 - 0.93 * 0.93).squareRoot())
        let provider = ScriptedEmbeddingProvider(vectors: [
            bodyA: [1, 0, 0, 0],
            bodyC: [0.93, bandY, 0, 0]
        ])
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: makeUsageSettings(),
            stage2: UsageMemoryEmbeddingService(provider: provider, policy: .defaults)
        )

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let cand1 = makeCandidate(text: "Changelog habit, first sighting.", salience: 0.8, now: now)
        let job1 = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand1],
            responseJSON: modelJSON(body: bodyA, candidateID: cand1.id),
            now: now
        )
        let neighborID = "memory-\(job1)-0"

        let cand2 = makeCandidate(text: "Changelog habit, phrased differently.", salience: 0.7, now: now)
        let job2 = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand2],
            responseJSON: modelJSON(body: bodyC, candidateID: cand2.id),
            now: now
        )
        let newID = "memory-\(job2)-0"

        // Both memories exist (the band inserts, it does not fold).
        let usageCount = try await usageMemoryCount(queue)
        XCTAssertEqual(usageCount, 2)
        let newSalience = try await salienceRow(queue, id: newID)
        XCTAssertEqual(newSalience?["corroboration"] as Int?, 1)

        // Exactly ONE directed link: from the new row to its neighbor.
        let links = try await linkRows(queue)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?["from_memory_id"] as String?, newID)
        XCTAssertEqual(links.first?["to_memory_id"] as String?, neighborID)
        XCTAssertEqual(links.first?["link_kind"] as String?, "near_duplicate")
        let linkScore = try XCTUnwrap(links.first?["score"] as Double?)
        XCTAssertGreaterThanOrEqual(linkScore, 0.92)
        XCTAssertLessThan(linkScore, 0.95)

        // The neighbor was NOT corroborated (band = new fact, not a repeat).
        let neighborSalience = try await salienceRow(queue, id: neighborID)
        XCTAssertEqual(neighborSalience?["corroboration"] as Int?, 1)
    }

    // MARK: - Novel path (orthogonal vectors)

    func test_orthogonalVectors_plainInsertSeedsPolicyTrust_noLinks() async throws {
        let bodyA = "Uses GRDB migrations for every schema change."
        let bodyD = "Writes commit messages in the imperative mood."
        let provider = ScriptedEmbeddingProvider(vectors: [
            bodyA: [1, 0, 0, 0],
            bodyD: [0, 1, 0, 0]
        ])
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: makeUsageSettings(),
            stage2: UsageMemoryEmbeddingService(provider: provider, policy: .defaults)
        )

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let cand1 = makeCandidate(text: "Migration workflow sighting.", salience: 0.8, now: now)
        _ = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand1],
            responseJSON: modelJSON(body: bodyA, candidateID: cand1.id),
            now: now
        )
        let cand2 = makeCandidate(text: "Commit message style sighting.", salience: 0.4, now: now)
        let job2 = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand2],
            responseJSON: modelJSON(body: bodyD, candidateID: cand2.id),
            now: now
        )

        let usageCount = try await usageMemoryCount(queue)
        XCTAssertEqual(usageCount, 2)
        let links = try await linkRows(queue)
        XCTAssertEqual(links.count, 0, "orthogonal facts never link")
        let salience = try await salienceRow(queue, id: "memory-\(job2)-0")
        XCTAssertEqual(salience?["salience"] as Double?, 0.4)
        XCTAssertEqual(salience?["corroboration"] as Int?, 1)
        XCTAssertEqual(salience?["source_trust"] as Double?, 0.5, "agent_session trust from policy")
    }

    func test_safariAskInsert_seedsSalienceWithSafariTrust() async throws {
        let body = "Researches SwiftUI APIs before adopting them."
        let provider = ScriptedEmbeddingProvider(vectors: [body: [0, 0, 0, 1]])
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: makeUsageSettings(),
            stage2: UsageMemoryEmbeddingService(provider: provider, policy: .defaults)
        )

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let candidate = makeCandidate(
            text: "Asked Safari about a SwiftUI API.",
            salience: 0.6,
            now: now,
            sourceKind: .safariAsk,
            sourceRef: "safari:ask-stage2"
        )
        let jobID = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [candidate],
            responseJSON: modelJSON(body: body, candidateID: candidate.id),
            now: now
        )

        let memoryID = "memory-\(jobID)-0"
        let row = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT source_kind FROM agent_memories WHERE id = ?", arguments: [memoryID])
        }
        XCTAssertEqual(row?["source_kind"] as String?, "safari_ask")
        let salience = try await salienceRow(queue, id: memoryID)
        XCTAssertEqual(salience?["source_trust"] as Double?, 0.7, "safari_ask trust from policy")
    }

    // MARK: - Cross-source corroboration vs chat

    func test_chatCrossSource_exactBody_corroboratesChatRowAndSkipsInsert() async throws {
        let sharedBody = "Deploys only after the full test suite is green."
        let provider = ScriptedEmbeddingProvider(vectors: [sharedBody: [0, 0, 1, 0]])
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: makeUsageSettings(),
            stage2: UsageMemoryEmbeddingService(provider: provider, policy: .defaults)
        )

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        _ = try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: sharedBody, scope: scope),
            id: "chat-seed-1",
            sourceKind: .chat,
            now: now,
            enabled: true
        )

        let candidate = makeCandidate(text: "Observed the deploy-only-on-green habit.", salience: 0.8, now: now)
        let jobID = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [candidate],
            responseJSON: modelJSON(body: sharedBody, candidateID: candidate.id),
            now: now
        )

        // The usage twin is never inserted; the chat row stays live.
        let usageCount = try await usageMemoryCount(queue)
        XCTAssertEqual(usageCount, 0)
        let suppressedRow = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM agent_memories WHERE id = ?",
                arguments: ["memory-\(jobID)-0"]
            )
        }
        XCTAssertNil(suppressedRow)
        let chatRow = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT valid_to FROM agent_memories WHERE id = 'chat-seed-1'")
        }
        XCTAssertNotNil(chatRow)
        XCTAssertNil(chatRow?["valid_to"] as Date?)

        // The chat row's salience sidecar carries the corroboration (row seeded
        // at 2 because chat inserts never seed salience themselves).
        let salience = try await salienceRow(queue, id: "chat-seed-1")
        XCTAssertEqual(salience?["corroboration"] as Int?, 2)
        XCTAssertEqual(salience?["source_trust"] as Double?, 1.0, "chat trust from policy")

        // Documented asymmetry: NO memory_links row in this skip-insert path
        // (a supports edge needs both ends to exist as authority rows).
        let links = try await linkRows(queue)
        XCTAssertEqual(links.count, 0)

        let auditLabels = try await corroboratedAuditLabels(queue)
        XCTAssertEqual(auditLabels.count, 1)
        XCTAssertTrue(auditLabels[0].contains("memory_id:chat-seed-1"))
        XCTAssertTrue(auditLabels[0].contains("source_kind:agent_session"))
        XCTAssertTrue(auditLabels[0].contains("score_bucket:exact"))

        // The candidate is still consumed.
        let statusCounts = try await candidateStatusCounts(queue)
        XCTAssertEqual(statusCounts["extracted"], 1)
    }

    // MARK: - Nil-embedding fallback

    func test_nilEmbedding_insertsWithoutRefAndSkipsSemanticChecks() async throws {
        let bodyA = "Pins tool versions in the repository manifest."
        // bodyE is deliberately NOT in the scripted map ⇒ embed returns nil.
        let bodyE = "Texto que el embebedor rechaza por no ser inglés."
        let provider = ScriptedEmbeddingProvider(vectors: [bodyA: [1, 0, 0, 0]])
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: makeUsageSettings(),
            stage2: UsageMemoryEmbeddingService(provider: provider, policy: .defaults)
        )

        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let cand1 = makeCandidate(text: "Tool pinning sighting.", salience: 0.8, now: now)
        _ = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand1],
            responseJSON: modelJSON(body: bodyA, candidateID: cand1.id),
            now: now
        )
        let cand2 = makeCandidate(text: "Un-embeddable sighting.", salience: 0.5, now: now)
        let job2 = try await runExtraction(
            engine: engine,
            store: store,
            candidates: [cand2],
            responseJSON: modelJSON(body: bodyE, candidateID: cand2.id),
            now: now
        )

        // The insert still happens — nil embedding degrades, never drops.
        let usageCount = try await usageMemoryCount(queue)
        XCTAssertEqual(usageCount, 2)
        let memoryID = "memory-\(job2)-0"
        let ref = try await queue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM memory_embedding_refs WHERE memory_id = ?",
                arguments: [memoryID]
            )
        }
        XCTAssertNil(ref, "no embedding ref without a vector")
        let refCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embedding_refs") ?? -1
        }
        XCTAssertEqual(refCount, 1, "only the embeddable memory has a ref")

        // No semantic checks ran: no links, no corroboration events.
        let links = try await linkRows(queue)
        XCTAssertEqual(links.count, 0)
        let auditLabels = try await corroboratedAuditLabels(queue)
        XCTAssertEqual(auditLabels.count, 0)

        // The salience seed still lands (it needs only the policy).
        let salience = try await salienceRow(queue, id: memoryID)
        XCTAssertEqual(salience?["salience"] as Double?, 0.5)
        XCTAssertEqual(salience?["corroboration"] as Int?, 1)
    }

    // MARK: - Fixtures

    private func makeEngineFixtureStore() throws -> (DatabaseQueue, DataStore, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        return (queue, dataStore, ControlPlaneStore(dbQueue: queue))
    }

    private func makeEngine(
        store: ControlPlaneStore,
        dataStore: DataStore,
        settings: SettingsManager,
        stage2: UsageMemoryEmbeddingService?
    ) -> MemoryExtractionEngine {
        let suite = "usage-stage2-ledger-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore(),
            authorityWritesGoLiveEnabled: true,
            usageCloudClient: Stage2UnreachableCloudClientFake(),
            usageTelemetry: UsageCurationTelemetry(defaults: defaults),
            usageBudgetLedger: UsageMemoryBudgetLedger(defaults: defaults),
            usageStage2: stage2
        )
    }

    /// Usage consent granted; chat consent deliberately OFF (lane isolation);
    /// the `.local` placement resolves to the endpoint the Ollama stub answers.
    private func makeUsageSettings() -> SettingsManager {
        let suite = "usage-stage2-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let settings = SettingsManager(defaults: defaults)
        settings.usageMemoryConsentGranted = true
        settings.summaryLocalBaseURL = "http://127.0.0.1:9999"
        settings.summaryLocalModel = "stage2-test-model"
        settings.summaryRequestTimeoutSeconds = 5
        return settings
    }

    /// Insert candidates, assemble ONE batch, point the model stub at
    /// `responseJSON`, drain, and assert the job succeeded.
    @discardableResult
    private func runExtraction(
        engine: MemoryExtractionEngine,
        store: ControlPlaneStore,
        candidates: [UsageMemoryCandidate],
        responseJSON: String,
        now: Date
    ) async throws -> String {
        try await store.insertUsageMemoryCandidates(candidates, cursorKey: nil, cursorJSON: nil, now: now)
        let batches = try await store.assembleUsageExtractionBatch(
            policy: singleBatchPolicy,
            promptVersion: "usage-extract-v1",
            scope: scope,
            now: now
        )
        XCTAssertEqual(batches.count, 1)
        let jobID = try XCTUnwrap(batches.first?.jobID)
        UsageStage2OllamaStub.responseJSON = responseJSON
        let report = await engine.runDrain()
        XCTAssertEqual(report.failed, 0)
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .succeeded)
        return jobID
    }

    private func modelJSON(body: String, candidateID: String) -> String {
        """
        {"memories":[{"text":"\(body)","kind":"preference","confidence":0.9,\
        "keywords":[],"tags":[],"context":"Stage-2 test context.","candidateId":"\(candidateID)"}]}
        """
    }

    private func makeCandidate(
        text: String,
        salience: Double,
        now: Date,
        sourceKind: MemorySourceKind = .agentSession,
        sourceRef: String = "codex:rollout-stage2"
    ) -> UsageMemoryCandidate {
        let payload = UsageMemoryCandidatePayload(
            schemaVersion: 1,
            text: text,
            role: "user",
            threadLogicalID: sourceRef,
            observedAt: now
        )
        let payloadJSON: String
        do {
            payloadJSON = String(decoding: try UsageMemoryCandidatePayload.encoder().encode(payload), as: UTF8.self)
        } catch {
            payloadJSON = "{}"
            XCTFail("payload encoding failed: \(error)")
        }
        let contentHash = UsageMemoryCandidate.contentHash(ofText: text)
        return UsageMemoryCandidate(
            id: UsageMemoryCandidate.spoolID(sourceRef: sourceRef, contentHash: contentHash),
            sourceKind: sourceKind,
            sourceRef: sourceRef,
            threadLogicalID: sourceRef,
            payloadJSON: payloadJSON,
            contentHash: contentHash,
            simhash: UsageMemorySimHash.storageValue(UsageMemorySimHash.hash(text)),
            salienceHint: salience
        )
    }

    // MARK: - Row probes

    private func usageMemoryCount(_ queue: DatabaseQueue) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind IN ('safari_ask','agent_session')"
            ) ?? -1
        }
    }

    private func salienceRow(_ queue: DatabaseQueue, id: String) async throws -> Row? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memory_salience WHERE memory_id = ?", arguments: [id])
        }
    }

    private func linkRows(_ queue: DatabaseQueue) async throws -> [Row] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memory_links ORDER BY created_at ASC, id ASC")
        }
    }

    private func corroboratedAuditLabels(_ queue: DatabaseQueue) async throws -> [String] {
        try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT labels_json FROM memory_audit WHERE action = 'memory.corroborated' ORDER BY seq ASC"
            )
        }
    }

    private func candidateStatusCounts(_ queue: DatabaseQueue) async throws -> [String: Int] {
        try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT status, COUNT(*) AS count FROM memory_usage_candidates GROUP BY status"
            )
            var counts: [String: Int] = [:]
            for row in rows {
                guard let status: String = row["status"], let count: Int = row["count"] else { continue }
                counts[status] = count
            }
            return counts
        }
    }
}

// MARK: - Embedding fakes

/// `DeterministicFakeEmbeddingProvider` (the shared CI embedder, 96-dim)
/// behind the Stage-2 seam: same text ⇒ same vector, no model download.
private struct DeterministicUsageEmbeddingProvider: UsageMemoryEmbeddingProviding {
    private let inner = DeterministicFakeEmbeddingProvider()

    var descriptor: EmbeddingModelDescriptor { inner.descriptor }

    func embed(_ text: String) async -> [Float]? {
        try? await inner.embedding(for: text) // try?-ok(deterministic fake never throws)
    }
}

/// Fully scripted provider for crafting exact cosine relationships: memory
/// body text → unit vector. A body NOT in the map embeds as nil (the
/// provider-declined path).
private struct ScriptedEmbeddingProvider: UsageMemoryEmbeddingProviding {
    let descriptor: EmbeddingModelDescriptor
    private let vectors: [String: [Float]]

    init(dimensions: Int = 4, vectors: [String: [Float]]) {
        self.descriptor = EmbeddingModelDescriptor(
            provider: "openburnbar-test",
            modelName: "stage2-scripted-embedding",
            dimensions: dimensions,
            distanceMetric: .cosine,
            versionTag: "stage2-scripted-v1",
            chunkerVersion: "memory-body-v1",
            normalizationVersion: "unit-l2-v1",
            promptVersion: "usage-memory-v1"
        )
        self.vectors = vectors
    }

    func embed(_ text: String) async -> [Float]? {
        vectors[text.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
}

// MARK: - Cloud client fake

/// Local-route tests never reach the cloud; if one ever does, fail loudly as
/// an exhausted allowance instead of egressing.
private final class Stage2UnreachableCloudClientFake: UsageCurationCloudClientProtocol, @unchecked Sendable {
    func curate(
        lane: UsageCurationLane,
        candidates: [UsageCurationCloudCandidate],
        requestId: String
    ) async throws -> UsageCurationBatchResponse {
        throw UsageCurationCloudError.budgetExhausted(lane: lane, resetsAt: "2026-09-01T00:00:00Z")
    }
}

// MARK: - Local Ollama HTTP stub

/// `URLProtocol` answering the local Ollama `/api/generate` endpoint with a
/// canned `{"response": <json>}` envelope — the exact path
/// `MemoryExtractionLLMClient.callOllama` takes for the usage `.localText`
/// route (mirrors `UsageStage1OllamaStub`).
private final class UsageStage2OllamaStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _responseJSON = "{\"memories\":[]}"

    static var responseJSON: String {
        get { lock.lock(); defer { lock.unlock() }; return _responseJSON }
        set { lock.lock(); _responseJSON = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _responseJSON = "{\"memories\":[]}"; lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("api/generate") ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); let json = Self._responseJSON; Self.lock.unlock()

        let escaped = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        let envelope = "{\"response\":\"\(escaped)\"}"
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://127.0.0.1")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(envelope.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
