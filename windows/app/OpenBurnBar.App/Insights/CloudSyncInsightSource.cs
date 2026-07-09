using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// Resolves insight widget data for the stamped canvas templates.
/// KPI tiles prefer the composed Dashboard usage summary
/// (<see cref="OpenBurnBar.App.Dashboard.DashboardUsageProvider"/>): LIVE local
/// SQLCipher <c>token_usage</c> aggregates, then the signed-in cloud usage feed
/// when the local DB is empty, then an honest empty state.
/// Non-KPI templates require the Engine analysis path.
///
/// Sample-mode policy (fail-closed hybrid):
/// <list type="bullet">
/// <item>When live usage is present (<c>summary.HasData</c>), never inject
/// <see cref="InsightSampleData"/> — unwired kinds stay empty so demos cannot
/// mix real KPI spend with fabricated series under one Sample chip.</item>
/// <item>When sample mode is on and there is no live usage, every kind may use
/// labeled sample generators.</item>
/// <item>Production (sample mode off) always returns <see cref="InsightEmptyData"/>
/// when live KPI seeds are unavailable.</item>
/// </list>
/// </summary>
public static class CloudSyncInsightSource
{
    /// <summary>
    /// Resolve any widget kind against a pre-loaded usage summary under the current
    /// runtime data mode. Callers load the summary from <c>DashboardUsageProvider</c>
    /// (or a test double).
    /// </summary>
    public static InsightWidgetData Resolve(InsightWidgetKind kind, int seed, DashboardUsageSummary summary)
    {
        if (kind == InsightWidgetKind.KpiTile)
        {
            return ResolveKpi(kind, seed, summary);
        }

        // Fail-closed hybrid: live data present ⇒ no fabricated non-KPI series.
        if (RuntimeDataMode.SampleModeEnabled && !summary.HasData)
        {
            return InsightSampleData.ForKind(kind, seed);
        }

        return InsightEmptyData.ForKind(
            kind,
            seed,
            RuntimeDataMode.EmptyStateDetail("SQLCipher usage database / Insights engine"));
    }

    /// <summary>
    /// Returns real KPI widget data from the composed local→cloud usage summary when data
    /// exists, or honest empty-state values when not. Non-KPI kinds are routed through
    /// <see cref="Resolve"/>.
    /// </summary>
    public static InsightWidgetData ResolveKpi(InsightWidgetKind kind, int seed, DashboardUsageSummary summary)
    {
        if (kind != InsightWidgetKind.KpiTile)
        {
            return Resolve(kind, seed, summary);
        }

        if (summary.HasData)
        {
            return seed switch
            {
                1 => new KpiData(
                    MetricLabel: "Cost (this month)",
                    Value: summary.SpendThisMonthUsd,
                    ValueFormat: ValueFormat.Currency),
                2 => new KpiData(
                    MetricLabel: "Sessions",
                    Value: summary.SessionCount,
                    ValueFormat: ValueFormat.Tokens),
                4 => new KpiData(
                    MetricLabel: "Tokens",
                    Value: summary.TotalTokens,
                    ValueFormat: ValueFormat.Tokens),
                // Seed 3 (cache hit) and other KPI seeds still need the Engine path.
                // Live present ⇒ empty, never sample (hybrid fail-closed).
                _ => InsightEmptyData.ForKind(
                    InsightWidgetKind.KpiTile,
                    seed,
                    RuntimeDataMode.EmptyStateDetail("SQLCipher usage database")),
            };
        }

        if (RuntimeDataMode.SampleModeEnabled)
        {
            return InsightSampleData.ForKind(kind, seed);
        }

        return InsightEmptyData.ForKind(
            InsightWidgetKind.KpiTile,
            seed,
            RuntimeDataMode.EmptyStateDetail("SQLCipher usage database"));
    }
}
