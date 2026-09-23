import Foundation
@testable import OpenBurnBarDaemon

/// Wave 2.1c-iii test support: completes a daemon-bootstrapped database
/// with the authority schema the migrator owns in production.
///
/// The daemon bootstrap owns its own tables; the migrator owns the
/// authority columns and satellite tables. These fixtures apply the
/// migrator's exact DDL so the lane and socket tests run against the
/// same shape production has.
extension BurnBarProjectCodeMemoryStore {
    func memoryAuthorityTestCompleteSchema() throws {
        // `ensureColumn` is idempotent: the daemon bootstrap already owns
        // `source_kind`, while the migrator owns the rest.
        try ensureColumn(table: "agent_memories", column: "source_kind", definition: "TEXT NOT NULL DEFAULT 'code'")
        try ensureColumn(table: "agent_memories", column: "user_id", definition: "TEXT")
        try ensureColumn(table: "agent_memories", column: "agent_id", definition: "TEXT")
        try ensureColumn(table: "agent_memories", column: "run_id", definition: "TEXT")
        try ensureColumn(table: "agent_memories", column: "app_id", definition: "TEXT")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_body_snapshots (
                id TEXT PRIMARY KEY,
                memory_id TEXT NOT NULL UNIQUE,
                body_ref TEXT NOT NULL UNIQUE,
                snapshot_json TEXT NOT NULL,
                body_hash TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_provenance (
                id TEXT PRIMARY KEY,
                memory_id TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                thread_logical_id TEXT NOT NULL,
                message_id TEXT,
                role TEXT NOT NULL,
                authored_at TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                occurrence INTEGER NOT NULL DEFAULT 0,
                xdevice_hmac TEXT NOT NULL,
                citation_state TEXT NOT NULL DEFAULT 'live',
                created_at TEXT NOT NULL
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_fact_tombstones (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                memory_id TEXT NOT NULL,
                source_refs_json TEXT NOT NULL,
                reason TEXT NOT NULL,
                created_at TEXT NOT NULL,
                replicated_at TEXT
            )
            """,
            []
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS memory_source_tombstones (
                id TEXT PRIMARY KEY,
                user_id TEXT,
                thread_logical_id TEXT NOT NULL,
                message_id TEXT,
                content_hash TEXT,
                reason TEXT NOT NULL,
                created_at TEXT NOT NULL,
                replicated_at TEXT
            )
            """,
            []
        )
    }
}
