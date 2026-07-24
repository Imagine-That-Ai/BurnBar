using System;
using System.Collections.Generic;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Everything the month grid needs to draw: per-day cost (drives the heatmap
/// fill) and the day's top providers (drives the dots). Port of macOS
/// <c>CalendarMonthSnapshot</c> (<c>CalendarDataService.swift</c>). Days are keyed
/// by local <see cref="DateOnly"/>; only days with usage appear — cells treat a
/// missing key as zero.
/// </summary>
public sealed record CalendarMonthSnapshot
{
    /// <summary>Up to three provider ids shown as dots under a busy day.</summary>
    public const int MaxDayProviders = 3;

    private CalendarMonthSnapshot(
        DateOnly monthStart,
        DateOnly gridStart,
        DateOnly gridEndExclusive,
        IReadOnlyDictionary<DateOnly, double> dayCosts,
        IReadOnlyDictionary<DateOnly, IReadOnlyList<string>> dayProviders,
        double peakDayCost,
        double monthTotalCost)
    {
        MonthStart = monthStart;
        GridStart = gridStart;
        GridEndExclusive = gridEndExclusive;
        DayCosts = dayCosts;
        DayProviders = dayProviders;
        PeakDayCost = peakDayCost;
        MonthTotalCost = monthTotalCost;
    }

    /// <summary>The grid model this snapshot was built for (defines the fetch window).</summary>
    public DateOnly MonthStart { get; }

    public DateOnly GridStart { get; }

    public DateOnly GridEndExclusive { get; }

    /// <summary>Total cost per local day. Only days with usage appear.</summary>
    public IReadOnlyDictionary<DateOnly, double> DayCosts { get; }

    /// <summary>Up to three providers per day, ranked by that day's cost.</summary>
    public IReadOnlyDictionary<DateOnly, IReadOnlyList<string>> DayProviders { get; }

    /// <summary>The month's busiest day cost — the denominator for heatmap intensity.</summary>
    public double PeakDayCost { get; }

    /// <summary>
    /// Spend on days inside the calendar month itself (grid overflow days from
    /// neighboring months excluded), for the header subtitle.
    /// </summary>
    public double MonthTotalCost { get; }

    /// <summary>Cost for a day (0 when the day carried no usage).</summary>
    public double CostFor(DateOnly day) => DayCosts.TryGetValue(day, out double cost) ? cost : 0;

    /// <summary>Top providers for a day (empty when the day carried no usage).</summary>
    public IReadOnlyList<string> ProvidersFor(DateOnly day) =>
        DayProviders.TryGetValue(day, out IReadOnlyList<string>? providers)
            ? providers
            : Array.Empty<string>();

    /// <summary>
    /// Pure builder — the Windows peer of <c>CalendarMonthSnapshot.build</c>.
    /// <paramref name="rows"/> is any superset of the grid window; rows whose local
    /// start day falls outside the grid are ignored.
    /// </summary>
    public static CalendarMonthSnapshot Build(
        IReadOnlyList<CalendarUsageRow> rows,
        CalendarMonthGridModel grid,
        TimeZoneInfo timeZone)
    {
        ArgumentNullException.ThrowIfNull(rows);
        ArgumentNullException.ThrowIfNull(grid);
        ArgumentNullException.ThrowIfNull(timeZone);

        DateOnly gridEnd = grid.GridEndExclusive;
        var dayCosts = new Dictionary<DateOnly, double>();
        var providerCosts = new Dictionary<DateOnly, Dictionary<string, double>>();
        foreach (CalendarUsageRow row in rows)
        {
            DateOnly day = CalendarLocalTime.LocalDay(row.StartUtc, timeZone);
            if (day < grid.GridStart || day >= gridEnd)
            {
                continue;
            }

            dayCosts[day] = dayCosts.TryGetValue(day, out double existing) ? existing + row.CostUsd : row.CostUsd;
            if (!providerCosts.TryGetValue(day, out Dictionary<string, double>? byProvider))
            {
                byProvider = new Dictionary<string, double>(StringComparer.Ordinal);
                providerCosts[day] = byProvider;
            }

            byProvider[row.Provider] = byProvider.TryGetValue(row.Provider, out double providerExisting)
                ? providerExisting + row.CostUsd
                : row.CostUsd;
        }

        var dayProviders = new Dictionary<DateOnly, IReadOnlyList<string>>();
        foreach ((DateOnly day, Dictionary<string, double> costs) in providerCosts)
        {
            dayProviders[day] = costs
                .OrderByDescending(pair => pair.Value)
                .ThenBy(pair => pair.Key, StringComparer.Ordinal)
                .Take(MaxDayProviders)
                .Select(pair => pair.Key)
                .ToArray();
        }

        double monthTotal = 0;
        foreach ((DateOnly day, double cost) in dayCosts)
        {
            if (grid.IsInMonth(day))
            {
                monthTotal += cost;
            }
        }

        return new CalendarMonthSnapshot(
            grid.MonthStart,
            grid.GridStart,
            gridEnd,
            dayCosts,
            dayProviders,
            dayCosts.Count == 0 ? 0 : dayCosts.Values.Max(),
            monthTotal);
    }
}
