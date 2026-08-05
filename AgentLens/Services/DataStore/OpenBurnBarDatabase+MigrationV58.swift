import GRDB

extension OpenBurnBarDatabase {
    /// v58 — AI Inbox tables.
    ///
    /// The daemon's `BurnBarAIInboxStore` creates these same tables with
    /// `IF NOT EXISTS` guards when it opens (so a profile whose app has
    /// not migrated yet still gets a working inbox). This migration is the app
    /// side of that contract: it guarantees the tables exist even on a profile
    /// where the inbox has never been enabled, so app-side reads can be written
    /// without defensive `sqlite_master` probes.
    ///
    /// Because both writers use `IF NOT EXISTS`, either order is safe and
    /// re-running is a no-op.
    ///
    /// Write ownership (there is no contention by construction):
    ///   • daemon writes `ai_inbox_items`, `ai_inbox_runs`, `ai_inbox_state`
    ///   • app writes `ai_inbox_item_state` only
    ///
    /// The statements below are kept byte-identical to
    /// `BurnBarAIInboxSchema` in the daemon and to the OpenBurnBarData mirror of
    /// this file; `AIInboxSchemaParityTests` fails the build if they drift.
    static func registerAIInboxMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v58_ai_inbox") { db in
            for statement in Self.aiInboxSchemaStatements {
                try db.execute(sql: statement)
            }
        }
    }

    /// Canonical AI Inbox DDL. See `BurnBarAIInboxSchema.statements`.
    static let aiInboxSchemaStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_items (
            id TEXT PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            kind TEXT NOT NULL,
            priority INTEGER NOT NULL,
            state TEXT NOT NULL DEFAULT 'new',
            title TEXT NOT NULL,
            summary_md TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            project_id TEXT,
            project_name TEXT,
            occurrence_count INTEGER NOT NULL DEFAULT 1,
            first_seen_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            resolved_at TEXT,
            resolution_note TEXT,
            tick_id TEXT NOT NULL,
            model_provenance TEXT NOT NULL DEFAULT 'local-rules'
        )
        """,
        """
        CREATE UNIQUE INDEX IF NOT EXISTS ai_inbox_items_open_fingerprint_idx
            ON ai_inbox_items(fingerprint) WHERE state IN ('new', 'updated')
        """,
        """
        CREATE INDEX IF NOT EXISTS ai_inbox_items_state_seen_idx
            ON ai_inbox_items(state, last_seen_at DESC)
        """,
        """
        CREATE INDEX IF NOT EXISTS ai_inbox_items_project_idx
            ON ai_inbox_items(project_id)
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_runs (
            tick_id TEXT PRIMARY KEY,
            started_at TEXT NOT NULL,
            finished_at TEXT,
            gate_result TEXT NOT NULL,
            gate_signature TEXT NOT NULL,
            egress_mode TEXT NOT NULL,
            llm_calls INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0,
            items_new INTEGER NOT NULL DEFAULT 0,
            items_updated INTEGER NOT NULL DEFAULT 0,
            items_resolved INTEGER NOT NULL DEFAULT 0,
            error TEXT
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS ai_inbox_runs_started_idx
            ON ai_inbox_runs(started_at DESC)
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_state (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS ai_inbox_item_state (
            item_id TEXT PRIMARY KEY,
            read_at TEXT,
            archived_at TEXT,
            snoozed_until TEXT,
            feedback TEXT,
            updated_at TEXT NOT NULL
        )
        """
    ]
}
