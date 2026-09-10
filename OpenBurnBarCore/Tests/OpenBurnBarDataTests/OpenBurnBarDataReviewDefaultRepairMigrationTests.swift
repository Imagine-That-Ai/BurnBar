import GRDB
import XCTest
@testable import OpenBurnBarData

/// Core-side coverage for `v68_agent_memories_review_default_repair` (review
/// #2565-F3). The AgentLens copy of `CommandBoardIndexMigration` is
/// byte-identical — pair identity is enforced by
/// `scripts/ci/verify-sqlite-schema-doc.mjs` — so running the Core migrator
/// against a stale-default `agent_memories` proves both halves of the repair.
final class OpenBurnBarDataReviewDefaultRepairMigrationTests: XCTestCase {

    /// An install whose shared table an older daemon binary created carries
    /// `DEFAULT 'approved'` on `review_status` — neither `ALTER` nor an
    /// `IF NOT EXISTS` create can rewrite a column default, so v68 rebuilds
    /// the table. Every column and row must survive the rebuild verbatim, and
    /// an insert that names no verdict must land in review afterwards.
    func test_rebuildsAStaleApprovedDefaultFailClosed() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v67_agent_memory_inbox")

        // The stale shape, verbatim: every column the v50–v67 migrator
        // produced, but `review_status` declared the way the older daemon
        // bootstrap did.
        try queue.write { db in
            try db.execute(sql: "DROP TABLE agent_memories")
            try db.execute(
                sql: """
                CREATE TABLE agent_memories (
                    id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    body_ref TEXT NOT NULL,
                    body_redacted TEXT NOT NULL,
                    tags_json TEXT NOT NULL,
                    source_path TEXT,
                    valid_from TEXT NOT NULL,
                    valid_to TEXT,
                    superseded_by TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    source_kind TEXT NOT NULL DEFAULT 'code',
                    review_status TEXT NOT NULL DEFAULT 'approved',
                    user_id TEXT,
                    agent_id TEXT,
                    run_id TEXT,
                    app_id TEXT
                )
                """
            )
            try db.execute(
                sql: """
                INSERT INTO agent_memories (
                    id, project_id, kind, scope, confidence, body_ref, body_redacted,
                    tags_json, source_path, valid_from, valid_to, superseded_by,
                    created_at, updated_at, source_kind, review_status, user_id
                ) VALUES (
                    'legacy-approved-row', 'project-1', 'fact', 'project', 0.9, 'ref',
                    'redacted', '[]', NULL, '2026-01-01T00:00:00Z', NULL, NULL,
                    '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 'agent',
                    'approved', 'member-1'
                )
                """
            )
        }

        try OpenBurnBarDatabase.migrator.migrate(queue)

        try queue.read { db in
            let declaredDefault = try String.fetchOne(
                db,
                sql: "SELECT dflt_value FROM pragma_table_info('agent_memories') WHERE name = 'review_status'"
            )
            XCTAssertEqual(
                declaredDefault, "'quarantined'",
                "the rebuilt table must carry the fail-closed default"
            )
            let preserved = try Row.fetchOne(
                db,
                sql: "SELECT review_status, user_id FROM agent_memories WHERE id = 'legacy-approved-row'"
            )
            XCTAssertEqual(preserved?["review_status"] as? String, "approved")
            XCTAssertEqual(preserved?["user_id"] as? String, "member-1")
            let rebuiltColumns = Set(
                try Row.fetchAll(db, sql: "PRAGMA table_info(agent_memories)")
                    .compactMap { $0["name"] as? String }
            )
            for column in ["source_kind", "user_id", "agent_id", "run_id", "app_id"] {
                XCTAssertTrue(rebuiltColumns.contains(column), "rebuild dropped column \(column)")
            }
            let indexes = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'agent_memories_%'"
                )
            )
            for index in ["agent_memories_project_idx", "agent_memories_review_status_idx", "agent_memories_chat_scope_idx"] {
                XCTAssertTrue(indexes.contains(index), "rebuild lost index \(index)")
            }
        }

        // The point of the repair: a write that names no verdict lands in review.
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO agent_memories (
                    id, project_id, kind, scope, confidence, body_ref, body_redacted,
                    tags_json, source_path, valid_from, valid_to, superseded_by,
                    created_at, updated_at
                ) VALUES (
                    'unvouched-insert', 'project-1', 'fact', 'project', 0.5, 'ref',
                    'redacted', '[]', NULL, '2026-01-02T00:00:00Z', NULL, NULL,
                    '2026-01-02T00:00:00Z', '2026-01-02T00:00:00Z'
                )
                """
            )
        }
        let landedStatus = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT review_status FROM agent_memories WHERE id = 'unvouched-insert'"
            )
        }
        XCTAssertEqual(
            landedStatus, "quarantined",
            "an insert that names no verdict must land in review, never in production"
        )
    }

    /// A fresh database gets `DEFAULT 'quarantined'` from v51's add-column, so
    /// the probe must leave the table alone — it is a probe, not a rewrite.
    func test_leavesAnAlreadyCorrectDefaultAlone() throws {
        let queue = try DatabaseQueue(path: ":memory:")
        try OpenBurnBarDatabase.migrator.migrate(queue, upTo: "v67_agent_memory_inbox")
        let tableSQLBefore = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'agent_memories'"
            )
        }

        try OpenBurnBarDatabase.migrator.migrate(queue)

        let tableSQLAfter = try queue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'agent_memories'"
            )
        }
        XCTAssertEqual(
            tableSQLBefore, tableSQLAfter,
            "a correct default must not trigger the rebuild — the probe returns early"
        )
        XCTAssertTrue(tableSQLAfter?.contains("DEFAULT 'quarantined'") == true)
    }
}
