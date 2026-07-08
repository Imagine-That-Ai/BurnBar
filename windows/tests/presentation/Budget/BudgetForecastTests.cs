using System;
using OpenBurnBar.App.Presentation.Budget;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Budget;

// Port of the projection safety + arithmetic locked in by BudgetForecastMattersTests.swift:
// an unreadable spend history fails CLOSED (willExceed, no headroom, unknown percent), and the
// linear period-end projection matches the Swift math.

public sealed class BudgetForecastTests
{
    [Fact]
    public void Unavailable_FailsClosed_NeverPaintsRuleAsSafe()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 100);
        BudgetProjection projection = BudgetForecaster.Project(
            rule, currentSpend: null, trailingDailyAverage: 5, reference: DateTimeOffset.UtcNow);

        Assert.True(projection.DataUnavailable);
        Assert.True(projection.WillExceed);            // unknown spend is treated as over
        Assert.Equal(0, projection.Headroom);          // no headroom promised
        Assert.Null(projection.UsedPercent);           // unknown, not 0%
        Assert.Null(projection.ProjectedHitDate());
    }

    [Fact]
    public void Healthy_UnderBudget_ReportsHeadroomAndPercent()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 100);
        BudgetProjection projection = BudgetForecaster.Project(
            rule, currentSpend: 30, trailingDailyAverage: 0, reference: DateTimeOffset.UtcNow);

        Assert.False(projection.DataUnavailable);
        Assert.Equal(0.30, projection.UsedPercent!.Value, 6);
        Assert.Equal(70, projection.Headroom);
        Assert.Null(projection.DaysUntilLimit);        // no trailing rate => no ETA
        Assert.Null(projection.ProjectedHitDate());
    }

    [Fact]
    public void DaysUntilLimit_AndHitDate_UseTheTrailingDailyAverage()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 100);
        DateTimeOffset now = new(2026, 7, 3, 0, 0, 0, TimeSpan.Zero);
        // remaining 60 at $10/day => 6 days to limit.
        BudgetProjection projection = BudgetForecaster.Project(
            rule, currentSpend: 40, trailingDailyAverage: 10, reference: now);

        Assert.Equal(6, projection.DaysUntilLimit!.Value, 6);
        DateTimeOffset? hit = projection.ProjectedHitDate();
        Assert.NotNull(hit);
        Assert.Equal(now.AddDays(6), hit!.Value);
    }

    [Fact]
    public void MonthProjection_LinearlyExtrapolatesTheDailyRate()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, scope: BudgetRuleScope.Global, amountUsd: 200, providerId: null, accountId: null) with { Period = BudgetPeriod.Month };
        // Window 2026-07-01 .. 2026-08-01 (31 days). At 14.5 days elapsed with $145 spent =>
        // $10/day => projected month-end = 310. Exceeds the 200 cap.
        DateTimeOffset reference = new(2026, 7, 15, 12, 0, 0, TimeSpan.Zero);
        BudgetProjection projection = BudgetForecaster.Project(
            rule, currentSpend: 145, trailingDailyAverage: 0, reference: reference);

        Assert.Equal(310, projection.ProjectedAtPeriodEnd, 3);
        Assert.True(projection.WillExceed);
    }

    [Fact]
    public void DayProjection_ExtrapolatesTodayToMidnight()
    {
        BudgetRule rule = BudgetFixtures.Rule(BudgetBehavior.WarnThenBlock, amountUsd: 50) with { Period = BudgetPeriod.Day };
        // 6 hours into the day, $3 spent => $12 projected by midnight.
        DateTimeOffset reference = new(2026, 7, 3, 6, 0, 0, TimeSpan.Zero);
        BudgetProjection projection = BudgetForecaster.Project(
            rule, currentSpend: 3, trailingDailyAverage: 0, reference: reference);

        Assert.Equal(12, projection.ProjectedAtPeriodEnd, 3);
        Assert.False(projection.WillExceed);
    }
}
