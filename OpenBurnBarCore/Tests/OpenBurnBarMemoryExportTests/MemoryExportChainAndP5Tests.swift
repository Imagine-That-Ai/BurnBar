// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportChainAndP5Tests — §7's walk and §5's memory-lane stop.

import GRDB
import XCTest
@testable import OpenBurnBarMemoryExport

final class MemoryExportChainAndP5Tests: XCTestCase {

    // MARK: - Chain

    func test_anIntactChainVerifiesThroughItsHead() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            for index in 1...5 {
                try MemoryExportFixtureStore.appendAudit(
                    db,
                    action: "memory.add",
                    projectID: "chat:user-1",
                    subjectID: "M\(index)",
                    labels: ["memory_id:M\(index)"],
                    ts: "2026-01-0\(index)T00:00:00.000Z"
                )
            }
        }
        let chain = MemoryExportAuditChain.verify(rows: try MemoryExportFixtureStore.snapshot(queue).auditRows)
        XCTAssertEqual(chain.verifiedThroughSeq, 5)
        XCTAssertTrue(chain.brokenAt.isEmpty)
        XCTAssertTrue(chain.forks.isEmpty)
        XCTAssertTrue(chain.isTrustworthy(seq: 5))
    }

    func test_aTamperedRowIsNamedAndStopsTheVerifiedSpan() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            for index in 1...4 {
                try MemoryExportFixtureStore.appendAudit(
                    db,
                    action: "memory.add",
                    projectID: "chat:user-1",
                    subjectID: "M\(index)",
                    labels: ["memory_id:M\(index)"],
                    ts: "2026-01-0\(index)T00:00:00.000Z"
                )
            }
            try MemoryExportFixtureStore.breakChain(db, atSeq: 3)
        }
        let chain = MemoryExportAuditChain.verify(rows: try MemoryExportFixtureStore.snapshot(queue).auditRows)
        XCTAssertEqual(chain.brokenAt, [3])
        // Row 4 links to row 3's now-wrong hash, so it forks too. Both are
        // recorded; neither repairs anything.
        XCTAssertEqual(chain.forks, [4])
        XCTAssertEqual(chain.verifiedThroughSeq, 2)
        XCTAssertFalse(chain.isTrustworthy(seq: 3))
        XCTAssertFalse(chain.isTrustworthy(seq: 4))
        XCTAssertTrue(chain.isTrustworthy(seq: 2), "a break never invalidates the span before it")
    }

    /// The writer hashes `previousSeq + 1` while the column is AUTOINCREMENT, so
    /// after a deletion the two diverge permanently. A seq-only walk would call
    /// every later row broken; recording the divergence keeps the span usable.
    func test_payloadSeqDivergenceIsRecordedRatherThanCalledABreak() {
        let first = chained(seq: 1, payloadSeq: 1, prevHash: nil, ts: "2026-01-01T00:00:00.000Z")
        // seq 7 in the column, but the writer hashed `previousSeq + 1` = 2.
        let second = chained(seq: 7, payloadSeq: 2, prevHash: first.hash, ts: "2026-01-02T00:00:00.000Z")
        let chain = MemoryExportAuditChain.verify(rows: [first, second])
        XCTAssertTrue(chain.seqDivergence)
        XCTAssertTrue(chain.brokenAt.isEmpty)
        XCTAssertEqual(chain.verifiedThroughSeq, 7)
    }

    private func chained(seq: Int, payloadSeq: Int, prevHash: String?, ts: String) -> MemoryExportAuditRow {
        var row = MemoryExportAuditRow(
            seq: seq,
            ts: ts,
            actor: "app",
            action: "memory.add",
            projectID: "chat:user-1",
            subjectID: "M\(seq)",
            labels: [],
            prevHash: prevHash
        )
        row.hash = MemoryExportAuditChain.payloadHash(row: row, payloadSeq: payloadSeq, prevHash: prevHash)
        return row
    }

    // MARK: - P5

    private var passingGates: MemoryExportP5Gates {
        MemoryExportP5Gates(
            sourceVersion: "1.0.41",
            requiredVersion: "1.0.41",
            socketTokenRotated: true,
            memoryWriteCapabilityWithdrawn: true
        )
    }

    func test_anUnmovedAuditHeadWithAnEmptyIdDiffPasses() {
        let result = MemoryExportP5Check.run(
            gates: passingGates,
            headBefore: 4_120,
            headAfter: 4_120,
            sourceLiveIDs: ["a", "b"],
            targetLiveIDs: ["a", "b"],
            storeID: "store-1"
        )
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.report.phase, .p5Reconcile)
        XCTAssertEqual(result.report.target?.quiesced, true)
    }

    func test_aMovedAuditHeadMeansAWriterSurvivedTheGates() {
        let result = MemoryExportP5Check.run(
            gates: passingGates,
            headBefore: 4_120,
            headAfter: 4_121,
            sourceLiveIDs: [],
            targetLiveIDs: [],
            storeID: "store-1"
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.holdReasons, [.p5SourceNotQuiesced])
        // The fix is the version gate, never a process kill — the finding says
        // so, because that is what D-0007 rules out.
        XCTAssertTrue(result.report.findings.contains { $0.code == .concurrentWrites })
    }

    func test_aPreBBRBuildIsRefusedByVersionRatherThanDisabledInPlace() {
        var gates = passingGates
        gates.sourceVersion = "1.0.9"
        gates.requiredVersion = "1.0.40"
        XCTAssertFalse(gates.buildIsNewEnough, "1.0.9 is older than 1.0.40; string order would say otherwise")
        let result = MemoryExportP5Check.run(
            gates: gates,
            headBefore: 1,
            headAfter: 1,
            sourceLiveIDs: [],
            targetLiveIDs: [],
            storeID: "store-1"
        )
        XCTAssertEqual(result.holdReasons, [.p5SourceBuildTooOld])
    }

    func test_reconcileIsAnIdSetDiffNotACount() {
        // Equal COUNTS, different SETS: a per-bundle count would pass this.
        let result = MemoryExportP5Check.run(
            gates: passingGates,
            headBefore: 1,
            headAfter: 1,
            sourceLiveIDs: ["only-source"],
            targetLiveIDs: ["only-target"],
            storeID: "store-1"
        )
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.holdReasons, [.reconciliationMismatch])
    }
    // MARK: - Store identity (F-11)

    /// Every canonical id is `sha256(store_id ‖ …)`, so `store_id` has to
    /// survive everything that leaves the user's data intact but rewrites the
    /// file. It used to be `sha256(inode ‖ creation date)`, and an inode
    /// survives none of a Time Machine restore, a `VACUUM`, an APFS clone or a
    /// reinstall — after any of those the same oracle rows minted DIFFERENT ids
    /// and a follow-up delta duplicated every app-lane row in the target.
    func test_theStoreIdentityComesFromInsideTheDatabase() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        let identity = try queue.read { try MemoryExportStoreReader.storeIdentity($0) }
        let again = try queue.read { try MemoryExportStoreReader.storeIdentity($0) }
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity, again, "two reads of one store agree")
        XCTAssertTrue(try XCTUnwrap(identity).hasPrefix("burnbar-"))

        // A VACUUM rewrites every page and renumbers the file; the identity is a
        // ROW, so it comes through unchanged. (An inode would not.)
        try queue.writeWithoutTransaction { try $0.execute(sql: "VACUUM") }
        XCTAssertEqual(try queue.read { try MemoryExportStoreReader.storeIdentity($0) }, identity)

        // A byte copy of the store is the SAME store, and must mint the same
        // ids — that is what makes a restore-then-delta idempotent rather than
        // a duplication of every row.
        let copy = try DatabaseQueue(path: ":memory:")
        try queue.backup(to: copy)
        XCTAssertEqual(try copy.read { try MemoryExportStoreReader.storeIdentity($0) }, identity)

        // A DIFFERENT store is a different identity.
        let other = try MemoryExportFixtureStore.makeQueue()
        try other.write { db in
            try db.execute(sql: "UPDATE devices SET deviceId = 'another-install' WHERE isLocal = 1")
        }
        XCTAssertNotEqual(try other.read { try MemoryExportStoreReader.storeIdentity($0) }, identity)
    }

    /// A store carrying nothing that identifies it from the inside returns nil,
    /// and the CLI refuses. Inventing one would mint ids nothing else can
    /// reproduce.
    func test_aStoreWithNoIdentityInsideItReturnsNil() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        XCTAssertNil(try queue.read { try MemoryExportStoreReader.storeIdentity($0) })
    }

}
