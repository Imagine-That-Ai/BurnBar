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
        labels: [String] = [],
        domain: String = "memory"
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
                VALUES (?, ?, ?, ?, ?, 'proj_fixture', ?, ?, NULL, ?)
                """,
                arguments: [seq, ts, actor, action, domain, subjectID, labelsJSON, "hash-\(seq)"]
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

        let record = try await store.memoryTimeline(memoryID: "mem_synced", userID: "user-1")
        XCTAssertEqual(record.writerDevice, "studio-ultra")

        // A memory that never came down from another device names none.
        try await insertAuthorityRow(queue, id: "mem_local")
        let local = try await store.memoryTimeline(memoryID: "mem_local", userID: "user-1")
        XCTAssertNil(local.writerDevice)
    }

    // MARK: - Truncation

    /// I2: a capped read used to return the OLDEST page and then call its last
    /// row "last recorded". On a memory with more events than the cap, the header
    /// rendered a stale timestamp as the latest one and nothing said the list was
    /// cut. The cap now takes the tail, and the record says it is a tail.
    func test_a_capped_read_keeps_the_latest_events_and_says_it_was_capped() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_busy")
        for seq in 1 ... 6 {
            try await insertAuditEvent(
                queue,
                seq: seq,
                subjectID: "mem_busy",
                action: "memory.update",
                ts: "2026-09-0\(seq)T00:00:00.000Z"
            )
        }

        let capped = try await store.memoryTimeline(memoryID: "mem_busy", limit: 3)
        XCTAssertEqual(capped.revisions.map(\.seq), [4, 5, 6], "a cap keeps the LATEST events, not the first page")
        XCTAssertEqual(
            capped.lastHelpedAt,
            "2026-09-06T00:00:00.000Z",
            "'last recorded' must be the last event, not the last row of an oldest-first page"
        )
        XCTAssertTrue(capped.truncated, "the member is told older events exist")

        let whole = try await store.memoryTimeline(memoryID: "mem_busy", limit: 50)
        XCTAssertEqual(whole.revisions.map(\.seq), [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(whole.truncated, "a complete history is not a truncated one")

        // Exactly at the cap is still complete.
        let exact = try await store.memoryTimeline(memoryID: "mem_busy", limit: 6)
        XCTAssertEqual(exact.revisions.count, 6)
        XCTAssertFalse(exact.truncated)
    }

    // MARK: - Domain scoping

    /// I5: `memory_audit` is a multi-namespace ledger. The daemon writes
    /// `domain = 'code'` rows into the same table with a completely different
    /// `subject_id` namespace (artifact ids, and filesystem paths for
    /// `code.index`). A memory's history must contain only memory events.
    func test_a_code_domain_event_is_not_rendered_as_memory_history() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_scoped")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_scoped",
            action: "memory.add",
            ts: "2026-09-01T00:00:00.000Z"
        )
        try await insertAuditEvent(
            queue,
            seq: 2,
            subjectID: "mem_scoped",
            action: "code.remember",
            ts: "2026-09-02T00:00:00.000Z",
            domain: "code"
        )

        let record = try await store.memoryTimeline(memoryID: "mem_scoped")

        XCTAssertEqual(record.revisions.map(\.event), ["memory.add"], "a foreign namespace never joins a memory's history")
        XCTAssertEqual(record.revisions.first?.meta["domain"], "memory")
        XCTAssertEqual(record.lastHelpedAt, "2026-09-01T00:00:00.000Z")
    }

    // MARK: - Cross-member scoping

    /// M2: `agent_memory_inbox` is user-scoped and the join was not. On a Mac
    /// where two accounts have signed in, another member's inbox row could name
    /// the device. The read now says whose inbox it is reading, and reads none
    /// when nobody is signed in.
    func test_the_inbound_device_is_read_only_from_the_signed_in_members_inbox() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_shared")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_shared",
            action: "memory.merge",
            ts: "2026-09-01T00:00:00.000Z"
        )
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_shared', 'proj_fixture', 'eng_shared', 'body', 'hash', ?, ?)
                """,
                arguments: ["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES ('doc-other', 'user-other', 'eng_shared', ?, ?, ?, NULL)
                """,
                arguments: [
                    #"{"memoryID":"eng_shared","writerDevice":"someone-elses-mac"}"#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }

        let mine = try await store.memoryTimeline(memoryID: "mem_shared", userID: "user-1")
        XCTAssertNil(mine.writerDevice, "another member's inbox row is not my provenance")
        XCTAssertEqual(mine.status, MemoryTimelineRecord.statusOK)

        let anonymous = try await store.memoryTimeline(memoryID: "mem_shared", userID: nil)
        XCTAssertNil(anonymous.writerDevice, "with nobody signed in there is no inbox to read")

        let theirs = try await store.memoryTimeline(memoryID: "mem_shared", userID: "user-other")
        XCTAssertEqual(theirs.writerDevice, "someone-elses-mac", "their own row is still theirs to see")
    }

    // MARK: - Payload bound

    /// M3: `payload_json` was deserialized whole, unbounded. It is written by
    /// the app's own verified pull lane, so this is a robustness bound rather
    /// than an attack surface — and exceeding it degrades to "no device named",
    /// never to a failed timeline.
    func test_an_oversized_inbox_payload_is_skipped_rather_than_parsed() async throws {
        let (queue, store) = try makeStore()
        try await insertAuthorityRow(queue, id: "mem_fat")
        try await insertAuditEvent(
            queue,
            seq: 1,
            subjectID: "mem_fat",
            action: "memory.merge",
            ts: "2026-09-01T00:00:00.000Z"
        )
        let padding = String(repeating: "p", count: ControlPlaneStore.memoryTimelinePayloadByteLimit + 1)
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memory_bodies
                    (memory_id, project_id, engine_memory_id, body, body_hash, created_at, updated_at)
                VALUES ('mem_fat', 'proj_fixture', 'eng_fat', 'body', 'hash', ?, ?)
                """,
                arguments: ["2026-09-01T00:00:00.000Z", "2026-09-01T00:00:00.000Z"]
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memory_inbox
                    (doc_id, user_id, engine_memory_id, payload_json, remote_updated_at, received_at, applied_at)
                VALUES ('doc-fat', 'user-1', 'eng_fat', ?, ?, ?, NULL)
                """,
                arguments: [
                    #"{"writerDevice":"studio-ultra","padding":"\#(padding)"}"#,
                    "2026-09-02T00:00:00.000Z",
                    "2026-09-02T00:01:00.000Z"
                ]
            )
        }

        let record = try await store.memoryTimeline(memoryID: "mem_fat", userID: "user-1")
        XCTAssertEqual(record.status, MemoryTimelineRecord.statusOK, "an oversized payload never fails the timeline")
        XCTAssertEqual(record.revisions.count, 1)
        XCTAssertNil(record.writerDevice, "past the bound the payload is not parsed at all")
    }
}
