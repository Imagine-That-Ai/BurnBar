import XCTest
import CryptoKit
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - PR10: usage-memory program acceptance / dormancy suite
//
// The executable close-out of the usage-memory program (PR1–PR9). Each test is
// one acceptance criterion, proven over the SAME service graph the app wires in
// `AgentLensApp+MemoryServices.makeMemoryServices` — real in-memory store, real
// engine/worker/miner/ticker, counting fakes on every I/O boundary:
//
//   1. DORMANCY E2E — all-defaults graph (no consent, `.local` placement,
//      gates off) over a minable corpus performs ZERO file reads, ZERO
//      database writes, ZERO LLM calls, ZERO cloud egress, ZERO telemetry.
//      Positive control: the SAME graph with the gate boxes flipped on
//      produces candidates → jobs → memories (fixture validity, not luck).
//      PR9's promote/self-heal LLM lanes are inside the sweep (the worker is
//      built with the engine's model client + router snapshot).
//   2. FORGET E2E — an approved usage memory deleted through the generalized
//      path wipes row + snapshot + provenance + embedding ref + salience +
//      links (both ends) and mints a fact tombstone; the quarantined variant
//      hard-deletes with NO tombstone.
//   3. STORAGE GROWTH, MEASURED — 1,000 synthetic usage memories through the
//      REAL Stage-1 batch + Stage-2 semantic write path (deterministic 512-d
//      embeddings, the production NLEmbedding dimension); SQLite page delta
//      printed and asserted under the 15 MB regression ceiling, scaled to the
//      5k `caps.maxUsageMemories` policy cap.
//   4. COST ACCOUNTING, ASSERTED — 30 Stage-1 ticker cloud batches at ~5k
//      prompt / 500 output tokens each; `UsageCurationTelemetry` monthly
//      aggregate math asserted exactly; the projected member-month USD at
//      CoreWeave prices printed and asserted under the $0.50 ceiling; the
//      client daily-cap ledger proven to HALT cloud routes once crossed.
//   5. RETRIEVAL-PRECISION BASELINE — a deterministic 20-memory / 5-query
//      eval over `recallChatMemorySnippets` with usage-machinery salience
//      seeds. Precision@3 (k capped at the per-query relevant count, R = 2)
//      printed and asserted ≥ 0.8. This is the BASELINE the future
//      self-improvement loop must beat; A/B rides the versioned
//      `UsageMemoryCurationPolicy` record (PR9), pinned here at version 1.
//   6. GATE-MATRIX SWEEP — the executable version of the design doc's
//      lattice: every {consent, RC extraction, RC writes, placement, cloud
//      consent} row asserts the exact extraction / cloud-egress / authority-
//      write behavior through the live SettingsManager gates, the engine's
//      composed authority closure, and the router.
//
// Measured numbers print with the `[ACCEPTANCE]` prefix for the PR body.
@MainActor
final class UsageMemoryAcceptanceTests: XCTestCase {

    private let appScope = MemoryScope(appID: "openburnbar")
    private let baseNow = Date(timeIntervalSince1970: 1_900_000_000)

    private var tempSessionsRoot: URL!

