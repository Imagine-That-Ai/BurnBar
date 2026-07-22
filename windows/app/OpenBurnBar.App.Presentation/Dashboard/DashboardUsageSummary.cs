using System;

namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>The five dashboard windows exposed by macOS <c>TimeRange</c>.</summary>
public enum DashboardUsageWindow
{
    Today,
    Last7Days,
    Last30Days,
    ThisMonth,
    AllTime,
}

public static class DashboardUsageWindowExtensions
{
    public static string DisplayName(this DashboardUsageWindow window) => window switch
    {
        DashboardUsageWindow.Today => "Today",
        DashboardUsageWindow.Last7Days => "Last 7 Days",
        DashboardUsageWindow.Last30Days => "Last 30 Days",
        DashboardUsageWindow.ThisMonth => "This Month",
        DashboardUsageWindow.AllTime => "All Time",
        _ => "Today",
    };

    /// <summary>
    /// Returns the inclusive UTC floor for the selected window. Calendar windows
    /// use the host's local day/month boundary before converting to UTC.
    /// </summary>
    public static DateTimeOffset? StartUtc(
        this DashboardUsageWindow window,
        DateTimeOffset now)
    {
        DateTimeOffset localNow = now.ToLocalTime();
        return window switch
        {
            DashboardUsageWindow.Today => StartOfLocalDay(localNow).ToUniversalTime(),
            DashboardUsageWindow.Last7Days => localNow.AddDays(-7).ToUniversalTime(),
            DashboardUsageWindow.Last30Days => localNow.AddDays(-30).ToUniversalTime(),
            DashboardUsageWindow.ThisMonth => new DateTimeOffset(
                localNow.Year,
                localNow.Month,
                1,
                0,
                0,
                0,
                localNow.Offset).ToUniversalTime(),
            DashboardUsageWindow.AllTime => null,
            _ => StartOfLocalDay(localNow).ToUniversalTime(),
        };
    }

    private static DateTimeOffset StartOfLocalDay(DateTimeOffset value) => new(
        value.Year,
        value.Month,
        value.Day,
        0,
        0,
        0,
        value.Offset);
}

/// <summary>Where a <see cref="DashboardUsageSummary"/>'s numbers were sourced from.</summary>
public enum DashboardUsageOrigin
{
    /// <summary>No configured/available source produced data — honest, fail-closed empty state.</summary>
    Empty,

    /// <summary>Local SQLCipher <c>token_usage</c> aggregates (highest signal, on-device).</summary>
    Local,

    /// <summary>Firestore <c>users/{uid}/usage</c> events pulled through the signed-in gateway.</summary>
    Cloud,

    /// <summary>Explicitly enabled labeled demo data (<c>OPENBURNBAR_SAMPLE_MODE</c>).</summary>
    Sample,
}

/// <summary>
/// Aggregated <c>token_usage</c> headline numbers for the Dashboard classic layout.
/// Resolved by <see cref="DashboardUsageSummarySource"/> preferring signal over samples:
/// LIVE local <see cref="OpenBurnBar.Storage.TokenUsageReadSeam"/> (SQLCipher) →
/// the signed-in cloud usage feed → labeled sample → honest empty. <see cref="Origin"/>
/// records which source won so surfaces can label live vs demo data truthfully.
/// </summary>
public sealed record DashboardUsageSummary(
    double TotalCostUsd,
    long TotalTokens,
    long SessionCount,
    bool HasData,
    DashboardUsageOrigin Origin = DashboardUsageOrigin.Empty,
    DashboardUsageWindow Window = DashboardUsageWindow.ThisMonth)
{
    /// <summary>Compatibility alias for consumers written before range-aware totals.</summary>
    public double SpendThisMonthUsd => TotalCostUsd;
}
