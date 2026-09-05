import GRDB

extension OpenBurnBarDatabase {
    /// v66 — Receipts accomplishments, quality review, and harness metadata.
    ///
    /// Additive schema migration extending the `receipts` table with:
    /// - `harness`: CLI harness name (e.g. "Claude Code", "Codex", "Cursor")
    /// - `actualAccomplishmentsJSON`: JSON array of concrete delivered accomplishments
    /// - `qualityReviewJSON`: JSON object of multi-factor quality review rubric, grade, and notes
    /// - `achievementsJSON`: JSON array of achievement badges (speed demon, cache beast, etc.)
    /// - `gitStatsJSON`: JSON object of git changes (commits, insertions, deletions, files)
    static func registerReceiptsAccomplishmentsAndQualityMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v66_receipts_accomplishments_and_quality") { db in
            try db.alter(table: "receipts") { t in
                t.add(column: "harness", .text).notNull().defaults(to: "")
                t.add(column: "actualAccomplishmentsJSON", .text).notNull().defaults(to: "[]")
                t.add(column: "qualityReviewJSON", .text).notNull().defaults(to: "{}")
                t.add(column: "achievementsJSON", .text).notNull().defaults(to: "[]")
                t.add(column: "gitStatsJSON", .text).notNull().defaults(to: "{}")
            }

            try db.create(
                index: "receipts_harness_idx",
                on: "receipts",
                columns: ["harness"],
                ifNotExists: true
            )
        }
    }
}