    /// minBatch 1 / one job per assembly, generous prompt budget — each test
    /// batches exactly the candidates it inserts (mirrors Stage-2's fixture).
    private let singleJobPolicy = UsageMemoryExtractionPolicy(
        minBatch: 1,
        maxBatch: 15,
        maxPromptChars: 100_000,
        maxOutputTokens: 4096,
        maxJobsPerTick: 1,
        perJobWallClock: 300,
        staleBatchAge: 48 * 3600
    )

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempSessionsRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-acceptance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempSessionsRoot, withIntermediateDirectories: true)
        AcceptanceOllamaStub.reset()
        URLProtocol.registerClass(AcceptanceOllamaStub.self)
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(AcceptanceOllamaStub.self)
        AcceptanceOllamaStub.reset()
        if let tempSessionsRoot {
            try? FileManager.default.removeItem(at: tempSessionsRoot)
        }
        tempSessionsRoot = nil
        try super.tearDownWithError()
    }

    // MARK: - 1. Dormancy E2E (the headline test)

    func test_acceptance_dormancy_fullGraphAllDefaults_zeroCallsZeroWritesZeroEgress_thenPositiveControl() async throws {
        let (queue, dataStore, store) = try makeEngineFixtureStore()

        // ALL defaults: no consent, `.local` placement, every gate closed.
        let settings = makeIsolatedSettings()
        XCTAssertFalse(settings.usageMemoryConsentGranted)
        XCTAssertFalse(settings.usageMemoryExtractionEnabled)
        XCTAssertFalse(settings.memoryExtractionEnabled)
        XCTAssertFalse(settings.usageMemoryCloudCurationConsentGranted)
        XCTAssertFalse(settings.usageMemoryCloudCurationEnabled)
        XCTAssertEqual(settings.usageMemoryModelPlacement, .local)
        XCTAssertFalse(settings.memoryApprovedCloudBackupEnabled)

        // Counting fakes on EVERY I/O boundary.
        let ledgerDefaults = try makeIsolatedDefaults()
        let telemetry = UsageCurationTelemetry(defaults: ledgerDefaults)
        let ledger = UsageMemoryBudgetLedger(defaults: ledgerDefaults)
        let cloudClient = SuccessCountingUsageCloudClient()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: settings,
            cloudClient: cloudClient,
            telemetry: telemetry,
            ledger: ledger,
            stage2: UsageMemoryEmbeddingService(provider: Deterministic512EmbeddingProvider(), policy: .defaults)
        )

        // A corpus that WOULD produce candidates when enabled: 12 minable
        // question-shaped user turns (>= the default minBatch of 10).
        let questions = (0 ..< 12).map {
            "How do I configure acceptance fixture number \($0) for the usage pipeline correctly?"
        }
        var lines: [String] = []
        for question in questions {
            lines.append(try userLine(question))
        }
        try writeRollout(named: "rollout-acceptance", lines: lines)

        // The graph, wired exactly as `makeMemoryServices` wires it (counting
        // file-open fixtures ride the PR4 seams).
        let countingFileManager = CountingFileManager()
        let opener = CountingOpener()
        let usageSwitch = engine.usageExtractionKillSwitch
        let miner = UsageSessionLogMiner(
            store: store,
            sessionsRootURL: tempSessionsRoot,
            isEnabled: { usageSwitch.isAllowed() },
            fileManager: countingFileManager,
            openFileForReading: { opener.open($0) }
        )
        let ticker = UsageMemoryStage1Ticker(
            store: store,
            miner: miner,
            engine: engine,
            isEnabled: { usageSwitch.isAllowed() },
            mineAgentSessions: { settings.usageMemorySourceAgentSessionsEnabled }
        )
        // PR9 shape: the consolidation worker carries the engine's Stage-2
        // service, its promote/self-heal model client (over the SAME counted
        // local/cloud transports), the live router snapshot, and the composed
        // authority gate — so the dormancy sweep covers the LLM lanes too.
        let worker = MemoryConsolidationWorker(
            store: store,
            isEnabled: { usageSwitch.isAllowed() },
            embedding: engine.usageStage2Service,
            modelClient: engine.usageConsolidationModelClient,
            routerSnapshotProvider: engine.usageConsolidationRouterSnapshotProvider,
            authorityWritesEnabled: engine.usageAuthorityWritesGate
        )
        // PR-E2 cloud replication: a signed-in, cloud-sync-ready account makes
        // the proof STRONGER — the memory levers alone must stop egress.
        let gateway = CloudSyncFirestoreFakeGateway()
        let cloudSync = MemoryCloudSyncDomain(
            store: store,
            accountManager: FakeAccountManager.makeSignedIn(uid: "acceptance-uid"),
            settingsManager: settings,
            firestoreGateway: gateway,
            vaultKeyProvider: TestConversationVaultKeyProvider()
        )

        // Run EVERY tick entry point while dormant.
        await ticker.tick(now: baseNow)
        let tickReport = await worker.consolidationTick(now: baseNow)
        XCTAssertEqual(tickReport, MemoryConsolidationWorker.TickReport(), "dormant consolidation tick reports all zeros (incl. promote/self-heal calls)")
        let pump = await engine.runDrain()
        XCTAssertEqual(pump.stoppedReason, .killSwitchOff)
        XCTAssertEqual(pump.processed, 0)
        engine.launchDrain()
        await cloudSync.sync()

        // ZERO everything.
        let candidateRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_usage_candidates") ?? -1
        }
        XCTAssertEqual(candidateRows, 0, "zero candidate rows")
        let jobRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_jobs") ?? -1
        }
        XCTAssertEqual(jobRows, 0, "zero extraction jobs (chat or usage)")
        let memoryRows = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories") ?? -1
        }
        XCTAssertEqual(memoryRows, 0, "zero agent_memories rows")
        for sidecar in ["memory_salience", "memory_links", "memory_embedding_refs", "memory_provenance", "memory_body_snapshots"] {
            let count = try await queue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(sidecar)") ?? -1
            }
            XCTAssertEqual(count, 0, "zero \(sidecar) rows")
        }
        XCTAssertEqual(AcceptanceOllamaStub.requestCount, 0, "zero local LLM invocations")
        XCTAssertEqual(cloudClient.callCount, 0, "zero cloud curation invocations")
        XCTAssertEqual(opener.opens, 0, "zero file opens (PR4 counting fixture)")
        XCTAssertEqual(countingFileManager.attributeCalls, 0, "zero per-file stat calls")
        let cursorJSON = try await store.usageSessionMinerCursorJSON()
        XCTAssertNil(cursorJSON, "zero cursor rows")
        XCTAssertNil(ledgerDefaults.data(forKey: "usageCurationTelemetryMonthly"), "zero persisted telemetry records")
        XCTAssertEqual(telemetry.currentMonth.callCount, 0)
        XCTAssertEqual(ledger.todaysSpendUSD, 0)
        XCTAssertEqual(gateway.batchCommitAttemptCount, 0, "zero Firestore commits")
        XCTAssertTrue(gateway.documents(under: "users/acceptance-uid/memory_facts").isEmpty, "zero replicated documents")
        XCTAssertNil(cloudSync.lastSyncDate, "the cloud-sync domain never started a cycle")

        // POSITIVE CONTROL: flip the gate boxes on — the SAME graph produces
        // candidates → jobs → memories, proving the fixture was minable and
        // dormancy (not a broken fixture) produced the zeros above.
        settings.usageMemoryConsentGranted = true
        settings.summaryLocalBaseURL = "http://127.0.0.1:9999"
        settings.summaryLocalModel = "acceptance-model"
        settings.summaryRequestTimeoutSeconds = 5
        engine.refreshKillSwitch()
        XCTAssertTrue(usageSwitch.isAllowed())

        let citedQuestion = questions[0]
        let citedID = UsageMemoryCandidate.spoolID(
            sourceRef: "codex:rollout-acceptance",
            contentHash: UsageMemoryCandidate.contentHash(ofText: citedQuestion)
        )
        AcceptanceOllamaStub.responseJSON = """
        {"memories":[{"text":"Configures acceptance fixtures for the usage pipeline before enabling it.",\
        "kind":"preference","confidence":0.85,"keywords":["fixtures","pipeline"],"tags":["workflow"],\
        "context":"Observed across acceptance sessions.","candidateId":"\(citedID)"}]}
        """

        await ticker.tick(now: baseNow.addingTimeInterval(60))
        _ = await engine.runDrain()
        try await waitUntil("the positive-control usage memory is written") {
            try await self.usageMemoryCount(queue) >= 1
        }

        let enabledCandidates = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_usage_candidates") ?? -1
        }
        XCTAssertEqual(enabledCandidates, 12, "the corpus mined 12 candidates once enabled")
        let enabledJobs = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_extraction_jobs WHERE source_kind = 'agent_session'") ?? -1
        }
        XCTAssertGreaterThanOrEqual(enabledJobs, 1)
        XCTAssertGreaterThanOrEqual(AcceptanceOllamaStub.requestCount, 1, "the local model was called once enabled")
        XCTAssertGreaterThan(opener.opens, 0, "the miner opened the corpus once enabled")
        let enabledCursor = try await store.usageSessionMinerCursorJSON()
        XCTAssertNotNil(enabledCursor)
        // Even fully enabled on `.local` placement: still zero egress.
        XCTAssertEqual(cloudClient.callCount, 0, "local placement keeps cloud invocations at zero")
        XCTAssertEqual(telemetry.currentMonth.callCount, 0, "local routes record no cloud telemetry")
        XCTAssertEqual(gateway.batchCommitAttemptCount, 0, "memory cloud backup stays opt-in-gated")
    }

    // MARK: - 2. Forget E2E

    func test_acceptance_forget_approvedMintsFactTombstoneAndWipesEverything_quarantinedHardDeletesWithoutTombstone() async throws {
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let settings = makeUsageSettings()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: settings,
            cloudClient: SuccessCountingUsageCloudClient(),
            policy: singleJobPolicy,
            stage2: UsageMemoryEmbeddingService(provider: Deterministic512EmbeddingProvider(), policy: .defaults)
        )

        // Seed → extract (fake local LLM) under a USER-scoped batch (fact
        // tombstones require an owning userID).
        let userScope = MemoryScope(userID: "acceptance-user", appID: "openburnbar")
        let candA = makeCandidate(
            text: "Prefers annotated tags when cutting releases from the main branch.",
            salience: 0.8,
            now: baseNow,
            sourceRef: "codex:forget-a"
        )
        let candB = makeCandidate(
            text: "Keeps notes current in the changelog before tagging anything.",
            salience: 0.6,
            now: baseNow,
            sourceRef: "codex:forget-b"
        )
        try await store.insertUsageMemoryCandidates([candA, candB], cursorKey: nil, cursorJSON: nil, now: baseNow)
        let batches = try await store.assembleUsageExtractionBatch(
            policy: singleJobPolicy,
            promptVersion: "usage-extract-v1",
            scope: userScope,
            now: baseNow
        )
        XCTAssertEqual(batches.count, 1)
        let jobID = try XCTUnwrap(batches.first?.jobID)
        AcceptanceOllamaStub.responseJSON = """
        {"memories":[\
        {"text":"Prefers annotated tags for every release cut.","kind":"preference","confidence":0.9,\
        "keywords":["release","tags"],"tags":["workflow"],"context":"Observed across release sessions.",\
        "candidateId":"\(candA.id)"},\
        {"text":"Maintains the changelog ahead of tagging.","kind":"fact","confidence":0.7,\
        "keywords":["changelog"],"tags":["habit"],"context":"Observed while preparing releases.",\
        "candidateId":"\(candB.id)"}]}
        """
        let report = await engine.runDrain()
        XCTAssertEqual(report.failed, 0)
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .succeeded)

        let approvedID = "memory-\(jobID)-0"
        let quarantinedID = "memory-\(jobID)-1"
        // A link touching both rows, to prove both-end link cleanup rides the
        // generalized delete.
        try await store.insertMemoryLink(
            from: quarantinedID,
            to: approvedID,
            kind: .nearDuplicate,
            score: 0.93,
            createdBy: "stage2",
            now: baseNow
        )

        // Everything a live Stage-2 write persists must EXIST before the
        // delete, so "all gone" below is meaningful.
        for (table, column) in [
            ("agent_memories", "id"),
            ("memory_body_snapshots", "memory_id"),
            ("memory_provenance", "memory_id"),
            ("memory_embedding_refs", "memory_id"),
            ("memory_salience", "memory_id")
        ] {
            let count = try await queue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?",
                    arguments: [approvedID]
                ) ?? -1
            }
            XCTAssertGreaterThanOrEqual(count, 1, "\(table) row exists for \(approvedID) before the delete")
        }

        // Approve, then delete through the GENERALIZED path.
        let approved = try await store.setMemoryReviewStatus(
            id: approvedID,
            status: .approved,
            sourceKinds: MemorySourceKind.usageKinds,
            now: baseNow.addingTimeInterval(60)
        )
        XCTAssertTrue(approved)
        let deleteNow = baseNow.addingTimeInterval(120)
        let deleted = try await store.deleteMemoryAuthorityRecord(
            id: approvedID,
            sourceKinds: MemorySourceKind.usageKinds,
            now: deleteNow
        )
        XCTAssertTrue(deleted)

        // Row + snapshot + provenance + embedding ref + salience + links: ALL gone.
        for (table, column) in [
            ("agent_memories", "id"),
            ("memory_body_snapshots", "memory_id"),
            ("memory_provenance", "memory_id"),
            ("memory_embedding_refs", "memory_id"),
            ("memory_salience", "memory_id")
        ] {
            let count = try await queue.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) = ?",
                    arguments: [approvedID]
                ) ?? -1
            }
            XCTAssertEqual(count, 0, "\(table) wiped for \(approvedID)")
        }
        let linkCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_links WHERE from_memory_id = ? OR to_memory_id = ?",
                arguments: [approvedID, approvedID]
            ) ?? -1
        }
        XCTAssertEqual(linkCount, 0, "links on BOTH ends rode the delete")

        // Fact tombstone minted: approved + userID, reason user_delete,
        // pending replication, provenance refs carried.
        let tombstones = try await store.fetchPendingMemoryFactTombstones(userID: "acceptance-user")
        XCTAssertEqual(tombstones.count, 1)
        let tombstone = try XCTUnwrap(tombstones.first)
        XCTAssertEqual(tombstone.memoryID, approvedID)
        XCTAssertEqual(tombstone.userID, "acceptance-user")
        XCTAssertEqual(tombstone.reason, "user_delete")
        XCTAssertEqual(tombstone.sourceRefs.count, 1)
        XCTAssertEqual(tombstone.sourceRefs.first?.contentHash, candA.contentHash, "the tombstone carries the spool-derived provenance hash")

        // Audit trail present.
        let deleteAudits = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT labels_json FROM memory_audit WHERE action = 'memory.delete'")
        }
        XCTAssertTrue(deleteAudits.contains { $0.contains("memory_id:\(approvedID)") })

        // Quarantined variant: hard delete, NO tombstone.
        let quarantinedDeleted = try await store.deleteMemoryAuthorityRecord(
            id: quarantinedID,
            sourceKinds: MemorySourceKind.usageKinds,
            now: deleteNow.addingTimeInterval(60)
        )
        XCTAssertTrue(quarantinedDeleted)
        let quarantinedRow = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT id FROM agent_memories WHERE id = ?", arguments: [quarantinedID])
        }
        XCTAssertNil(quarantinedRow)
        let tombstoneTotal = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_fact_tombstones") ?? -1
        }
        XCTAssertEqual(tombstoneTotal, 1, "a quarantined delete mints NO tombstone")
        let quarantinedAudit = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT labels_json FROM memory_audit WHERE action = 'memory.delete'")
        }
        XCTAssertTrue(quarantinedAudit.contains { $0.contains("memory_id:\(quarantinedID)") })
    }

    // MARK: - 3. Storage growth, measured

    func test_acceptance_storageGrowth_thousandMemoriesThroughRealStage2Path_underRegressionCeiling() async throws {
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        let settings = makeUsageSettings()
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: settings,
            cloudClient: SuccessCountingUsageCloudClient(),
            policy: singleJobPolicy,
            stage2: UsageMemoryEmbeddingService(provider: Deterministic512EmbeddingProvider(), policy: .defaults)
        )

        let bytesBefore = try await databaseBytes(queue)
        let target = 1_000
        var inserted = 0
        var batchIndex = 0
        while inserted < target {
            let count = min(15, target - inserted)
            var candidates: [UsageMemoryCandidate] = []
            for offset in 0 ..< count {
                let n = inserted + offset
                candidates.append(
                    makeCandidate(
                        text: "Acceptance storage candidate \(n) asks about reproducible workflow topic \(n).",
                        salience: 0.5,
                        now: baseNow,
                        sourceRef: "codex:storage-\(n)"
                    )
                )
            }
            try await store.insertUsageMemoryCandidates(candidates, cursorKey: nil, cursorJSON: nil, now: baseNow)
            let batches = try await store.assembleUsageExtractionBatch(
                policy: singleJobPolicy,
                promptVersion: "usage-extract-v1",
                scope: appScope,
                now: baseNow
            )
            XCTAssertEqual(batches.count, 1, "batch \(batchIndex) assembled")
            let batch = try XCTUnwrap(batches.first)
            var memories: [String] = []
            for candidate in batch.candidates {
                let n = inserted + memories.count
                memories.append(memoryJSON(
                    body: "Usage fact \(n): prefers deterministic tooling pass \(n) with pinned versions and a reproducible build graph for project \(n).",
                    candidateID: candidate.id,
                    context: "Observed during acceptance storage session \(n).",
                    keywords: ["workflow", "tooling"],
                    tags: ["habit"]
                ))
            }
            AcceptanceOllamaStub.responseJSON = "{\"memories\":[\(memories.joined(separator: ","))]}"
            let report = await engine.runDrain()
            XCTAssertEqual(report.failed, 0, "batch \(batchIndex) drained clean")
            inserted += count
            batchIndex += 1
        }

        let memoryCount = try await usageMemoryCount(queue)
        XCTAssertEqual(memoryCount, target, "every synthetic memory landed as a distinct usage row")
        let refCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embedding_refs") ?? -1
        }
        XCTAssertEqual(refCount, target, "each memory carries its 512-d embedding ref")
        let salienceCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_salience") ?? -1
        }
        XCTAssertEqual(salienceCount, target)

        let bytesAfter = try await databaseBytes(queue)
        let delta = bytesAfter - bytesBefore
        let deltaMB = Double(delta) / (1024 * 1024)
        let cap = UsageMemoryCurationPolicy.defaults.caps.maxUsageMemories
        let scaledMB = deltaMB * Double(cap) / Double(target)
        print("[ACCEPTANCE] storage: \(target) usage memories (512-d refs, snapshots, provenance, salience, audit, spool) grew SQLite by \(delta) bytes = \(String(format: "%.2f", deltaMB)) MB (\(delta / target) B/memory); projected at the \(cap)-memory cap: \(String(format: "%.2f", scaledMB)) MB")
        XCTAssertLessThan(delta, 15 * 1024 * 1024, "storage regression ceiling: 1k memories must stay under 15 MB")
    }

    // MARK: - 4. Cost accounting, asserted

    func test_acceptance_costAccounting_thirtyTickerCloudBatches_monthlyAggregateMath_andDailyCapHalt() async throws {
        let (queue, dataStore, store) = try makeEngineFixtureStore()
        // Cloud lane fully consented: usage consent + separate cloud consent +
        // BurnBar cloud placement; NO local model, so cloud is the only route.
        let settings = makeIsolatedSettings()
        settings.usageMemoryConsentGranted = true
        settings.usageMemoryCloudCurationConsentGranted = true
        settings.usageMemoryModelPlacement = .burnbarCloud
        settings.summaryLocalBaseURL = ""
        settings.summaryLocalModel = ""

        let ledgerDefaults = try makeIsolatedDefaults()
        let telemetry = UsageCurationTelemetry(defaults: ledgerDefaults)
        let ledger = UsageMemoryBudgetLedger(defaults: ledgerDefaults)
        // Realistic curation batch: ~5k prompt / 500 output tokens, text lane.
        let cloudClient = SuccessCountingUsageCloudClient(promptTokensPerCall: 5_000, outputTokensPerCall: 500)
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: settings,
            cloudClient: cloudClient,
            telemetry: telemetry,
            ledger: ledger,
            policy: singleJobPolicy,
            stage2: UsageMemoryEmbeddingService(provider: Deterministic512EmbeddingProvider(), policy: .defaults)
        )
        let usageSwitch = engine.usageExtractionKillSwitch
        let miner = UsageSessionLogMiner(
            store: store,
            sessionsRootURL: tempSessionsRoot,
            isEnabled: { usageSwitch.isAllowed() }
        )
        // The REAL Stage-1 entry point drives every batch (mining off: the
        // spool is seeded directly, one candidate per tick).
        let ticker = UsageMemoryStage1Ticker(
            store: store,
            miner: miner,
            engine: engine,
            policy: singleJobPolicy,
            isEnabled: { usageSwitch.isAllowed() },
            mineAgentSessions: { false }
        )

        let batchCount = 30
        for index in 0 ..< batchCount {
            let candidate = makeCandidate(
                text: "Cloud accounting fact \(index) about durable member workflow habits.",
                salience: 0.5,
                now: baseNow,
                sourceRef: "codex:cost-\(index)"
            )
            try await store.insertUsageMemoryCandidates([candidate], cursorKey: nil, cursorJSON: nil, now: baseNow)
            await ticker.tick(now: baseNow.addingTimeInterval(Double(index)))
            _ = await engine.runDrain()
            // Wait for the batch to be fully CONSUMED (not merely called), so
            // the next iteration's assembly can never fold two candidates into
            // one batch — exactly one cloud call per batch.
            try await waitUntil("cloud batch \(index + 1) settles") {
                let extracted = try await self.candidateStatusCounts(queue)["extracted"] ?? 0
                return cloudClient.callCount == index + 1 && extracted == index + 1
            }
        }

        // Monthly aggregate math, exact.
        let aggregate = telemetry.currentMonth
        XCTAssertEqual(aggregate.callCount, batchCount)
        XCTAssertEqual(aggregate.promptTokens, batchCount * 5_000)
        XCTAssertEqual(aggregate.outputTokens, batchCount * 500)
        XCTAssertEqual(aggregate.cachedTokens, 0)
        let expectedPerCallUSD = (5_000.0 * 0.14 + 500.0 * 0.28) / 1_000_000
        let expectedMonthUSD = Double(batchCount) * expectedPerCallUSD
        XCTAssertEqual(aggregate.estimatedUSD, expectedMonthUSD, accuracy: 1e-9)
        XCTAssertEqual(ledger.todaysSpendUSD, expectedMonthUSD, accuracy: 1e-9)
        print("[ACCEPTANCE] cost: \(batchCount) sleep-time cloud batches/month at ~5k prompt + 500 output tokens = \(aggregate.promptTokens + aggregate.outputTokens) tokens, projected member-month USD at CoreWeave prices = $\(String(format: "%.4f", aggregate.estimatedUSD)) (ceiling $0.50)")
        XCTAssertLessThan(aggregate.estimatedUSD, 0.50, "projected member-month spend stays under the $0.50 ceiling")

        // The client daily-cap belt HALTS cloud routes once crossed: spike the
        // ledger past the $0.50 cap, then run one more batch — the router
        // resolves no cloud route, the job defers, zero new cloud calls.
        ledger.record(
            usage: UsageCurationTokenUsage(promptTokens: 5_000_000, outputTokens: 0, cachedTokens: 0, lane: .text),
            lane: .text
        )
        XCTAssertFalse(ledger.cloudBudgetOK())
        let haltCandidate = makeCandidate(
            text: "Cloud accounting fact beyond the daily cap must never egress.",
            salience: 0.5,
            now: baseNow,
            sourceRef: "codex:cost-halt"
        )
        try await store.insertUsageMemoryCandidates([haltCandidate], cursorKey: nil, cursorJSON: nil, now: baseNow)
        await ticker.tick(now: baseNow.addingTimeInterval(1_000))
        _ = await engine.runDrain()
        try await waitUntil("the over-cap job defers") {
            let statuses = try await self.jobStatusCounts(queue)
            return (statuses["failed"] ?? 0) >= 1
        }
        XCTAssertEqual(cloudClient.callCount, batchCount, "the crossed daily cap halted the cloud route: no 31st call")
        XCTAssertEqual(AcceptanceOllamaStub.requestCount, 0, "no local fallback exists in this fixture: nothing was called")
        let statusCounts = try await candidateStatusCounts(queue)
        XCTAssertEqual(statusCounts["batched"], 1, "the over-cap batch stays batched for the retry")
    }

    // MARK: - 5. Retrieval-precision baseline harness

    /// A deterministic BASELINE, not a judgment: 5 canned queries, 10 relevant
    /// memories (2 per query, containing BOTH query terms by construction) and
    /// 10 distractors (5 sharing exactly ONE term with a query, 5 sharing
    /// none), confidence held equal so ranking is decided by text overlap +
    /// the usage-machinery salience boost. Precision@3 caps k at the
    /// per-query relevant count (R = 2). The future self-improvement loop
    /// must beat this number; its A/B rides the versioned
    /// `UsageMemoryCurationPolicy` record (PR9), pinned at version 1 here.
    func test_acceptance_retrievalPrecisionBaseline_deterministicEval_printsAndPins() async throws {
        let (_, dataStore, store) = try makeEngineFixtureStore()
        _ = dataStore

        // The baseline is recorded against policy version 1 (a fresh store
        // loads the compiled defaults; A/B bumps `policyVersion`).
        let policy = try await store.loadUsageMemoryCurationPolicy()
        XCTAssertEqual(policy, .defaults)
        XCTAssertEqual(policy.policyVersion, 1)

        struct EvalQuery {
            let query: String
            let relevantIDs: [String]
        }
        // (id, body, relevant) — relevant bodies contain BOTH query terms; the
        // paired distractor shares exactly one.
        let corpus: [(id: String, body: String, salience: Double?)] = [
            ("r1a", "Prefers annotated release tagging from the main branch.", 0.9),
            ("r1b", "Automates release tagging in the deploy pipeline.", 0.9),
            ("r2a", "Runs database migrations inside a transaction.", 0.9),
            ("r2b", "Reviews database migrations with a schema diff.", 0.9),
            ("r3a", "Tracks coverage reports per module in continuous integration.", 0.9),
            ("r3b", "Blocks merges when coverage reports regress.", 0.9),
            ("r4a", "Requests peer review from two maintainers.", 0.9),
            ("r4b", "Batches peer review comments into one pass.", 0.9),
            ("r5a", "Routes error logging through a single sink.", 0.9),
            ("r5b", "Scrubs secrets from error logging output.", 0.9),
            ("d1", "Keeps the release calendar pinned to the dashboard.", 0.5),
            ("d2", "Backs up the database every night at midnight.", 0.5),
            ("d3", "Publishes coverage newsletters to the whole team.", 0.5),
            ("d4", "Reads peer feedback guidelines every quarter.", 0.5),
            ("d5", "Watches the logging dashboard on Monday mornings.", 0.5),
            ("d6", "Enjoys espresso during the morning standup.", nil),
            ("d7", "Keeps a plant collection near the desk.", nil),
            ("d8", "Listens to instrumental albums while focusing.", nil),
            ("d9", "Walks the dog between long meetings.", nil),
            ("d10", "Collects vintage keyboards as a hobby.", nil)
        ]
        let queries = [
            EvalQuery(query: "release tagging", relevantIDs: ["r1a", "r1b"]),
            EvalQuery(query: "database migrations", relevantIDs: ["r2a", "r2b"]),
            EvalQuery(query: "coverage reports", relevantIDs: ["r3a", "r3b"]),
            EvalQuery(query: "peer review", relevantIDs: ["r4a", "r4b"]),
            EvalQuery(query: "error logging", relevantIDs: ["r5a", "r5b"])
        ]

        for entry in corpus {
            _ = try await store.addMemoryAuthorityRecord(
                MemoryAddRequest(
                    text: entry.body,
                    kind: .preference,
                    scope: appScope,
                    confidence: 0.6,
                    reviewStatus: .approved
                ),
                id: entry.id,
                sourceKind: .chat,
                now: baseNow,
                enabled: true
            )
            if let salience = entry.salience {
                // Salience seeded through the usage-machinery sidecar — the
                // signal Stage-2 corroboration + Stage-3 decay maintain.
                try await store.seedMemorySalience(
                    memoryID: entry.id,
                    salience: salience,
                    sourceTrust: 1.0,
                    now: baseNow
                )
            }
        }

        var hits = 0
        var possible = 0
        var perQuery: [String] = []
        for eval in queries {
            let snippets = try await store.recallChatMemorySnippets(
                MemoryRecallRequest(query: eval.query, scope: appScope, tokenBudget: 4_000, limit: 3)
            )
            let k = min(3, eval.relevantIDs.count)
            let top = snippets.prefix(k).map(\.memoryID)
            let queryHits = top.filter { eval.relevantIDs.contains($0) }.count
            hits += queryHits
            possible += k
            perQuery.append("\(eval.query)=\(queryHits)/\(k)")
        }
        let precision = Double(hits) / Double(possible)
        print("[ACCEPTANCE] precision@3 baseline (k = min(3, R), R = 2 relevant/query; deterministic salience + text overlap; policyVersion 1): \(String(format: "%.2f", precision)) [\(perQuery.joined(separator: ", "))] — the self-improvement loop must beat this")
        XCTAssertGreaterThanOrEqual(precision, 0.8, "the deterministic embedding/salience setup must hold the 0.8 precision baseline")
    }

    // MARK: - 6. Gate-matrix sweep

    /// The executable lattice: {usage consent, RC extraction, RC authority
    /// writes, placement, cloud consent} → the EXACT allowed behavior:
    ///   * extraction on/off (`usageMemoryExtractionEnabled` + the live gate
    ///     box the miner/ticker/consolidation worker all share);
    ///   * cloud egress on/off (`usageMemoryCloudCurationEnabled` + the
    ///     router's resolved route for a text batch);
    ///   * durable authority writes on/off (the engine's composed
    ///     `usageAuthorityWritesGate`).
    func test_acceptance_gateMatrix_everyLatticeRowBehavesExactly() async throws {
        let (_, dataStore, store) = try makeEngineFixtureStore()
        let settings = makeIsolatedSettings()
        // A configured local model makes the non-cloud fallback deterministic.
        settings.summaryLocalBaseURL = "http://127.0.0.1:9999"
        settings.summaryLocalModel = "gate-matrix-model"
        let ledger = UsageMemoryBudgetLedger(defaults: try makeIsolatedDefaults())
        let engine = makeEngine(
            store: store,
            dataStore: dataStore,
            settings: settings,
            cloudClient: SuccessCountingUsageCloudClient(),
            ledger: ledger,
            stage2: nil
        )

        var rows = 0
        for consent in [false, true] {
            for rcExtraction in [false, true] {
                for rcWrites in [false, true] {
                    for cloudConsent in [false, true] {
                        for placement in UsageMemoryModelPlacement.allCases {
                            rows += 1
                            settings.usageMemoryConsentGranted = consent
                            settings.usageMemoryExtractionRemoteConfigEnabled = rcExtraction
                            settings.usageMemoryAuthorityWritesRemoteConfigEnabled = rcWrites
                            settings.usageMemoryCloudCurationConsentGranted = cloudConsent
                            settings.usageMemoryModelPlacement = placement
                            engine.refreshKillSwitch()

                            let label = "consent=\(consent) rcExtract=\(rcExtraction) rcWrites=\(rcWrites) cloudConsent=\(cloudConsent) placement=\(placement)"
                            let extractionOn = consent && rcExtraction
                            let cloudOn = extractionOn && cloudConsent && placement.isCloud
                            let writesOn = extractionOn && rcWrites

                            // Lattice values.
                            XCTAssertEqual(settings.usageMemoryExtractionEnabled, extractionOn, label)
                            XCTAssertEqual(settings.usageMemoryCloudCurationEnabled, cloudOn, label)
                            // The LIVE gate box the miner, Stage-1 ticker, and
                            // Stage-3 worker all share.
                            XCTAssertEqual(engine.usageExtractionKillSwitch.isAllowed(), extractionOn, label)
                            // The composed authority-write closure (extraction
                            // box AND authority box AND the write default).
                            XCTAssertEqual(engine.usageAuthorityWritesGate(), writesOn, label)

                            // The router's resolved route for a text batch.
                            let snapshot = MemoryExtractionEngine.makeUsageRouterSnapshot(
                                settingsManager: settings,
                                ledger: ledger
                            )
                            let route = UsageMemoryModelRouter.route(snapshot: snapshot, hasImageContent: false)
                            if !extractionOn {
                                XCTAssertEqual(route, .queueOnly, label)
                            } else if cloudOn {
                                XCTAssertEqual(route, .burnbarCloudText, label)
                            } else {
                                XCTAssertEqual(route, .localText, label)
                            }
                            // Cloud egress is IMPOSSIBLE whenever the cloud
                            // gate is closed.
                            if !cloudOn {
                                XCTAssertNotEqual(route, .burnbarCloudText, label)
                                XCTAssertNotEqual(route, .burnbarCloudMultimodal, label)
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rows, 48, "the full lattice was swept")
        // Leave the shared registries in the closed state.
        settings.usageMemoryConsentGranted = false
        settings.usageMemoryExtractionRemoteConfigEnabled = true
        settings.usageMemoryAuthorityWritesRemoteConfigEnabled = true
        engine.refreshKillSwitch()
    }

    // MARK: - Fixtures

    private func makeEngineFixtureStore() throws -> (DatabaseQueue, DataStore, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        return (queue, dataStore, ControlPlaneStore(dbQueue: queue))
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "usage-acceptance-\(UUID().uuidString)"))
    }

    private func makeIsolatedSettings() -> SettingsManager {
        let defaults = UserDefaults(suiteName: "usage-acceptance-settings-\(UUID().uuidString)") ?? .standard
        return SettingsManager(defaults: defaults)
    }

    /// Usage consent granted; chat consent deliberately OFF (lane isolation);
    /// the `.local` placement resolves to the endpoint the Ollama stub answers.
    private func makeUsageSettings() -> SettingsManager {
        let settings = makeIsolatedSettings()
        settings.usageMemoryConsentGranted = true
        settings.summaryLocalBaseURL = "http://127.0.0.1:9999"
        settings.summaryLocalModel = "acceptance-model"
        settings.summaryRequestTimeoutSeconds = 5
        return settings
    }

    private func makeEngine(
        store: ControlPlaneStore,
        dataStore: DataStore,
        settings: SettingsManager,
        cloudClient: any UsageCurationCloudClientProtocol,
        telemetry: UsageCurationTelemetry? = nil,
        ledger: UsageMemoryBudgetLedger? = nil,
        policy: UsageMemoryExtractionPolicy = .default,
        stage2: UsageMemoryEmbeddingService?
    ) -> MemoryExtractionEngine {
        let defaults = UserDefaults(suiteName: "usage-acceptance-ledger-\(UUID().uuidString)") ?? .standard
        return MemoryExtractionEngine(
            chatMemoryStore: store,
            dataStore: dataStore,
            settingsManager: settings,
            providerAPIKeyStore: ProviderAPIKeyStore(),
            authorityWritesGoLiveEnabled: true,
            usageCloudClient: cloudClient,
            usageTelemetry: telemetry ?? UsageCurationTelemetry(defaults: defaults),
            usageBudgetLedger: ledger ?? UsageMemoryBudgetLedger(defaults: defaults),
            usageExtractionPolicy: policy,
            usageStage2: stage2
        )
    }

    private func makeCandidate(
        text: String,
        salience: Double,
        now: Date,
        sourceRef: String
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
            sourceKind: .agentSession,
            sourceRef: sourceRef,
            threadLogicalID: sourceRef,
            payloadJSON: payloadJSON,
            contentHash: contentHash,
            simhash: UsageMemorySimHash.storageValue(UsageMemorySimHash.hash(text)),
            salienceHint: salience
        )
    }

    private func memoryJSON(
        body: String,
        candidateID: String,
        context: String,
        keywords: [String],
        tags: [String],
        confidence: Double = 0.85
    ) -> String {
        let keywordList = keywords.map { "\"\($0)\"" }.joined(separator: ",")
        let tagList = tags.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"text\":\"\(body)\",\"kind\":\"preference\",\"confidence\":\(confidence),\"keywords\":[\(keywordList)],\"tags\":[\(tagList)],\"context\":\"\(context)\",\"candidateId\":\"\(candidateID)\"}"
    }

    // MARK: Rollout corpus helpers (PR4 fixture shapes)

    private func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func userLine(_ text: String) throws -> String {
        try jsonLine([
            "timestamp": "2026-08-15T10:00:00.000Z",
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": text]]
            ]
        ])
    }

    @discardableResult
    private func writeRollout(named name: String, lines: [String]) throws -> URL {
        let url = tempSessionsRoot.appendingPathComponent("\(name).jsonl", isDirectory: false)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
        return url
    }

    // MARK: Probes

    private func usageMemoryCount(_ queue: DatabaseQueue) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind IN ('safari_ask','agent_session')"
            ) ?? -1
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

    private func jobStatusCounts(_ queue: DatabaseQueue) async throws -> [String: Int] {
        try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT status, COUNT(*) AS count FROM memory_extraction_jobs GROUP BY status"
            )
            var counts: [String: Int] = [:]
            for row in rows {
                guard let status: String = row["status"], let count: Int = row["count"] else { continue }
                counts[status] = count
            }
            return counts
        }
    }

    private func databaseBytes(_ queue: DatabaseQueue) async throws -> Int {
        try await queue.read { db in
            let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            return pageCount * pageSize
        }
    }

    /// Bounded async poll: fire-and-forget drain tasks (`launchDrain`) settle
    /// within a few ticks; assertions poll instead of racing them.
    private func waitUntil(
        _ label: String,
        timeout: TimeInterval = 20,
        condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out waiting for \(label)")
    }
}

