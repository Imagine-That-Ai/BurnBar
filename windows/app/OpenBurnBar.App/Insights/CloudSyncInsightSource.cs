using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.CloudSync;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// Resolves real insight data from the SQLCipher DB (token_usage aggregates via
/// <see cref="OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary"/>)
/// for the KPI tiles, and from Firestore insight canvas docs for saved canvases.
/// Falls back to <see cref="InsightSampleData"/> when neither is configured — the
/// "SampleChip" UI marker stays visible in that case.
/// </summary>
public static class CloudSyncInsightSource
{
    /// <summary>
    /// Returns real KPI widget data from the SQLCipher DB when configured, or
    /// <see cref="InsightSampleData.ForKind"/> when not. The KPI tiles (cost,
    /// sessions, tokens, cache) are derivable from token_usage aggregates —
    /// the complex widgets (narratives, recommendations, forecasts) still need
    /// the Engine's LLM analysis (deferred to the C-ABI binding follow-up).
    /// </summary>
    public static InsightWidgetData ResolveKpi(InsightWidgetKind kind, int seed)
    {
        var summary = OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary();
        if (summary.HasData)
        {
            return (kind, seed) switch
            {
                (InsightWidgetKind.KpiTile, 1) => new KpiData(
                    MetricLabel: "Cost (this month)",
                    Value: summary.SpendThisMonthUsd,
                    ValueFormat: ValueFormat.Currency),
                (InsightWidgetKind.KpiTile, 2) => new KpiData(
                    MetricLabel: "Sessions",
                    Value: summary.SessionCount,
                    ValueFormat: ValueFormat.Tokens),
                (InsightWidgetKind.KpiTile, 4) => new KpiData(
                    MetricLabel: "Tokens",
                    Value: summary.TotalTokens,
                    ValueFormat: ValueFormat.Tokens),
                _ => InsightSampleData.ForKind(kind, seed),
            };
        }

        return InsightSampleData.ForKind(kind, seed);
    }
}
