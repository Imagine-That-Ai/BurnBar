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
        // R6 — the boolean travels with the report, not only the finding.
        XCTAssertFalse(result.report.concurrentWrites)
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
        // R6 — `headBefore: 5, headAfter: 6` used to leave
        // `report.concurrent_writes == false` while holding on a finding a
        // reader keying on the boolean never saw.
        XCTAssertTrue(result.report.concurrentWrites)
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
    // MARK: - p5 store refusal (R6)

    /// The p5 lane seeded every canonical id from the literal `"unknown"` when
    /// the store carried no identity — matching no bundle and colliding across
    /// every identity-less store. Now both lanes refuse with the same code.
    func test_aP5CheckWithoutAStoreIdentityIsARefusalNotAnUnknown() throws {
        XCTAssertEqual(try MemoryExportP5Check.requireStoreID("store-1"), "store-1")
        XCTAssertThrowsError(try MemoryExportP5Check.requireStoreID(nil)) { error in
            XCTAssertEqual(error as? MIFExportError, .storeIdentityAbsent)
            XCTAssertEqual(
                (error as? MIFExportError)?.rawValue,
                "EXPORT_STORE_IDENTITY_ABSENT"
            )
        }
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

    /// R9 — migration v22 reads `deviceId` from a `UserDefaults` key nothing
    /// writes, so every migrated store carries the literal `"unknown"` and
    /// `createdAt` is the only varying input. Same millisecond, same identity.
    func test_createdAtIsTheOnlyVaryingInputInPractice() throws {
        func identity(deviceID: String, createdAt: String) throws -> String? {
            let queue = try DatabaseQueue(path: ":memory:")
            try queue.write { db in
                try db.execute(
                    sql: "CREATE TABLE devices (deviceId TEXT PRIMARY KEY, isLocal INTEGER, createdAt TEXT)"
                )
                try db.execute(
                    sql: "INSERT INTO devices (deviceId, isLocal, createdAt) VALUES (?, 1, ?)",
                    arguments: [deviceID, createdAt]
                )
            }
            return try queue.read { try MemoryExportStoreReader.storeIdentity($0) }
        }
        let first = try XCTUnwrap(identity(deviceID: "unknown", createdAt: "2026-01-01 00:00:00.000"))
        let second = try XCTUnwrap(identity(deviceID: "unknown", createdAt: "2026-01-01 00:00:00.000"))
        XCTAssertEqual(
            first,
            second,
            "two stores migrated in the same millisecond collide — documented in D-BB-E-13, not fixed here"
        )
        let later = try XCTUnwrap(identity(deviceID: "unknown", createdAt: "2026-01-02 00:00:00.000"))
        XCTAssertNotEqual(first, later, "createdAt is the input that varies")
    }

    /// A store carrying nothing that identifies it from the inside returns nil,
    /// and the CLI refuses. Inventing one would mint ids nothing else can
    /// reproduce.
    func test_aStoreWithNoIdentityInsideItReturnsNil() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        XCTAssertNil(try queue.read { try MemoryExportStoreReader.storeIdentity($0) })
    }

    /// R9's second rung, which had no test at all (review F-8): a store
    /// predating migration v22 has no `devices` row, and the identity falls back
    /// to the audit chain's **genesis** hash — equally in-file, equally
    /// immutable, and equally a row.
    ///
    /// Genesis and not the head is the whole point: the head moves with every
    /// write, so seeding ids from it would mint a different `mem_` for the same
    /// oracle row on every export and a follow-up delta would duplicate the
    /// store instead of updating it.
    func test_theIdentityFallsBackToTheAuditChainGenesis() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        let withDevices = try queue.read { try MemoryExportStoreReader.storeIdentity($0) }
        try queue.write { db in
            try db.execute(sql: "DELETE FROM devices")
            _ = try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.add",
                projectID: "chat:user-1",
                subjectID: "genesis-subject",
                labels: ["memory_id:genesis-subject"],
                ts: "2026-01-01T00:00:00.000Z"
            )
        }
        let genesisHash = try XCTUnwrap(
            try queue.read { try String.fetchOne($0, sql: "SELECT hash FROM memory_audit ORDER BY seq LIMIT 1") }
        )
        let identity = try XCTUnwrap(try queue.read { try MemoryExportStoreReader.storeIdentity($0) })
        XCTAssertEqual(
            identity,
            "burnbar-" + String(
                MemoryExportDigest.sha256Hex("memory_audit.genesis\u{1F}\(genesisHash)").prefix(24)
            ),
            "the fallback is sha256 over the genesis hash, computed here rather than by the reader"
        )
        XCTAssertNotEqual(identity, withDevices, "the `devices` rung is preferred while it exists")

        // Appending more audit rows does not move it: the chain HEAD is not the
        // seed, the genesis is.
        try queue.write { db in
            _ = try MemoryExportFixtureStore.appendAudit(
                db,
                action: "memory.add",
                projectID: "chat:user-1",
                subjectID: "later-subject",
                labels: ["memory_id:later-subject"],
                ts: "2026-02-01T00:00:00.000Z"
            )
        }
        XCTAssertEqual(
            try queue.read { try MemoryExportStoreReader.storeIdentity($0) },
            identity,
            "a write to the store must not re-mint every canonical id"
        )
    }

}
