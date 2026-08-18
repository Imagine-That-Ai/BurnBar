import GRDB

extension OpenBurnBarDatabase {
    /// Adds STARTED BY attribution (War Room Command Board): who originated the
    /// work a usage row belongs to — you, the Flame, the Wand, a mission, a
    /// Hermes bot/cron, or an external session. Both columns are nullable:
    /// parsers that cannot derive an originator leave the row unattributed
    /// rather than guessing (`BurnBarOriginator` carries the vocabulary).
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
