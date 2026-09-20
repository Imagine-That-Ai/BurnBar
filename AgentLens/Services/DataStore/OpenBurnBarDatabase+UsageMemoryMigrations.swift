import GRDB

extension OpenBurnBarDatabase {
    /// v61: usage-memory substrate — the Stage-0 candidate spool, the salience
    /// sidecar, typed memory links, and a `source_kind` discriminator on the
    /// extraction job queue. Additive only: `agent_memories` DDL is untouched,
    /// so its daemon/python bootstrap mirrors stay byte-identical, and the
    /// sidecar tables keep salience state out of the mirrored surface entirely.
    ///
    /// This file exists as a byte-identical pair (AgentLens +
    /// OpenBurnBarCore/Sources/OpenBurnBarData); keep both copies in lockstep.
    static func registerUsageMemoryMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v61_usage_memory") { db in
            // Stage-0 output / Stage-1 input. payload_json lives inside the
            // SQLCipher database — the same at-rest posture as
            // memory_body_snapshots.snapshot_json. id is content-derived
            // (sha256(source_ref|content_hash)) so re-mining is idempotent.
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_usage_candidates (
                    id TEXT PRIMARY KEY,
                    source_kind TEXT NOT NULL,
                    source_ref TEXT NOT NULL,
                    thread_logical_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    simhash INTEGER NOT NULL,
                    salience_hint REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    batch_job_id TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_usage_candidates_status_idx
                ON memory_usage_candidates(status, salience_hint, created_at)
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_usage_candidates_simhash_idx
                ON memory_usage_candidates(source_kind, simhash)
                """
            )
            // Salience sidecar: consolidation owns corroboration/source trust;
            // daemon recall owns hit reinforcement for project-memory ranking.
            // A sidecar (not an ALTER on agent_memories) keeps the mirrored
            // agent_memories DDL untouched across app/daemon/python/doc copies.
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_salience (
                    memory_id TEXT PRIMARY KEY,
                    salience REAL NOT NULL,
                    hit_count INTEGER NOT NULL DEFAULT 0,
                    last_reinforced_at TEXT,
                    corroboration INTEGER NOT NULL DEFAULT 1,
                    source_trust REAL NOT NULL,
                    computed_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            // Typed edges for consolidation (near_duplicate | contradicts |
            // supports | promoted_from). tags_json on agent_memories keeps its
            // extraction keywords/tags semantics; links need indexed traversal.
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_links (
                    id TEXT PRIMARY KEY,
                    from_memory_id TEXT NOT NULL,
                    to_memory_id TEXT NOT NULL,
                    link_kind TEXT NOT NULL,
                    score REAL NOT NULL,
                    created_by TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_links_from_idx
                ON memory_links(from_memory_id, link_kind)
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_links_to_idx
                ON memory_links(to_memory_id, link_kind)
                """
            )
            // Job-queue discriminator: existing rows are all chat jobs, so the
            // backfill default is correct as well as safe. The daemon and the
            // python MCP tool never create this table.
            let jobColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(memory_extraction_jobs)")
                .compactMap { $0["name"] as? String }
            if !jobColumns.contains("source_kind") {
                try db.alter(table: "memory_extraction_jobs") { t in
                    t.add(column: "source_kind", .text).notNull().defaults(to: "chat")
                }
            }
        }
    }
}
