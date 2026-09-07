// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportBodyResolverTests — §3.2, including the adversarial value the
// detection order exists to defeat.

import GRDB
import XCTest
@testable import OpenBurnBarMemoryExport

final class MemoryExportBodyResolverTests: XCTestCase {

    // MARK: - Detection

    func test_detectionOrderIsPrefixFirst() {
        let hex = String(repeating: "a", count: 64)
        XCTAssertEqual(
            MemoryExportBodyResolver.detectConvention(bodyRef: "memory_body_snapshots:memory-x"),
            .snapshotSlug
        )
        XCTAssertEqual(MemoryExportBodyResolver.detectConvention(bodyRef: hex), .sha256)
        // The door case: a hostile `memory_body_snapshots:<64 hex>` must resolve
        // as convention A and never be steerable into the daemon store.
        XCTAssertEqual(
            MemoryExportBodyResolver.detectConvention(bodyRef: "memory_body_snapshots:\(hex)"),
            .adversarialSlugHex
        )
        XCTAssertEqual(MemoryExportBodyResolver.detectConvention(bodyRef: "nonsense"), .unknown)
        XCTAssertEqual(MemoryExportBodyResolver.detectConvention(bodyRef: ""), .absent)
    }

    func test_adversarialSlugHexResolvesInTheAppStoreNotTheDaemonOne() {
        let hex = MemoryExportDigest.sha256Hex("daemon body")
        let memory = MemoryExportMemoryRow(
            id: "X1",
            projectID: "proj-1",
            bodyRef: "memory_body_snapshots:\(hex)",
            bodyRedacted: "memory_body_snapshots:\(hex)",
            validFrom: "2026-01-01T00:00:00.000Z",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        let stores = MemoryExportBodyStores(
            snapshotsByMemoryID: ["X1": MemoryExportBodySnapshotRow(
                id: "slug",
                memoryID: "X1",
                bodyRef: "memory_body_snapshots:\(hex)",
                snapshotJSON: #"{"body":"app body","bodyHash":""}"#,
                bodyHash: MemoryExportDigest.sha256Hex("app body"),
                createdAt: "2026-01-01T00:00:00.000Z",
                updatedAt: "2026-01-01T00:00:00.000Z"
            )],
            projectSnapshotJSONBySlug: ["agent-proj-1": #"""
            {"pages":[{"id":"agent-notes","sections":[{"id":"X1","body":"daemon body"}]}]}
            """#]
        )
        guard case .resolved(let body) = MemoryExportBodyResolver.resolve(memory: memory, stores: stores) else {
            return XCTFail("the app lane should have answered")
        }
        XCTAssertEqual(body.body, "app body")
        XCTAssertEqual(body.recoveredFrom, .memoryBodySnapshots)
        // Present in both stores with different text is the D5 divergent case.
        XCTAssertEqual(body.integrity, .divergent)
        XCTAssertTrue(body.findings.contains(.bodyDivergentStores))
    }

    // MARK: - Both conventions, end to end through the migrator's schema

    func test_bothConventionsResolveAgainstARealStore() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        let daemonID = "mem_" + String(repeating: "c", count: 32)
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(db, id: "B1", body: "app lane body")
            try MemoryExportFixtureStore.insertDaemonMemory(
                db,
                id: daemonID,
                body: "daemon lane body",
                projectID: "proj-9"
            )
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        let stores = MemoryExportBodyStores(
            snapshotsByMemoryID: Dictionary(snapshot.bodySnapshots.map { ($0.memoryID, $0) }) { first, _ in first },
            projectSnapshotJSONBySlug: snapshot.projectSnapshots,
            quarantineBodiesByMemoryID: snapshot.quarantineBodies
        )
        for (id, expected) in [("B1", "app lane body"), (daemonID, "daemon lane body")] {
            // swiftlint:disable:next force_unwrapping reason: both rows were just written
            let memory = snapshot.memories.first { $0.id == id }!
            guard case .resolved(let body) = MemoryExportBodyResolver.resolve(memory: memory, stores: stores) else {
                return XCTFail("\(id) should resolve")
            }
            XCTAssertEqual(body.body, expected)
            XCTAssertEqual(body.integrity, .verified, "both lanes get the same hash check")
        }
    }

    /// A quarantined daemon row's body lives in `memory_quarantine_bodies`, not
    /// in the project snapshot. Treating that as loss would silently drop the
    /// daemon lane's whole review queue.
    func test_quarantinedDaemonBodyIsRecoveredFromTheQuarantineStore() throws {
        let id = "mem_" + String(repeating: "d", count: 32)
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertDaemonMemory(
                db,
                id: id,
                body: "held for review",
                projectID: "proj-8",
                reviewStatus: "quarantined",
                quarantineBodyInstead: true
            )
        }
        let snapshot = try MemoryExportFixtureStore.snapshot(queue)
        // swiftlint:disable:next force_unwrapping reason: the row was just written
        let memory = snapshot.memories.first!
        let stores = MemoryExportBodyStores(
            projectSnapshotJSONBySlug: snapshot.projectSnapshots,
            quarantineBodiesByMemoryID: snapshot.quarantineBodies
        )
        guard case .resolved(let body) = MemoryExportBodyResolver.resolve(memory: memory, stores: stores) else {
            return XCTFail("a quarantined daemon body must not read as loss")
        }
        XCTAssertEqual(body.body, "held for review")
        XCTAssertTrue(body.fromQuarantineStore)
    }

    // MARK: - Recovery and loss

    func test_legacyPlaintextInBodyRedactedIsRecoveredBeforeLossIsDeclared() {
        let memory = MemoryExportMemoryRow(
            id: "X2",
            projectID: "proj-1",
            bodyRef: "memory_body_snapshots:memory-X2",
            // Pre-v39 app rows held the plaintext here, and the daemon's
            // migration of those into snapshots can fail or be interrupted.
            bodyRedacted: "the original plaintext body",
            validFrom: "2026-01-01T00:00:00.000Z",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        guard case .resolved(let body) = MemoryExportBodyResolver.resolve(
            memory: memory,
            stores: MemoryExportBodyStores()
        ) else {
            return XCTFail("recovery runs before loss")
        }
        XCTAssertEqual(body.body, "the original plaintext body")
        XCTAssertEqual(body.integrity, .recoveredLegacyPlaintext)
        XCTAssertEqual(body.recoveredFrom, .bodyRedactedLegacyPlaintext)
    }

    func test_orphanBodyIsUnreconstructibleAndNamed() {
        let memory = MemoryExportMemoryRow(
            id: "X3",
            projectID: "proj-1",
            bodyRef: "memory_body_snapshots:memory-X3",
            bodyRedacted: "memory_body_snapshots:memory-X3",
            validFrom: "2026-01-01T00:00:00.000Z",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        guard case .unreconstructible(let failure) = MemoryExportBodyResolver.resolve(
            memory: memory,
            stores: MemoryExportBodyStores()
        ) else {
            return XCTFail("no body means no memory record")
        }
        XCTAssertTrue(failure.findings.contains(.bodyUnreconstructible))
        XCTAssertFalse(failure.reasonDetail.isEmpty, "a count is not a name")
    }

    func test_hashMismatchIsReportedRatherThanTrusted() {
        let memory = MemoryExportMemoryRow(
            id: "X4",
            projectID: "proj-1",
            bodyRef: "memory_body_snapshots:memory-X4",
            validFrom: "2026-01-01T00:00:00.000Z",
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )
        let stores = MemoryExportBodyStores(snapshotsByMemoryID: ["X4": MemoryExportBodySnapshotRow(
            id: "slug",
            memoryID: "X4",
            bodyRef: "memory_body_snapshots:memory-X4",
            snapshotJSON: #"{"body":"actual text"}"#,
            bodyHash: MemoryExportDigest.sha256Hex("different text"),
            createdAt: "2026-01-01T00:00:00.000Z",
            updatedAt: "2026-01-01T00:00:00.000Z"
        )])
        guard case .resolved(let body) = MemoryExportBodyResolver.resolve(memory: memory, stores: stores) else {
            return XCTFail("the row still travels")
        }
        XCTAssertEqual(body.integrity, .mismatch)
        XCTAssertTrue(body.findings.contains(.bodyHashMismatch))
    }
}
