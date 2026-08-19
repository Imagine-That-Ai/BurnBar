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
    }
}
