import Foundation
import GRDB

extension OpenBurnBarDatabase {
    /// War Room Face C: the Command Board slices `token_usage` by a start-time
    /// window and groups by session.
    ///
    /// Every existing `startTime` index is compound with a leading column the
    /// board does not filter on (`executionSourceID`, `billingKind`,
    /// `originatorKind`), so none of them serve `WHERE startTime >= ?`. Without
    /// this index the board's `LIMIT` applies only after the whole window has
    /// been grouped and sorted, which on a heavy user's largest table is a
    /// full scan per open.
    static func registerCommandBoardIndexMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v64_token_usage_start_time_index") { db in
            try db.create(
                index: "token_usage_start_time_idx",
                on: "token_usage",
                columns: ["startTime"],
                ifNotExists: true
            )
        }
        // The daemon owns quarantined memory bodies, but the shared encrypted
        // database schema must be complete no matter which first-party process
        // opens a fresh profile first.
        migrator.registerMigration("v65_memory_quarantine_bodies") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS memory_quarantine_bodies (
                    memory_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    body TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS memory_quarantine_bodies_project_idx
                ON memory_quarantine_bodies(project_id)
                """
            )
        }
        // Approved bodies for memories the Memory MCP engine mirrors. The engine's
        // store is the canonical copy; this is the shared-database copy blind sync
        // seals and uploads, so it carries the engine's own 128-bit memory id (the
        // daemon's id is derived from `projectID:bodyHash` and differs between a
        // member's devices). Written by the daemon, read by the app's sync lane.
        migrator.registerMigration("v66_agent_memory_bodies") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS agent_memory_bodies (
                    memory_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    engine_memory_id TEXT NOT NULL,
                    body TEXT NOT NULL,
                    body_hash TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS agent_memory_bodies_engine_idx
                ON agent_memory_bodies(engine_memory_id)
                """
            )
        }
        // Landing zone for memory facts pulled back down from the member's own
        // cloud vault (Memory Blind Sync PR-2). Pulled rows are deliberately NOT
        // written into `agent_memories`: that table is this device's own upload
        // source, so a remote row landing there would be re-sealed and re-uploaded
        // in a loop. `payload_json` is the opened plaintext payload and rests in
        // SQLCipher exactly as `memory_body_snapshots` does. The engine drains
        // unapplied rows through the daemon and stamps `applied_at`.
        migrator.registerMigration("v67_agent_memory_inbox") { db in
            try db.execute(
                sql: """
                CREATE TABLE IF NOT EXISTS agent_memory_inbox (
                    doc_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    engine_memory_id TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    remote_updated_at TEXT NOT NULL,
                    received_at TEXT NOT NULL,
                    applied_at TEXT
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS agent_memory_inbox_user_applied_idx
                ON agent_memory_inbox(user_id, applied_at)
                """
            )
        }
        // Review #2565: v51's `add(column:)` is a no-op on an `agent_memories`
        // table that already carried `review_status` — and a daemon binary that
        // bootstrapped the shared table first could have written it with
        // `DEFAULT 'approved'`. SQLite never updates a column default on
        // `ALTER`/`CREATE IF NOT EXISTS`, so those installs keep a fail-open
        // default: any insert omitting `review_status` lands pre-approved. The
        // only repair is a table rebuild, done generically off `table_info` so
        // every column — including ones added after this migration was written —
        // survives verbatim. The daemon's bootstrap runs the same repair, so
        // the default is corrected no matter which first-party process opens a
        // stale profile first.
        migrator.registerMigration("v68_agent_memories_review_default_repair") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(agent_memories)")
            guard columns.isEmpty == false,
                  let reviewColumn = columns.first(where: { ($0["name"] as? String) == "review_status" }) else { return }
            // `dflt_value` arrives as declared — `'quarantined'` with quotes —
            // or NULL when no default exists; both need the rebuild.
            let declaredDefault = (reviewColumn["dflt_value"] as? String)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            guard declaredDefault != "quarantined" else { return }

            var definitions: [String] = []
            var quotedNames: [String] = []
            var primaryKeyColumns: [String] = []
            for column in columns {
                guard let name = column["name"] as? String, name.isEmpty == false else { continue }
                let type = (column["type"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "TEXT"
                var definition = "\"\(name)\" \(type)"
                let notNull: Int64 = column["notnull"] ?? 0
                if notNull == 1 { definition += " NOT NULL" }
                if name == "review_status" {
                    definition += " DEFAULT 'quarantined'"
                } else if let other = column["dflt_value"] as? String {
                    definition += " DEFAULT \(other)"
                }
                definitions.append(definition)
                quotedNames.append("\"\(name)\"")
                let pk: Int64 = column["pk"] ?? 0
                if pk > 0 { primaryKeyColumns.append("\"\(name)\"") }
            }
            if primaryKeyColumns.isEmpty == false {
                definitions.append("PRIMARY KEY (\(primaryKeyColumns.joined(separator: ", ")))")
            }

            try db.execute(
                sql: """
                CREATE TABLE agent_memories__review_default_repair (
                    \(definitions.joined(separator: ",\n    "))
                )
                """
            )
            let names = quotedNames.joined(separator: ", ")
            try db.execute(
                sql: "INSERT INTO agent_memories__review_default_repair (\(names)) SELECT \(names) FROM agent_memories"
            )
            try db.execute(sql: "DROP TABLE agent_memories")
            try db.execute(sql: "ALTER TABLE agent_memories__review_default_repair RENAME TO agent_memories")
            // DROP took the table's indexes with it; recreate the three the
            // schema owns. `chat_scope_idx` names columns the daemon bootstrap
            // may not have added, so it reappears only when ALL of them exist.
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS agent_memories_project_idx
                ON agent_memories(project_id, scope, updated_at)
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS agent_memories_review_status_idx
                ON agent_memories(project_id, review_status, updated_at)
                """
            )
            let scopeColumns: Set<String> = ["\"user_id\"", "\"agent_id\"", "\"run_id\"", "\"app_id\""]
            if scopeColumns.isSubset(of: Set(quotedNames)) {
                try db.execute(
                    sql: """
                    CREATE INDEX IF NOT EXISTS agent_memories_chat_scope_idx
                    ON agent_memories(source_kind, user_id, agent_id, run_id, app_id, updated_at)
                    """
                )
            }
        }
    }
}
