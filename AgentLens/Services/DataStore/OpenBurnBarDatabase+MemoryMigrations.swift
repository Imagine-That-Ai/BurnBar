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
                    t.add(column: "review_status", .text).notNull().defaults(to: "approved")
                }
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
    }
}
