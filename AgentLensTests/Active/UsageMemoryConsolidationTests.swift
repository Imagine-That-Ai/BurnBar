import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - PR8: Stage-3 zero-LLM consolidation passes
//
// Covers the deterministic consolidation surface over in-memory DB fixtures:
//   * decay recompute golden values (fixed dates, hand-computed salience for
//     three profiles) + the 24 h computed_at staleness gate;
//   * reinforce-on-use bumps hits/timestamps and lazily seeds absent rows
//     (chat AND usage ids uniformly);
//   * decay eviction deletes ONLY quarantined+aged+unused+low-salience usage
//     rows — with sidecar/link/ref cleanup riding the delete path — while
//     approved rows survive even with WORSE salience (the v1 never-evict-
//     approved invariant), and cap eviction takes lowest-salience quarantined
//     first;
//   * candidate TTL expiry + orphan repair/GC counts (incl. the synthetic
//     suppressed-extraction `from`-id exception on memory_links);
//   * recall parity: a salience-free database ranks EXACTLY as pre-PR8
//     (the regression pin for live chat recall), and a salience-rich one
//     boosts (clamped) higher-salience rows above equal-text-score rivals;
//   * worker dormancy (gate off ⇒ zeroed report, zero writes) and the full
//     tick order recompute → evict → TTL expiry → orphan purge.
// The chat lane's deeper regression proof is `MemoryActivationEndToEndTests`,
// run alongside this suite.
@MainActor
final class UsageMemoryConsolidationTests: XCTestCase {

    private let scope = MemoryScope(appID: "openburnbar")
    /// Fixed clock for every fixture — decay math must never read the wall clock.
    private let baseNow = Date(timeIntervalSince1970: 1_900_000_000)

    private func days(_ count: Double) -> TimeInterval { count * 86_400 }

    // MARK: - Decay recompute

    func test_recomputeMemorySalience_goldenProfiles() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore
        let seedStamp = baseNow.addingTimeInterval(-days(3))

        // Profile A — reinforced chat row: age anchors on last_reinforced_at
        // (10 d), NOT valid_from (40 d). hits 4, corroboration 2, trust 1.0:
        //   0.35·e^(−10/30) + 0.25·ln(5)/ln(101) + 0.20·1.0 + 0.20·(2/5)
        _ = try await insertMemory(store: store, id: "profile-a", body: "Profile A body.", sourceKind: .chat, now: baseNow.addingTimeInterval(-days(40)))
        try await store.seedMemorySalience(memoryID: "profile-a", salience: 0.5, sourceTrust: 1.0, now: seedStamp)
        try await setSalienceCounters(queue, id: "profile-a", hitCount: 4, corroboration: 2, lastReinforcedAt: baseNow.addingTimeInterval(-days(10)))

        // Profile B — never-reinforced usage row aged 60 d, hits 0,
        // corroboration 1, trust 0.5:
        //   0.35·e^(−2) + 0 + 0.20·0.5 + 0.20·(1/5)
        _ = try await insertMemory(store: store, id: "profile-b", body: "Profile B body.", sourceKind: .agentSession, now: baseNow.addingTimeInterval(-days(60)))
        try await store.seedMemorySalience(memoryID: "profile-b", salience: 0.5, sourceTrust: 0.5, now: seedStamp)

        // Profile C — reinforced NOW, hits 100 (log term saturates exactly at
        // 1.0), corroboration 9 capped to 5, trust 0.7:
        //   0.35·1 + 0.25·1 + 0.20·0.7 + 0.20·1 = 0.94
        _ = try await insertMemory(store: store, id: "profile-c", body: "Profile C body.", sourceKind: .safariAsk, now: baseNow.addingTimeInterval(-days(90)))
        try await store.seedMemorySalience(memoryID: "profile-c", salience: 0.5, sourceTrust: 0.7, now: seedStamp)
        try await setSalienceCounters(queue, id: "profile-c", hitCount: 100, corroboration: 9, lastReinforcedAt: baseNow)

