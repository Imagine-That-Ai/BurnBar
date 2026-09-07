// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportClassifierTests — the §3.1 table, row by row, against BurnBar
// shapes built by BurnBar's own migrator.
//
// The property every one of these guards: **nothing arrives `approved` that a
// human cannot be proved to have approved, bound to the body that travels.**

import GRDB
import XCTest
@testable import OpenBurnBarMemoryExport

final class MemoryExportClassifierTests: XCTestCase {

    private let bodyTime = "2026-01-01T00:00:00.000Z"
    private let verdictTime = "2026-01-02T00:00:00.000Z"

    // MARK: - Row 2: proven human approve

    func test_provenHumanApprove_keepsApprovedAndNamesItsAuditSeq() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "A1",
                body: "Alberto prefers fewer, fatter PRs.",
                reviewStatus: "approved",
                createdAt: bodyTime,
                updatedAt: verdictTime
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.approve",
                projectID: "chat:user-1",
                subjectID: "A1",
                labels: ["memory_id:A1", "review_status:approved", "source_kind:chat"],
                ts: verdictTime
            )
        }
        let result = try classify(queue, id: "A1")
        XCTAssertEqual(result.reviewStatus, .approved)
        XCTAssertEqual(result.originKind, .human)
        XCTAssertEqual(result.importOriginDetail, .humanVerdict)
        XCTAssertEqual(result.bodyVerdictBinding, .bound)
        // M-20: a human exit must NAME the audit row section 09 has to carry.
        XCTAssertNotNil(result.verdictAuditSeq)
    }

    // MARK: - Row 8: approve, then the body was rewritten under it

    func test_bodyMutatedAfterVerdict_quarantinesAndSaysWhy() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "A2",
                body: "Rewritten after the human read it.",
                reviewStatus: "approved",
                createdAt: bodyTime,
                updatedAt: "2026-01-03T00:00:00.000Z",
                // The snapshot is NEWER than the verdict: the update path
                // rewrites a sealed body in place and never touches
                // review_status, which is exactly the M-01 hole.
                bodyUpdatedAt: "2026-01-03T00:00:00.000Z"
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.approve",
                projectID: "chat:user-1",
                subjectID: "A2",
                labels: ["memory_id:A2", "review_status:approved", "source_kind:chat"],
                ts: verdictTime
            )
        }
        let result = try classify(queue, id: "A2")
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.importOriginDetail, .approvedBodyMutatedAfterVerdict)
        XCTAssertEqual(result.bodyVerdictBinding, .bodyMutatedAfterVerdict)
        XCTAssertTrue(result.findings.contains(.approvedBodyMutatedAfterVerdict))
    }

    // MARK: - Row 4: a daemon `code` row approved by default

    func test_daemonCodeRowApprovedByDefault_quarantines() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertDaemonMemory(
                db,
                id: "mem_" + String(repeating: "a", count: 32),
                body: "The Linux CI lane is the only gate that catches cfg(linux) breaks.",
                projectID: "proj-1"
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.remember",
                actor: "daemon",
                projectID: "proj-1",
                subjectID: "mem_" + String(repeating: "a", count: 32),
                labels: ["review_status:approved"],
                ts: bodyTime
            )
        }
        let result = try classify(queue, id: "mem_" + String(repeating: "a", count: 32))
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.importOriginDetail, .daemonDefault)
        XCTAssertEqual(result.originKind, .importOrigin)
    }

    // MARK: - Row 6: label-only approval with no verdict row

    func test_labelOnlyApproval_isTheV51Backfill() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "A3",
                body: "Approved by a migration, not by a person.",
                reviewStatus: "approved"
            )
            // A labelled row that is not a verdict verb: reading the label alone
            // would promote this, which is what the six conjuncts prevent.
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.add",
                projectID: "chat:user-1",
                subjectID: "A3",
                labels: ["review_status:approved"],
                ts: bodyTime
            )
        }
        let result = try classify(queue, id: "A3")
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.importOriginDetail, .v51Backfill)
    }

    // MARK: - Row 7: a verdict inside a broken span

    func test_verdictOnBrokenChain_isNotProof() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "A4",
                body: "Approved inside an unverifiable span.",
                reviewStatus: "approved",
                updatedAt: verdictTime
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.add",
                projectID: "chat:user-1",
                subjectID: "A4",
                labels: ["memory_id:A4"],
                ts: bodyTime
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.approve",
                projectID: "chat:user-1",
                subjectID: "A4",
                labels: ["memory_id:A4", "review_status:approved", "source_kind:chat"],
                ts: verdictTime
            )
            try MemoryExportFixtureStore.breakChain(db, atSeq: 1)
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        let chain = MemoryExportAuditChain.verify(rows: snapshot.auditRows)
        XCTAssertEqual(chain.brokenAt, [1], "the walk must name the corrupted link")
        XCTAssertEqual(chain.verifiedThroughSeq, 0, "nothing after a break is contiguously verified")

        let result = try classify(queue, id: "A4")
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
        XCTAssertTrue(result.findings.contains(.verdictOnBrokenChain))
    }

    // MARK: - Row 9: a forged `actor: "app"`

    func test_forgedAppActorOnDaemonRow_isRefused() throws {
        let id = "mem_" + String(repeating: "b", count: 32)
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertDaemonMemory(
                db,
                id: id,
                body: "A code row wearing an app verdict.",
                projectID: "proj-2",
                reviewStatus: "approved"
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.approve",
                actor: "app",
                projectID: "proj-2",
                subjectID: id,
                labels: ["review_status:approved"],
                ts: verdictTime
            )
        }
        let result = try classify(queue, id: id)
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertTrue(result.findings.contains(.forgedHumanVerdictRefused))
    }

    // MARK: - Row 3: `memory.reject` carrying `review_status:quarantined`

    func test_sendBackToReview_readsTheLabelNotTheVerb() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "A5",
                body: "Sent back to review, not rejected.",
                reviewStatus: "quarantined",
                updatedAt: verdictTime
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.reject",
                projectID: "chat:user-1",
                subjectID: "A5",
                labels: ["memory_id:A5", "review_status:quarantined", "source_kind:chat"],
                ts: verdictTime
            )
        }
        let result = try classify(queue, id: "A5")
        // Reading the VERB would make this `rejected` + human origin, which §4's
        // merge then makes permanent and unrecallable.
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.originKind, .human)
    }

    // MARK: - Rows 13 and 16: absent column, absent table

    func test_absentReviewStatusColumn_quarantines() {
        var memory = row(id: "A6")
        memory.reviewStatus = nil
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(memory: memory))
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.importOriginDetail, .absentColumn)
    }

    func test_absentAuditTable_quarantinesEverything() {
        var memory = row(id: "A7")
        memory.reviewStatus = "approved"
        let result = MemoryExportClassifier.classify(
            MemoryExportClassifierInput(memory: memory, auditTableAvailable: false)
        )
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.importOriginDetail, .unknown)
    }

    // MARK: - Rows 11, 12, 14

    func test_storedRejected_isNeverRaised() {
        var memory = row(id: "A8")
        memory.reviewStatus = "rejected"
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(memory: memory))
        XCTAssertEqual(result.reviewStatus, .rejected)
        XCTAssertEqual(result.importOriginDetail, .rejectedRetainedUnproven)
    }

    func test_storedForgotten_isNotAMemoryRecord() {
        var memory = row(id: "A9")
        memory.reviewStatus = "forgotten"
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(memory: memory))
        XCTAssertTrue(result.isTombstoneOnly)
    }

    func test_unknownReviewStatusValue_quarantinesWithAFinding() {
        var memory = row(id: "A10")
        memory.reviewStatus = "pending"
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(memory: memory))
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.importOriginDetail, .unknownValue)
        XCTAssertTrue(result.findings.contains(.reviewStatusUnknownValue))
    }

    // MARK: - M-12 selection

    func test_laterRejectBeatsHigherSeqApprove() {
        var memory = row(id: "A11")
        memory.reviewStatus = "approved"
        let approve = MemoryExportAuditRow(
            seq: 100,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A11",
            labels: ["review_status:approved"]
        )
        let reject = MemoryExportAuditRow(
            // A LOWER seq with a LATER ts — the payload-seq divergence case
            // where ordering by seq alone resolves the wrong way.
            seq: 99,
            ts: "2026-01-03T00:00:00.000Z",
            actor: "app",
            action: "memory.reject",
            subjectID: "A11",
            labels: ["review_status:rejected"]
        )
        let chain = MemoryExportChainVerification(verifiedThroughSeq: 1000, rowsWalked: 2)
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [approve, reject],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: chain
        ))
        XCTAssertEqual(result.reviewStatus, .rejected)
        XCTAssertEqual(result.verdictAuditSeq, 99)
    }

    // MARK: - Helpers

    private func classify(_ queue: DatabaseQueue, id: String) throws -> MemoryExportClassification {
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        guard let memory = snapshot.memories.first(where: { $0.id == id }) else {
            throw XCTSkip("fixture row \(id) was not written")
        }
        return MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: snapshot.auditRows.filter { $0.subjectID == id },
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse(
                snapshot.bodySnapshots.first { $0.memoryID == id }?.updatedAt
            ),
            chain: MemoryExportAuditChain.verify(rows: snapshot.auditRows),
            auditTableAvailable: snapshot.auditTableAvailable
        ))
    }

    private func row(id: String) -> MemoryExportMemoryRow {
        MemoryExportMemoryRow(
            id: id,
            projectID: "chat:user-1",
            bodyRef: "memory_body_snapshots:memory-\(id)",
            validFrom: "2026-01-01T00:00:00.000Z",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z",
            userID: "user-1",
            appID: "app-1"
        )
    }
}
