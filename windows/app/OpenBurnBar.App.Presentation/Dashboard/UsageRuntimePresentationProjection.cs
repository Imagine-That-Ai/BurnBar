using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using OpenBurnBar.App.Presentation.Flyout;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App.Presentation.Dashboard;

/// <summary>
/// Pure projection from the shared usage runtime into dashboard and flyout models.
/// Keeping this outside WinUI makes the visible range and metric behavior portable-testable.
/// </summary>
public static class UsageRuntimePresentationProjection
{
    public static FlyoutTraySnapshot ToFlyoutSnapshot(
        UsageRuntimeState state,
        DashboardUsageWindow selectedWindow,
        bool displayTokens,
        DateTimeOffset? nowOverride = null)
    {
        DateTimeOffset now = nowOverride ?? DateTimeOffset.Now;
        IReadOnlyList<UsageEngineRecord> usages = state.Snapshot.Usages;
        if (usages.Count == 0)
        {
            return FlyoutTraySnapshot.Empty with
            {
                TodayMetricLabel = displayTokens ? "0" : "$0.00",
                WeekMetricLabel = displayTokens ? "0" : "$0.00",
                MonthMetricLabel = displayTokens ? "0" : "$0.00",
                FreshnessLabel = state.StatusMessage,
            };
        }

        DateTime today = now.LocalDateTime.Date;
        UsageEngineRecord[] todayRows = RowsForWindow(usages, DashboardUsageWindow.Today, now);
        UsageEngineRecord[] weekRows = RowsForWindow(usages, DashboardUsageWindow.Last7Days, now);
        UsageEngineRecord[] monthRows = RowsForWindow(usages, DashboardUsageWindow.ThisMonth, now);
        UsageEngineRecord[] activeRows = RowsForWindow(usages, selectedWindow, now);
        DashboardProviderSidebarRow[] providers = ProviderRows(activeRows, displayTokens);

        var insights = new List<FlyoutInsightCard>();
        if (providers.FirstOrDefault() is { } topProvider)
        {
            insights.Add(new FlyoutInsightCard(
                "Most active provider",
                $"{topProvider.DisplayName} accounts for {topProvider.SessionCount} recent session"
                    + (topProvider.SessionCount == 1 ? "." : "s."),
                "info"));
        }
        if (state.Phase is UsageRuntimePhase.Degraded or UsageRuntimePhase.Failed)
        {
            insights.Add(new FlyoutInsightCard(
                "Refresh needs attention",
                state.StatusMessage,
                "warning"));
        }

        string freshness = state.IsScanning
            ? "Scanning provider activity..."
            : state.LastSuccessfulScan is { } updated
                ? $"Updated {FormatFreshness(updated, now)}"
                : state.StatusMessage;

        return new FlyoutTraySnapshot(
            TodayMetricLabel: FormatMetric(todayRows, displayTokens),
            WeekMetricLabel: FormatMetric(weekRows, displayTokens),
            MonthMetricLabel: FormatMetric(monthRows, displayTokens),
            SessionCount: DistinctSessionCount(activeRows),
            FreshnessLabel: freshness,
            Sparkline: DailySeries(usages, today, displayTokens),
            Providers: providers,
            Insights: insights,
            Origin: DashboardUsageOrigin.Local);
    }

