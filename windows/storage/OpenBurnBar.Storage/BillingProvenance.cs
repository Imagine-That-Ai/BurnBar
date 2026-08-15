using System;
using System.Collections.Generic;

namespace OpenBurnBar.Storage;

/// <summary>
/// Write-time billing provenance for <c>token_usage</c> rows — real per-token API
/// dollars (<c>api</c>) vs the imputed list-price value of work that ran inside a
/// flat subscription plan (<c>subscription</c>).
/// </summary>
/// <remarks>
/// <para>
/// The Windows peer of the Swift <c>BurnBarBillingProvenance.classify(provider:usageSource:)</c>,
/// and deliberately identical to the v60 SQL backfill
/// (<see cref="WindowsSqlCipherProvisioner.BillingKindBackfillSql"/>): the same row
/// must classify the same way whether it was stamped at write time on macOS, stamped
/// at write time on Windows, or backfilled by the migration. A disagreement would
/// permanently corrupt the money-vs-imputed split, so
/// <c>BillingKindBackfillMatchesClassifierTests</c> runs the real backfill SQL over
/// every combination this classifier distinguishes and asserts they agree.
/// </para>
/// <para>
/// <see cref="Unknown"/> is the honest bucket, never a silent fold into either
/// side: consumers surface it separately, and an <c>unknown</c> can be reclassified
/// later where a wrong guess could not be undone.
/// </para>
/// </remarks>
public static class BillingProvenance
{
    /// <summary>Real per-token dollars billed against an API key.</summary>
    public const string Api = "api";

    /// <summary>Imputed list-price value of work covered by a flat plan.</summary>
    public const string Subscription = "subscription";

    /// <summary>Not classifiable without guessing — the schema default.</summary>
    public const string Unknown = "unknown";

    /// <summary>
    /// Harnesses whose parsed sessions are overwhelmingly plan-billed. Mirror of the
    /// backfill's first <c>provider_log</c> arm and of the Swift
    /// <c>subscriptionFirstProviders</c> set (<c>AgentProvider</c> raw values).
    /// </summary>
    private static readonly HashSet<string> SubscriptionFirstProviders = new(StringComparer.Ordinal)
    {
        "Claude Code", "Codex", "Copilot", "Cursor", "Cursor Agent",
        "Factory", "Junie", "Windsurf", "Warp",
    };

    /// <summary>
    /// Bring-your-own-key harnesses: parsed sessions bill against the user's own API
    /// key. Mirror of the backfill's second <c>provider_log</c> arm.
    /// </summary>
    private static readonly HashSet<string> ApiKeyFirstProviders = new(StringComparer.Ordinal)
    {
        "Aider", "Hermes", "DeepSeek", "OpenAI", "xAI",
    };

    /// <summary>
    /// The billing kind for a row ingested from <paramref name="usageSource"/> for
    /// <paramref name="provider"/>. Billing-API and daemon-gateway ingest are real
    /// dollars by construction (the daemon only ever dials key-backed provider
    /// slots), so the provider name is consulted only for parsed harness logs —
    /// exactly as the SQL <c>CASE</c> does.
    /// </summary>
    public static string Classify(string provider, string usageSource)
    {
        if (string.Equals(usageSource, "billing_api", StringComparison.Ordinal)
            || string.Equals(usageSource, "daemon", StringComparison.Ordinal))
        {
            return Api;
        }

        if (!string.Equals(usageSource, "provider_log", StringComparison.Ordinal))
        {
            return Unknown;
        }

        if (SubscriptionFirstProviders.Contains(provider))
        {
            return Subscription;
        }

        return ApiKeyFirstProviders.Contains(provider) ? Api : Unknown;
    }
}
