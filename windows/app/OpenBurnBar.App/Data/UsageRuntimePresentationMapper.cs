using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.Flyout;
using OpenBurnBar.App.UsageRuntime;

namespace OpenBurnBar.App.Data;

internal static class UsageRuntimePresentationMapper
{
    public static FlyoutTraySnapshot ToFlyoutSnapshot(
        UsageRuntimeState state,
        DateTimeOffset? nowOverride = null)
    {
        DateTimeOffset now = nowOverride ?? DateTimeOffset.Now;
        IReadOnlyList<UsageEngineRecord> usages = state.Snapshot.Usages;
        if (usages.Count == 0)
        {
            return FlyoutTraySnapshot.Empty with
            {
                FreshnessLabel = state.StatusMessage,
            };
        }

        DateTime today = now.LocalDateTime.Date;
        DateTime weekFloor = today.AddDays(-6);
        DateTime monthFloor = new(today.Year, today.Month, 1);
        UsageEngineRecord[] todayRows = usages.Where(row => LocalDate(row) >= today).ToArray();
        UsageEngineRecord[] weekRows = usages.Where(row => LocalDate(row) >= weekFloor).ToArray();
        UsageEngineRecord[] monthRows = usages.Where(row => LocalDate(row) >= monthFloor).ToArray();
        DashboardProviderSidebarRow[] providers = ProviderRows(todayRows.Length > 0 ? todayRows : usages);

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
                ? $"Updated {WindowsUsageRuntime.FormatFreshness(updated, now)}"
                : state.StatusMessage;

        return new FlyoutTraySnapshot(
            TodayMetricLabel: FormatCost(todayRows.Sum(row => row.CostUsd)),
            WeekMetricLabel: FormatCost(weekRows.Sum(row => row.CostUsd)),
            MonthMetricLabel: FormatCost(monthRows.Sum(row => row.CostUsd)),
            SessionCount: DistinctSessionCount(todayRows.Length > 0 ? todayRows : usages),
            FreshnessLabel: freshness,
            Sparkline: DailyCostSeries(usages, today),
            Providers: providers,
            Insights: insights,
            Origin: DashboardUsageOrigin.Local);
    }

    public static DashboardCommandSnapshot ToDashboardCommandSnapshot(
        UsageRuntimeState state,
        DateTimeOffset? nowOverride = null)
    {
        IReadOnlyList<UsageEngineRecord> usages = state.Snapshot.Usages;
        if (usages.Count == 0)
        {
            return DashboardCommandSnapshot.Empty;
        }

        DateTime today = (nowOverride ?? DateTimeOffset.Now).LocalDateTime.Date;
        UsageEngineRecord[] todayRows = usages.Where(row => LocalDate(row) >= today).ToArray();
        IReadOnlyList<UsageEngineRecord> activeRows = todayRows.Length > 0 ? todayRows : usages;
        DashboardProviderSidebarRow[] providers = ProviderRows(activeRows);
        DashboardModelSidebarRow[] models = activeRows
            .GroupBy(row => new { row.Provider, row.Model })
            .Select(group => new DashboardModelSidebarRow(
                Id: $"{group.Key.Provider}:{group.Key.Model}",
                DisplayName: string.IsNullOrWhiteSpace(group.Key.Model) ? "Unknown model" : group.Key.Model,
                ProviderId: group.Key.Provider,
                TotalCostUsd: group.Sum(row => row.CostUsd),
                TotalTokens: group.Sum(row => row.TotalTokens),
                SessionCount: DistinctSessionCount(group),
                MetricLabel: FormatCost(group.Sum(row => row.CostUsd))))
            .OrderByDescending(row => row.TotalCostUsd)
            .ThenByDescending(row => row.TotalTokens)
            .ThenBy(row => row.DisplayName, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        double totalCost = activeRows.Sum(row => row.CostUsd);
        return new DashboardCommandSnapshot(
            TotalCostUsd: totalCost,
            TotalTokens: activeRows.Sum(row => row.TotalTokens),
            SessionCount: DistinctSessionCount(activeRows),
            OverviewMetricLabel: FormatCost(totalCost),
            TimeRangeDisplayName: todayRows.Length > 0 ? "Today" : "All time",
            ActiveProviderCount: providers.Length,
            Providers: providers,
            Models: models,
            Origin: DashboardUsageOrigin.Local);
    }

    private static DashboardProviderSidebarRow[] ProviderRows(
        IEnumerable<UsageEngineRecord> usages) => usages
        .GroupBy(row => row.Provider)
        .Select(group => new DashboardProviderSidebarRow(
            Id: group.Key,
            DisplayName: group.Key,
            TotalCostUsd: group.Sum(row => row.CostUsd),
            TotalTokens: group.Sum(row => row.TotalTokens),
            SessionCount: DistinctSessionCount(group),
            MetricLabel: FormatCost(group.Sum(row => row.CostUsd))))
        .OrderByDescending(row => row.TotalCostUsd)
        .ThenByDescending(row => row.TotalTokens)
        .ThenBy(row => row.DisplayName, StringComparer.OrdinalIgnoreCase)
        .ToArray();

    private static IReadOnlyList<double> DailyCostSeries(
        IEnumerable<UsageEngineRecord> usages,
        DateTime today)
    {
        var byDate = usages
            .GroupBy(LocalDate)
            .ToDictionary(group => group.Key, group => group.Sum(row => row.CostUsd));
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

    private static DateTime LocalDate(UsageEngineRecord usage)
    {
        try
        {
            return DateTimeOffset.FromUnixTimeMilliseconds(usage.EndUnixMilliseconds)
                .LocalDateTime.Date;
        }
        catch (ArgumentOutOfRangeException)
        {
            return DateTime.MinValue;
        }
    }

    private static string FormatCost(double cost) => cost.ToString("C2", CultureInfo.GetCultureInfo("en-US"));
}
