using System;
using System.Linq;
using OpenBurnBar.App.Presentation.Calendar;
using OpenBurnBar.App.Presentation.Dashboard;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Calendar;

/// <summary>
/// Pins the labeled sample tier: deterministic rows that cover the requested
/// month grid (any navigable month), never claim future spend, and are marked
/// <see cref="DashboardUsageOrigin.Sample"/> so the UI labels them honestly.
/// </summary>
public sealed class CalendarUsageSampleDataTests
{
    private static readonly DateTimeOffset FixedNow =
        new(2026, 7, 15, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Sample_is_deterministic_for_the_same_month_and_clock()
    {
        CalendarUsageData first = CalendarUsageSampleData.Rows(new DateOnly(2026, 7, 1), FixedNow, TimeZoneInfo.Utc);
        CalendarUsageData second = CalendarUsageSampleData.Rows(new DateOnly(2026, 7, 1), FixedNow, TimeZoneInfo.Utc);

        Assert.Equal(first.Rows.Select(r => r.Id), second.Rows.Select(r => r.Id));
        Assert.Equal(first.Rows.Select(r => r.CostUsd), second.Rows.Select(r => r.CostUsd));
    }

    [Fact]
    public void Sample_rows_land_inside_the_requested_month_grid()
    {
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 7, 1));
        CalendarUsageData data = CalendarUsageSampleData.Rows(new DateOnly(2026, 7, 1), FixedNow, TimeZoneInfo.Utc);

        Assert.Equal(DashboardUsageOrigin.Sample, data.Origin);
        Assert.True(data.HasData);
        Assert.All(data.Rows, row =>
        {
            DateOnly day = CalendarLocalTime.LocalDay(row.StartUtc, TimeZoneInfo.Utc);
            Assert.True(day >= grid.GridStart && day < grid.GridEndExclusive);
        });
        // Both the month proper and overflow days carry rows so the grid renders fully.
        Assert.Contains(data.Rows, row => grid.IsInMonth(CalendarLocalTime.LocalDay(row.StartUtc, TimeZoneInfo.Utc)));
    }

    [Fact]
    public void Sample_never_claims_future_spend()
    {
        CalendarUsageData data = CalendarUsageSampleData.Rows(new DateOnly(2026, 7, 1), FixedNow, TimeZoneInfo.Utc);
        DateOnly today = CalendarLocalTime.Today(TimeZoneInfo.Utc, FixedNow);

        Assert.All(data.Rows, row =>
            Assert.True(CalendarLocalTime.LocalDay(row.StartUtc, TimeZoneInfo.Utc) <= today));
    }

    [Fact]
    public void Sample_feeds_every_analytics_card()
    {
        CalendarUsageData data = CalendarUsageSampleData.Rows(new DateOnly(2026, 7, 1), FixedNow, TimeZoneInfo.Utc);
        CalendarMonthGridModel grid = CalendarMonthGridModel.Create(new DateOnly(2026, 7, 1));
        CalendarMonthSnapshot month = CalendarMonthSnapshot.Build(data.Rows, grid, TimeZoneInfo.Utc);

        Assert.True(month.PeakDayCost > 0);
        Assert.True(month.MonthTotalCost > 0);
        Assert.NotEmpty(month.DayProviders);

        var selection = new CalendarSelectionModel();
        selection.Select(new DateOnly(2026, 7, 6));
        selection.ExtendTo(new DateOnly(2026, 7, 10));
        CalendarSelectionSnapshot snapshot = CalendarSelectionSnapshot.Build(
            data.Rows,
            selection.SelectedDays,
            TimeZoneInfo.Utc);

        Assert.False(snapshot.IsEmpty);
        Assert.True(snapshot.TotalCost > 0);
        Assert.NotEmpty(snapshot.ProviderShares);
        Assert.NotEmpty(snapshot.TopModels);
        Assert.NotEmpty(snapshot.ProjectShares);
        Assert.NotNull(snapshot.PeakWeekdayIndex);
        Assert.True(snapshot.CacheReadTokens > 0);
        Assert.True(snapshot.ReasoningTokens > 0);
    }
}
