/// Write-time billing provenance for `token_usage` rows — real per-token API
/// dollars (`api`) vs the imputed list-price value of work that ran inside a flat
/// subscription plan (`subscription`).
///
/// This is the storage-layer peer of `BurnBarBillingProvenance` in
/// OpenBurnBarKernel. It is deliberately a separate, string-keyed mirror rather
/// than a re-export: `OpenBurnBarData` depends only on GRDB so it stays buildable
/// inside the Linux/daemon boundary build, where the Kernel's `AgentProvider` and
/// `UsageSource` enums are not linked. The three surfaces that can decide a row's
/// billing kind — this classifier, the Kernel classifier, and the v60 SQL backfill
/// (`OpenBurnBarDatabase.billingKindBackfillSQL`) — must agree on every input, so
/// `OpenBurnBarBillingProvenanceTests` executes that exact SQL against every
/// combination this classifier distinguishes and asserts the answers match.
///
/// `unknown` is the honest bucket, never a silent fold into either side: an
/// `unknown` can be reclassified later, a wrong guess could not be undone.
public enum OpenBurnBarBillingProvenance {
    /// Real per-token dollars billed against an API key.
    public static let api = "api"

    /// Imputed list-price value of work covered by a flat plan.
    public static let subscription = "subscription"

    /// Not classifiable without guessing — the schema default.
    public static let unknown = "unknown"

    /// Harnesses whose parsed sessions are overwhelmingly plan-billed. Mirror of
    /// the backfill's first `provider_log` arm (`AgentProvider` raw values).
    static let subscriptionFirstProviders: Set<String> = [
        "Claude Code", "Codex", "Copilot", "Cursor", "Cursor Agent",
        "Factory", "Junie", "Windsurf", "Warp"
    ]

    /// Bring-your-own-key harnesses: parsed sessions bill against the user's own
    /// API key. Mirror of the backfill's second `provider_log` arm.
    static let apiKeyFirstProviders: Set<String> = [
        "Aider", "Hermes", "DeepSeek", "OpenAI", "xAI"
    ]

    /// The billing kind for a row ingested from `usageSource` for `provider`.
    /// Billing-API and daemon-gateway ingest are real dollars by construction (the
    /// daemon gateway only ever dials key-backed provider slots), so the provider
    /// name is consulted only for parsed harness logs — exactly as the SQL `CASE`
    /// does, including for provider names this build has never heard of.
    public static func classify(provider: String, usageSource: String) -> String {
        if usageSource == "billing_api" || usageSource == "daemon" { return api }
        guard usageSource == "provider_log" else { return unknown }
        if subscriptionFirstProviders.contains(provider) { return subscription }
        return apiKeyFirstProviders.contains(provider) ? api : unknown
    }
}