        let recomputed = try await store.recomputeMemorySalience(policy: .defaults, now: baseNow)
        XCTAssertEqual(recomputed, 3)

        let salienceAFetched = try await salienceValue(queue, id: "profile-a")
        let salienceA = try XCTUnwrap(salienceAFetched)
        XCTAssertEqual(salienceA, 0.6179688343462737, accuracy: 1e-9)
        let salienceBFetched = try await salienceValue(queue, id: "profile-b")
        let salienceB = try XCTUnwrap(salienceBFetched)
        XCTAssertEqual(salienceB, 0.18736734913281447, accuracy: 1e-9)
        let salienceCFetched = try await salienceValue(queue, id: "profile-c")
        let salienceC = try XCTUnwrap(salienceCFetched)
        XCTAssertEqual(salienceC, 0.94, accuracy: 1e-9)

        // The pass stamps computed_at, so an immediate second pass is a no-op.
        let again = try await store.recomputeMemorySalience(policy: .defaults, now: baseNow)
        XCTAssertEqual(again, 0)
    }

    func test_recomputeMemorySalience_skipsFreshlyComputedRows() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore
        _ = try await insertMemory(store: store, id: "fresh-1", body: "Fresh row body.", sourceKind: .agentSession, now: baseNow.addingTimeInterval(-days(60)))
        // Seeded 1 h ago — inside the 24 h freshness window.
        try await store.seedMemorySalience(memoryID: "fresh-1", salience: 0.42, sourceTrust: 0.5, now: baseNow.addingTimeInterval(-3600))

        let recomputed = try await store.recomputeMemorySalience(policy: .defaults, now: baseNow)
        XCTAssertEqual(recomputed, 0)
        let salienceFetched = try await salienceValue(queue, id: "fresh-1")
        let salience = try XCTUnwrap(salienceFetched)
        XCTAssertEqual(salience, 0.42, "a fresh row keeps its seed untouched")
    }

    // MARK: - Reinforce-on-use

    func test_reinforceMemories_bumpsHitsAndSeedsAbsentRows() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore
        _ = try await insertMemory(store: store, id: "use-1", body: "Seeded usage row.", sourceKind: .agentSession, now: baseNow)
        try await store.seedMemorySalience(memoryID: "use-1", salience: 0.8, sourceTrust: 0.5, now: baseNow)
        _ = try await insertMemory(store: store, id: "chat-1", body: "Chat row without a sidecar.", sourceKind: .chat, now: baseNow)

        let reinforceStamp = baseNow.addingTimeInterval(3600)
        try await store.reinforceMemories(ids: ["use-1", "chat-1"], now: reinforceStamp)

        // The existing usage seed keeps salience/corroboration/trust; only the
        // usage counters move.
        let usageRowFetched = try await salienceRow(queue, id: "use-1")
        let usageRow = try XCTUnwrap(usageRowFetched)
        XCTAssertEqual(usageRow["hit_count"] as Int?, 1)
        XCTAssertEqual(usageRow["salience"] as Double?, 0.8)
        XCTAssertEqual(usageRow["corroboration"] as Int?, 1)
        XCTAssertEqual(usageRow["source_trust"] as Double?, 0.5)
        let usageReinforcedAt = try XCTUnwrap(usageRow["last_reinforced_at"] as Date?)
        XCTAssertEqual(usageReinforcedAt.timeIntervalSince1970, reinforceStamp.timeIntervalSince1970, accuracy: 0.01)

        // The chat row was seeded lazily: salience 0 (no recall boost until the
        // next recompute scores it), chat policy trust, and the hit it just earned.
        let chatRowFetched = try await salienceRow(queue, id: "chat-1")
        let chatRow = try XCTUnwrap(chatRowFetched)
        XCTAssertEqual(chatRow["hit_count"] as Int?, 1)
        XCTAssertEqual(chatRow["salience"] as Double?, 0.0)
        XCTAssertEqual(chatRow["corroboration"] as Int?, 1)
        XCTAssertEqual(chatRow["source_trust"] as Double?, 1.0)

        try await store.reinforceMemories(ids: ["use-1"], now: reinforceStamp.addingTimeInterval(60))
        let bumpedRowFetched = try await salienceRow(queue, id: "use-1")
        let bumpedRow = try XCTUnwrap(bumpedRowFetched)
        XCTAssertEqual(bumpedRow["hit_count"] as Int?, 2)
    }

    // MARK: - Eviction

    func test_evictDecayed_deletesOnlyAgedUnusedQuarantinedUsageRows() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore
        let old = baseNow.addingTimeInterval(-days(30))

        // The victim: quarantined usage row, salience 0.05 < 0.15, 30 d old,
        // never recalled — plus a ref and links on BOTH ends to prove the
        // delete-path cleanup.
        _ = try await insertMemory(store: store, id: "evict-me", body: "Decayed quarantined usage fact.", sourceKind: .agentSession, now: old)
        try await store.seedMemorySalience(memoryID: "evict-me", salience: 0.05, sourceTrust: 0.5, now: old)
        try await insertEmbeddingRef(queue, memoryID: "evict-me", now: old)
        _ = try await insertMemory(store: store, id: "keeper", body: "Live neighbor fact.", sourceKind: .agentSession, now: baseNow)
        try await store.insertMemoryLink(from: "evict-me", to: "keeper", kind: .nearDuplicate, score: 0.93, createdBy: "stage2", now: old)
        try await store.insertMemoryLink(from: "memory-ghost-job-0", to: "evict-me", kind: .nearDuplicate, score: 0.99, createdBy: "stage2", now: old)

        // Survivors: approved with WORSE salience (the v1 invariant), young
        // quarantined, used quarantined, and a chat row (wrong partition).
        _ = try await insertMemory(store: store, id: "approved-worse", body: "Approved fact with terrible salience.", sourceKind: .agentSession, reviewStatus: .approved, now: old)
        try await store.seedMemorySalience(memoryID: "approved-worse", salience: 0.01, sourceTrust: 0.5, now: old)
        _ = try await insertMemory(store: store, id: "young-quarantined", body: "Recently created quarantined fact.", sourceKind: .agentSession, now: baseNow.addingTimeInterval(-days(5)))
        try await store.seedMemorySalience(memoryID: "young-quarantined", salience: 0.05, sourceTrust: 0.5, now: baseNow.addingTimeInterval(-days(5)))
        _ = try await insertMemory(store: store, id: "used-quarantined", body: "Recalled quarantined fact.", sourceKind: .agentSession, now: old)
        try await store.seedMemorySalience(memoryID: "used-quarantined", salience: 0.05, sourceTrust: 0.5, now: old)
        try await setSalienceCounters(queue, id: "used-quarantined", hitCount: 1, corroboration: 1, lastReinforcedAt: baseNow)
        _ = try await insertMemory(store: store, id: "chat-low", body: "Low-salience chat fact.", sourceKind: .chat, now: old)
        try await store.seedMemorySalience(memoryID: "chat-low", salience: 0.01, sourceTrust: 1.0, now: old)

        let report = try await store.evictDecayedUsageMemories(policy: .defaults, now: baseNow)
        XCTAssertEqual(report.decayed, 1)
        XCTAssertEqual(report.overCap, 0)

        // The victim is gone from the authority table AND every sidecar.
        let victimRow = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT id FROM agent_memories WHERE id = 'evict-me'")
        }
        XCTAssertNil(victimRow)
        let victimSalience = try await salienceRow(queue, id: "evict-me")
        XCTAssertNil(victimSalience)
        let victimRefCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embedding_refs WHERE memory_id = 'evict-me'") ?? -1
        }
        XCTAssertEqual(victimRefCount, 0)
        let victimLinkCount = try await queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_links WHERE from_memory_id = 'evict-me' OR to_memory_id = 'evict-me'"
            ) ?? -1
        }
        XCTAssertEqual(victimLinkCount, 0, "links on BOTH ends ride the delete")

        // The audit rides the delete path.
        let deleteLabels = try await queue.read { db in
            try String.fetchAll(db, sql: "SELECT labels_json FROM memory_audit WHERE action = 'memory.delete' ORDER BY seq ASC")
        }
        XCTAssertTrue(deleteLabels.contains { $0.contains("memory_id:evict-me") })

        // Every survivor is intact — the approved row explicitly so, despite
        // having the WORST salience on the table (never-evict-approved, v1).
        for survivor in ["keeper", "approved-worse", "young-quarantined", "used-quarantined", "chat-low"] {
            let row = try await queue.read { db in
                try Row.fetchOne(db, sql: "SELECT id FROM agent_memories WHERE id = ?", arguments: [survivor])
            }
            XCTAssertNotNil(row, "\(survivor) must survive the decay sweep")
        }
    }

    func test_capEviction_takesLowestSalienceQuarantinedFirst_neverApproved() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore
        var policy = UsageMemoryCurationPolicy.defaults
        policy.caps.maxUsageMemories = 2

        // All young + above the evict threshold, so the decay pass stays out
        // of the way and ONLY cap pressure evicts.
        let recent = baseNow.addingTimeInterval(-days(1))
        _ = try await insertMemory(store: store, id: "cap-a", body: "Cap fixture fact A.", sourceKind: .agentSession, now: recent)
        try await store.seedMemorySalience(memoryID: "cap-a", salience: 0.3, sourceTrust: 0.5, now: recent)
        _ = try await insertMemory(store: store, id: "cap-b", body: "Cap fixture fact B.", sourceKind: .agentSession, now: recent)
        try await store.seedMemorySalience(memoryID: "cap-b", salience: 0.5, sourceTrust: 0.5, now: recent)
        _ = try await insertMemory(store: store, id: "cap-c", body: "Cap fixture fact C.", sourceKind: .agentSession, now: recent)
        try await store.seedMemorySalience(memoryID: "cap-c", salience: 0.9, sourceTrust: 0.5, now: recent)
        // Approved row with the LOWEST salience of all — cap pressure must
        // still never touch it (v1 never-evict-approved).
        _ = try await insertMemory(store: store, id: "cap-approved", body: "Approved cap fixture fact.", sourceKind: .agentSession, reviewStatus: .approved, now: recent)
        try await store.seedMemorySalience(memoryID: "cap-approved", salience: 0.05, sourceTrust: 0.5, now: recent)

        let report = try await store.evictDecayedUsageMemories(policy: policy, now: baseNow)
        XCTAssertEqual(report.decayed, 0)
        XCTAssertEqual(report.overCap, 2, "4 usage rows over a cap of 2 evicts exactly the overflow")

        let survivors = try await queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT id FROM agent_memories WHERE source_kind IN ('safari_ask','agent_session') ORDER BY id ASC"
            )
        }
        XCTAssertEqual(survivors, ["cap-approved", "cap-c"], "lowest-salience quarantined (0.3, 0.5) went first; approved survives at 0.05")
    }

    // MARK: - TTL expiry + orphan purge

    func test_candidateTTLExpiry_andOrphanPurge_counts() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore

        // TTL: two pending candidates 20 d old, one 1 d old; TTL 14 d.
        try await store.insertUsageMemoryCandidates(
            [
                makeCandidate(text: "Stale spool candidate one.", sourceRef: "codex:stale-1"),
                makeCandidate(text: "Stale spool candidate two.", sourceRef: "codex:stale-2")
            ],
            cursorKey: nil,
            cursorJSON: nil,
            now: baseNow.addingTimeInterval(-days(20))
        )
        try await store.insertUsageMemoryCandidates(
            [makeCandidate(text: "Fresh spool candidate.", sourceRef: "codex:fresh-1")],
            cursorKey: nil,
            cursorJSON: nil,
            now: baseNow.addingTimeInterval(-days(1))
        )
        let expired = try await store.expireUsageCandidates(olderThan: 14, now: baseNow)
        XCTAssertEqual(expired, 2)
        let pending = try await store.pendingUsageCandidateCount()
        XCTAssertEqual(pending, 1)

        // Orphans: one live anchor row, then strays of every species.
        _ = try await insertMemory(store: store, id: "keeper", body: "Live anchor fact.", sourceKind: .agentSession, now: baseNow)
        try await store.seedMemorySalience(memoryID: "ghost-salience", salience: 0.4, sourceTrust: 0.5, now: baseNow)
        try await insertEmbeddingRef(queue, memoryID: "ghost-ref", now: baseNow)
        // L1: synthetic suppressed-extraction from-id + live to ⇒ KEPT.
        try await store.insertMemoryLink(from: "memory-job-abc-0", to: "keeper", kind: .nearDuplicate, score: 0.99, createdBy: "stage2", now: baseNow)
        // L2: non-synthetic missing from + live to ⇒ purged.
        try await store.insertMemoryLink(from: "5D1FB9C0-DEAD-BEEF-0000-000000000000", to: "keeper", kind: .nearDuplicate, score: 0.99, createdBy: "stage2", now: baseNow)
        // L3: live from + missing to ⇒ purged.
        try await store.insertMemoryLink(from: "keeper", to: "gone-to", kind: .supports, score: 0.9, createdBy: "stage3", now: baseNow)
        // L4: synthetic from + missing to ⇒ purged (the trace dies with its winner).
        try await store.insertMemoryLink(from: "memory-job-def-1", to: "gone-to-2", kind: .nearDuplicate, score: 0.99, createdBy: "stage2", now: baseNow)

        let purged = try await store.purgeOrphanConsolidationRows()
        XCTAssertEqual(purged, 5, "1 salience + 1 ref + L2 + L3 + L4")

        let remainingLinks = try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT from_memory_id, to_memory_id FROM memory_links")
        }
        XCTAssertEqual(remainingLinks.count, 1)
        XCTAssertEqual(remainingLinks.first?["from_memory_id"] as String?, "memory-job-abc-0")
        XCTAssertEqual(remainingLinks.first?["to_memory_id"] as String?, "keeper")
        let ghostSalience = try await salienceRow(queue, id: "ghost-salience")
        XCTAssertNil(ghostSalience)
        let ghostRefCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embedding_refs WHERE memory_id = 'ghost-ref'") ?? -1
        }
        XCTAssertEqual(ghostRefCount, 0)
    }

    // MARK: - Recall ranking

    func test_recallParity_salienceFreeDatabase_keepsPrePR8Ordering() async throws {
        let (_, dataStore, store) = try makeStore()
        _ = dataStore
        // Four approved chat rows, all fully matching the query (text score
        // 1.0 each), with NO salience rows anywhere: ranking must be EXACTLY
        // the pre-PR8 formula — confidence DESC, then id ASC on the tie.
        _ = try await insertMemory(store: store, id: "pin-a", body: "Alpha bravo memo one.", sourceKind: .chat, reviewStatus: .approved, confidence: 0.9, now: baseNow)
        _ = try await insertMemory(store: store, id: "pin-b", body: "Alpha bravo memo two.", sourceKind: .chat, reviewStatus: .approved, confidence: 0.7, now: baseNow)
        _ = try await insertMemory(store: store, id: "pin-c", body: "Alpha bravo memo three.", sourceKind: .chat, reviewStatus: .approved, confidence: 0.5, now: baseNow)
        _ = try await insertMemory(store: store, id: "pin-d", body: "Alpha bravo memo four.", sourceKind: .chat, reviewStatus: .approved, confidence: 0.5, now: baseNow)

        let snippets = try await store.recallChatMemorySnippets(
            MemoryRecallRequest(query: "alpha bravo", scope: scope, tokenBudget: 4000, limit: 8)
        )
        XCTAssertEqual(snippets.map(\.memoryID), ["pin-a", "pin-b", "pin-c", "pin-d"])

        let searched = try await store.searchChatMemoryAuthorityRecords(
            MemoryQuery(text: "alpha bravo", scope: scope, limit: 8)
        )
        XCTAssertEqual(searched.map(\.id), ["pin-a", "pin-b", "pin-c", "pin-d"])
    }

    func test_recall_salienceBoost_outranksEqualTextScoreRival_andClamps() async throws {
        let (_, dataStore, store) = try makeStore()
        _ = dataStore
        // Equal confidence, equal text score ⇒ pre-PR8 tie broken by id ASC.
        _ = try await insertMemory(store: store, id: "tie-a", body: "Green tea is the preferred afternoon drink.", sourceKind: .chat, reviewStatus: .approved, now: baseNow)
        _ = try await insertMemory(store: store, id: "tie-b", body: "Green tea keeps the focus sharp at night.", sourceKind: .chat, reviewStatus: .approved, now: baseNow)
        let request = MemoryRecallRequest(query: "green tea", scope: scope, tokenBudget: 4000, limit: 8)

        let baseline = try await store.recallChatMemorySnippets(request)
        XCTAssertEqual(baseline.map(\.memoryID), ["tie-a", "tie-b"], "no salience rows ⇒ id ASC tiebreak")

        // Salience 1.0 on the rival flips the order (+0.3 beats the tiebreak).
        try await store.seedMemorySalience(memoryID: "tie-b", salience: 1.0, sourceTrust: 1.0, now: baseNow)
        let boosted = try await store.recallChatMemorySnippets(request)
        XCTAssertEqual(boosted.map(\.memoryID), ["tie-b", "tie-a"])

        // An out-of-range salience clamps to 1.0: both boosts are now +0.3, so
        // the id-ASC tiebreak decides again.
        try await store.seedMemorySalience(memoryID: "tie-a", salience: 5.0, sourceTrust: 1.0, now: baseNow)
        let clamped = try await store.recallChatMemorySnippets(request)
        XCTAssertEqual(clamped.map(\.memoryID), ["tie-a", "tie-b"], "clamp(5.0) == clamp(1.0) ⇒ tie ⇒ id ASC")
    }

    // MARK: - Worker

    func test_worker_gateOff_returnsZeroedReport_andWritesNothing() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore
        // State every pass WOULD touch if the gate were open.
        try await store.insertUsageMemoryCandidates(
            [makeCandidate(text: "Stale spool candidate.", sourceRef: "codex:dormant-1")],
            cursorKey: nil,
            cursorJSON: nil,
            now: baseNow.addingTimeInterval(-days(20))
        )
        _ = try await insertMemory(store: store, id: "old-1", body: "Ancient quarantined usage fact.", sourceKind: .agentSession, now: baseNow.addingTimeInterval(-days(120)))
        try await store.seedMemorySalience(memoryID: "old-1", salience: 0.9, sourceTrust: 0.5, now: baseNow.addingTimeInterval(-days(3)))
        try await store.seedMemorySalience(memoryID: "ghost-salience", salience: 0.4, sourceTrust: 0.5, now: baseNow)

        let worker = MemoryConsolidationWorker(store: store, isEnabled: { false })
        let report = await worker.consolidationTick(policy: .defaults, now: baseNow)
        XCTAssertEqual(report, MemoryConsolidationWorker.TickReport())

        let pending = try await store.pendingUsageCandidateCount()
        XCTAssertEqual(pending, 1, "dormant tick expires nothing")
        let oldSalienceFetched = try await salienceValue(queue, id: "old-1")
        let oldSalience = try XCTUnwrap(oldSalienceFetched)
        XCTAssertEqual(oldSalience, 0.9, "dormant tick recomputes nothing")
        let ghost = try await salienceRow(queue, id: "ghost-salience")
        XCTAssertNotNil(ghost, "dormant tick purges nothing")
        let memoryCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories") ?? -1
        }
        XCTAssertEqual(memoryCount, 1, "dormant tick evicts nothing")
    }

    func test_worker_tick_runsAllPassesInOrder() async throws {
        let (queue, dataStore, store) = try makeStore()
        _ = dataStore
        // A 120 d-old quarantined usage row seeded ABOVE the evict threshold:
        // only the recompute (0.35·e^(−4) + 0.20·0.5 + 0.20·(1/5) ≈ 0.14641 <
        // 0.15) makes it evictable — proving the recompute → evict order.
        _ = try await insertMemory(store: store, id: "old-1", body: "Ancient quarantined usage fact.", sourceKind: .agentSession, now: baseNow.addingTimeInterval(-days(120)))
        try await store.seedMemorySalience(memoryID: "old-1", salience: 0.9, sourceTrust: 0.5, now: baseNow.addingTimeInterval(-days(3)))
        try await store.insertUsageMemoryCandidates(
            [makeCandidate(text: "Stale spool candidate.", sourceRef: "codex:tick-1")],
            cursorKey: nil,
            cursorJSON: nil,
            now: baseNow.addingTimeInterval(-days(20))
        )
        try await insertEmbeddingRef(queue, memoryID: "ghost-ref", now: baseNow)

        let worker = MemoryConsolidationWorker(store: store, isEnabled: { true })
        let report = await worker.consolidationTick(policy: .defaults, now: baseNow)
        XCTAssertEqual(report.recomputed, 1)
        XCTAssertEqual(report.evicted, 1, "recompute-first made the seeded-0.9 row evictable")
        XCTAssertEqual(report.expired, 1)
        XCTAssertEqual(report.purged, 1, "the ghost embedding ref; the evicted row's sidecars rode the delete path")

        let victim = try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT id FROM agent_memories WHERE id = 'old-1'")
        }
        XCTAssertNil(victim)
        let pending = try await store.pendingUsageCandidateCount()
        XCTAssertEqual(pending, 0)
    }

    // MARK: - Fixtures

    private func makeStore() throws -> (DatabaseQueue, DataStore, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let dataStore = try DataStore(databaseQueue: queue, runMigrations: true)
        return (queue, dataStore, ControlPlaneStore(dbQueue: queue))
    }

    @discardableResult
    private func insertMemory(
        store: ControlPlaneStore,
        id: String,
        body: String,
        sourceKind: MemorySourceKind,
        reviewStatus: MemoryReviewStatus = .quarantined,
        confidence: Double = 0.6,
        now: Date
    ) async throws -> Memory {
        try await store.addMemoryAuthorityRecord(
            MemoryAddRequest(text: body, scope: scope, confidence: confidence, reviewStatus: reviewStatus),
            id: id,
            sourceKind: sourceKind,
            now: now,
            enabled: true
        )
    }

    /// Overwrite the seeded counters directly — the seeding API deliberately
    /// refuses to rewrite live rows, and these tests need exact profiles.
    private func setSalienceCounters(
        _ queue: DatabaseQueue,
        id: String,
        hitCount: Int,
        corroboration: Int,
        lastReinforcedAt: Date?
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_salience
                SET hit_count = ?, corroboration = ?, last_reinforced_at = ?
                WHERE memory_id = ?
                """,
                arguments: [hitCount, corroboration, lastReinforcedAt, id]
            )
        }
    }

    private func insertEmbeddingRef(_ queue: DatabaseQueue, memoryID: String, now: Date) async throws {
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_embedding_refs (
                    memory_id, embedding_version_id, dimension, vector, norm, created_at
                ) VALUES (?, 'consolidation-test-v1', 4, ?, 1.0, ?)
                """,
                arguments: [memoryID, Data([0, 0, 128, 63]), now]
            )
        }
    }

    private func makeCandidate(text: String, sourceRef: String) -> UsageMemoryCandidate {
        let payload = UsageMemoryCandidatePayload(
            schemaVersion: 1,
            text: text,
            role: "user",
            threadLogicalID: sourceRef,
            observedAt: baseNow
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
            salienceHint: 0.5
        )
    }

    // MARK: - Row probes

    private func salienceRow(_ queue: DatabaseQueue, id: String) async throws -> Row? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memory_salience WHERE memory_id = ?", arguments: [id])
        }
    }

    private func salienceValue(_ queue: DatabaseQueue, id: String) async throws -> Double? {
        try await queue.read { db in
            try Double.fetchOne(db, sql: "SELECT salience FROM memory_salience WHERE memory_id = ?", arguments: [id])
        }
    }
}
