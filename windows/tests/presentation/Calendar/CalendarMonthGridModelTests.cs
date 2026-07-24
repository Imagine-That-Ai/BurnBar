using System;
using System.Globalization;
using System.Linq;
using OpenBurnBar.App.Presentation.Calendar;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the pure month-grid math (parity: macOS <c>CalendarMonthGridTests</c>):
/// leading overflow days per locale first-weekday, 4–6 week rows, month
/// boundaries/leap years, header symbol order, ‹ › navigation, and the
/// drag-hit cell mapping.
/// </summary>
public sealed class CalendarMonthGridModelTests
{
    private static readonly CultureInfo EnUs = CultureInfo.GetCultureInfo("en-US"); // Sunday-first
    private static readonly CultureInfo DeDe = CultureInfo.GetCultureInfo("de-DE"); // Monday-first

    [Fact]
    public void March_2026_sunday_first_has_no_leading_days_and_five_rows()
    {
        // Mar 1 2026 is a Sunday; 31 days → ceil(31/7) = 5 rows.
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 3, 15), EnUs);

        Assert.Equal(new DateOnly(2026, 3, 1), grid.MonthStart);
        Assert.Equal(new DateOnly(2026, 3, 1), grid.GridStart);
        Assert.Equal(5, grid.Weeks.Count);
        Assert.Equal(35, grid.AllDays.Count);
        Assert.Equal(new DateOnly(2026, 4, 5), grid.GridEndExclusive); // last cell Apr 4 + 1
    }

    [Fact]
    public void June_2026_sunday_first_leads_one_day_into_may()
    {
        // Jun 1 2026 is a Monday → 1 leading day (May 31).
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 6, 1), EnUs);

        Assert.Equal(new DateOnly(2026, 5, 31), grid.GridStart);
        Assert.False(grid.IsInMonth(new DateOnly(2026, 5, 31)));
        Assert.True(grid.IsInMonth(new DateOnly(2026, 6, 1)));
        Assert.True(grid.IsInMonth(new DateOnly(2026, 6, 30)));
        Assert.False(grid.IsInMonth(new DateOnly(2026, 7, 1)));
    }

    [Fact]
    public void June_2026_monday_first_has_no_leading_days()
    {
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 6, 1), DeDe);

        Assert.Equal(DayOfWeek.Monday, grid.FirstDayOfWeek);
        Assert.Equal(new DateOnly(2026, 6, 1), grid.GridStart);
    }

    [Fact]
    public void February_2027_non_leap_has_five_rows_sunday_first()
    {
        // Feb 1 2027 is a Monday; 28 days + 1 leading = 29 cells → 5 rows.
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2027, 2, 10), EnUs);

        Assert.Equal(28, grid.AllDays.Count(grid.IsInMonth));
        Assert.Equal(5, grid.Weeks.Count);
    }

    [Fact]
    public void February_2024_leap_day_lands_in_grid()
    {
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2024, 2, 14), EnUs);

        Assert.Contains(new DateOnly(2024, 2, 29), grid.AllDays);
        Assert.Equal(29, grid.AllDays.Count(grid.IsInMonth));
    }

    [Fact]
    public void Weekday_symbols_follow_locale_first_weekday()
    {
        CalendarMonthGridModel sunday = CalendarMonthGridModel.Create(new DateOnly(2026, 6, 1), EnUs);
        CalendarMonthGridModel monday = CalendarMonthGridModel.Create(new DateOnly(2026, 6, 1), DeDe);

        Assert.Equal(7, sunday.WeekdaySymbols.Count);
        Assert.Equal("Sun", sunday.WeekdaySymbols[0]);
        Assert.Equal("Sat", sunday.WeekdaySymbols[6]);
        Assert.Equal("Mo", monday.WeekdaySymbols[0]);
        Assert.Equal("So", monday.WeekdaySymbols[6]);
    }

    [Fact]
    public void Advanced_navigates_across_year_boundaries()
    {
        CalendarMonthGridModel january = CalendarMonthGridModel.Create(new DateOnly(2026, 1, 20), EnUs);

        Assert.Equal(new DateOnly(2025, 12, 1), january.Advanced(-1).MonthStart);
        Assert.Equal(new DateOnly(2026, 2, 1), january.Advanced(1).MonthStart);
        Assert.Equal(new DateOnly(2027, 1, 1), january.Advanced(12).MonthStart);
    }

    [Fact]
    public void MonthStartContaining_normalizes_any_day()
    {
        Assert.Equal(new DateOnly(2026, 7, 1), CalendarMonthGridModel.MonthStartContaining(new DateOnly(2026, 7, 31)));
    }

    [Fact]
    public void DayIndexAt_maps_points_like_the_macos_grid()
    {
        // 7 cells of 50 DIPs + 6 gutters of 4 → gridWidth 374; cell pitch 54.
        const double gridWidth = (7 * 50) + (6 * 4);

        Assert.Equal(0, CalendarMonthGridModel.DayIndexAt(0, 0, gridWidth, rows: 5, cellHeight: 46));
        Assert.Equal(6, CalendarMonthGridModel.DayIndexAt(373, 0, gridWidth, rows: 5, cellHeight: 46));
        // Row pitch is 50 (46 cell + 4 gutter): y=47 still maps to row 0's gutter…
        Assert.Equal(0, CalendarMonthGridModel.DayIndexAt(0, 47, gridWidth, rows: 5, cellHeight: 46));
        // …and y=51 lands on row 1.
        Assert.Equal(7, CalendarMonthGridModel.DayIndexAt(0, 51, gridWidth, rows: 5, cellHeight: 46));
        // The gutter between columns resolves to the nearest cell (drag never dies).
        Assert.Equal(0, CalendarMonthGridModel.DayIndexAt(51, 0, gridWidth, rows: 5, cellHeight: 46));
        // Beyond the last column clamps to column 6.
        Assert.Equal(6, CalendarMonthGridModel.DayIndexAt(10_000, 0, gridWidth, rows: 5, cellHeight: 46));
        // Outside the rows / negative → null.
        Assert.Null(CalendarMonthGridModel.DayIndexAt(0, 5 * 50 + 1, gridWidth, rows: 5, cellHeight: 46));
        Assert.Null(CalendarMonthGridModel.DayIndexAt(-1, 0, gridWidth, rows: 5, cellHeight: 46));
        Assert.Null(CalendarMonthGridModel.DayIndexAt(0, -1, gridWidth, rows: 5, cellHeight: 46));
    }
}