// MARK: - Deterministic 512-d embedding provider

/// SHA-256-expanded deterministic embedding at the production NLEmbedding
/// dimension (512): same text ⇒ same unit vector, distinct texts ⇒
/// near-orthogonal vectors (|cosine| concentrates around 1/√512 ≈ 0.04, far
/// below the 0.92 novelty threshold), no model download, no wall-clock.
private struct Deterministic512EmbeddingProvider: UsageMemoryEmbeddingProviding {
    let descriptor = EmbeddingModelDescriptor(
        provider: "openburnbar-test",
        modelName: "acceptance-deterministic-512",
        dimensions: 512,
        distanceMetric: .cosine,
        versionTag: "acceptance-512-v1",
        chunkerVersion: "memory-body-v1",
        normalizationVersion: "unit-l2-v1",
        promptVersion: "usage-memory-v1"
    )

    func embed(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        let seed = Data(SHA256.hash(data: Data(trimmed.utf8)))
        var values: [Float] = []
        values.reserveCapacity(512)
        var counter: UInt64 = 0
        while values.count < 512 {
            var block = seed
            withUnsafeBytes(of: counter.bigEndian) { block.append(contentsOf: $0) }
            for byte in SHA256.hash(data: block) where values.count < 512 {
                values.append(Float(byte) / 255.0 * 2.0 - 1.0)
            }
            counter += 1
        }
        let norm = values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return nil }
        return values.map { $0 / norm }
    }
}

