import GRDB

extension OpenBurnBarDatabase {
    /// v59 — Founder Lens tables: reply threads, the Founder Plan Ledger, and
    /// the app→daemon approved-memory export.
    ///
    /// Same three-writer contract as v58: the daemon's `BurnBarAIInboxStore`
    /// self-heals these tables with `IF NOT EXISTS` on open, and this migration
    /// guarantees they exist app-side so reads never need `sqlite_master`
    /// probes. Either order is safe; re-running is a no-op.
    ///
    /// Write ownership:
    ///   • daemon writes `ai_inbox_threads`, `ai_inbox_thread_messages`,
    ///     `ai_inbox_plans`, `ai_inbox_plan_steps`, `ai_inbox_plan_events`
    ///     (all mutations arrive via human-confirmed RPCs)
    ///   • daemon writes `ai_inbox_memory_export` rows on behalf of the app's
    ///     export RPC — the app never touches these tables directly
    ///
    /// The statements below are kept byte-identical to
    /// `BurnBarAIInboxSchema.founderLensStatements` in the daemon and to the
    /// OpenBurnBarData mirror of this file; `AIInboxSchemaParityTests` fails
    /// the build if they drift.
    static func registerFounderLensMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v59_founder_lens") { db in
            for statement in Self.founderLensSchemaStatements {
                try db.execute(sql: statement)
            }
        }
    }

    /// Canonical Founder Lens DDL. See `BurnBarAIInboxSchema.founderLensStatements`.
    static let founderLensSchemaStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_threads (
            fingerprint TEXT PRIMARY KEY,
            item_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            turn_count INTEGER NOT NULL DEFAULT 0,
            total_cost_usd REAL NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_thread_messages (
            id TEXT PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            role TEXT NOT NULL,
            body_md TEXT NOT NULL,
            plan_candidates_json TEXT,
            model_provenance TEXT,
            cost_usd REAL NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS ai_inbox_thread_messages_thread_idx
            ON ai_inbox_thread_messages(fingerprint, created_at)
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_plans (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            horizon TEXT NOT NULL,
            pack TEXT NOT NULL,
            status TEXT NOT NULL,
            summary_md TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            origin_fingerprint TEXT,
            memory_id TEXT,
            pensieve_vector_id TEXT,
            grade_avg REAL,
            metrics_json TEXT
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS ai_inbox_plans_status_idx
            ON ai_inbox_plans(status, updated_at DESC)
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_plan_steps (
            id TEXT PRIMARY KEY,
            plan_id TEXT NOT NULL,
            parent_step_id TEXT,
            ordinal INTEGER NOT NULL,
            title TEXT NOT NULL,
            body_md TEXT NOT NULL,
            status TEXT NOT NULL,
            next_move_md TEXT,
            evidence_ids_json TEXT,
            mission_id TEXT,
            followup_id TEXT,
            memory_id TEXT,
            inbox_fingerprint TEXT,
            grade INTEGER,
            grade_note_md TEXT,
            graded_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            completed_at TEXT
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS ai_inbox_plan_steps_plan_idx
            ON ai_inbox_plan_steps(plan_id, ordinal)
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_plan_events (
            id TEXT PRIMARY KEY,
            plan_id TEXT NOT NULL,
            step_id TEXT,
            event TEXT NOT NULL,
            detail_json TEXT,
            created_at TEXT NOT NULL
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS ai_inbox_plan_events_plan_idx
            ON ai_inbox_plan_events(plan_id, created_at)
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_memory_export (
            memory_id TEXT PRIMARY KEY,
            provenance TEXT NOT NULL,
            snippet_md TEXT NOT NULL,
            approved_at TEXT NOT NULL,
            exported_at TEXT NOT NULL
        )
        """
    ]
}
