import GRDB

extension OpenBurnBarDatabase {
    static func registerChatMemoryAuthorityMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v51_chat_memory_authority") { db in
            let agentMemoryColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(agent_memories)")
                .compactMap { $0["name"] as? String }
            if !agentMemoryColumns.contains("source_kind") {
                try db.alter(table: "agent_memories") { t in
                    t.add(column: "source_kind", .text).notNull().defaults(to: "code")
                }
            }
            if !agentMemoryColumns.contains("review_status") {
                try db.alter(table: "agent_memories") { t in
                    t.add(column: "review_status", .text).notNull().defaults(to: "quarantined")
                }
                try db.execute(sql: "UPDATE agent_memories SET review_status = 'approved' WHERE source_kind = 'code'")
            }
            if !agentMemoryColumns.contains("user_id") {
                try db.alter(table: "agent_memories") { t in
                    t.add(column: "user_id", .text)
                }
            }
            if !agentMemoryColumns.contains("agent_id") {
                try db.alter(table: "agent_memories") { t in
                    t.add(column: "agent_id", .text)
                }
            }
            if !agentMemoryColumns.contains("run_id") {
                try db.alter(table: "agent_memories") { t in
                    t.add(column: "run_id", .text)
                }
            }
            if !agentMemoryColumns.contains("app_id") {
                try db.alter(table: "agent_memories") { t in
                    t.add(column: "app_id", .text)
                }
            }
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS agent_memories_chat_scope_idx
                ON agent_memories(source_kind, user_id, agent_id, run_id, app_id, updated_at)
                """
            )
            try db.execute(
                sql: """
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
                """
            )
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS memory_provenance_memory_idx ON memory_provenance(memory_id)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS memory_provenance_hmac_idx ON memory_provenance(xdevice_hmac)")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS memory_provenance_msg_idx ON memory_provenance(message_id)")
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_extraction_jobs (
                    id TEXT PRIMARY KEY,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    thread_id TEXT NOT NULL,
                    message_id TEXT NOT NULL,
                    scope_json TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    not_before TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_extraction_jobs_status_idx
                ON memory_extraction_jobs(status, not_before)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_embedding_refs (
                    memory_id TEXT NOT NULL,
                    embedding_version_id TEXT NOT NULL,
                    dimension INTEGER NOT NULL,
                    vector BLOB NOT NULL,
                    norm REAL NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (memory_id, embedding_version_id)
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_embedding_refs_version_idx
                ON memory_embedding_refs(embedding_version_id, dimension)
                """
            )
            try db.execute(
                sql: """
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
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_body_snapshots_source_idx
                ON memory_body_snapshots(source_kind, updated_at)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_source_tombstones (
                    id TEXT PRIMARY KEY,
                    thread_logical_id TEXT NOT NULL,
                    message_id TEXT,
                    content_hash TEXT,
                    reason TEXT NOT NULL,
                    created_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_source_tombstones_thread_idx
                ON memory_source_tombstones(thread_logical_id)
                """
            )
        }
        migrator.registerMigration("v52_memory_extraction_job_intent_and_lease") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(memory_extraction_jobs)")
                .compactMap { $0["name"] as? String }
            if !columns.contains("thread_logical_id") {
                try db.alter(table: "memory_extraction_jobs") { t in
                    t.add(column: "thread_logical_id", .text).notNull().defaults(to: "")
                }
                try db.execute(
                    sql: """
                    UPDATE memory_extraction_jobs
                    SET thread_logical_id = thread_id
                    WHERE thread_logical_id = ''
                    """
                )
            }
            if !columns.contains("prompt_version") {
                try db.alter(table: "memory_extraction_jobs") { t in
                    t.add(column: "prompt_version", .text).notNull().defaults(to: "legacy-unknown")
                }
            }
            if !columns.contains("lease_expires_at") {
                try db.alter(table: "memory_extraction_jobs") { t in
                    t.add(column: "lease_expires_at", .text)
                }
                try db.execute(
                    sql: """
                    UPDATE memory_extraction_jobs
                    SET lease_expires_at = updated_at
                    WHERE status = 'running' AND lease_expires_at IS NULL
                    """
                )
            }
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_extraction_jobs_lease_idx
                ON memory_extraction_jobs(status, lease_expires_at)
                """
            )
        }
        migrator.registerMigration("v53_memory_forget_outbox") { db in
            let sourceColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(memory_source_tombstones)")
                .compactMap { $0["name"] as? String }
            if !sourceColumns.contains("user_id") {
                try db.alter(table: "memory_source_tombstones") { t in
                    t.add(column: "user_id", .text)
                }
            }
            if !sourceColumns.contains("replicated_at") {
                try db.alter(table: "memory_source_tombstones") { t in
                    t.add(column: "replicated_at", .text)
                }
            }
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_source_tombstones_pending_idx
                ON memory_source_tombstones(user_id, replicated_at, created_at)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_fact_tombstones (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    memory_id TEXT NOT NULL,
                    source_refs_json TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    replicated_at TEXT
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_fact_tombstones_pending_idx
                ON memory_fact_tombstones(user_id, replicated_at, created_at)
                """
            )
        }
    }
}
