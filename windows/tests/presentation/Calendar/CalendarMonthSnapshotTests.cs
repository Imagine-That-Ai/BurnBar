using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Calendar;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the month-grid snapshot (parity: macOS <c>CalendarMonthSnapshot.build</c>):
/// per-day costs keyed by local day, the visible month's peak as the heatmap
/// denominator, top-3 providers per day with ordinal tie-break, and the
/// month-total that excludes grid-overflow days from neighboring months.
/// </summary>
public sealed class CalendarMonthSnapshotTests
{
    private static readonly TimeZoneInfo Tz = TimeZoneInfo.Utc;

    [Fact]
    public void Day_costs_sum_rows_on_the_same_local_day_and_ignore_out_of_range_rows()
    {
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 7, 15));
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-03T10:00:00Z", 2.0, "Codex"),
            Row("2026-07-03T18:00:00Z", 1.5, "Codex"),
            Row("2026-07-10T09:00:00Z", 4.0, "Claude Code"),
            Row("2026-08-05T09:00:00Z", 99.0, "Codex"), // outside the July grid
        };

        CalendarMonthSnapshot snapshot = CalendarMonthSnapshot.Build(rows, grid, Tz);

        Assert.Equal(3.5, snapshot.CostFor(new DateOnly(2026, 7, 3)));
        Assert.Equal(4.0, snapshot.CostFor(new DateOnly(2026, 7, 10)));
        Assert.Equal(0, snapshot.CostFor(new DateOnly(2026, 7, 11)));
        Assert.Equal(0, snapshot.CostFor(new DateOnly(2026, 8, 5)));
    }

    [Fact]
    public void Peak_day_cost_is_the_visible_months_busiest_day()
    {
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 7, 15));
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-03T10:00:00Z", 9.0, "Codex"),
            Row("2026-07-10T09:00:00Z", 1.0, "Codex"),
        };

        CalendarMonthSnapshot snapshot = CalendarMonthSnapshot.Build(rows, grid, Tz);

        Assert.Equal(9.0, snapshot.PeakDayCost);
    }

    [Fact]
    public void Heatmap_intensity_is_sqrt_scaled_against_the_peak()
    {
        // The macOS CalendarDayCell/ChartKitHeatmap recipe: 0.10 + 0.55 × √(cost/peak).
        Assert.Equal(0.65, CalendarHeatmap.FillOpacity(9.0, 9.0), 6);
        Assert.Equal(0.10 + (0.55 * Math.Sqrt(1.0 / 9.0)), CalendarHeatmap.FillOpacity(1.0, 9.0), 10);
        Assert.Equal(0, CalendarHeatmap.FillOpacity(0, 9.0));
        Assert.Equal(0, CalendarHeatmap.FillOpacity(5.0, 0)); // no peak → plain surface fill
        Assert.Equal(1.0 / 3.0, CalendarHeatmap.Intensity(1.0, 9.0), 10);
    }

    [Fact]
    public void Day_providers_rank_by_cost_with_ordinal_tiebreak_and_cap_at_three()
    {
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 7, 15));
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-07-03T08:00:00Z", 2.0, "Cursor"),
            Row("2026-07-03T09:00:00Z", 2.0, "Codex"),   // tie with Cursor → "Codex" first ordinally
            Row("2026-07-03T10:00:00Z", 5.0, "Claude Code"),
            Row("2026-07-03T11:00:00Z", 1.0, "Zed"),      // 4th place → no dot
        };

        CalendarMonthSnapshot snapshot = CalendarMonthSnapshot.Build(rows, grid, Tz);

        Assert.Equal(
            new[] { "Claude Code", "Codex", "Cursor" },
            snapshot.ProvidersFor(new DateOnly(2026, 7, 3)));
        Assert.Empty(snapshot.ProvidersFor(new DateOnly(2026, 7, 4)));
    }

    [Fact]
    public void Month_total_excludes_overflow_days_from_neighboring_months()
    {
        // July 2026's grid starts Jun 28 (Wednesday Jul 1 → 3 leading days).
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 7, 15));
        Assert.Equal(new DateOnly(2026, 6, 28), grid.GridStart);
        var rows = new List<CalendarUsageRow>
        {
            Row("2026-06-28T10:00:00Z", 7.0, "Codex"), // overflow day → heatmap yes, month total no
            Row("2026-07-02T10:00:00Z", 3.0, "Codex"),
            Row("2026-07-31T10:00:00Z", 4.0, "Codex"),
            Row("2026-08-01T10:00:00Z", 9.0, "Codex"), // trailing overflow day inside the grid
        };

        CalendarMonthSnapshot snapshot = CalendarMonthSnapshot.Build(rows, grid, Tz);

        Assert.Equal(7.0, snapshot.CostFor(new DateOnly(2026, 6, 28)));
        Assert.Equal(9.0, snapshot.CostFor(new DateOnly(2026, 8, 1)));
        Assert.Equal(7.0, snapshot.MonthTotalCost); // 3 + 4 only
    }

    [Fact]
    public void Attribution_follows_local_start_day_not_utc()
    {
        var newYork = TimeZoneInfo.FindSystemTimeZoneById("America/New_York");
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 7, 15));
        // Jul 3 23:30 EDT = Jul 4 03:30Z — belongs to Jul 3 locally.
        var rows = new List<CalendarUsageRow> { Row("2026-07-04T03:30:00Z", 6.0, "Codex") };

        CalendarMonthSnapshot snapshot = CalendarMonthSnapshot.Build(rows, grid, newYork);

        Assert.Equal(6.0, snapshot.CostFor(new DateOnly(2026, 7, 3)));
        Assert.Equal(0, snapshot.CostFor(new DateOnly(2026, 7, 4)));
    }

    private static CalendarUsageRow Row(string startIso, double cost, string provider)
    {
        DateTimeOffset start = DateTimeOffset.Parse(
            startIso,
            System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.RoundtripKind);
        return new CalendarUsageRow(
            $"u-{startIso}-{provider}",
            provider,
            "sess-1",
            "project",
            "model",
            InputTokens: 100,
            OutputTokens: 50,
            CacheCreationTokens: 0,
            CacheReadTokens: 0,
            ReasoningTokens: 0,
            TotalTokens: 150,
            cost,
            start);
    }
}
