// SPDX-License-Identifier: AGPL-3.0-only
//
// MemoryExportStoreReaderRowLimitTests — the per-table row cap.
//
// The reader materializes every row it touches, so an unbounded store is an
// OOM, not a slow export. These tests pin the refusal (named table, named
// count, before the first row is read) and the gate that raises it: absent or
// unparseable is the safe default, never unlimited.

import GRDB
import XCTest
@testable import OpenBurnBarData
@testable import OpenBurnBarMemoryExport

final class MemoryExportStoreReaderRowLimitTests: XCTestCase {

    // MARK: - Refusal

    func test_read_refusesOverLimitStore_beforeReadingRows() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            for index in 1...5 {
                try MemoryExportFixtureStore.insertAppMemory(db, id: "M\(index)", body: "body \(index)")
            }
        }
        XCTAssertThrowsError(
            try queue.read { try MemoryExportStoreReader.read($0, maxRowsPerTable: 4) }
        ) { error in
            XCTAssertEqual(
                error as? MemoryExportStoreReaderError,
                .rowLimitExceeded(table: "agent_memories", count: 5, limit: 4)
            )
        }
    }

    func test_read_atLimitReads() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            for index in 1...4 {
                try MemoryExportFixtureStore.insertAppMemory(db, id: "M\(index)", body: "body \(index)")
            }
        }
        let snapshot = try queue.read { try MemoryExportStoreReader.read($0, maxRowsPerTable: 4) }
        XCTAssertEqual(snapshot.memories.count, 4)
        XCTAssertEqual(snapshot.sourceRowCounts["agent_memories"], 4)
    }

    func test_read_refusesOverLimitAuditChain() throws {
        // `memory_audit` has no §10 count edge of its own but is read whole,
        // so the cap counts it directly.
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            try MemoryExportFixtureStore.insertAppMemory(db, id: "M1", body: "body")
            for index in 1...3 {
                try MemoryExportFixtureStore.appendAudit(
                    db,
                    action: "memory.add",
                    projectID: "chat:user-1",
                    subjectID: "M1",
                    labels: ["memory_id:M1"],
                    ts: "2026-01-0\(index)T00:00:00.000Z"
                )
            }
        }
        XCTAssertThrowsError(
            try queue.read { try MemoryExportStoreReader.read($0, maxRowsPerTable: 2) }
        ) { error in
            XCTAssertEqual(
                error as? MemoryExportStoreReaderError,
                .rowLimitExceeded(table: "memory_audit", count: 3, limit: 2)
            )
        }
    }

    // MARK: - Gate

    func test_gate_defaultIsSafe() {
        XCTAssertGreaterThan(MemoryExportRowLimit.defaultValue, 0)
        XCTAssertEqual(MemoryExportRowLimit.resolve(environment: [:]), MemoryExportRowLimit.defaultValue)
    }

    func test_gate_parsesExplicitValue() {
        XCTAssertEqual(
            MemoryExportRowLimit.resolve(environment: [MemoryExportRowLimit.environmentKey: "250000"]),
            250_000
        )
    }

    func test_gate_unparseableFallsBackToDefault() {
        for raw in ["", "  ", "abc", "0", "-5", "10.5"] {
            XCTAssertEqual(
                MemoryExportRowLimit.resolve(environment: [MemoryExportRowLimit.environmentKey: raw]),
                MemoryExportRowLimit.defaultValue,
                "gate value \(raw.debugDescription) must fall back to the safe default"
            )
        }
    }

    func test_gate_unlimitedDisablesCap() {
        XCTAssertEqual(
            MemoryExportRowLimit.resolve(environment: [MemoryExportRowLimit.environmentKey: "unlimited"]),
            .max
        )
        XCTAssertEqual(
            MemoryExportRowLimit.resolve(environment: [MemoryExportRowLimit.environmentKey: "UNLIMITED"]),
            .max
        )
    }

    func test_read_honorsGateEnvironment() throws {
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            for index in 1...3 {
                try MemoryExportFixtureStore.insertAppMemory(db, id: "M\(index)", body: "body \(index)")
            }
        }
        // The gate alone refuses, with no explicit parameter.
        XCTAssertThrowsError(
            try queue.read {
                try MemoryExportStoreReader.read(
                    $0,
                    environment: [MemoryExportRowLimit.environmentKey: "2"]
                )
            }
        ) { error in
            XCTAssertEqual(
                error as? MemoryExportStoreReaderError,
                .rowLimitExceeded(table: "agent_memories", count: 3, limit: 2)
            )
        }
        // An explicit parameter overrides the gate.
        let snapshot = try queue.read {
            try MemoryExportStoreReader.read(
                $0,
                maxRowsPerTable: 10,
                environment: [MemoryExportRowLimit.environmentKey: "2"]
            )
        }
        XCTAssertEqual(snapshot.memories.count, 3)
    }

    // MARK: - Bounded load

    /// Always-on load probe with an opt-up evidence mode. Without
    /// `OPENBURNBAR_EXPORT_LOAD_ROWS`, it builds a small store (fast enough
    /// for CI) and asserts the read materializes every row. With
    /// `OPENBURNBAR_EXPORT_LOAD_ROWS=N`, it builds N rows and reports what
    /// one `read` costs instead — full materialization when the gate is
    /// raised, a millisecond refusal at the default. N is clamped so a stray
    /// environment cannot OOM the lane.
    ///
    /// Deliberately never skipped: an env-gated skip here would hide the one
    /// test that exercises multi-hundred-row reads (shrink-only skip budget).
    private static let defaultLoadProbeRows = 1_000
    private static let maxLoadProbeRows = 250_000

    func test_load_rowsReportReadCost() throws {
        let requested = ProcessInfo.processInfo.environment["OPENBURNBAR_EXPORT_LOAD_ROWS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
        let rows = min(requested ?? Self.defaultLoadProbeRows, Self.maxLoadProbeRows)
        let gate = ProcessInfo.processInfo.environment[MemoryExportRowLimit.environmentKey] ?? "(default)"
        let queue = try MemoryExportFixtureStore.makeQueue()
        try queue.write { db in
            for index in 1...rows {
                try MemoryExportFixtureStore.insertMemoryRow(
                    db,
                    id: "L\(index)",
                    projectID: "chat:user-1",
                    bodyRef: "quarantine:q#L\(index)",
                    bodyRedacted: "Quarantine body ref:q#L\(index)",
                    sourceKind: "chat",
                    reviewStatus: "quarantined",
                    userID: "user-1",
                    appID: "app-1",
                    createdAt: "2026-01-01T00:00:00.000Z",
                    updatedAt: "2026-01-01T00:00:00.000Z"
                )
            }
        }
        let start = Date()
        do {
            let snapshot = try queue.read { try MemoryExportStoreReader.read($0) }
            print("LOAD rows=\(rows) gate=\(gate) outcome=read seconds=\(Date().timeIntervalSince(start)) memories=\(snapshot.memories.count)")
            XCTAssertEqual(
                snapshot.memories.count, rows,
                "a successful read must materialize every inserted row"
            )
        } catch {
            print("LOAD rows=\(rows) gate=\(gate) outcome=refused seconds=\(Date().timeIntervalSince(start)) error=\(error)")
            // Refusal with no gate override and a below-default row count means
            // the read path regressed — the gate cannot have refused it. (With
            // a gate override set, the operator is probing refusal itself, so
            // there is nothing to assert; refusal shape is pinned above.)
            if ProcessInfo.processInfo.environment[MemoryExportRowLimit.environmentKey] == nil {
                XCTAssertGreaterThan(
                    rows, MemoryExportRowLimit.defaultValue,
                    "refusal below the default gate means the read path regressed, not the gate"
                )
            }
        }
    }
}
