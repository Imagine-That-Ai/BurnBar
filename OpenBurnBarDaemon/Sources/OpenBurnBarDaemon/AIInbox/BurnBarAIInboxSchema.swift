import Foundation
import OpenBurnBarEngine

/// Canonical DDL for the AI Inbox tables.
///
/// This is the SINGLE source of truth. It is executed verbatim in two places:
///
///   1. `BurnBarAIInboxStore.bootstrapSchema()` — the daemon opens the shared
///      database with `SQLITE_OPEN_CREATE` and self-heals its own tables, so the
///      inbox works on a profile whose app has not yet run migration v58.
///   2. The app's GRDB migration `v58_ai_inbox` — mirrored character-for-character
///      in both migration trees so the app never sees a table shape the daemon
///      did not write.
///
/// A parity test asserts all three copies are byte-identical. When you change a
/// statement here, change it in the two migration files in the same commit.
///
/// Ownership rules (why there is no write contention):
///   • daemon writes `ai_inbox_items`, `ai_inbox_runs`, `ai_inbox_state`
///   • app writes `ai_inbox_item_state` only
///   • each side reads the other's tables, never writes them
enum BurnBarAIInboxSchema {
    /// Bumped when the payload JSON shape changes in a way readers must notice.
    static let version = 1

    /// Ordered DDL statements. Order matters: tables before their indexes.
    static let statements: [String] = [
        createItems,
        createItemsOpenFingerprintIndex,
        createItemsStateSeenIndex,
        createItemsProjectIndex,
        createRuns,
        createRunsStartedIndex,
        createState,
        createItemState
    ]

    /// Founder Lens DDL (threads, plan ledger, memory export) — the v59 wave.
    /// Kept as a separate list so the v58 parity test stays byte-stable while
    /// the v59 parity test covers exactly these statements.
    static let founderLensStatements: [String] = [
        createThreads,
        createThreadMessages,
        createThreadMessagesThreadIndex,
        createPlans,
        createPlansStatusIndex,
        createPlanSteps,
        createPlanStepsPlanIndex,
        createPlanEvents,
        createPlanEventsPlanIndex,
        createMemoryExport
    ]

    // MARK: - Items

    /// One row per surfaced observation.
    ///
    /// `fingerprint` is the stable identity of a *condition* ("this workflow is
    /// wasting cycles"), while `id` is the identity of a *row*. That split is
    /// what lets a recurring condition update in place (bumping
    /// `occurrence_count`) instead of flooding the list, while still keeping
    /// resolved history for trend reading.
    static let createItems = """
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
        """

    /// The dedupe invariant, enforced by the database rather than by convention:
    /// at most ONE open item per fingerprint. Partial (`WHERE state IN …`) so
    /// resolved rows accumulate freely as history.
    static let createItemsOpenFingerprintIndex = """
        CREATE UNIQUE INDEX IF NOT EXISTS ai_inbox_items_open_fingerprint_idx
            ON ai_inbox_items(fingerprint) WHERE state IN ('new', 'updated')
        """

    /// Backs the default list query (open items, newest first).
    static let createItemsStateSeenIndex = """
        CREATE INDEX IF NOT EXISTS ai_inbox_items_state_seen_idx
            ON ai_inbox_items(state, last_seen_at DESC)
        """

    static let createItemsProjectIndex = """
        CREATE INDEX IF NOT EXISTS ai_inbox_items_project_idx
            ON ai_inbox_items(project_id)
        """

    // MARK: - Runs

    /// Per-tick telemetry — written even for skipped ticks, so "is the loop
    /// alive and is it actually free?" is answerable from data instead of logs.
    static let createRuns = """
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
        """

    static let createRunsStartedIndex = """
        CREATE INDEX IF NOT EXISTS ai_inbox_runs_started_idx
            ON ai_inbox_runs(started_at DESC)
        """

    // MARK: - State

    /// Daemon-owned key/value scratch: config, gate signature, rolling cost
    /// baselines, GitHub ETags, suppression fingerprints, notification stamps.
    /// A KV table (rather than a column per concept) keeps the observatory
    /// evolvable without a migration for every new heuristic.
    static let createState = """
        CREATE TABLE IF NOT EXISTS ai_inbox_state (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """

    // MARK: - Item state (app-owned)

