using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace OpenBurnBar.App.Presentation.Calendar;

/// <summary>
/// Pure month-grid math: which days fill which cells, in what order the weekday
/// header reads, and the exact fetch window the visible grid spans. Port of macOS
/// <c>AgentLens/Views/Calendar/CalendarMonthGrid.swift</c> (the view-free
/// <c>CalendarMonthGridModel</c>) — kept view-free so the whole layout is
/// unit-testable, including month boundaries and locales whose week starts on Monday.
///
/// Day arithmetic is Gregorian (<see cref="DateOnly"/>); the injected
/// <see cref="CultureInfo"/> supplies the header symbols and first weekday, the
/// same surface area the Windows shell exposes elsewhere.
/// </summary>
public sealed class CalendarMonthGridModel : IEquatable<CalendarMonthGridModel>
{
    /// <summary>Cell gutter in DIPs; shared by the drag-hit math and the XAML grid.</summary>
    public const double CellSpacing = 4;

    private CalendarMonthGridModel(
        DateOnly monthStart,
        DayOfWeek firstDayOfWeek,
        CultureInfo culture,
        DateOnly gridStart,
        IReadOnlyList<IReadOnlyList<DateOnly>> weeks,
        IReadOnlyList<string> weekdaySymbols)
    {
        MonthStart = monthStart;
        FirstDayOfWeek = firstDayOfWeek;
        Culture = culture;
        GridStart = gridStart;
        Weeks = weeks;
        WeekdaySymbols = weekdaySymbols;
    }

    /// <summary>First day of the visible month.</summary>
    public DateOnly MonthStart { get; }

    /// <summary>The locale's first weekday (drives the leading overflow cells + header order).</summary>
    public DayOfWeek FirstDayOfWeek { get; }

    /// <summary>The culture the header symbols came from.</summary>
    public CultureInfo Culture { get; }

    /// <summary>First displayed cell — up to 6 days into the previous month.</summary>
    public DateOnly GridStart { get; }

    /// <summary>Displayed days in row-major order, 7 per week, 4–6 weeks.</summary>
    public IReadOnlyList<IReadOnlyList<DateOnly>> Weeks { get; }

    /// <summary>Weekday abbreviations ordered for <see cref="FirstDayOfWeek"/>.</summary>
    public IReadOnlyList<string> WeekdaySymbols { get; }

    /// <summary>All displayed days flattened, row-major (index = drag-gesture cell index).</summary>
    public IReadOnlyList<DateOnly> AllDays => Weeks.SelectMany(week => week).ToArray();

    /// <summary>Exclusive fetch-window end: the day after the last displayed cell.</summary>
    public DateOnly GridEndExclusive => Weeks[^1][^1].AddDays(1);

    /// <summary>Whether <paramref name="day"/> belongs to the visible calendar month itself.</summary>
    public bool IsInMonth(DateOnly day) =>
        day.Year == MonthStart.Year && day.Month == MonthStart.Month;

    /// <summary>The month grid containing <paramref name="month"/> (any day inside the month).</summary>
    public static CalendarMonthGridModel Create(DateOnly month, CultureInfo? culture = null)
    {
        CultureInfo effectiveCulture = culture ?? CultureInfo.CurrentCulture;
        DayOfWeek firstDayOfWeek = effectiveCulture.DateTimeFormat.FirstDayOfWeek;
        var monthStart = new DateOnly(month.Year, month.Month, 1);

        int leading = ((int)monthStart.DayOfWeek - (int)firstDayOfWeek + 7) % 7;
        DateOnly gridStart = monthStart.AddDays(-leading);

        int daysInMonth = DateTime.DaysInMonth(monthStart.Year, monthStart.Month);
        int cellCount = (int)Math.Ceiling((leading + daysInMonth) / 7.0) * 7;

        var days = new List<DateOnly>(cellCount);
        DateOnly cursor = gridStart;
        for (int i = 0; i < cellCount; i++)
        {
            days.Add(cursor);
            cursor = cursor.AddDays(1);
        }

        var weeks = new List<IReadOnlyList<DateOnly>>(cellCount / 7);
        for (int start = 0; start < days.Count; start += 7)
        {
            weeks.Add(days.GetRange(start, Math.Min(7, days.Count - start)));
        }

        string[] symbols = effectiveCulture.DateTimeFormat.AbbreviatedDayNames;
        int first = (int)firstDayOfWeek;
        var ordered = symbols.Skip(first).Concat(symbols.Take(first)).ToArray();

        return new CalendarMonthGridModel(monthStart, firstDayOfWeek, effectiveCulture, gridStart, weeks, ordered);
    }

    /// <summary>Start-of-month of the month containing <paramref name="day"/>.</summary>
    public static DateOnly MonthStartContaining(DateOnly day) => new(day.Year, day.Month, 1);

    /// <summary>The month <paramref name="deltaMonths"/> months away from this one (for ‹ › navigation).</summary>
    public CalendarMonthGridModel Advanced(int deltaMonths) =>
        Create(MonthStart.AddMonths(deltaMonths), Culture);

    // MARK: Drag-hit math

    /// <summary>
    /// Maps a point inside the cells area to a row-major cell index
    /// (<see cref="AllDays"/>). Columns are 7 across; rows are
    /// <paramref name="cellHeight"/> tall with <paramref name="spacing"/> gutters.
    /// Gaps between cells resolve to the nearest cell so a drag never dies in the
    /// gutter; points outside the area return <c>null</c>. Port of the macOS
    /// <c>dayIndex(at:gridWidth:rows:cellHeight:spacing:)</c>.
    /// </summary>
    public static int? DayIndexAt(
        double x,
        double y,
        double gridWidth,
        int rows,
        double cellHeight,
        double spacing = CellSpacing)
    {
        double cellWidth = (gridWidth - (6 * spacing)) / 7;
        if (cellWidth <= 0 || cellHeight <= 0 || x < 0 || y < 0)
        {
            return null;
        }

        int column = (int)(x / (cellWidth + spacing));
        int row = (int)(y / (cellHeight + spacing));
        if (row < 0 || row >= rows)
        {
            return null;
        }

        int clampedColumn = Math.Min(6, column);
        return (row * 7) + clampedColumn;
    }

    public bool Equals(CalendarMonthGridModel? other) =>
        other is not null
        && MonthStart == other.MonthStart
        && FirstDayOfWeek == other.FirstDayOfWeek
        && GridStart == other.GridStart
        && Weeks.Count == other.Weeks.Count
        && Weeks.SelectMany(w => w).SequenceEqual(other.Weeks.SelectMany(w => w));

    public override bool Equals(object? obj) => Equals(obj as CalendarMonthGridModel);

    public override int GetHashCode() => HashCode.Combine(MonthStart, FirstDayOfWeek, GridStart, Weeks.Count);
}
