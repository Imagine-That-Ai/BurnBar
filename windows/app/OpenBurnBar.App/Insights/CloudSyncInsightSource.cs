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
/// Non-KPI templates (narratives, recommendations, forecasts, rankings, etc.)
/// require the Engine analysis path; production mode returns honest empty
/// widgets. Deterministic <see cref="InsightSampleData"/> is available only
/// when <see cref="RuntimeDataMode.SampleModeEnabled"/> is explicitly on.
/// </summary>
public static class CloudSyncInsightSource
{
    /// <summary>
    /// Resolve any widget kind against a pre-loaded usage summary under the current
    /// runtime data mode. Sample data is never constructed unless sample mode is enabled.
    /// Callers load the summary from <c>DashboardUsageProvider</c> (or a test double).
    /// </summary>
    public static InsightWidgetData Resolve(InsightWidgetKind kind, int seed, DashboardUsageSummary summary)
    {
        if (kind == InsightWidgetKind.KpiTile)
        {
            return ResolveKpi(kind, seed, summary);
        }

        if (RuntimeDataMode.SampleModeEnabled)
        {
            return InsightSampleData.ForKind(kind, seed);
        }

        return InsightEmptyData.ForKind(kind, seed, RuntimeDataMode.EmptyStateDetail("SQLCipher usage database / Insights engine"));
    }

    /// <summary>
    /// Returns real KPI widget data from the composed local→cloud usage summary when data
    /// exists, or honest empty-state KPI values when not. Non-KPI kinds are routed through
    /// <see cref="Resolve"/> so production never fabricates sample series.
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
                // Seed 3 (cache hit) and other KPI seeds still need the Engine
                // analysis path. Sample mode may label them; production stays empty.
                _ => SampleOrEmpty(kind, seed),
            };
        }

        return SampleOrEmpty(kind, seed);
    }

    private static InsightWidgetData SampleOrEmpty(InsightWidgetKind kind, int seed)
        => RuntimeDataMode.SampleModeEnabled
            ? InsightSampleData.ForKind(kind, seed)
            : InsightEmptyData.ForKind(
                kind,
                seed,
                RuntimeDataMode.EmptyStateDetail("SQLCipher usage database"));
}
