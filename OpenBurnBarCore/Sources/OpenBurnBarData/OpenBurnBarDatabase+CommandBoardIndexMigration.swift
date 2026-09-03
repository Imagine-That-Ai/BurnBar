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
    }
}
