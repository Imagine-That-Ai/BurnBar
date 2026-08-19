import GRDB

extension OpenBurnBarDatabase {
    /// War Room W6 (the rhythm): recurring work the fleet performs without
    /// being asked each time.
    ///
    /// The cadence is stored decomposed — a kind discriminator plus the four
    /// components any one kind may use — rather than as an opaque blob, so a
    /// human reading the table can tell what a row means and SQL can filter on
    /// it. `StandingOrderRow` in OpenBurnBarKernel owns the encoding.
    ///
    /// `targetBodyId` is nullable on purpose: null means "let the Flame choose
    /// at fire time", which is the default and the reason an order survives the
    /// fleet changing shape between runs.
    static func registerStandingOrdersMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v63_standing_orders") { db in
            try db.create(table: "standing_orders", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("instruction", .text).notNull()
                t.column("cadenceKind", .text).notNull()
                t.column("cadenceMinutes", .integer)
                t.column("cadenceHour", .integer)
                t.column("cadenceMinute", .integer)
                t.column("cadenceWeekday", .integer)
                t.column("targetBodyId", .text)
                t.column("requiredCapabilities", .text).notNull().defaults(to: "")
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("lastFiredAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // The scheduler's only hot query is "what is enabled and overdue",
            // which this covers end to end.
            try db.create(
                index: "standing_orders_enabled_fired_idx",
                on: "standing_orders",
                columns: ["isEnabled", "lastFiredAt"],
                ifNotExists: true
            )
        }
    }
}