// MARK: - Counting cloud-client fake

/// Successful counting cloud fake: every `curate` call settles with the
/// configured token usage and EMPTY results (a valid "nothing durable"
/// verdict), so cost accounting is exact and no authority writes ride along.
/// Doubles as the dormancy sweep's zero-egress probe (`callCount` stays 0).
private final class SuccessCountingUsageCloudClient: UsageCurationCloudClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private let promptTokensPerCall: Int
    private let outputTokensPerCall: Int

    init(promptTokensPerCall: Int = 5_000, outputTokensPerCall: Int = 500) {
        self.promptTokensPerCall = promptTokensPerCall
        self.outputTokensPerCall = outputTokensPerCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    /// Synchronous on purpose: `NSLock` is `noasync`, so the async `curate`
    /// hops through this sync helper.
    private func recordCall() {
        lock.lock()
        _callCount += 1
        lock.unlock()
    }

    func curate(
        lane: UsageCurationLane,
        candidates: [UsageCurationCloudCandidate],
        requestId: String
    ) async throws -> UsageCurationBatchResponse {
        recordCall()
        return UsageCurationBatchResponse(
            results: [],
            promptVersion: "usage-extract-v1",
            usage: UsageCurationTokenUsage(
                promptTokens: promptTokensPerCall,
                outputTokens: outputTokensPerCall,
                cachedTokens: 0,
                lane: lane
            ),
            allowance: UsageCurationAllowance(
                textRemainingMonth: 10_000_000,
                multimodalRemainingMonth: 10_000_000,
                resetsAt: "2026-09-01T00:00:00Z"
            )
        )
    }
}

