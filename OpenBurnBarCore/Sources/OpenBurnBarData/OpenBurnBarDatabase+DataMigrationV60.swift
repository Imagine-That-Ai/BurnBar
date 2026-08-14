import GRDB

extension OpenBurnBarDatabase {
    /// v60 — billing provenance: real per-token API dollars vs the imputed
    /// list-price value of work that ran inside a flat subscription plan.
    ///
    /// `billingKind` is one of `api` / `subscription` / `unknown`
    /// (`BurnBarBillingKind` in OpenBurnBarKernel). `unknown` is the honest
    /// bucket — consumers surface it separately, never fold it silently into
    /// either side. Writers stamp the kind at insert time; the backfill below
    /// classifies history deterministically and conservatively:
    ///
    ///   • `billing_api` rows ARE the provider's bill → `api`.
    ///   • `daemon` rows come from the daemon gateway, which only ever dials
    ///     key-backed provider slots → `api`.
    ///   • `provider_log` rows from plan-first harnesses (Claude Code on Max,
    ///     Codex on ChatGPT, Cursor, Copilot, Factory, Junie, Windsurf, Warp,
    ///     Cursor Agent) → `subscription`.
    ///   • `provider_log` rows from bring-your-own-key harnesses (Aider,
    ///     Hermes, DeepSeek, OpenAI, xAI) → `api`.
    ///   • Everything else stays `unknown` — a wrong guess here would corrupt
    ///     the money/imputed split forever, an `unknown` can be reclassified.
    ///
    /// Kept byte-identical to the AgentLens mirror of this file; the
    /// migrator-parity ratchet (scripts/check-migrator-parity.mjs) fails the
    /// build if the surfaces drift.
    static func registerBillingKindMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v60_billing_kind") { db in
            try db.alter(table: "token_usage") { t in
                t.add(column: "billingKind", .text).notNull().defaults(to: "unknown")
            }
            try db.execute(sql: Self.billingKindBackfillSQL)
            try db.create(
                index: "token_usage_billing_kind_time_idx",
                on: "token_usage",
                columns: ["billingKind", "startTime"],
                ifNotExists: true
            )
        }
    }

    static let billingKindBackfillSQL = """
        UPDATE token_usage
        SET billingKind = CASE
                WHEN usageSource IN ('billing_api', 'daemon') THEN 'api'
                WHEN usageSource = 'provider_log' AND provider IN (
                    'Claude Code', 'Codex', 'Copilot', 'Cursor', 'Cursor Agent',
                    'Factory', 'Junie', 'Windsurf', 'Warp'
                ) THEN 'subscription'
                WHEN usageSource = 'provider_log' AND provider IN (
                    'Aider', 'Hermes', 'DeepSeek', 'OpenAI', 'xAI'
                ) THEN 'api'
                ELSE 'unknown'
            END
        WHERE billingKind = 'unknown'
        """
}
