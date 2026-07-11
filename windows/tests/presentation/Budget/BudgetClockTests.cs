using System;
using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// Deterministic port of BudgetPeriod.windowStart / nextReset (Swift OpenBurnBarCore).

public sealed class BudgetClockTests
{
    private static readonly DateTimeOffset Ref = new(2026, 7, 3, 14, 30, 0, TimeSpan.Zero); // a Friday

    [Fact]
    public void Day_WindowStartIsMidnight_ResetIsNextMidnight()
    {
        BudgetClock clock = BudgetClock.Default;
        Assert.Equal(new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.Zero), clock.WindowStart(BudgetPeriod.Day, Ref));
        Assert.Equal(new DateTimeOffset(2026, 7, 4, 0, 0, 0, TimeSpan.Zero), clock.NextReset(BudgetPeriod.Day, Ref));
    }

    [Fact]
    public void Week_SundayStart_WrapsToPriorSunday_ResetSevenDaysOn()
    {
        BudgetClock clock = new(DayOfWeek.Sunday);
        // 2026-07-03 is a Friday; the Sunday of its week is 2026-06-28.
        Assert.Equal(new DateTimeOffset(2026, 6, 28, 0, 0, 0, TimeSpan.Zero), clock.WindowStart(BudgetPeriod.Week, Ref));
        Assert.Equal(new DateTimeOffset(2026, 7, 5, 0, 0, 0, TimeSpan.Zero), clock.NextReset(BudgetPeriod.Week, Ref));
    }

    [Fact]
    public void Week_MondayStart_WrapsToPriorMonday()
    {
        BudgetClock clock = new(DayOfWeek.Monday);
        // Monday of the 2026-07-03 (Friday) week is 2026-06-29.
        Assert.Equal(new DateTimeOffset(2026, 6, 29, 0, 0, 0, TimeSpan.Zero), clock.WindowStart(BudgetPeriod.Week, Ref));
    }

    [Fact]
    public void Month_WindowStartIsFirst_ResetIsNextMonthFirst()
    {
        BudgetClock clock = BudgetClock.Default;
        Assert.Equal(new DateTimeOffset(2026, 7, 1, 0, 0, 0, TimeSpan.Zero), clock.WindowStart(BudgetPeriod.Month, Ref));
        Assert.Equal(new DateTimeOffset(2026, 8, 1, 0, 0, 0, TimeSpan.Zero), clock.NextReset(BudgetPeriod.Month, Ref));
    }

    [Fact]
    public void Month_December_ResetRollsToNextYear()
    {
        BudgetClock clock = BudgetClock.Default;
        DateTimeOffset dec = new(2026, 12, 20, 9, 0, 0, TimeSpan.Zero);
        Assert.Equal(new DateTimeOffset(2027, 1, 1, 0, 0, 0, TimeSpan.Zero), clock.NextReset(BudgetPeriod.Month, dec));
    }

    [Fact]
    public void AllTime_HasNoWindowOrReset()
    {
        BudgetClock clock = BudgetClock.Default;
        Assert.Null(clock.WindowStart(BudgetPeriod.AllTime, Ref));
        Assert.Null(clock.NextReset(BudgetPeriod.AllTime, Ref));
    }

    [Fact]
    public void WindowStart_PreservesTheReferenceOffset()
    {
        BudgetClock clock = BudgetClock.Default;
        DateTimeOffset pacific = new(2026, 7, 3, 14, 30, 0, TimeSpan.FromHours(-7));
        DateTimeOffset? start = clock.WindowStart(BudgetPeriod.Day, pacific);
        Assert.NotNull(start);
        Assert.Equal(TimeSpan.FromHours(-7), start!.Value.Offset);
        Assert.Equal(new DateTimeOffset(2026, 7, 3, 0, 0, 0, TimeSpan.FromHours(-7)), start!.Value);
    }
}
