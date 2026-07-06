using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.CloudSync;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Insights;

/// <summary>
/// Resolves real insight data from the SQLCipher DB (token_usage aggregates via
/// <see cref="OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary"/>)
/// for the KPI tiles, and from Firestore insight canvas docs for saved canvases.
/// KPI widgets use real SQLCipher aggregates or honest empty-state values. Non-KPI templates can
/// still render deterministic samples, with the visible "SampleChip" marker.
/// </summary>
public static class CloudSyncInsightSource
{
    /// <summary>
    /// Returns real KPI widget data from the SQLCipher DB when configured, or honest empty-state
    /// KPI values when not. Complex widgets (narratives, recommendations, forecasts) still need
    /// the Engine analysis path; those templates remain visibly marked as samples.
    /// </summary>
    public static InsightWidgetData ResolveKpi(InsightWidgetKind kind, int seed)
        => ResolveKpi(
            kind,
            seed,
            OpenBurnBar.App.Storage.WindowsStorageDevHost.LoadDashboardUsageSummary());

    public static InsightWidgetData ResolveKpi(InsightWidgetKind kind, int seed, DashboardUsageSummary summary)
    {
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

        return kind == InsightWidgetKind.KpiTile
            ? EmptyKpi(seed)
            : InsightSampleData.ForKind(kind, seed);
    }

    private static InsightWidgetData EmptyKpi(int seed) => seed switch
    {
        1 => new KpiData("Cost (this month)", 0, ValueFormat.Currency, ContextLabel: RuntimeDataMode.EmptyStateDetail("SQLCipher usage database")),
        2 => new KpiData("Sessions", 0, ValueFormat.Tokens, ContextLabel: RuntimeDataMode.EmptyStateDetail("SQLCipher usage database")),
        4 => new KpiData("Tokens", 0, ValueFormat.Tokens, ContextLabel: RuntimeDataMode.EmptyStateDetail("SQLCipher usage database")),
        _ => new KpiData("No data", 0, ValueFormat.Count, ContextLabel: RuntimeDataMode.EmptyStateDetail("SQLCipher usage database")),
    };
}
