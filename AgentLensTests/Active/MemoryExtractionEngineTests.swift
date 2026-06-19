import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

// MARK: - PR-D2 MemoryExtractionEngine / pump tests
//
// Proves the PR-D2 must-fixes of the memory-activation build plan at their
// deterministic core — the worker pump, the Sendable kill-switch atomic, the failed-job
// read seam, and the local-first provider ordering. The `MemoryExtractionEngine` itself
// is a thin `@MainActor` scheduler over these pieces; the load-bearing correctness is
// here, where it can be driven without a full app graph.
//
//   #1 THE PUMP. The worker's `drainClaimedJob` catches an extractor error, marks the
//      job failed, and returns WITHOUT re-throwing — so a `Bool`-guarded loop
//      (`while drainOne()`) would HALT the whole backlog on the first failing job. The
//      tri-state `drainNext()` lets the pump keep draining past a failure. This is the
//      headline regression the plan flags; `test_pump_drainsPastFailingJob` is its proof.
//   #2/#4 The kill switch is a `Sendable` atomic re-established at the WORKER boundary
//      and read LIVE (never cached): flipping it between ticks changes behavior.
//   #3 A failed job is observable only via its terminal status (errors do not propagate
//      through `drainNext`); `mostRecentFailedMemoryExtractionJob` is that seam.
//   #7 Provider order is forced local-first regardless of the user's summary order.
//
// The whole feature ships OFF; these tests force the gates ON explicitly to exercise the
// dormant machinery, mirroring the PR-D1 extractor tests.
@MainActor
final class MemoryExtractionEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeStore() throws -> (ControlPlaneStore, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (ControlPlaneStore(dbQueue: queue), queue)
    }

    private func insertChatMessage(
        _ queue: DatabaseQueue,
        threadID: String,
        id: String,
        role: String,
        body: String,
        at date: Date
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO chat_threads (id, createdAt, updatedAt) VALUES (?, ?, ?)",
                arguments: [threadID, date, date]
            )
            try db.execute(
                sql: """
                INSERT INTO chat_messages (id, role, content, timestamp, threadId)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [id, role, body, date, threadID]
            )
        }
    }

    @discardableResult
    private func enqueue(
        _ store: ControlPlaneStore,
        threadID: String,
        messageID: String,
        idempotencyKey: String,
        now: Date
    ) async throws -> String {
        let intent = ExtractionIntent(
            threadID: threadID,
            threadLogicalID: "\(threadID)-logical",
            messageID: messageID,
            scope: MemoryScope(userID: "pr-d2-user", appID: "pr-d2-app"),
            promptVersion: "memory-extract-v1",
            idempotencyKey: idempotencyKey
        )
        return try await store.enqueueMemoryExtraction(intent, now: now)
    }

    /// Drive the worker the way `MemoryExtractionEngine.runDrain` does: loop on the
    /// tri-state until idle, bounded by a max-jobs rail. Returns (processed, failed).
    private func pump(
        _ worker: MemoryExtractionWorker,
        maxJobs: Int = 16
    ) async throws -> (processed: Int, failed: Int) {
        var processed = 0
        var failed = 0
        for _ in 0 ..< maxJobs {
            let outcome = try await worker.drainNext()
            switch outcome {
            case .drained:
                processed += 1
            case .claimedButFailed:
                processed += 1
                failed += 1
            case .idle:
                return (processed, failed)
            }
        }
        return (processed, failed)
    }

    // MARK: - #1 The pump: a failing job must NOT halt the backlog

    func test_pump_drainsPastFailingJob() async throws {
        let (store, queue) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        // Two independent jobs. Job A's transcript message is MISSING from the DB, so the
        // extractor below throws for it (simulating a transient read fault). Job B is
        // well-formed and yields one durable fact.
        try await insertChatMessage(queue, threadID: "thread-b", id: "msg-b", role: "user", body: "I deploy on Fridays.", at: now)
        let jobA = try await enqueue(store, threadID: "thread-a", messageID: "msg-a", idempotencyKey: "idem-a", now: now)
        let jobB = try await enqueue(store, threadID: "thread-b", messageID: "msg-b", idempotencyKey: "idem-b", now: now)

        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { job in
                if job.threadID == "thread-a" {
                    // Simulate a genuine transient fault for job A only.
                    throw NSError(domain: "test.pump", code: 1)
                }
                return [
                    MemoryAddRequest(
                        text: "User deploys on Fridays.",
                        kind: .preference,
                        scope: job.scope,
                        confidence: 0.8,
                        citations: [
                            MemoryCitation(
                                id: "cite-b",
                                threadLogicalID: job.threadLogicalID,
                                messageID: "msg-b",
                                role: "user",
                                authoredAt: now,
                                contentHash: "ignored-by-worker",
                                crossDeviceHMAC: "ignored-by-worker"
                            )
                        ],
                        reviewStatus: .quarantined
                    )
                ]
            }
        )

        // A `while drainOne()` loop would stop here after the FIRST tick (job A returns
        // false). The tri-state pump keeps going.
        let result = try await pump(worker)

        XCTAssertEqual(result.processed, 2, "both jobs claimed despite one failing")
        XCTAssertEqual(result.failed, 1, "exactly job A failed")

        let statusA = try await store.memoryExtractionJobStatus(id: jobA)
        let statusB = try await store.memoryExtractionJobStatus(id: jobB)
        XCTAssertEqual(statusA, .failed, "job A failed")
        XCTAssertEqual(statusB, .succeeded, "job B drained even though it sat behind a failing job")

        // Job B's fact was persisted (quarantined) — the backlog truly drained.
        let bodyCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? 0
        }
        XCTAssertEqual(bodyCount, 1)
    }

    // MARK: - Worker-boundary G7 DROP gate (PR-D FIX #4): defense-in-depth
    //
    // The extractor has its OWN candidate pre-filter, but the design leans on the WORKER's
    // G7 DROP gate as the last line of defense: even if a secret-bearing candidate reaches
    // `drainClaimedJob` (a buggy/bypassed/prompt-injected extractor, a future refactor that
    // drops the pre-filter), it MUST NOT be persisted, while clean siblings in the same
    // batch DO persist. This test feeds a secret candidate DIRECTLY to the worker (the
    // extractor closure here returns it verbatim, bypassing any pre-filter) and proves the
    // worker drops exactly the secret and stores the clean ones — the path PR-D leaned on
    // but left unproven.
    func test_worker_dropsSecretCandidate_persistsCleanSiblings() async throws {
        let (store, queue) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_600)

        // The cited source message must exist so the clean candidates' provenance resolves.
        try await insertChatMessage(
            queue,
            threadID: "thread-secret",
            id: "msg-secret",
            role: "assistant",
            body: "Here is some context for the extracted facts.",
            at: now
        )
        let jobID = try await enqueue(
            store,
            threadID: "thread-secret",
            messageID: "msg-secret",
            idempotencyKey: "idem-secret",
            now: now
        )

        // A live-looking Anthropic key the G7 corpus flags as `anthropic-api-key`. Bypasses
        // the extractor pre-filter entirely: the closure hands it straight to the worker.
        let secret = "sk-ant-deadbeefdeadbeefdeadbeef0001"

        func candidate(_ text: String) -> MemoryAddRequest {
            MemoryAddRequest(
                text: text,
                kind: .fact,
                scope: MemoryScope(userID: "pr-d2-user", appID: "pr-d2-app"),
                confidence: 0.9,
                citations: [
                    MemoryCitation(
                        id: "cite",
                        threadLogicalID: "thread-secret-logical",
                        messageID: "msg-secret",
                        role: "assistant",
                        authoredAt: now,
                        // Worker recomputes provenance; these are ignored on purpose.
                        contentHash: "ignored-by-worker",
                        crossDeviceHMAC: "ignored-by-worker"
                    )
                ],
                reviewStatus: .quarantined
            )
        }

        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            // Batch order: clean (index 0) → SECRET (index 1) → clean (index 2). The worker
            // must drop ONLY index 1 and persist 0 and 2.
            extractor: { _ in
                [
                    candidate("User prefers concise answers."),
                    candidate("My api key is \(secret) keep it safe."),
                    candidate("User works in the Pacific time zone.")
                ]
            }
        )

        let outcome = try await worker.drainNext()
        // The job SUCCEEDS even though one candidate was dropped — a dropped secret is not a
        // job failure; the clean facts still committed.
        XCTAssertEqual(outcome, .drained, "the job succeeds; the secret is dropped, not failed")
        XCTAssertEqual(try await store.memoryExtractionJobStatus(id: jobID), .succeeded)

        // Index 0 and 2 persisted with their clean bodies; index 1 (the secret) did NOT.
        let mem0 = try await store.fetchChatMemoryAuthorityRecord(id: "memory-\(jobID)-0")
        let mem1 = try await store.fetchChatMemoryAuthorityRecord(id: "memory-\(jobID)-1")
        let mem2 = try await store.fetchChatMemoryAuthorityRecord(id: "memory-\(jobID)-2")
        XCTAssertEqual(mem0?.bodyRedacted, "User prefers concise answers.")
        XCTAssertNil(mem1, "the secret-bearing candidate was DROPPED by the worker's G7 gate")
        XCTAssertEqual(mem2?.bodyRedacted, "User works in the Pacific time zone.")

        // Exactly two clean memories total — the secret never reached `agent_memories`.
        let total = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_memories WHERE source_kind = 'chat'") ?? -1
        }
        XCTAssertEqual(total, 2, "two clean siblings stored; the secret persisted nowhere")

        // Belt-and-braces: the raw secret string appears in NO stored body — neither the
        // redacted column on `agent_memories` nor any `memory_body_snapshots` JSON snapshot
        // (the secret candidate is dropped BEFORE either is written).
        let redactedHits = try await queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM agent_memories WHERE body_redacted LIKE ?",
                arguments: ["%\(secret)%"]
            ) ?? -1
        }
        XCTAssertEqual(redactedHits, 0, "the secret string is absent from every agent_memories row")
        let snapshotHits = try await queue.read { db -> Int in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_body_snapshots WHERE snapshot_json LIKE ?",
                arguments: ["%\(secret)%"]
            ) ?? -1
        }
        XCTAssertEqual(snapshotHits, 0, "the secret string is absent from every stored body snapshot")
    }

    // MARK: - Tri-state correctness

    func test_drainNext_returnsClaimedButFailed_onExtractorThrow() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_100)
        let jobID = try await enqueue(store, threadID: "thread-f", messageID: "msg-f", idempotencyKey: "idem-f", now: now)

        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { _ in throw NSError(domain: "test", code: 2) }
        )

        let outcome = try await worker.drainNext()
        XCTAssertEqual(outcome, .claimedButFailed)
        let status = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(status, .failed)
    }

    func test_drainNext_returnsIdle_whenNothingClaimable() async throws {
        let (store, _) = try makeStore()
        let worker = MemoryExtractionWorker(
            store: store,
            authorityWritesEnabled: { true },
            extractor: { _ in [] }
        )
        let outcome = try await worker.drainNext()
        XCTAssertEqual(outcome, .idle, "no enqueued jobs -> idle")
    }

    // MARK: - #2/#4 Kill switch atomic at the worker boundary, read LIVE

    func test_drainNext_returnsIdle_whenKillSwitchClosed() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_200)
        let jobID = try await enqueue(store, threadID: "thread-k", messageID: "msg-k", idempotencyKey: "idem-k", now: now)

        let killSwitch = MemoryExtractionKillSwitch(initiallyAllowed: false)
        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { killSwitch.isAllowed() },
            extractor: { _ in [MemoryAddRequest(text: "should never run", scope: MemoryScope(appID: "x"))] }
        )

        // Closed: the pre-claim guard returns idle and never claims the job.
        let blocked = try await worker.drainNext()
        XCTAssertEqual(blocked, .idle)
        let stillPending = try await store.memoryExtractionJobStatus(id: jobID)
        XCTAssertEqual(stillPending, .pending, "a closed kill switch must not claim (burn an attempt on) the job")
    }

    func test_killSwitch_isLiveNotCached_acrossTicks() async throws {
        let (store, queue) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_300)
        try await insertChatMessage(queue, threadID: "thread-live", id: "msg-live", role: "user", body: "Remember this.", at: now)
        let jobID = try await enqueue(store, threadID: "thread-live", messageID: "msg-live", idempotencyKey: "idem-live", now: now)

        // Start CLOSED; the worker closure reads the SAME atomic instance every tick.
        let killSwitch = MemoryExtractionKillSwitch(initiallyAllowed: false)
        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { killSwitch.isAllowed() },
            extractor: { job in
                [MemoryAddRequest(text: "A durable preference.", kind: .preference, scope: job.scope)]
            }
        )

        // Tick 1: closed -> idle, job untouched.
        XCTAssertEqual(try await worker.drainNext(), .idle)
        XCTAssertEqual(try await store.memoryExtractionJobStatus(id: jobID), .pending)

        // Flip the atomic OPEN (as the MainActor would on a toggle / Remote Config change).
        killSwitch.set(true)

        // Tick 2: the worker sees the NEW value with no reconstruction -> drains.
        XCTAssertEqual(try await worker.drainNext(), .drained)
        XCTAssertEqual(try await store.memoryExtractionJobStatus(id: jobID), .succeeded)
    }

    // MARK: - #3 Failed-job read seam

    func test_mostRecentFailedJob_returnsTheFailedJob() async throws {
        let (store, _) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_400)
        let jobID = try await enqueue(store, threadID: "thread-mr", messageID: "msg-mr", idempotencyKey: "idem-mr", now: now)

        XCTAssertNil(try await store.mostRecentFailedMemoryExtractionJob(), "no failures yet")

        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { _ in throw NSError(domain: "test", code: 3) }
        )
        _ = try await worker.drainNext()

        let failed = try await store.mostRecentFailedMemoryExtractionJob()
        XCTAssertEqual(failed?.id, jobID)
        XCTAssertEqual(failed?.status, .failed)
        XCTAssertNotNil(failed?.lastError)
    }

    // MARK: - #6 Back-compat: drainOne is still a Bool over the tri-state

    func test_drainOne_boolAdapter_trueOnSuccess_falseOtherwise() async throws {
        let (store, queue) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_900_000_500)
        try await insertChatMessage(queue, threadID: "thread-bc", id: "msg-bc", role: "user", body: "Note.", at: now)
        let okJob = try await enqueue(store, threadID: "thread-bc", messageID: "msg-bc", idempotencyKey: "idem-bc", now: now)

        let worker = MemoryExtractionWorker(
            store: store,
            nowProvider: { now },
            authorityWritesEnabled: { true },
            extractor: { job in [MemoryAddRequest(text: "A note.", scope: job.scope)] }
        )
        let drained = try await worker.drainOne()
        XCTAssertTrue(drained, "drainOne returns true on a successful drain")
        XCTAssertEqual(try await store.memoryExtractionJobStatus(id: okJob), .succeeded)

        // Nothing left -> drainOne returns false (idle).
        XCTAssertFalse(try await worker.drainOne())
    }

    // MARK: - #7 Local-first provider ordering (pure policy)

    func test_localFirstProviderOrder_forcesOnDeviceProvidersFirst() {
        // A deliberately CLOUD-FIRST user configuration.
        let cloudFirst: [SummaryProviderID] = [.openrouter, .zai, .local, .minimax, .mlx, .ollama]
        let ordered = MemoryExtractionEngine.localFirstProviderOrder(cloudFirst)

        // On-device providers lead, in their original relative order; cloud follows.
        XCTAssertEqual(Array(ordered.prefix(3)), [.local, .mlx, .ollama])
        XCTAssertEqual(ordered, [.local, .mlx, .ollama, .openrouter, .zai, .minimax])
        // No duplicates.
        XCTAssertEqual(Set(ordered).count, ordered.count)
    }

    func test_localFirstProviderOrder_injectsLocalWhenUserRemovedAllOnDevice() {
        let cloudOnly: [SummaryProviderID] = [.openrouter, .zai]
        let ordered = MemoryExtractionEngine.localFirstProviderOrder(cloudOnly)
        XCTAssertEqual(ordered.first, .local, "at least one on-device provider must lead")
        XCTAssertEqual(ordered, [.local, .openrouter, .zai])
    }

    func test_localFirstProviderOrder_emptyConfigFallsBackToAllLocalFirst() {
        let ordered = MemoryExtractionEngine.localFirstProviderOrder([])
        XCTAssertEqual(Array(ordered.prefix(3)), [.local, .mlx, .ollama])
        XCTAssertEqual(Set(ordered).count, ordered.count)
    }
}