// MARK: - Counting file fixtures (PR4 technique)

/// Counts per-file stat calls. (`enumerator(at:...)` lives in a Swift overlay
/// extension and cannot be overridden, so directory listing itself is not
/// countable — the zero-open + zero-stat pair still proves no file was read.)
private final class CountingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var _attributeCalls = 0

    var attributeCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _attributeCalls
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        lock.lock()
        _attributeCalls += 1
        lock.unlock()
        return try super.attributesOfItem(atPath: path)
    }
}

private final class CountingOpener: @unchecked Sendable {
    private let lock = NSLock()
    private var _opens = 0

    var opens: Int {
        lock.lock()
        defer { lock.unlock() }
        return _opens
    }

    func open(_ path: String) -> FileHandle? {
        lock.lock()
        _opens += 1
        lock.unlock()
        return FileHandle(forReadingAtPath: path)
    }
}

// MARK: - Local Ollama HTTP stub

/// `URLProtocol` answering the local Ollama `/api/generate` endpoint with a
/// canned `{"response": <json>}` envelope — the exact path
/// `MemoryExtractionLLMClient.callOllama` takes for the usage `.localText`
/// route (mirrors `UsageStage1OllamaStub`). Counting doubles as the "zero LLM
/// invocations" dormancy probe.
private final class AcceptanceOllamaStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requestCount = 0
    nonisolated(unsafe) private static var _responseJSON = "{\"memories\":[]}"

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestCount
    }

    static var responseJSON: String {
        get { lock.lock(); defer { lock.unlock() }; return _responseJSON }
        set { lock.lock(); _responseJSON = newValue; lock.unlock() }
    }

    static func reset() {
        lock.lock(); _requestCount = 0; _responseJSON = "{\"memories\":[]}"; lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.path.contains("api/generate") ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._requestCount += 1; let json = Self._responseJSON; Self.lock.unlock()

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
