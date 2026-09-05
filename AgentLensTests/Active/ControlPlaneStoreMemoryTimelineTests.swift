import GRDB
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBar

/// B8, app half: `ControlPlaneStore.memoryTimeline` reads the APP's own
/// hash-chained `memory_audit` ledger — not the engine's revision bodies, which
/// live in a store no Swift process reads.
///
/// The distinctions these tests exist to hold:
///   * `seq` order is the history's order, whatever order rows come back in.
///   * `lastHelpedSource` can only ever be `"history"` here. The engine also
///     serves `"recall_serve"`, from a table the app does not keep.
///   * "nothing knows that id" (`not_found`) is not "known, nothing happened"
///     (`ok` with no revisions).
///   * revision contents were never retained, and the record says so rather
///     than letting nil `before`/`after` read as "unchanged".
///   * a database that cannot answer is a FAILURE, never an empty timeline.
final class ControlPlaneStoreMemoryTimelineTests: XCTestCase {

    private func makeStore() throws -> (DatabaseQueue, ControlPlaneStore) {
        let queue = try DatabaseQueue()
        let database = OpenBurnBarDatabase(databaseQueue: queue)
        try database.runMigrationsSafely()
        return (queue, ControlPlaneStore(dbQueue: queue))
    }

    /// Inserts an audit row with an explicit `seq` so the read's ORDER BY is
    /// tested rather than SQLite's insertion order.
    private func insertAuditEvent(
        _ queue: DatabaseQueue,
        seq: Int,
        subjectID: String,
        action: String,
        ts: String,
        actor: String = "app",
        labels: [String] = []
    ) async throws {
        let labelsJSON = String(
            data: try JSONSerialization.data(withJSONObject: labels.sorted(), options: [.sortedKeys]),
            encoding: .utf8
        ) ?? "[]"
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_audit
                    (seq, ts, actor, action, domain, project_id, subject_id, labels_json, prev_hash, hash)
                VALUES (?, ?, ?, ?, 'memory', 'proj_fixture', ?, ?, NULL, ?)
                """,
                arguments: [seq, ts, actor, action, subjectID, labelsJSON, "hash-\(seq)"]
            )
        }
    }

    private func insertAuthorityRow(
        _ queue: DatabaseQueue,
        id: String,
        validFrom: String = "2026-09-01T00:00:00.000Z",
        validTo: String? = nil,
        supersededBy: String? = nil
    ) async throws {
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memories
                    (id, project_id, kind, scope, confidence, body_ref, body_redacted, tags_json,
                     source_path, valid_from, valid_to, superseded_by, created_at, updated_at)
                VALUES (?, 'proj_fixture', 'fact', 'project', 0.7, 'ref', 'redacted', '[]',
                        NULL, ?, ?, ?, ?, ?)
                """,
                arguments: [id, validFrom, validTo, supersededBy, validFrom, validFrom]
            )
        }
    }

    // MARK: - Ordering

    func test_the_timeline_orders_audit_events_by_seq_ascending() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_ordered")
        // Inserted out of order on purpose.
        try await insertAuditEvent(queue, seq: 3, subjectID: "mem_ordered", action: "memory.approve", ts: "2026-09-03T00:00:00.000Z")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_ordered", action: "memory.add", ts: "2026-09-01T00:00:00.000Z", labels: ["fact"])
        try await insertAuditEvent(queue, seq: 2, subjectID: "mem_ordered", action: "memory.update", ts: "2026-09-02T00:00:00.000Z")
        // A different memory's events must not leak into this timeline.
        try await insertAuditEvent(queue, seq: 4, subjectID: "mem_other", action: "memory.add", ts: "2026-09-04T00:00:00.000Z")

        let record = try await store.memoryTimeline(memoryID: "mem_ordered")

        XCTAssertEqual(record.status, MemoryTimelineRecord.statusOK)
        XCTAssertEqual(record.memoryID, "mem_ordered")
        XCTAssertEqual(record.revisions.map(\.seq), [1, 2, 3])
        XCTAssertEqual(record.revisions.map(\.event), ["memory.add", "memory.update", "memory.approve"])
        XCTAssertEqual(record.revisions.map(\.ts), [
            "2026-09-01T00:00:00.000Z",
            "2026-09-02T00:00:00.000Z",
            "2026-09-03T00:00:00.000Z"
        ])
        XCTAssertEqual(record.revisions.first?.meta["labels"], "fact")
        XCTAssertEqual(record.source, MemoryTimelineSource.appAudit)
        XCTAssertEqual(record.validFrom, "2026-09-01T00:00:00.000Z")
    }

    // MARK: - Last helped

    func test_last_helped_source_is_history_and_never_recall_serve() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_helped")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_helped", action: "memory.add", ts: "2026-09-01T00:00:00.000Z")
        try await insertAuditEvent(queue, seq: 2, subjectID: "mem_helped", action: "memory.approve", ts: "2026-09-04T09:30:00.000Z")

        let record = try await store.memoryTimeline(memoryID: "mem_helped")

        XCTAssertEqual(record.lastHelpedAt, "2026-09-04T09:30:00.000Z", "the latest recorded event, not the first")
        XCTAssertEqual(record.lastHelpedSource, MemoryTimelineRecord.lastHelpedSourceHistory)
        XCTAssertNotEqual(
            record.lastHelpedSource,
            "recall_serve",
            "the app keeps no recall-serve ledger, so it can never claim that source"
        )

        // A known memory nothing has touched reports no last-helped at all
        // rather than inventing one.
        try await insertAuthorityRow(queue, id: "mem_untouched")
        let untouched = try await store.memoryTimeline(memoryID: "mem_untouched")
        XCTAssertEqual(untouched.status, MemoryTimelineRecord.statusOK)
        XCTAssertTrue(untouched.revisions.isEmpty)
        XCTAssertNil(untouched.lastHelpedAt)
        XCTAssertNil(untouched.lastHelpedSource)
    }

    // MARK: - not_found vs empty ok

    func test_an_unknown_memory_id_is_not_found_rather_than_an_empty_ok() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_known")

        let unknown = try await store.memoryTimeline(memoryID: "mem_never_existed")
        XCTAssertEqual(unknown.status, MemoryTimelineRecord.statusNotFound)
        XCTAssertTrue(unknown.revisions.isEmpty)
        XCTAssertNil(unknown.validFrom)

        let known = try await store.memoryTimeline(memoryID: "mem_known")
        XCTAssertEqual(known.status, MemoryTimelineRecord.statusOK)
        XCTAssertTrue(known.revisions.isEmpty)
        XCTAssertNotEqual(
            known.status,
            unknown.status,
            "'known but untouched' and 'no such memory' are different answers"
        )
    }

    // MARK: - Revision bodies

    func test_revision_bodies_are_absent_and_the_record_says_so() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_bodies")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_bodies", action: "memory.add", ts: "2026-09-01T00:00:00.000Z")
        try await insertAuditEvent(queue, seq: 2, subjectID: "mem_bodies", action: "memory.update", ts: "2026-09-02T00:00:00.000Z")

        let record = try await store.memoryTimeline(memoryID: "mem_bodies")

        XCTAssertEqual(record.revisions.count, 2)
        XCTAssertTrue(record.revisions.allSatisfy { $0.before == nil && $0.after == nil })
        XCTAssertFalse(
            record.revisionBodiesRetained,
            "the audit ledger never retained revision contents, and the record must say so"
        )
        XCTAssertTrue(
            record.revisions.allSatisfy { $0.writerDevice == nil },
            "memory_audit records no per-event device — every row was written by this device"
        )
    }

    // MARK: - Table absent is a failure

    func test_a_missing_audit_table_is_a_failure_not_an_empty_timeline() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_no_ledger")
        try await queue.write { db in
            try db.execute(sql: "DROP TABLE memory_audit")
        }

        do {
            let record = try await store.memoryTimeline(memoryID: "mem_no_ledger")
            XCTFail("a database that cannot answer must throw, got \(record.status)")
        } catch let error as MemoryTimelineError {
            guard case .historyUnavailable = error else {
                XCTFail("unexpected timeline error \(error)")
                return
            }
            XCTAssertEqual(
                error.errorDescription?.hasPrefix("History unavailable"),
                true,
                "the member is told the history could not be read, not that there is none"
            )
        }
    }

    // MARK: - Inbound writer device

    func test_a_synced_memory_names_the_device_it_arrived_from() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_synced")
        try await insertAuditEvent(queue, seq: 1, subjectID: "mem_synced", action: "memory.merge", ts: "2026-09-01T00:00:00.000Z")
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_synced', 'proj_fixture', 'eng_mem_1', 'body', 'hash', ?, ?)
                """,
                arguments: ["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES ('doc-1', 'user-1', 'eng_mem_1', ?, ?, ?, NULL)
                """,
                arguments: [
                    #"{"memoryID":"eng_mem_1","writerDevice":"studio-ultra"}"#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }

        let record = try await store.memoryTimeline(memoryID: "mem_synced")
        XCTAssertEqual(record.writerDevice, "studio-ultra")

        // A memory that never came down from another device names none.
        try await insertAuthorityRow(queue, id: "mem_local")
        let local = try await store.memoryTimeline(memoryID: "mem_local")
        XCTAssertNil(local.writerDevice)
    }
}
