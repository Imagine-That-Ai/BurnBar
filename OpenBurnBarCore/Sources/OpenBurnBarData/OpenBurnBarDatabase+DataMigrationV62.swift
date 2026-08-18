import GRDB

extension OpenBurnBarDatabase {
    /// Parity mirror of the app-side v62 War Room originator migration.
    static func registerWarRoomOriginatorMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v62_war_room_originator") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "originatorKind", .text)
                t.add(column: "originatorRef", .text)
            }
            try db.create(
                index: "token_usage_originator_time_idx",
                on: "token_usage",
                columns: ["originatorKind", "startTime"],
                ifNotExists: true
            )
        }
    }
}
