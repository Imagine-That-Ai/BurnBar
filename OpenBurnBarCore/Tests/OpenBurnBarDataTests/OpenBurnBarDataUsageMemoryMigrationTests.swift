import GRDB
import XCTest
@testable import OpenBurnBarData

/// Core-side diff-coverage tests for the `v61_usage_memory` migration
/// (`OpenBurnBarDatabase+UsageMemoryMigrations.swift`) and its migrator
/// wiring line in `OpenBurnBarDatabase.swift`. The app-side
/// `UsageMemoryMigrationTests` exercises the byte-identical AgentLens copy
/// (pair identity is enforced by `scripts/ci/verify-sqlite-schema-doc.mjs`);
/// these tests run the Core `OpenBurnBarDatabase` migrator directly so the
/// SwiftPM diff-coverage gate sees the changed Core lines.
final class OpenBurnBarDataUsageMemoryMigrationTests: XCTestCase {

    // MARK: - Fresh database shape

    func test_freshMigrationCreatesUsageMemorySubstrate() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue)

        let shape = try queue.read { db -> (tables: Set<String>, indexes: Set<String>, jobColumns: [String]) in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            let jobColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(memory_extraction_jobs)")
                .compactMap { $0["name"] as? String }
            return (tables, indexes, jobColumns)
        }

        XCTAssertTrue(shape.tables.contains("memory_usage_candidates"))
        XCTAssertTrue(shape.tables.contains("memory_salience"))
        XCTAssertTrue(shape.tables.contains("memory_links"))
        XCTAssertTrue(shape.indexes.contains("memory_usage_candidates_status_idx"))
        XCTAssertTrue(shape.indexes.contains("memory_usage_candidates_simhash_idx"))
        XCTAssertTrue(shape.indexes.contains("memory_links_from_idx"))
        XCTAssertTrue(shape.indexes.contains("memory_links_to_idx"))
        XCTAssertTrue(shape.jobColumns.contains("source_kind"))
    }

    // MARK: - Upgrade path (pre-v61 rows backfilled as chat)

    func test_upgradeBackfillsExistingExtractionJobsAsChat() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v60_billing_kind")

        let legacyDate = Date(timeIntervalSince1970: 1_700_000_000)
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_extraction_jobs (
                    id, idempotency_key, thread_id, thread_logical_id, message_id,
                    prompt_version, scope_json, status, attempts, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)
                """,
                arguments: [
                    "job-pre-v61",
                    "idem-pre-v61",
                    "thread-legacy",
                    "thread-legacy",
                    "msg-legacy",
                    "v1",
                    "{}",
                    legacyDate,
                    legacyDate
                ]
            )
        }

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let sourceKind = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT source_kind FROM memory_extraction_jobs WHERE id = 'job-pre-v61'"
            )
        }
        XCTAssertEqual(sourceKind, "chat")
    }

    // MARK: - Candidate spool round trip

    func test_usageCandidateRowRoundTripsThroughSpoolSchema() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_usage_candidates (
                    id, source_kind, source_ref, thread_logical_id, payload_json,
                    content_hash, simhash, salience_hint, created_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    "cand-1",
                    "safari_ask",
                    "safari-ask:obs-1",
                    "safari-ask:obs-1",
                    #"{"schemaVersion":1,"prompt":"how do I pin a GRDB migration?"}"#,
                    "hash-1",
                    Int64(bitPattern: 0x8000_0000_0000_0001),
                    0.75,
                    now,
                    now
                ]
            )
        }

        let row = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memory_usage_candidates WHERE id = 'cand-1'")
        }
        XCTAssertEqual(row?["status"] as String?, "pending")
        XCTAssertEqual(row?["simhash"] as Int64?, Int64(bitPattern: 0x8000_0000_0000_0001))
        XCTAssertNil(row?["batch_job_id"] as String?)
    }
}
