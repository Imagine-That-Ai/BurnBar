import XCTest
import GRDB
import OpenBurnBarCore
import OpenBurnBarMemoryExport
@testable import OpenBurnBar
import OpenBurnBarData

/// Wave 2.1c-iii memory authority single-writer cutover: the app finalizes
/// its memory write sets locally and commits them through the
/// `MemoryAuthorityWriter` seam instead of writing the authority tables
/// directly.
///
/// These tests pin the exact app→daemon mapping for all ten flows
/// (remember, update+reseal, review, delete, source-tombstone record,
/// reconcile, claim, enqueue, mark-replicated, audit append), prove the
/// local connection is never written (pre-reads only), prove the reseal
/// compare-and-swap retry and the fail-closed paths, and prove the local
/// test double round-trips records identically to the old local path with
/// an audit chain that verifies through the real export verifier.
///
/// Run via: `./scripts/test-openburnbar-app.sh` (normalizes to `OpenBurnBarTests`).
final class MemoryAuthorityCutoverTests: XCTestCase {

    // MARK: - Harness

    private struct Fixture {
        let queue: DatabaseQueue
        let local: ControlPlaneStore
        let recording: ControlPlaneStore
        let writer: RecordingMemoryAuthorityWriter
    }

    private func makeFixture() throws -> Fixture {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase(databaseQueue: queue).runMigrationsSafely()
        let writer = RecordingMemoryAuthorityWriter()
        return Fixture(
            queue: queue,
            local: ControlPlaneStore(dbQueue: queue, memoryAuthorityWriter: LocalMemoryAuthorityWriter(dbQueue: queue)),
            recording: ControlPlaneStore(dbQueue: queue, memoryAuthorityWriter: writer),
            writer: writer
        )
    }

    private func count(_ queue: DatabaseQueue, _ sql: String) async throws -> Int {
        try await queue.read { db in
            try Int.fetchOne(db, sql: sql) ?? -1
        }
    }

    private func makeScope() -> MemoryScope {
        MemoryScope(userID: "user-1", projectID: "project-1")
    }

    private func makeCitation() -> MemoryCitation {
        MemoryCitation(
            id: "cit-1",
            threadLogicalID: "thread-1",
            messageID: "msg-1",
            role: "user",
            authoredAt: Date(timeIntervalSince1970: 1_749_999_000),
            contentHash: ControlPlaneStore.sha256Hex("source text"),
            occurrence: 0,
            crossDeviceHMAC: "hmac-cross-device-1",
            citationState: .live
        )
    }

    private func makeAddRequest(scope: MemoryScope? = nil, reviewStatus: MemoryReviewStatus = .quarantined) -> MemoryAddRequest {
        MemoryAddRequest(
            text: "User prefers Swift over Python for new services.",
            kind: .fact,
            scope: scope ?? makeScope(),
            confidence: 0.9,
            citations: [makeCitation()],
            reviewStatus: reviewStatus
        )
    }

    // MARK: - Remember mapping