    /// Read/archive/snooze/feedback. Split into its own table precisely so the
    /// app can write user intent without ever touching a daemon-owned row.
    static let createItemState = """
        CREATE TABLE IF NOT EXISTS ai_inbox_item_state (
            item_id TEXT PRIMARY KEY,
            read_at TEXT,
            archived_at TEXT,
            snoozed_until TEXT,
            feedback TEXT,
            updated_at TEXT NOT NULL
        )
        """

    // MARK: - Threads (v59, daemon-owned)

    /// One thread per *condition*, keyed by fingerprint rather than item id
    /// (loophole L1): items resolve and re-open as the world changes, but the
    /// conversation about a condition must survive that churn. `item_id` is a
    /// soft bind to the most recent row for UI navigation.
    static let createThreads = """
        CREATE TABLE IF NOT EXISTS ai_inbox_threads (
            fingerprint TEXT PRIMARY KEY,
            item_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            turn_count INTEGER NOT NULL DEFAULT 0,
            total_cost_usd REAL NOT NULL DEFAULT 0
        )
        """

    /// Individual turns. `role` is 'user' or 'assistant'; assistant rows carry
    /// model provenance and cost so spend is attributable per reply.
    static let createThreadMessages = """
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
        """

    static let createThreadMessagesThreadIndex = """
        CREATE INDEX IF NOT EXISTS ai_inbox_thread_messages_thread_idx
            ON ai_inbox_thread_messages(fingerprint, created_at)
        """

    // MARK: - Founder Plan Ledger (v59, daemon-owned)

    /// Durable business/engineering plans compounded from inbox suggestions.
    /// Rows are created only through the accept RPC (human-confirmed) — the
    /// analyst can propose, never write.
    static let createPlans = """
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
        """

    static let createPlansStatusIndex = """
        CREATE INDEX IF NOT EXISTS ai_inbox_plans_status_idx
            ON ai_inbox_plans(status, updated_at DESC)
        """

    static let createPlanSteps = """
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
        """

    static let createPlanStepsPlanIndex = """
        CREATE INDEX IF NOT EXISTS ai_inbox_plan_steps_plan_idx
            ON ai_inbox_plan_steps(plan_id, ordinal)
        """

    /// Append-only audit of plan lifecycle: accepts, status transitions,
    /// grades, promotions. The observability half of "executed, audited,
    /// graded" — if the system can't explain what it did, it didn't do it.
    static let createPlanEvents = """
        CREATE TABLE IF NOT EXISTS ai_inbox_plan_events (
            id TEXT PRIMARY KEY,
            plan_id TEXT NOT NULL,
            step_id TEXT,
            event TEXT NOT NULL,
            detail_json TEXT,
            created_at TEXT NOT NULL
        )
        """

    static let createPlanEventsPlanIndex = """
        CREATE INDEX IF NOT EXISTS ai_inbox_plan_events_plan_idx
            ON ai_inbox_plan_events(plan_id, created_at)
        """

    // MARK: - Memory export (v59, app→daemon bridge)

    /// Approved chat-authority snippets pushed BY THE APP so the headless
    /// daemon can cite durable facts (loophole L21). The daemon treats these
    /// as untrusted data (G8-fenced at prompt time); the app is the sole
    /// writer via the export RPC and re-pushes the full set on each approval,
    /// so a revoked memory disappears here too.
    static let createMemoryExport = """
        CREATE TABLE IF NOT EXISTS ai_inbox_memory_export (
            memory_id TEXT PRIMARY KEY,
            provenance TEXT NOT NULL,
            snippet_md TEXT NOT NULL,
            approved_at TEXT NOT NULL,
            exported_at TEXT NOT NULL
        )
        """

    // MARK: - Well-known state keys

    enum StateKey {
        static let config = "config"
        static let gateSignature = "gate_signature"
        static let observatory = "observatory"
        static let githubETags = "gh_etags"
        static let suppressedFingerprints = "suppressed_fingerprints"
        static let costBaselines = "cost_baselines"
        static let notificationStamps = "notification_stamps"
        static let tickCounter = "tick_counter"
        /// Learned per-kind usefulness. See `BurnBarAIInboxCalibration`.
        static let calibration = "calibration"
        /// Feedback rows already folded into the calibration, so a 👍 is counted
        /// once rather than on every tick that sees it.
        static let consumedFeedback = "consumed_feedback"
    }
}
