using System;
using System.Collections.Generic;

namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>
/// Agents vs Models sidebar mode — macOS <c>DashboardViewMode</c>
/// (<c>@AppStorage("dashboardViewMode")</c> in <c>DashboardView.swift</c>).
/// </summary>
public enum DashboardCommandViewMode
{
    Agents,
    Models,
}

/// <summary>
/// One provider row in the Command sidebar — macOS <c>ProviderSummary</c> slice
/// used by <c>SidebarItem</c> in <c>DashboardSidebarComponents.swift</c>.
/// </summary>
public sealed record DashboardProviderSidebarRow(
    string Id,
    string DisplayName,
    double TotalCostUsd,
    long TotalTokens,
    int SessionCount,
    string MetricLabel);

/// <summary>
/// One model row in the Command sidebar — macOS <c>ModelSummary</c> slice
/// used by <c>ModelSidebarItem</c>.
/// </summary>
public sealed record DashboardModelSidebarRow(
    string Id,
    string DisplayName,
    string ProviderId,
    double TotalCostUsd,
    long TotalTokens,
    int SessionCount,
    string MetricLabel);

/// <summary>
/// Snapshot that drives the Command sidebar + Atelier provider rail —
/// mirrors the fields <c>DashboardSidebarView</c> reads from the usage window.
/// </summary>
public sealed record DashboardCommandSnapshot(
    double TotalCostUsd,
    long TotalTokens,
    int SessionCount,
    string OverviewMetricLabel,
    string TimeRangeDisplayName,
    int ActiveProviderCount,
    IReadOnlyList<DashboardProviderSidebarRow> Providers,
    IReadOnlyList<DashboardModelSidebarRow> Models,
    DashboardUsageOrigin Origin = DashboardUsageOrigin.Empty)
{
    public static DashboardCommandSnapshot Empty { get; } = new(
        TotalCostUsd: 0,
        TotalTokens: 0,
        SessionCount: 0,
        OverviewMetricLabel: "$0.00",
        TimeRangeDisplayName: "Today",
        ActiveProviderCount: 0,
        Providers: Array.Empty<DashboardProviderSidebarRow>(),
        Models: Array.Empty<DashboardModelSidebarRow>(),
        Origin: DashboardUsageOrigin.Empty);
}
