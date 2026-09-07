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
        // M-20: a human exit must NAME the audit row section 09 has to carry —
        // the approve above is the fixture's only audit row, so seq 1. A bare
        // non-nil assert passed for any path that happened to set the field.
        XCTAssertEqual(result.verdictAuditSeq, 1)
    }

    // MARK: - Row 1: proven human reject

    /// The review's uncovered exit: nothing asserted `originKind` or
    /// `importOriginDetail` on it. A stored `approved` the human rejected
    /// exports `rejected` + `human`, naming the audit row section 09 carries.
    func test_provenHumanReject_isRowOne() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "R1",
                body: "Alberto killed the auto-tagging experiment.",
                reviewStatus: "approved",
                createdAt: bodyTime,
                updatedAt: verdictTime
            )
            try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.reject",
                projectID: "chat:user-1",
                subjectID: "R1",
                labels: ["memory_id:R1", "review_status:rejected", "source_kind:chat"],
                ts: verdictTime
            )
        }
        let result = try classify(queue, id: "R1")
        XCTAssertEqual(result.reviewStatus, .rejected)
        XCTAssertEqual(result.originKind, .human)
        XCTAssertEqual(result.importOriginDetail, .humanVerdict)
        XCTAssertEqual(result.verdictAuditSeq, 1)
        XCTAssertEqual(result.originalReviewStatus, "approved")
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

    // MARK: - R1: an untrustworthy SIBLING decides the regime, not the winner

    /// The review's end-to-end case, built from BurnBar's own migrator and its
    /// own chain expression.
    ///
    /// `row-leak` is stored `quarantined`. Two app verdicts name it: an
    /// `approve` at seq 2 with a LATER wall clock, and the user's `reject` at
    /// seq 5 — chain-later, and the only row whose stored hash is corrupted. The
    /// walk therefore reports `verified_through 4`, `broken [5]`.
    ///
    /// Deciding the regime over the whole candidate set while checking conjunct
    /// 5 on the WINNER ALONE exported this as `review_status: approved`,
    /// `origin_kind: human`, `import_origin_detail: human_verdict`,
    /// `verdict_audit_seq: 2` — a verdict no human gave, promoted over the human
    /// rejection that outranks it in the chain, with `chain_verified: true`
    /// stamped on the minted review event and §4's merge making it permanent.
    func test_anUntrustworthySiblingCannotPromoteAClockSkewedApprove() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(
                db,
                id: "row-leak",
                body: "The one the user threw away.",
                reviewStatus: "quarantined",
                updatedAt: "2026-01-10T00:00:00.000Z"
            )
            try MemoryExportFixtureStore.appendAudit(
                db, action: "memory.add", projectID: "chat:user-1", subjectID: "row-leak",
                labels: ["memory_id:row-leak"], ts: "2026-01-01T00:00:00.000Z"
            )
            // seq 2 — the approve, with the later wall clock.
            try MemoryExportFixtureStore.appendAudit(
                db, action: "memory.approve", projectID: "chat:user-1", subjectID: "row-leak",
                labels: ["memory_id:row-leak", "review_status:approved", "source_kind:chat"],
                ts: "2026-01-10T00:00:00.000Z"
            )
            for filler in 3...4 {
                try MemoryExportFixtureStore.appendAudit(
                    db, action: "memory.add", projectID: "chat:user-1", subjectID: "other-\(filler)",
                    labels: [], ts: "2026-01-02T00:00:00.000Z"
                )
            }
            // seq 5 — the human's rejection, chain-later and inside the break.
            try MemoryExportFixtureStore.appendAudit(
                db, action: "memory.reject", projectID: "chat:user-1", subjectID: "row-leak",
                labels: ["memory_id:row-leak", "review_status:rejected", "source_kind:chat"],
                ts: "2026-01-05T00:00:00.000Z"
            )
            try MemoryExportFixtureStore.breakChain(db, atSeq: 5)
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        let chain = MemoryExportAuditChain.verify(rows: snapshot.auditRows)
        XCTAssertEqual(chain.verifiedThroughSeq, 4)
        XCTAssertEqual(chain.brokenAt, [5])
        XCTAssertTrue(chain.isTrustworthy(seq: 2), "the approve is inside the verified span, on its own account")
        XCTAssertFalse(chain.isTrustworthy(seq: 5), "the rejection is not")

        let result = try classify(queue, id: "row-leak")
        // §3.1 row 7 to the letter: `quarantined` + `verdict_on_broken_chain`.
        // The R1 property is unchanged and is the one that matters — the
        // clock-skewed approve is NOT promoted, and nothing in an unverifiable
        // span leaves as `human` — while the row itself goes back in the review
        // queue rather than being lowered by a verdict nobody could place (F-5).
        XCTAssertEqual(result.reviewStatus, .quarantined, "an unplaceable verdict decides nothing")
        XCTAssertNotEqual(result.reviewStatus, .approved, "the clock-skewed approve is never promoted")
        XCTAssertEqual(result.originKind, .importOrigin, "no verdict in an unverifiable span is `human`")
        XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
        XCTAssertTrue(result.findings.contains(.verdictOnBrokenChain))
        XCTAssertNil(result.verdictAuditSeq, "an unproven verdict names no seq for section 09 to carry")
        XCTAssertEqual(result.originalReviewStatus, "quarantined")
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

    // MARK: - M-12 selection, which is segment-aware

    /// F-5, and the direction that corrupts truth. On an INTACT chain §3.1 case
    /// 1 orders by `seq DESC`, because seq is the oracle's own append order and
    /// inside a verified run it is exactly the fact the chain proves. Ordering
    /// by `(ts, seq)` here lets a clock skew between the app and daemon writers
    /// promote an `approve` over a later-sequenced `reject` — a verdict no human
    /// gave arriving as `approved`, `origin_kind: human`, with a
    /// `record_review_event` minted for it.
    func test_insideAnIntactSegmentAHigherSeqRejectBeatsAClockSkewedApprove() {
        var memory = row(id: "A12")
        memory.reviewStatus = "approved"
        let reject = MemoryExportAuditRow(
            seq: 100,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.reject",
            subjectID: "A12",
            labels: ["review_status:rejected"]
        )
        let approve = MemoryExportAuditRow(
            // A LOWER seq with a LATER ts: the app and daemon writers disagree
            // about the wall clock, and the chain has already ordered them.
            seq: 99,
            ts: "2026-01-03T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A12",
            labels: ["review_status:approved"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [reject, approve],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 2)
        ))
        XCTAssertEqual(result.reviewStatus, .rejected)
        XCTAssertEqual(result.verdictAuditSeq, 100)
    }

    /// The mirror, so the rule is "seq decides inside an intact run" rather than
    /// "reject always wins": the same shape with the verdicts swapped keeps the
    /// approve, and it is a real human approval.
    func test_insideAnIntactSegmentAHigherSeqApproveBeatsAClockSkewedReject() {
        var memory = row(id: "A13")
        memory.reviewStatus = "approved"
        let approve = MemoryExportAuditRow(
            seq: 100,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A13",
            labels: ["review_status:approved"]
        )
        let reject = MemoryExportAuditRow(
            seq: 99,
            ts: "2026-01-03T00:00:00.000Z",
            actor: "app",
            action: "memory.reject",
            subjectID: "A13",
            labels: ["review_status:rejected"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [approve, reject],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 2)
        ))
        XCTAssertEqual(result.reviewStatus, .approved)
        XCTAssertEqual(result.originKind, .human)
        XCTAssertEqual(result.verdictAuditSeq, 100)
    }

    /// §3.1 case 2, and the sentence that governs its OUTCOME: "Rows selected
    /// under case 2 additionally fail conjunct 5 and therefore export
    /// `quarantined` with `verdict_on_broken_chain` (row 7)". The timestamp
    /// still decides which row is selected; it never decides that the selection
    /// is proof. A `human` exit from a straddling candidate set is what R1
    /// closed, and this test asserts `origin_kind` so swapping the two verbs
    /// cannot quietly turn it into one.
    func test_acrossABrokenBoundaryTheSelectionIsNeverHuman() {
        var memory = row(id: "A14")
        memory.reviewStatus = "approved"
        let approve = MemoryExportAuditRow(
            seq: 100,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A14",
            labels: ["review_status:approved"]
        )
        let reject = MemoryExportAuditRow(
            seq: 99,
            ts: "2026-01-03T00:00:00.000Z",
            actor: "app",
            action: "memory.reject",
            subjectID: "A14",
            labels: ["review_status:rejected"]
        )
        // The approve sits above the verified span; the reject is inside it.
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [approve, reject],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 99, brokenAt: [100], rowsWalked: 2)
        ))
        XCTAssertEqual(result.reviewStatus, .quarantined, "§3.1 row 7's own word")
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
        XCTAssertNil(result.verdictAuditSeq)
    }

    /// The same shape with the two verbs swapped — the review's swap, which used
    /// to export `approved` + `human` because only `reviewStatus` and
    /// `verdictAuditSeq` were asserted above. The approve now wins the case-2
    /// order on its later timestamp and still leaves as row 7, and the sibling
    /// rejection nobody refuted keeps the row out of the approved set.
    func test_acrossABrokenBoundaryTheSwappedVerbsAreNotHumanEither() {
        var memory = row(id: "A14b")
        memory.reviewStatus = "approved"
        let reject = MemoryExportAuditRow(
            seq: 100,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.reject",
            subjectID: "A14b",
            labels: ["review_status:rejected"]
        )
        let approve = MemoryExportAuditRow(
            seq: 99,
            ts: "2026-01-03T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A14b",
            labels: ["review_status:approved"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [reject, approve],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 99, brokenAt: [100], rowsWalked: 2)
        ))
        XCTAssertNotEqual(result.reviewStatus, .approved)
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
    }

    /// And when the unverified row is the one the timestamp picks, case 2
    /// decides only WHICH finding is reported: conjunct 5 still refuses the
    /// claim, so nothing unproven is inherited (§3.1 row 7).
    func test_acrossABrokenBoundaryAnUnverifiedWinnerIsStillNotProof() {
        var memory = row(id: "A15")
        memory.reviewStatus = "approved"
        let reject = MemoryExportAuditRow(
            seq: 99,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.reject",
            subjectID: "A15",
            labels: ["review_status:rejected"]
        )
        let approve = MemoryExportAuditRow(
            seq: 100,
            ts: "2026-01-03T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A15",
            labels: ["review_status:approved"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [reject, approve],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 99, brokenAt: [100], rowsWalked: 2)
        ))
        // `quarantined`, which is what §3.1 row 7 says and all it says: neither
        // candidate can be placed, so neither decides anything. Lowering the row
        // on the sibling's label was the invented rule F-5 removed.
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
        XCTAssertTrue(result.findings.contains(.verdictOnBrokenChain))
    }

    /// R2. §3.1 compares `ts` **lexicographically** and says it "is not
    /// otherwise treated as a clock". These two stamps order one way as strings
    /// and the other way as instants: `+09:00` makes the reject the EARLIER
    /// instant and the LATER string. Parsing them made the approve the case-2
    /// winner — the unsafe direction, decided by an offset the writing row
    /// supplies.
    func test_acrossABrokenBoundaryTheTimestampIsComparedAsAString() throws {
        var memory = row(id: "A17")
        memory.reviewStatus = "approved"
        let approve = MemoryExportAuditRow(
            seq: 100,
            ts: "2026-01-01T20:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A17",
            labels: ["review_status:approved"]
        )
        let reject = MemoryExportAuditRow(
            seq: 99,
            // Later as a string, EARLIER as an instant (11:00Z on the 1st).
            ts: "2026-01-02T00:00:00.000+09:00",
            actor: "app",
            action: "memory.reject",
            subjectID: "A17",
            labels: ["review_status:rejected"]
        )
        XCTAssertLessThan(approve.ts, reject.ts, "the reject is the later STRING")
        XCTAssertGreaterThan(
            try XCTUnwrap(MemoryExportTimestamp.parse(approve.ts)),
            try XCTUnwrap(MemoryExportTimestamp.parse(reject.ts)),
            "and the later INSTANT is the approve — the divergence this pins"
        )
        let selection = try XCTUnwrap(MemoryExportClassifier.selectVerdict(
            for: memory,
            in: [approve, reject],
            chain: MemoryExportChainVerification(verifiedThroughSeq: 99, brokenAt: [100], rowsWalked: 2)
        ))
        XCTAssertEqual(selection.row.seq, 99, "the lexicographically later row wins")
        XCTAssertFalse(selection.regimeIsIntact)
    }

    /// R2, M-13. A tie on `(ts, seq)` is won by `rejected` — and which row that
    /// is comes from the `review_status:` label, never from the verb. BurnBar
    /// writes `memory.reject` for approved→quarantined too, so ranking on the
    /// verb picks the row below whose LABEL says `approved`.
    func test_aTieIsBrokenByTheLabelAndNeverByTheActionVerb() throws {
        var memory = row(id: "A18")
        memory.reviewStatus = "approved"
        let shared = "2026-01-02T00:00:00.000Z"
        let rejectVerbApprovedLabel = MemoryExportAuditRow(
            seq: 7,
            ts: shared,
            actor: "app",
            action: "memory.reject",
            subjectID: "A18",
            labels: ["review_status:approved"]
        )
        let approveVerbRejectedLabel = MemoryExportAuditRow(
            seq: 7,
            ts: shared,
            actor: "app",
            action: "memory.approve",
            subjectID: "A18",
            labels: ["review_status:rejected"]
        )
        let selection = try XCTUnwrap(MemoryExportClassifier.selectVerdict(
            for: memory,
            in: [rejectVerbApprovedLabel, approveVerbRejectedLabel],
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 2)
        ))
        XCTAssertEqual(selection.row.action, "memory.approve", "the tie went to the row LABELLED rejected")

        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [rejectVerbApprovedLabel, approveVerbRejectedLabel],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 2)
        ))
        XCTAssertEqual(result.reviewStatus, .rejected, "ranking on the verb exports `approved` here")
        XCTAssertEqual(result.originKind, .human)
    }

    /// §3.1 case 3, in both segment cases: a genuine tie resolves to the safe
    /// side, which is the only one that cannot promote text no human read.
    func test_aTieOnSeqAndTimestampIsWonByTheReject() {
        // R7 — this looped both chains under one `XCTAssertNotEqual(.approved)`
        // that quarantine also satisfies, so the second iteration proved
        // nothing about the tie rule. Each chain now asserts its own outcome.
        let chains: [(chain: MemoryExportChainVerification, broken: Bool)] = [
            (MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 2), false),
            (MemoryExportChainVerification(verifiedThroughSeq: 0, brokenAt: [7], rowsWalked: 2), true)
        ]
        for (chain, broken) in chains {
            var memory = row(id: "A16")
            memory.reviewStatus = "approved"
            let shared = "2026-01-02T00:00:00.000Z"
            let approve = MemoryExportAuditRow(
                seq: 7,
                ts: shared,
                actor: "app",
                action: "memory.approve",
                subjectID: "A16",
                labels: ["review_status:approved"]
            )
            let reject = MemoryExportAuditRow(
                seq: 7,
                ts: shared,
                actor: "app",
                action: "memory.reject",
                subjectID: "A16",
                labels: ["review_status:rejected"]
            )
            let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
                memory: memory,
                auditRows: [approve, reject],
                bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
                chain: chain
            ))
            if broken {
                // The tie still picks the reject label — but case 2 decides
                // only WHICH finding is reported, so it leaves as row 7, and
                // row 7 is `quarantined` whichever candidate won (F-5).
                XCTAssertEqual(result.reviewStatus, .quarantined)
                XCTAssertEqual(result.originKind, .importOrigin)
                XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
                XCTAssertTrue(result.findings.contains(.verdictOnBrokenChain))
            } else {
                // Intact: the reject wins the tie and all six conjuncts hold,
                // so this is §3.1 row 1 — rejected, human, named seq.
                XCTAssertEqual(result.reviewStatus, .rejected)
                XCTAssertEqual(result.originKind, .human)
                XCTAssertEqual(result.importOriginDetail, .humanVerdict)
                XCTAssertEqual(result.verdictAuditSeq, 7)
            }
        }
    }

    // MARK: - Rows 5, 10, 15 and 11: the uncovered exits (R8)

    /// §3.1 row 5 — a label-only MCP approval is nobody's verdict.
    func test_mcpLabelOnlyApproval_isRowFive() {
        var memory = row(id: "A5")
        memory.reviewStatus = "approved"
        let audit = MemoryExportAuditRow(
            seq: 3,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "local-mcp",
            action: "memory.approve",
            subjectID: "A5",
            labels: ["review_status:approved"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [audit],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse(bodyTime),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 1)
        ))
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .mcpDefault)
    }

    /// §3.1 row 10 — stored `quarantined` with no verdict evidence stays put.
    func test_storedQuarantined_isRowTen() {
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: row(id: "A10"),
            auditRows: [],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse(bodyTime),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 0)
        ))
        XCTAssertEqual(result.reviewStatus, .quarantined)
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .asStored)
    }

    /// §3.1 row 15 — a cloud-only approved row is a rules invariant, not a
    /// verdict — unless a local row 1–3 names the same memory, in which case
    /// the verdict wins.
    func test_cloudOnlyApproved_isRowFifteen() {
        var memory = row(id: "A15c")
        memory.reviewStatus = "approved"
        let cloudOnly = MemoryExportClassifierInput(
            memory: memory,
            auditRows: [],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse(bodyTime),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 0),
            isCloudOnly: true
        )
        let held = MemoryExportClassifier.classify(cloudOnly)
        XCTAssertEqual(held.reviewStatus, .quarantined)
        XCTAssertEqual(held.originKind, .importOrigin)
        XCTAssertEqual(held.importOriginDetail, .cloud)

        // ...unless a local row 1–3 names the same memory.
        var proven = cloudOnly
        proven.auditRows = [MemoryExportAuditRow(
            seq: 5,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A15c",
            labels: ["review_status:approved"]
        )]
        let verdict = MemoryExportClassifier.classify(proven)
        XCTAssertEqual(verdict.reviewStatus, .approved)
        XCTAssertEqual(verdict.originKind, .human)
        XCTAssertEqual(verdict.importOriginDetail, .humanVerdict)
    }

    /// §3.1 row 11 — an absent verdict label on a stored-`rejected` memory
    /// exports `rejected`, never quarantined: quarantining it would put a
    /// memory the user rejected back in the review queue.
    func test_storedRejectedWithAnAbsentLabel_isNeverRaised() {
        var memory = row(id: "A11")
        memory.reviewStatus = "rejected"
        let audit = MemoryExportAuditRow(
            seq: 4,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A11",
            labels: ["memory_id:A11"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [audit],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse(bodyTime),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 1_000, rowsWalked: 1)
        ))
        XCTAssertEqual(result.reviewStatus, .rejected)
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .unknownValue)
        XCTAssertTrue(result.findings.contains(.reviewStatusUnknownValue))
    }

    /// Rows 7/8/9 raise nothing either: a stored `rejected` under a broken
    /// chain stays `rejected`, with the broken-chain finding.
    func test_storedRejectedOnABrokenChain_isNeverRaised() {
        var memory = row(id: "A11b")
        memory.reviewStatus = "rejected"
        let audit = MemoryExportAuditRow(
            seq: 9,
            ts: "2026-01-03T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A11b",
            labels: ["review_status:approved"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [audit],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse(bodyTime),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 0, brokenAt: [9], rowsWalked: 1)
        ))
        XCTAssertEqual(result.reviewStatus, .rejected)
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
        XCTAssertTrue(result.findings.contains(.verdictOnBrokenChain))
    }

    // MARK: - F-5: breaking a chain cannot lower a row

    /// The cost of the rule F-5 removed, as a test.
    ///
    /// `unprovenStatus` used to return `rejected` whenever ANY candidate in the
    /// span carried a `review_status:rejected` label. `memory_audit` is a
    /// three-writer table with no lock and a self-declared `actor`, so a writer
    /// who can append a `memory.reject{review_status:rejected}` row and break or
    /// fork the chain around it could force **any** memory to `rejected` — and
    /// §4's merge makes a rejection permanent and unrecallable, which is the
    /// exact sentence M-13 uses about the mirror-image defect.
    ///
    /// §3.1 row 7 exports `quarantined`, so the vector closes: the forged
    /// rejection is unplaceable, it decides nothing, and the row goes back in
    /// the review queue carrying its finding.
    func test_aChainBreakerCannotLowerAQuarantinedRowToRejected() {
        var memory = row(id: "A19")
        memory.reviewStatus = "quarantined"
        let approve = MemoryExportAuditRow(
            seq: 40,
            ts: "2026-01-01T00:00:00.000Z",
            actor: "app",
            action: "memory.approve",
            subjectID: "A19",
            labels: ["review_status:approved"]
        )
        // The appended row, inside the span the same writer broke.
        let forgedReject = MemoryExportAuditRow(
            seq: 41,
            ts: "2026-01-02T00:00:00.000Z",
            actor: "app",
            action: "memory.reject",
            subjectID: "A19",
            labels: ["review_status:rejected"]
        )
        let result = MemoryExportClassifier.classify(MemoryExportClassifierInput(
            memory: memory,
            auditRows: [approve, forgedReject],
            bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
            chain: MemoryExportChainVerification(verifiedThroughSeq: 39, brokenAt: [41], rowsWalked: 2)
        ))
        XCTAssertEqual(result.reviewStatus, .quarantined, "a verdict nobody can place lowers nothing")
        XCTAssertEqual(result.originKind, .importOrigin)
        XCTAssertEqual(result.importOriginDetail, .verdictOnBrokenChain)
        XCTAssertTrue(result.findings.contains(.verdictOnBrokenChain))
        XCTAssertEqual(result.originalReviewStatus, "quarantined", "nothing is silently rewritten")

        // And the two clamps that remain are unmoved: a stored `rejected` is
        // never raised (row 11), and row 8's winner still clamps on its own
        // label.
        var stored = memory
        stored.reviewStatus = "rejected"
        XCTAssertEqual(
            MemoryExportClassifier.classify(MemoryExportClassifierInput(
                memory: stored,
                auditRows: [approve, forgedReject],
                bodySnapshotUpdatedAt: MemoryExportTimestamp.parse("2026-01-01T00:00:00.000Z"),
                chain: MemoryExportChainVerification(verifiedThroughSeq: 39, brokenAt: [41], rowsWalked: 2)
            )).reviewStatus,
            .rejected
        )
        XCTAssertEqual(
            MemoryExportClassifier.unprovenStatus(stored: "quarantined", winner: forgedReject),
            .rejected,
            "row 8's winner is a placeable verdict on an intact chain, and its label still clamps"
        )
    }

    // MARK: - Helpers

    private func classify(_ queue: DatabaseQueue, id: String) throws -> MemoryExportClassification {
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        guard let memory = snapshot.memories.first(where: { $0.id == id }) else {
            // R7 — this was `throw XCTSkip`, which XCTest reports GREEN. Had
            // `insertAppMemory` ever stopped writing (renamed column, schema
            // drift), rows 2, 3, 4, 6, 7, 8 and 9 would silently stop testing
            // while the suite still read "0 failures". A fixture that cannot
            // be built is a failing test.
            XCTFail("fixture row \(id) was not written — the fixture drifted, not the classifier")
            throw MemoryExportFixtureError.rowMissing(id)
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

/// R7 — thrown after `XCTFail` when a fixture row is absent, so the seven
/// classifier tests that share `classify(queue:id:)` run or fail, never skip.
enum MemoryExportFixtureError: Error {
    case rowMissing(String)
}
