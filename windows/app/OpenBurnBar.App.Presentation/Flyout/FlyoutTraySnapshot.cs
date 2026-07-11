using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Dashboard;

namespace OpenBurnBar.App.Presentation.Flyout;

/// <summary>
/// Snapshot that drives the tray popover — macOS <c>MenuBarPopoverView</c> body.
/// </summary>
public sealed record FlyoutTraySnapshot(
    string TodayMetricLabel,
    string WeekMetricLabel,
    string MonthMetricLabel,
    int SessionCount,
    string FreshnessLabel,
    IReadOnlyList<double> Sparkline,
    IReadOnlyList<DashboardProviderSidebarRow> Providers,
    IReadOnlyList<FlyoutInsightCard> Insights,
    DashboardUsageOrigin Origin = DashboardUsageOrigin.Empty)
{
    public static FlyoutTraySnapshot Empty { get; } = new(
        TodayMetricLabel: "$0.00",
        WeekMetricLabel: "$0.00",
        MonthMetricLabel: "$0.00",
        SessionCount: 0,
        FreshnessLabel: "No data yet",
        Sparkline: Array.Empty<double>(),
        Providers: Array.Empty<DashboardProviderSidebarRow>(),
        Insights: Array.Empty<FlyoutInsightCard>(),
        Origin: DashboardUsageOrigin.Empty);
}

public sealed record FlyoutInsightCard(string Title, string Detail, string Severity);
