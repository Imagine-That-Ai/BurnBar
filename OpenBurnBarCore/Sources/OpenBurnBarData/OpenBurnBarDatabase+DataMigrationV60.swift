import GRDB

extension OpenBurnBarDatabase {
    /// v60 — bind a canonical approved-memory id to each Founder Plan step.
    ///
    /// Fresh databases already receive the column from the v59 create-table
    /// statement. The conditional keeps this migration safe for both fresh and
    /// upgraded profiles.
    static func registerFounderLensAuthorityMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v60_founder_lens_authority") { db in
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(ai_inbox_plan_steps)")
                .compactMap { $0["name"] as String? }
            if columns.contains("memory_id") == false {
                try db.alter(table: "ai_inbox_plan_steps") { table in
                    table.add(column: "memory_id", .text)
                }
            }
        }
    }
}
