using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Every analytics card's prepared data for the current day selection — the
/// selection-driven twin of the month snapshot. Port of macOS
/// <c>CalendarSelectionSnapshot</c> (<c>CalendarDataService.swift</c>); cards
/// render with zero aggregation of their own.
/// </summary>
public sealed record CalendarSelectionSnapshot
{
    /// <summary>One provider's share of the selection (drives the Provider Mix card + logos).</summary>
    public sealed record ProviderShare(string Provider, double Cost);

    /// <summary>One model's cost; <see cref="Model"/> is the raw key, <see cref="DisplayName"/> the human label.</summary>
    public sealed record ModelCost(string Model, string DisplayName, double Cost);

    /// <summary>One project's cost ("Unattributed" when the rows carry no project).</summary>
    public sealed record ProjectCost(string Name, double Cost);

    private CalendarSelectionSnapshot(
        IReadOnlyList<DateOnly> selectedDays,
        bool isEmpty,
        double totalCost,
        long totalTokens,
        int sessionCount,
        int activeDays,
        double averageCostPerDay,
        IReadOnlyList<CalendarDateBucket> dailyBurn,
        IReadOnlyList<ProviderShare> providerShares,
        IReadOnlyList<ModelCost> topModels,
        IReadOnlyList<ProjectCost> projectShares,
        double[][] hourWeekdayCost,
        int? peakWeekdayIndex,
        int? peakHour,
        double cacheHitRate,
        long cacheReadTokens,
        double cacheSavingsEstimate,
        double reasoningShare,
        long reasoningTokens)
    {
        SelectedDays = selectedDays;
        IsEmpty = isEmpty;
        TotalCost = totalCost;
        TotalTokens = totalTokens;
        SessionCount = sessionCount;
        ActiveDays = activeDays;
        AverageCostPerDay = averageCostPerDay;
        DailyBurn = dailyBurn;
        ProviderShares = providerShares;
        TopModels = topModels;
        ProjectShares = projectShares;
        HourWeekdayCost = hourWeekdayCost;
        PeakWeekdayIndex = peakWeekdayIndex;
        PeakHour = peakHour;
        CacheHitRate = cacheHitRate;
        CacheReadTokens = cacheReadTokens;
        CacheSavingsEstimate = cacheSavingsEstimate;
        ReasoningShare = reasoningShare;
        ReasoningTokens = reasoningTokens;
    }

    /// <summary>Selected days, ascending.</summary>
    public IReadOnlyList<DateOnly> SelectedDays { get; }

    /// <summary>True when no usage rows land on any selected day.</summary>
    public bool IsEmpty { get; }

    // MARK: KPI tiles

    public double TotalCost { get; }

    public long TotalTokens { get; }

    /// <summary>Distinct <c>sessionId</c> count across the selection (COUNT DISTINCT).</summary>
    public int SessionCount { get; }

    /// <summary>Selected days that carry at least one usage row.</summary>
    public int ActiveDays { get; }

    /// <summary>Total cost averaged over every selected day (silent days included).</summary>
    public double AverageCostPerDay { get; }

    // MARK: burnOverSelection

    /// <summary>Per-day cost across the selection's span, gap-filled.</summary>
    public IReadOnlyList<CalendarDateBucket> DailyBurn { get; }

    // MARK: providerMix / modelMix / projectFocus

    public IReadOnlyList<ProviderShare> ProviderShares { get; }

    public IReadOnlyList<ModelCost> TopModels { get; }

    public IReadOnlyList<ProjectCost> ProjectShares { get; }

    // MARK: hourOfDayHeatmap

    /// <summary>7×24 cost matrix; row 0 = Sunday (Gregorian weekday order).</summary>
    public double[][] HourWeekdayCost { get; }

    public int? PeakWeekdayIndex { get; }

    public int? PeakHour { get; }

    // MARK: cacheROI / reasoningShare

    public double CacheHitRate { get; }

    public long CacheReadTokens { get; }

    /// <summary>
    /// Cache reads billed at ~10% of the blended per-token rate (same estimate as
    /// <c>ChartsSnapshot.cacheSavingsEstimate</c>). Labeled "(est.)" in UI.
    /// </summary>
    public double CacheSavingsEstimate { get; }

    public double ReasoningShare { get; }

    public long ReasoningTokens { get; }