    public static DashboardCommandSnapshot ToDashboardCommandSnapshot(
        UsageRuntimeState state,
        DashboardUsageWindow window,
        bool displayTokens,
        DateTimeOffset? nowOverride = null)
    {
        IReadOnlyList<UsageEngineRecord> usages = state.Snapshot.Usages;
        if (usages.Count == 0)
        {
            return DashboardCommandSnapshot.Empty with
            {
                OverviewMetricLabel = displayTokens ? "0" : "$0.00",
                TimeRangeDisplayName = window.DisplayName(),
            };
        }

        DateTimeOffset now = nowOverride ?? DateTimeOffset.Now;
        IReadOnlyList<UsageEngineRecord> activeRows = RowsForWindow(usages, window, now);
        DashboardProviderSidebarRow[] providers = ProviderRows(activeRows, displayTokens);
        DashboardModelSidebarRow[] models = activeRows
            .GroupBy(row => new { row.Provider, row.Model })
            .Select(group => new DashboardModelSidebarRow(
                Id: $"{group.Key.Provider}:{group.Key.Model}",
                DisplayName: string.IsNullOrWhiteSpace(group.Key.Model) ? "Unknown model" : group.Key.Model,
                ProviderId: group.Key.Provider,
                TotalCostUsd: group.Sum(row => row.CostUsd),
                TotalTokens: group.Sum(row => row.TotalTokens),
                SessionCount: DistinctSessionCount(group),
                MetricLabel: FormatMetric(group, displayTokens)))
            .OrderByDescending(row => displayTokens ? row.TotalTokens : row.TotalCostUsd)
            .ThenByDescending(row => row.TotalTokens)
            .ThenBy(row => row.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        return new DashboardCommandSnapshot(
            TotalCostUsd: activeRows.Sum(row => row.CostUsd),
            TotalTokens: activeRows.Sum(row => row.TotalTokens),
            SessionCount: DistinctSessionCount(activeRows),
            OverviewMetricLabel: FormatMetric(activeRows, displayTokens),
            TimeRangeDisplayName: window.DisplayName(),
            ActiveProviderCount: providers.Length,
            Providers: providers,
            Models: models,
            Origin: DashboardUsageOrigin.Local);
    }

    private static DashboardProviderSidebarRow[] ProviderRows(
        IEnumerable<UsageEngineRecord> usages,
        bool displayTokens) => usages
        .GroupBy(row => row.Provider)
        .Select(group => new DashboardProviderSidebarRow(
            Id: group.Key,
            DisplayName: group.Key,
            TotalCostUsd: group.Sum(row => row.CostUsd),
            TotalTokens: group.Sum(row => row.TotalTokens),
            SessionCount: DistinctSessionCount(group),
            MetricLabel: FormatMetric(group, displayTokens)))
        .OrderByDescending(row => displayTokens ? row.TotalTokens : row.TotalCostUsd)
        .ThenByDescending(row => row.TotalTokens)
        .ThenBy(row => row.DisplayName, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    private static IReadOnlyList<double> DailySeries(
        IEnumerable<UsageEngineRecord> usages,
        DateTime today,
        bool displayTokens)
    {
        var byDate = usages
            .GroupBy(LocalDate)
            .ToDictionary(
                group => group.Key,
                group => displayTokens
                    ? group.Sum(row => (double)row.TotalTokens)
                    : group.Sum(row => row.CostUsd));
        var values = new double[7];
        for (int index = 0; index < values.Length; index++)
        {
            DateTime day = today.AddDays(index - (values.Length - 1));
            values[index] = byDate.TryGetValue(day, out double value) ? value : 0;
        }
        return values;
    }

    private static int DistinctSessionCount(IEnumerable<UsageEngineRecord> usages) => usages
        .Select(row => $"{row.Provider}\u001f{row.SessionId}")
        .Distinct(StringComparer.Ordinal)
        .Count();

    private static UsageEngineRecord[] RowsForWindow(
        IEnumerable<UsageEngineRecord> usages,
        DashboardUsageWindow window,
        DateTimeOffset now)
    {
        DateTimeOffset? start = window.StartUtc(now);
        return start is null
            ? usages.ToArray()
            : usages.Where(row => EventTime(row) >= start.Value).ToArray();
    }

    private static DateTimeOffset EventTime(UsageEngineRecord usage)
    {
        try
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(usage.EndUnixMilliseconds);
        }
        catch (ArgumentOutOfRangeException)
        {
            return DateTimeOffset.MinValue;
        }
    }

    private static DateTime LocalDate(UsageEngineRecord usage) => EventTime(usage).LocalDateTime.Date;

    private static string FormatCost(double cost) =>
        cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"));

    private static string FormatMetric(
        IEnumerable<UsageEngineRecord> usages,
        bool displayTokens) => displayTokens
            ? FormatTokens(usages.Sum(row => row.TotalTokens))
            : FormatCost(usages.Sum(row => row.CostUsd));

    private static string FormatTokens(long tokens)
    {
        if (tokens >= 1_000_000_000) return $"{tokens / 1_000_000_000.0:0.##}B";
        if (tokens >= 1_000_000) return $"{tokens / 1_000_000.0:0.##}M";
        if (tokens >= 1_000) return $"{tokens / 1_000.0:0.#}K";
        return tokens.ToString(CultureInfo.InvariantCulture);
    }

    private static string FormatFreshness(DateTimeOffset timestamp, DateTimeOffset now)
    {
        TimeSpan age = now - timestamp;
        if (age < TimeSpan.Zero) age = TimeSpan.Zero;
        if (age < TimeSpan.FromMinutes(1)) return "just now";
        if (age < TimeSpan.FromHours(1)) return $"{Math.Max(1, (int)age.TotalMinutes)}m ago";
        if (age < TimeSpan.FromDays(1)) return $"{Math.Max(1, (int)age.TotalHours)}h ago";
        return $"{Math.Max(1, (int)age.TotalDays)}d ago";
    }
}
