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
        // Try real data from the SQLCipher DB for KPI tiles.
        var summary = OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary();
        if (summary.HasData)
        {
            return kind switch
            {
                InsightWidgetKind.KpiTile when seed == 1 => InsightWidgetData.Kpi(
                    value: summary.TotalSpend.ToString("F2"),
                    label: "Cost (this month)",
                    subtext: $"${summary.TotalSpend:F2} spent",
                    trend: null),
                InsightWidgetKind.KpiTile when seed == 2 => InsightWidgetData.Kpi(
                    value: summary.SessionCount.ToString(),
                    label: "Sessions",
                    subtext: $"{summary.SessionCount} sessions",
                    trend: null),
                InsightWidgetKind.KpiTile when seed == 4 => InsightWidgetData.Kpi(
                    value: summary.TotalTokens.ToString("N0"),
                    label: "Tokens",
                    subtext: $"{summary.TotalTokens:N0} tokens",
                    trend: null),
                _ => InsightSampleData.ForKind(kind, seed),
            };
        }

        // No DB configured — use the sample data (the SampleChip stays visible).
        return InsightSampleData.ForKind(kind, seed);
    }
}