    /// <summary>
    /// Pure builder. <paramref name="rows"/> = the loaded month rows (any superset
    /// of the selection window); only rows whose local start day is selected
    /// contribute.
    /// </summary>
    public static CalendarSelectionSnapshot Build(
        IReadOnlyList<CalendarUsageRow> rows,
        IReadOnlySet<DateOnly> selectedDays,
        TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(selectedDays);
        ArgumentNullException.ThrowIfNull(timeZone);

        DateOnly[] sortedDays = selectedDays.OrderBy(day => day).ToArray();
        var selected = new List<CalendarUsageRow>();
        foreach (CalendarUsageRow row in rows)
        {
            if (selectedDays.Contains(CalendarLocalTime.LocalDay(row.StartUtc, timeZone)))
            {
                selected.Add(row);
            }
        }

        double totalCost = selected.Sum(row => row.CostUsd);
        long totalTokens = selected.Sum(row => row.TotalTokens);
        int sessionCount = selected
            .Select(row => row.SessionId)
            .Distinct(StringComparer.Ordinal)
            .Count();
        int activeDays = selected
            .Select(row => CalendarLocalTime.LocalDay(row.StartUtc, timeZone))
            .Distinct()
            .Count();

        // Per-day burn across the selection's span — gap-filled so silent days
        // draw as zero bars instead of collapsing.
        IReadOnlyList<CalendarDateBucket> dailyBurn = sortedDays.Length == 0
            ? Array.Empty<CalendarDateBucket>()
            : CalendarBucketing.DayBuckets(
                selected.Select(row => (row.StartUtc, row.CostUsd)),
                sortedDays[0],
                sortedDays[^1],
                timeZone);

        var providerShares = selected
            .GroupBy(row => row.Provider, StringComparer.Ordinal)
            .Select(group => new ProviderShare(group.Key, group.Sum(row => row.CostUsd)))
            .OrderByDescending(share => share.Cost)
            .ThenBy(share => share.Provider, StringComparer.Ordinal)
            .ToArray();

        var topModels = selected
            .GroupBy(row => CalendarModelNames.NormalizeModelKey(row.Model), StringComparer.Ordinal)
            .Select(group => new ModelCost(
                group.Key,
                CalendarModelNames.DisplayNameForModel(group.Key),
                group.Sum(row => row.CostUsd)))
            .OrderByDescending(model => model.Cost)
            .ThenBy(model => model.Model, StringComparer.Ordinal)
            .Take(6)
            .ToArray();

        var projectShares = selected
            .GroupBy(row => string.IsNullOrWhiteSpace(row.ProjectName) ? "Unattributed" : row.ProjectName, StringComparer.Ordinal)
            .Select(group => new ProjectCost(group.Key, group.Sum(row => row.CostUsd)))
            .OrderByDescending(project => project.Cost)
            .ThenBy(project => project.Name, StringComparer.Ordinal)
            .Take(5)
            .ToArray();

        double[][] matrix = CalendarBucketing.HourWeekdayMatrix(
            selected.Select(row => (row.StartUtc, row.CostUsd)),
            timeZone);
        int? peakWeekday = null;
        int? peakHour = null;
        double peakValue = 0;
        for (int weekday = 0; weekday < matrix.Length; weekday++)
        {
            for (int hour = 0; hour < matrix[weekday].Length; hour++)
            {
                if (matrix[weekday][hour] > peakValue)
                {
                    peakValue = matrix[weekday][hour];
                    peakWeekday = weekday;
                    peakHour = hour;
                }
            }
        }

        long cacheRead = selected.Sum(row => row.CacheReadTokens);
        long promptBasis = selected.Sum(row => row.InputTokens + row.CacheCreationTokens + row.CacheReadTokens);
        double cacheHitRate = promptBasis > 0 ? (double)cacheRead / promptBasis : 0;
        double blendedRate = totalTokens > 0 ? totalCost / totalTokens : 0;
        double cacheSavings = 0.9 * cacheRead * blendedRate;
        long reasoningTokens = selected.Sum(row => row.ReasoningTokens);
        double reasoningShare = totalTokens > 0 ? (double)reasoningTokens / totalTokens : 0;

        return new CalendarSelectionSnapshot(
            sortedDays,
            selected.Count == 0,
            totalCost,
            totalTokens,
            sessionCount,
            activeDays,
            totalCost / Math.Max(sortedDays.Length, 1),
            dailyBurn,
            providerShares,
            topModels,
            projectShares,
            matrix,
            peakWeekday,
            peakHour,
            cacheHitRate,
            cacheRead,
            cacheSavings,
            reasoningShare,
            reasoningTokens);
    }
}
