import GRDB

extension OpenBurnBarDatabase {
    /// v65 — Receipts substrate: durable itemized receipts with token economics,
    /// cache efficiency, SHA-256 provenance signature, and sub-millisecond FTS5 search.
    static func registerReceiptsSubstrateMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v65_receipts_substrate") { db in
            try db.create(table: "receipts", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull()
                t.column("projectName", .text).notNull()
                t.column("provider", .text).notNull()
                t.column("modelName", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("durationSeconds", .double).notNull().defaults(to: 0.0)
                t.column("inputTokens", .integer).notNull().defaults(to: 0)
                t.column("outputTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheReadTokens", .integer).notNull().defaults(to: 0)
                t.column("cacheWriteTokens", .integer).notNull().defaults(to: 0)
                t.column("totalCostUSD", .double).notNull().defaults(to: 0.0)
                t.column("estimatedCacheSavingsUSD", .double).notNull().defaults(to: 0.0)
                t.column("cacheHitPercentage", .double).notNull().defaults(to: 0.0)
                t.column("tokensPerSecond", .double).notNull().defaults(to: 0.0)
                t.column("promptSummary", .text).notNull().defaults(to: "")
                t.column("filesTouchedJSON", .text).notNull().defaults(to: "[]")
                t.column("toolsUsedJSON", .text).notNull().defaults(to: "[]")
                t.column("gitBranch", .text)
                t.column("gitCommit", .text)
                t.column("isStarred", .boolean).notNull().defaults(to: false)
                t.column("contentSignature", .text).notNull()
                t.column("createdAt", .datetime).notNull().defaults(to: Date())
            }

            try db.create(
                index: "receipts_session_idx",
                on: "receipts",
                columns: ["sessionId"],
                ifNotExists: true
            )
            try db.create(
                index: "receipts_timestamp_idx",
                on: "receipts",
                columns: ["timestamp"],
                ifNotExists: true
            )
            try db.create(
                index: "receipts_project_idx",
                on: "receipts",
                columns: ["projectName"],
                ifNotExists: true
            )
            try db.create(
                index: "receipts_provider_idx",
                on: "receipts",
                columns: ["provider"],
                ifNotExists: true
            )
            try db.create(
                index: "receipts_cost_idx",
                on: "receipts",
                columns: ["totalCostUSD"],
                ifNotExists: true
            )
            try db.create(
                index: "receipts_starred_idx",
                on: "receipts",
                columns: ["isStarred"],
                ifNotExists: true
            )

            // FTS5 Virtual Table for sub-millisecond search across prompt summaries, files, tools, models, projects
            try db.execute(sql: "DROP TRIGGER IF EXISTS receipts_ai")
            try db.execute(sql: "DROP TRIGGER IF EXISTS receipts_ad")
            try db.execute(sql: "DROP TRIGGER IF EXISTS receipts_au")
            try db.execute(sql: "DROP TABLE IF EXISTS receipts_fts")

            try db.execute(
                sql: """
                CREATE VIRTUAL TABLE receipts_fts USING fts5(
                    promptSummary,
                    filesTouched,
                    toolsUsed,
                    modelName,
                    projectName,
                    tokenize='porter unicode61'
                )
                """
            )

            try db.execute(
                sql: """
                INSERT INTO receipts_fts(rowid, promptSummary, filesTouched, toolsUsed, modelName, projectName)
                SELECT rowid, promptSummary, filesTouchedJSON, toolsUsedJSON, modelName, projectName FROM receipts
                """
            )

            try db.execute(
                sql: """
                CREATE TRIGGER receipts_ai AFTER INSERT ON receipts BEGIN
                    INSERT INTO receipts_fts(rowid, promptSummary, filesTouched, toolsUsed, modelName, projectName)
                    VALUES (new.rowid, new.promptSummary, new.filesTouchedJSON, new.toolsUsedJSON, new.modelName, new.projectName);
                END
                """
            )

            try db.execute(
                sql: """
                CREATE TRIGGER receipts_ad AFTER DELETE ON receipts BEGIN
                    DELETE FROM receipts_fts WHERE rowid = old.rowid;
                END
                """
            )

            try db.execute(
                sql: """
                CREATE TRIGGER receipts_au AFTER UPDATE ON receipts BEGIN
                    DELETE FROM receipts_fts WHERE rowid = old.rowid;
                    INSERT INTO receipts_fts(rowid, promptSummary, filesTouched, toolsUsed, modelName, projectName)
                    VALUES (new.rowid, new.promptSummary, new.filesTouchedJSON, new.toolsUsedJSON, new.modelName, new.projectName);
                END
                """
            )
        }
    }
}