    func testAddFinalizesWriteSetAndCommitsOneRemember() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let memory = try await fixture.recording.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "mem-1",
            now: now
        )

        XCTAssertEqual(fixture.writer.requests.count, 1)
        let request = try XCTUnwrap(fixture.writer.requests.first)
        XCTAssertEqual(request.actor, "app")
        XCTAssertEqual(request.operations.count, 1)
        guard case .remember(let remember) = request.operations.first else {
            XCTFail("add must commit a remember operation"); return
        }

        // Snapshot: sealed reference, exact body hash, chat kind.
        XCTAssertEqual(remember.snapshot.id, "memory-mem-1")
        XCTAssertEqual(remember.snapshot.memoryID, "mem-1")
        XCTAssertEqual(remember.snapshot.bodyRef, "memory_body_snapshots:memory-mem-1")
        XCTAssertEqual(remember.snapshot.bodyHash, ControlPlaneStore.sha256Hex("User prefers Swift over Python for new services."))
        XCTAssertEqual(remember.snapshot.sourceKind, "chat")
        XCTAssertEqual(remember.snapshot.createdAtText, ControlPlaneStore.memoryAuthorityTimestampText(now))
        XCTAssertFalse(remember.snapshot.snapshotJSON.isEmpty)

        // Memory row: legacy v50 spellings, scope-carried ownership.
        XCTAssertEqual(remember.memory.id, "mem-1")
        XCTAssertEqual(remember.memory.projectID, "project-1")
        XCTAssertEqual(remember.memory.kind, "fact")
        XCTAssertEqual(remember.memory.scopeText, "chat")
        XCTAssertEqual(remember.memory.confidence, 0.9)
        XCTAssertEqual(remember.memory.bodyRef, "memory_body_snapshots:memory-mem-1")
        XCTAssertEqual(remember.memory.bodyRedacted, "memory_body_snapshots:memory-mem-1")
        XCTAssertEqual(remember.memory.sourceKind, "chat")
        XCTAssertEqual(remember.memory.reviewStatus, "quarantined")
        XCTAssertEqual(remember.memory.userID, "user-1")
        XCTAssertNil(remember.memory.validToText)
        XCTAssertNil(remember.memory.supersededBy)
        XCTAssertNil(remember.merge, "no duplicates on a fresh database")

        // Provenance: citation carried verbatim, HMAC untouched.
        XCTAssertEqual(remember.provenance.count, 1)
        let provenance = try XCTUnwrap(remember.provenance.first)
        XCTAssertEqual(provenance.id, "mem-1#cit-1")
        XCTAssertEqual(provenance.memoryID, "mem-1")
        XCTAssertEqual(provenance.sourceKind, "chat_message")
        XCTAssertEqual(provenance.threadLogicalID, "thread-1")
        XCTAssertEqual(provenance.messageID, "msg-1")
        XCTAssertEqual(provenance.role, "user")
        XCTAssertEqual(provenance.xdeviceHMAC, "hmac-cross-device-1")
        XCTAssertEqual(provenance.citationState, "live")

        // Audit: the add event with sorted labels and the ISO stamp.
        XCTAssertEqual(remember.audits.count, 1)
        let audit = try XCTUnwrap(remember.audits.first)
        XCTAssertEqual(audit.action, "memory.add")
        XCTAssertEqual(audit.projectID, "project-1")
        XCTAssertEqual(audit.subjectID, "mem-1")
        XCTAssertEqual(audit.labels, [
            "body_ref:memory_body_snapshots:memory-mem-1",
            "memory_id:mem-1",
            "review_status:quarantined",
            "source_kind:chat"
        ].sorted())
        XCTAssertEqual(audit.timestampText, ControlPlaneStore.iso8601String(now))

        // The returned memory echoes the finalized write, not the wire.
        XCTAssertEqual(memory.id, "mem-1")
        XCTAssertEqual(memory.bodyRedacted, "memory_body_snapshots:memory-mem-1")
        XCTAssertNil(memory.supersededBy)

        // The commit crossed the seam; nothing landed locally.
        let hoisted0 = try await count(fixture.queue, "SELECT COUNT(*) FROM agent_memories")
        XCTAssertEqual(hoisted0, 0)
        let hoisted1 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_body_snapshots")
        XCTAssertEqual(hoisted1, 0)
        let hoisted2 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_provenance")
        XCTAssertEqual(hoisted2, 0)
        let hoisted3 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_audit")
        XCTAssertEqual(hoisted3, 0)
    }

    func testAddPlansMergeForDuplicateBody() async throws {
        let fixture = try makeFixture()
        let seedNow = Date(timeIntervalSince1970: 1_749_990_000)
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        // The seed wins the election: approved outranks quarantined at any
        // confidence, so the new memory lands superseded by it.
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            MemoryAddRequest(
                text: "User prefers Swift over Python for new services.",
                kind: .fact,
                scope: makeScope(),
                confidence: 0.5,
                citations: [],
                reviewStatus: .approved
            ),
            id: "seed-1",
            now: seedNow
        )

        let memory = try await fixture.recording.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "new-1",
            now: now
        )

        XCTAssertEqual(fixture.writer.requests.count, 1)
        guard case .remember(let remember) = fixture.writer.requests.first?.operations.first else {
            XCTFail("add must commit a remember operation"); return
        }
        XCTAssertEqual(remember.memory.supersededBy, "seed-1")
        XCTAssertEqual(remember.memory.validToText, ControlPlaneStore.memoryAuthorityTimestampText(now))
        let merge = try XCTUnwrap(remember.merge, "an exact-hash duplicate must plan a merge")
        XCTAssertEqual(merge.winnerID, "seed-1")
        XCTAssertEqual(merge.loserIDs, ["new-1"])
        XCTAssertEqual(merge.supersedeAudits.count, 1, "one supersede audit per loser")
        XCTAssertEqual(merge.supersedeAudits.first?.action, "memory.supersede")
        XCTAssertEqual(merge.supersedeAudits.first?.subjectID, "new-1")
        XCTAssertEqual(merge.mergeAudit.action, "memory.merge")
        XCTAssertEqual(merge.mergeAudit.subjectID, "seed-1")
        XCTAssertEqual(memory.supersededBy, "seed-1")
    }

    // MARK: - Update + reseal

    func testUpdateResealsWithCompareAndSwapPrecondition() async throws {
        let fixture = try makeFixture()
        let seedNow = Date(timeIntervalSince1970: 1_749_990_000)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await fixture.local.addChatMemoryAuthorityRecord(makeAddRequest(), id: "mem-1", now: seedNow)

        let updated = try await fixture.recording.updateChatMemoryAuthorityRecord(
            id: "mem-1",
            patch: MemoryPatch(text: "User prefers Swift for new services.", kind: .preference, confidence: 0.95),
            now: now
        )

        XCTAssertTrue(updated)
        XCTAssertEqual(fixture.writer.requests.count, 1)
        guard case .updateBody(let update) = fixture.writer.requests.first?.operations.first else {
            XCTFail("update must commit an updateBody operation"); return
        }
        XCTAssertEqual(update.memoryID, "mem-1")
        XCTAssertEqual(update.sourceKind, "chat")
        XCTAssertEqual(update.kind, "preference")
        XCTAssertEqual(update.confidence, 0.95)
        XCTAssertEqual(update.updatedAtText, ControlPlaneStore.memoryAuthorityTimestampText(now))
        // The precondition names the stored seal: a moved row refuses.
        let reseal = try XCTUnwrap(update.reseal, "a body patch must reseal")
        XCTAssertEqual(reseal.expectedBodyHash, ControlPlaneStore.sha256Hex("User prefers Swift over Python for new services."))
        XCTAssertEqual(reseal.expectedUpdatedAtText, ControlPlaneStore.memoryAuthorityTimestampText(seedNow))
        XCTAssertEqual(reseal.snapshot.bodyHash, ControlPlaneStore.sha256Hex("User prefers Swift for new services."))
        XCTAssertEqual(reseal.snapshot.updatedAtText, ControlPlaneStore.memoryAuthorityTimestampText(now))
        XCTAssertEqual(update.audit.action, "memory.update")

        // The local seal is untouched — the daemon owns the reseal.
        let storedHash = try await fixture.queue.read { db in
            try String.fetchOne(db, sql: "SELECT body_hash FROM memory_body_snapshots WHERE memory_id = ?", arguments: ["mem-1"])
        }
        XCTAssertEqual(storedHash, ControlPlaneStore.sha256Hex("User prefers Swift over Python for new services."))
    }

    func testUpdateWithoutBodyPatchSkipsReseal() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )

        let updated = try await fixture.recording.updateChatMemoryAuthorityRecord(
            id: "mem-1",
            patch: MemoryPatch(confidence: 0.5),
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        XCTAssertTrue(updated)
        guard case .updateBody(let update) = fixture.writer.requests.first?.operations.first else {
            XCTFail("update must commit an updateBody operation"); return
        }
        XCTAssertNil(update.reseal, "a confidence-only patch seals nothing")
        XCTAssertNil(update.kind)
        XCTAssertEqual(update.confidence, 0.5)
    }

    func testUpdateRetriesOnceOnConflictThenSucceeds() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )
        fixture.writer.scriptErrors([OpenBurnBarDaemonManagerError.rpcConflict("seal moved")])

        let updated = try await fixture.recording.updateChatMemoryAuthorityRecord(
            id: "mem-1",
            patch: MemoryPatch(text: "User prefers Swift for new services."),
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        XCTAssertTrue(updated, "one conflicting reseal retries and converges")
        XCTAssertEqual(fixture.writer.requests.count, 2)
        // Both attempts carry the same precondition: the recording writer
        // applied nothing, so the re-read seal is the seeded one.
        let preconditions = fixture.writer.requests.compactMap { request -> String? in
            guard case .updateBody(let update) = request.operations.first else { return nil }
            return update.reseal?.expectedBodyHash
        }
        XCTAssertEqual(preconditions.count, 2)
        XCTAssertEqual(
            preconditions.first,
            ControlPlaneStore.sha256Hex("User prefers Swift over Python for new services.")
        )
        XCTAssertEqual(preconditions.first, preconditions.last)
    }

    func testUpdateExhaustsRetriesAfterThreeConflicts() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )
        fixture.writer.scriptErrors([
            OpenBurnBarDaemonManagerError.rpcConflict("1"),
            OpenBurnBarDaemonManagerError.rpcConflict("2"),
            OpenBurnBarDaemonManagerError.rpcConflict("3")
        ])

        do {
            _ = try await fixture.recording.updateChatMemoryAuthorityRecord(
                id: "mem-1",
                patch: MemoryPatch(text: "User prefers Swift for new services."),
                now: Date(timeIntervalSince1970: 1_750_000_000)
            )
            XCTFail("three conflicting reseals must surface, not loop")
        } catch ControlPlaneStore.ChatMemoryAuthorityError.conflictRetryExhausted {
        } catch {
            XCTFail("expected conflictRetryExhausted, got \(error)")
        }
        XCTAssertEqual(fixture.writer.requests.count, 3, "the loop is bounded at three attempts")
    }

    func testUpdateMissingRecordTouchesNoRPC() async throws {
        let fixture = try makeFixture()

        let updated = try await fixture.recording.updateChatMemoryAuthorityRecord(
            id: "missing",
            patch: MemoryPatch(text: "No such memory."),
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        XCTAssertFalse(updated)
        XCTAssertTrue(fixture.writer.requests.isEmpty, "a missing record returns before any commit")
    }

    // MARK: - Review

    func testRejectApprovedSeedsTombstone() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(reviewStatus: .approved),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )

        let changed = try await fixture.recording.setChatMemoryReviewStatus(id: "mem-1", status: .rejected, now: now)

        XCTAssertTrue(changed)
        guard case .setReviewStatus(let review) = fixture.writer.requests.first?.operations.first else {
            XCTFail("review must commit a setReviewStatus operation"); return
        }
        XCTAssertEqual(review.memoryID, "mem-1")
        XCTAssertEqual(review.sourceKind, "chat")
        XCTAssertEqual(review.reviewStatus, "rejected")
        // The legacy ISO quirk in `updated_at` rides the wire verbatim.
        XCTAssertEqual(review.updatedAtText, ControlPlaneStore.iso8601String(now))
        let tombstone = try XCTUnwrap(review.factTombstone, "leaving approved with an owner must seed a tombstone")
        XCTAssertEqual(tombstone.memoryID, "mem-1")
        XCTAssertEqual(tombstone.userID, "user-1")
        XCTAssertEqual(tombstone.reason, "review_status_rejected")
        XCTAssertTrue(tombstone.overwriteOnConflict)
        XCTAssertTrue(tombstone.refreshSourceRefsOnConflict)
        XCTAssertFalse(review.markFactTombstoneReplicated)
        XCTAssertEqual(review.audit.action, "memory.reject")
        XCTAssertEqual(review.audit.labels, ["memory_id:mem-1", "review_status:rejected", "source_kind:chat"].sorted())

        // The local verdict is untouched — the daemon owns the update.
        let stored = try await fixture.queue.read { db in
            try String.fetchOne(db, sql: "SELECT review_status FROM agent_memories WHERE id = ?", arguments: ["mem-1"])
        }
        XCTAssertEqual(stored, "approved")
    }

    func testApproveMarksTombstoneReplicated() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )

        let changed = try await fixture.recording.setChatMemoryReviewStatus(id: "mem-1", status: .approved, now: now)

        XCTAssertTrue(changed)
        guard case .setReviewStatus(let review) = fixture.writer.requests.first?.operations.first else {
            XCTFail("review must commit a setReviewStatus operation"); return
        }
        XCTAssertEqual(review.reviewStatus, "approved")
        XCTAssertNil(review.factTombstone, "approving seeds no tombstone")
        XCTAssertTrue(review.markFactTombstoneReplicated)
        XCTAssertEqual(review.replicatedAtText, ControlPlaneStore.memoryAuthorityTimestampText(now))
        XCTAssertEqual(review.audit.action, "memory.approve")
    }

    // MARK: - Delete

    func testDeleteApprovedChatCommitsCascadeWithTombstone() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(reviewStatus: .approved),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )

        let deleted = try await fixture.recording.deleteChatMemoryAuthorityRecord(id: "mem-1", now: now)

        XCTAssertTrue(deleted)
        guard case .deleteMemory(let delete) = fixture.writer.requests.first?.operations.first else {
            XCTFail("delete must commit a deleteMemory operation"); return
        }
        XCTAssertEqual(delete.memoryID, "mem-1")
        XCTAssertEqual(delete.sourceKind, "chat")
        XCTAssertNil(delete.agent, "a chat delete carries no agent half")
        let tombstone = try XCTUnwrap(delete.factTombstone, "deleting an approved owned row must tombstone the cloud copy")
        XCTAssertEqual(tombstone.reason, "user_delete")
        XCTAssertNil(delete.blankedBodyUpdatedAtText, "blanking is the agent lane's")
        XCTAssertEqual(delete.audit.action, "memory.delete")

        // Every local byte stays: the cascade is the daemon's.
        let hoisted4 = try await count(fixture.queue, "SELECT COUNT(*) FROM agent_memories")
        XCTAssertEqual(hoisted4, 1)
        let hoisted5 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_body_snapshots")
        XCTAssertEqual(hoisted5, 1)
        let hoisted6 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_provenance")
        XCTAssertEqual(hoisted6, 1)
    }

    // MARK: - Source tombstones + reconcile

    func testRecordSourceTombstoneCommitsAndReturnsDeterministicID() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let first = try await fixture.recording.recordMemorySourceTombstone(
            userID: "user-1",
            threadLogicalID: "thread-1",
            messageID: nil,
            contentHash: nil,
            reason: "user_delete",
            now: now
        )
        let second = try await fixture.recording.recordMemorySourceTombstone(
            userID: "user-1",
            threadLogicalID: "thread-1",
            messageID: nil,
            contentHash: nil,
            reason: "user_delete",
            now: now
        )

        XCTAssertEqual(first, second, "the tombstone id is content-derived, not random")
        XCTAssertEqual(fixture.writer.requests.count, 2)
        guard case .recordSourceTombstone(let record) = fixture.writer.requests.first?.operations.first else {
            XCTFail("record must commit a recordSourceTombstone operation"); return
        }
        XCTAssertEqual(record.tombstone.id, first)
        XCTAssertEqual(record.tombstone.threadLogicalID, "thread-1")
        XCTAssertEqual(record.tombstone.reason, "user_delete")
        let hoisted7 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_source_tombstones")
        XCTAssertEqual(hoisted7, 0)
    }

    func testReconcileSuppressesTombstonedSources() async throws {
        let fixture = try makeFixture()
        // The memory cites thread-1; the tombstone covers all of thread-1.
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )
        _ = try await fixture.local.recordMemorySourceTombstone(
            userID: "user-1",
            threadLogicalID: "thread-1",
            messageID: nil,
            contentHash: nil,
            reason: "user_delete",
            now: Date(timeIntervalSince1970: 1_749_991_000)
        )
        fixture.writer.stubAffectedRows = 1
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        let suppressed = try await fixture.recording.reconcileMemorySourceTombstones(now: now)

        XCTAssertEqual(suppressed, 1, "the flow returns the daemon's swept count")
        guard case .reconcileSuppressions(let reconcile) = fixture.writer.requests.first?.operations.first else {
            XCTFail("reconcile must commit a reconcileSuppressions operation"); return
        }
        XCTAssertEqual(reconcile.matches.count, 1)
        XCTAssertEqual(reconcile.matches.first?.memoryID, "mem-1")
        XCTAssertEqual(reconcile.matches.first?.projectID, "project-1")
        XCTAssertEqual(reconcile.matches.first?.labels, [
            "memory_id:mem-1",
            "reason:source_tombstone",
            "source_kind:chat"
        ].sorted())
        XCTAssertEqual(reconcile.validToText, ControlPlaneStore.memoryAuthorityTimestampText(now))
        XCTAssertEqual(reconcile.timestampText, ControlPlaneStore.iso8601String(now))

        // The local row is still live — the sweep is the daemon's.
        let validTo = try await fixture.queue.read { db in
            try String.fetchOne(db, sql: "SELECT valid_to FROM agent_memories WHERE id = ?", arguments: ["mem-1"])
        }
        XCTAssertNil(validTo)
    }

    func testReconcileWithNoMatchesIssuesNoRPC() async throws {
        let fixture = try makeFixture()

        let suppressed = try await fixture.recording.reconcileMemorySourceTombstones(
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        XCTAssertEqual(suppressed, 0)
        XCTAssertTrue(fixture.writer.requests.isEmpty, "no matches means no commit")
    }

    // MARK: - Claim + enqueue + marks

    func testClaimCommitsAndReturnsDaemonCount() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.local.addMemoryAuthorityRecord(
            makeAddRequest(scope: MemoryScope()),
            id: "agent-1",
            sourceKind: .agent,
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )
        fixture.writer.stubAffectedRows = 2

        let claimed = try await fixture.recording.claimUnownedAgentMemories(userID: "user-9")

        XCTAssertEqual(claimed, 2, "the flow returns the daemon's claimed count")
        guard case .claimUnowned(let claim) = fixture.writer.requests.first?.operations.first else {
            XCTFail("claim must commit a claimUnowned operation"); return
        }
        XCTAssertEqual(claim.userID, "user-9")
        XCTAssertEqual(claim.sourceKind, "agent")
    }

    func testEnqueueCommitsTombstonesForForgottenAgentMemories() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.local.addMemoryAuthorityRecord(
            makeAddRequest(scope: makeScope(), reviewStatus: .forgotten),
            id: "agent-1",
            sourceKind: .agent,
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )
        fixture.writer.stubAffectedRows = 1

        let enqueued = try await fixture.recording.enqueueTombstonesForUnsyncableAgentMemories(
            userID: "user-1",
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        XCTAssertEqual(enqueued, 1)
        guard case .enqueueFactTombstones(let enqueue) = fixture.writer.requests.first?.operations.first else {
            XCTFail("enqueue must commit an enqueueFactTombstones operation"); return
        }
        XCTAssertEqual(enqueue.tombstones.count, 1)
        let tombstone = try XCTUnwrap(enqueue.tombstones.first)
        XCTAssertEqual(
            tombstone.id,
            ControlPlaneStore.agentMemoryFactTombstoneID(memoryID: "agent-1", engineMemoryID: nil)
        )
        XCTAssertEqual(tombstone.userID, "user-1")
        XCTAssertEqual(tombstone.reason, "user_delete")
        XCTAssertFalse(tombstone.overwriteOnConflict, "enqueue never overwrites a drained tombstone")
        XCTAssertFalse(tombstone.refreshSourceRefsOnConflict)
    }

    func testEnqueueWithNoCandidatesIssuesNoRPC() async throws {
        let fixture = try makeFixture()

        let enqueued = try await fixture.recording.enqueueTombstonesForUnsyncableAgentMemories(
            userID: "user-1",
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        XCTAssertEqual(enqueued, 0)
        XCTAssertTrue(fixture.writer.requests.isEmpty, "no candidates means no commit")
    }

    func testMarkReplicatedCommitsBothTables() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        try await fixture.recording.markMemoryFactTombstoneReplicated(id: "tomb-1", now: now)
        try await fixture.recording.markMemorySourceTombstoneReplicated(id: "source-1", now: now)

        XCTAssertEqual(fixture.writer.requests.count, 2)
        guard case .markTombstoneReplicated(let fact) = fixture.writer.requests.first?.operations.first,
              case .markTombstoneReplicated(let source) = fixture.writer.requests.last?.operations.first else {
            XCTFail("marks must commit markTombstoneReplicated operations"); return
        }
        XCTAssertEqual(fact.table, .fact)
        XCTAssertEqual(fact.id, "tomb-1")
        XCTAssertEqual(fact.replicatedAtText, ControlPlaneStore.memoryAuthorityTimestampText(now))
        XCTAssertEqual(source.table, .source)
        XCTAssertEqual(source.id, "source-1")
    }

    // MARK: - Audit appends

    func testAppendAuditSortsLabelsAndCommits() async throws {
        let fixture = try makeFixture()
        let now = Date(timeIntervalSince1970: 1_750_000_000)

        try await fixture.recording.appendMemoryAuditEvent(
            action: "memory.candidate_dropped",
            projectID: "project-1",
            subjectID: "mem-1",
            labels: ["memory_id": "mem-1", "zeta": "1", "source_kind": "chat", "alpha": "2"],
            now: now
        )

        guard case .appendAudit(let event) = fixture.writer.requests.first?.operations.first else {
            XCTFail("append must commit an appendAudit operation"); return
        }
        XCTAssertEqual(event.action, "memory.candidate_dropped")
        XCTAssertEqual(event.labels, ["alpha:2", "memory_id:mem-1", "source_kind:chat", "zeta:1"])
        XCTAssertEqual(event.labelsJSON, try ControlPlaneStore.auditLabelsJSON(event.labels))
        XCTAssertEqual(event.timestampText, ControlPlaneStore.iso8601String(now))
        let hoisted8 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_audit")
        XCTAssertEqual(hoisted8, 0)
    }

    func testCandidateDroppedCarriesStableLabels() async throws {
        let fixture = try makeFixture()

        try await fixture.recording.appendMemoryCandidateDroppedAuditEvent(
            projectID: "project-1",
            memoryID: "mem-1",
            sourceKind: "chat",
            findingLabels: "openai-api-key",
            candidateIndex: 2,
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )

        guard case .appendAudit(let event) = fixture.writer.requests.first?.operations.first else {
            XCTFail("append must commit an appendAudit operation"); return
        }
        XCTAssertEqual(event.labels, [
            "candidate_index:2",
            "finding_labels:openai-api-key",
            "memory_id:mem-1",
            "source_kind:chat"
        ])
    }

    // MARK: - Fail-closed

    func testThrowingWriterFailsClosed() async throws {
        let queue = try DatabaseQueue()
        try OpenBurnBarDatabase(databaseQueue: queue).runMigrationsSafely()
        let store = ControlPlaneStore(dbQueue: queue, memoryAuthorityWriter: ThrowingMemoryAuthorityWriter())

        do {
            _ = try await store.addChatMemoryAuthorityRecord(
                makeAddRequest(),
                id: "mem-1",
                now: Date(timeIntervalSince1970: 1_750_000_000)
            )
            XCTFail("an unreachable daemon must throw, never silently succeed")
        } catch is ThrowingMemoryAuthorityWriter.Boom {
        }
        let hoisted9 = try await count(queue, "SELECT COUNT(*) FROM agent_memories")
        XCTAssertEqual(hoisted9, 0)
        let hoisted10 = try await count(queue, "SELECT COUNT(*) FROM memory_body_snapshots")
        XCTAssertEqual(hoisted10, 0)
        let hoisted11 = try await count(queue, "SELECT COUNT(*) FROM memory_provenance")
        XCTAssertEqual(hoisted11, 0)
        let hoisted12 = try await count(queue, "SELECT COUNT(*) FROM memory_audit")
        XCTAssertEqual(hoisted12, 0)
    }

    func testResponseMutationMismatchThrows() async throws {
        let fixture = try makeFixture()
        fixture.writer.stubMutationID = "someone-elses-mutation"

        do {
            _ = try await fixture.recording.addChatMemoryAuthorityRecord(
                makeAddRequest(),
                id: "mem-1",
                now: Date(timeIntervalSince1970: 1_750_000_000)
            )
            XCTFail("a shape-mismatched response must throw, never silently succeed")
        } catch ControlPlaneStore.ChatMemoryAuthorityError.authorityResultMismatch {
        } catch {
            XCTFail("expected authorityResultMismatch, got \(error)")
        }
    }

    func testResponseCountMismatchThrows() async throws {
        let fixture = try makeFixture()
        fixture.writer.stubResultCount = 0

        do {
            _ = try await fixture.recording.addChatMemoryAuthorityRecord(
                makeAddRequest(),
                id: "mem-1",
                now: Date(timeIntervalSince1970: 1_750_000_000)
            )
            XCTFail("a short response must throw, never read as a silent partial apply")
        } catch ControlPlaneStore.ChatMemoryAuthorityError.authorityResultMismatch {
        } catch {
            XCTFail("expected authorityResultMismatch, got \(error)")
        }
    }

    // MARK: - Local double parity

    func testLocalDoubleRoundTripsLikeLegacyPath() async throws {
        let fixture = try makeFixture()
        let seedNow = Date(timeIntervalSince1970: 1_749_990_000)

        _ = try await fixture.local.addChatMemoryAuthorityRecord(makeAddRequest(), id: "mem-1", now: seedNow)
        let fetched = try await fixture.local.fetchChatMemoryAuthorityRecord(id: "mem-1")
        XCTAssertEqual(fetched?.id, "mem-1")
        XCTAssertEqual(fetched?.reviewStatus, .quarantined)
        XCTAssertEqual(fetched?.citations.count, 1)
        XCTAssertEqual(fetched?.citations.first?.threadLogicalID, "thread-1")

        _ = try await fixture.local.updateChatMemoryAuthorityRecord(
            id: "mem-1",
            patch: MemoryPatch(confidence: 0.5),
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let hoisted13 = try await fixture.local.fetchChatMemoryAuthorityRecord(id: "mem-1")?.confidence
        XCTAssertEqual(hoisted13, 0.5)

        _ = try await fixture.local.setChatMemoryReviewStatus(
            id: "mem-1",
            status: .approved,
            now: Date(timeIntervalSince1970: 1_750_000_100)
        )
        let hoisted14 = try await fixture.local.fetchChatMemoryAuthorityRecord(id: "mem-1")?.reviewStatus
        XCTAssertEqual(hoisted14, .approved)

        _ = try await fixture.local.deleteChatMemoryAuthorityRecord(
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_750_000_200)
        )
        let hoisted15 = try await fixture.local.fetchChatMemoryAuthorityRecord(id: "mem-1")
        XCTAssertNil(hoisted15)
        let hoisted16 = try await count(fixture.queue, "SELECT COUNT(*) FROM agent_memories")
        XCTAssertEqual(hoisted16, 0)
        let hoisted17 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_body_snapshots")
        XCTAssertEqual(hoisted17, 0)
        let hoisted18 = try await count(fixture.queue, "SELECT COUNT(*) FROM memory_provenance")
        XCTAssertEqual(hoisted18, 0)
    }

    func testLocalDoubleChainVerifiesThroughExportVerifier() async throws {
        let fixture = try makeFixture()
        _ = try await fixture.local.addChatMemoryAuthorityRecord(
            makeAddRequest(),
            id: "mem-1",
            now: Date(timeIntervalSince1970: 1_749_990_000)
        )
        _ = try await fixture.local.updateChatMemoryAuthorityRecord(
            id: "mem-1",
            patch: MemoryPatch(text: "User prefers Swift for new services."),
            now: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try await fixture.local.appendMemoryAuditEvent(
            action: "memory.candidate_dropped",
            projectID: "project-1",
            subjectID: "mem-1",
            labels: ["memory_id": "mem-1", "source_kind": "chat"],
            now: Date(timeIntervalSince1970: 1_750_000_100)
        )

        // The double appends through the shared v2 payload, so the real
        // export verifier — not a reimplementation — must walk it clean.
        let rows = try await fixture.queue.read { db in
            try Row.fetchAll(db, sql: "SELECT seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash FROM memory_audit ORDER BY seq ASC")
        }
        XCTAssertEqual(rows.count, 3)
        let exportRows = try rows.map { row -> MemoryExportAuditRow in
            let labelsJSON: String = row["labels_json"]
            let labels = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(labelsJSON.utf8)) as? [String])
            return MemoryExportAuditRow(
                seq: row["seq"],
                ts: row["ts"],
                actor: row["actor"],
                action: row["action"],
                domain: row["domain"],
                projectID: row["project_id"],
                subjectID: row["subject_id"],
                labels: labels,
                prevHash: row["prev_hash"],
                hash: row["hash"]
            )
        }
        let verification = MemoryExportAuditChain.verify(rows: exportRows)
        XCTAssertEqual(verification.verifiedThroughSeq, 3)
        XCTAssertEqual(verification.brokenAt, [])
        XCTAssertEqual(verification.forks, [])
        XCTAssertFalse(verification.seqDivergence)
    }
}
