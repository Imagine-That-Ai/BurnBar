using System;

namespace OpenBurnBar.App.Presentation.Budget;

// PORTED from AgentLens/Services/DataStore/BudgetForecast.swift — the "at the current burn
// rate, when will this rule cross its limit?" projection that renders the "Projected hit"
// chip beside each rule. The Swift actor mixes SQL reads with the arithmetic; this port keeps
// the arithmetic PURE (spend + trailing daily average come in as inputs), so it is fully
// unit-tested on macOS while the SQL spend source is a later storage-wave seam.
//
// The fail-CLOSED contract is preserved: an unavailable spend read yields
// BudgetProjection.Unavailable, whose derived safety properties (WillExceed==true,
// Headroom==0, UsedPercent==null) refuse to paint a rule as under budget on a read fault.

/// <summary>Forward projection for a rule. Mirrors Swift <c>BudgetForecast.Projection</c>.</summary>
public sealed record BudgetProjection
{
    public string RuleId { get; init; } = string.Empty;
    public double CurrentSpend { get; init; }
    public double Limit { get; init; }
    public double TrailingDailyAverage { get; init; }
    public double? DaysUntilLimit { get; init; }
    public double ProjectedAtPeriodEnd { get; init; }
    public DateTimeOffset GeneratedAt { get; init; }

    /// <summary>
    /// True when the spend history could not be read. The numeric fields are meaningless in
    /// this state; the derived safety properties fail closed.
    /// </summary>
    public bool DataUnavailable { get; init; }

    /// <summary>A fail-closed projection for when the spend ledger could not be read.</summary>
    public static BudgetProjection Unavailable(BudgetRule rule, DateTimeOffset generatedAt) => new()
    {
        RuleId = rule.Id,
        CurrentSpend = 0,
        Limit = rule.AmountUsd,
        TrailingDailyAverage = 0,
        DaysUntilLimit = null,
        ProjectedAtPeriodEnd = 0,
        GeneratedAt = generatedAt,
        DataUnavailable = true,
    };

    /// <summary>Fails closed on a read fault: an unknown spend is treated as potentially over.</summary>
    public bool WillExceed => DataUnavailable || ProjectedAtPeriodEnd >= Limit;

    /// <summary>Fails closed on a read fault: no headroom is promised when spend is unknown.</summary>
    public double Headroom => DataUnavailable ? 0 : Math.Max(0, Limit - CurrentSpend);

    /// <summary><c>null</c> when spend is unknown (read fault) — distinct from a genuine 0.</summary>
    public double? UsedPercent
    {
        get
        {
            if (DataUnavailable)
            {
                return null;
            }

            return Limit > 0 ? CurrentSpend / Limit : 0;
        }
    }

    /// <summary>ETA for the daily-rate projection; <c>null</c> when the trailing rate is zero or unread.</summary>
    public DateTimeOffset? ProjectedHitDate()
    {
        if (DataUnavailable)
        {
            return null;
        }

        if (DaysUntilLimit is not double days || double.IsNaN(days) || double.IsInfinity(days))
        {
            return null;
        }

        return GeneratedAt.AddSeconds(days * 86_400);
    }
}

/// <summary>
/// Pure projection arithmetic. Mirrors the Swift <c>BudgetForecast.forecast(forRule:)</c> body
/// after the SQL reads have resolved (or failed).
/// </summary>
public static class BudgetForecaster
{
    /// <summary>
    /// Projects a rule given its current spend window. <paramref name="currentSpend"/> and
    /// <paramref name="trailingDailyAverage"/> are the resolved ledger reads; pass a
    /// <c>null</c> spend to model a read fault (yields the fail-closed unavailable projection).
    /// </summary>
    public static BudgetProjection Project(
        BudgetRule rule,
        double? currentSpend,
        double trailingDailyAverage,
        DateTimeOffset reference,
        BudgetClock? clock = null)
    {
        if (currentSpend is not double spend)
        {
            return BudgetProjection.Unavailable(rule, reference);
        }

        BudgetClock realClock = clock ?? BudgetClock.Default;
        double limit = rule.AmountUsd;
        double remaining = Math.Max(0, limit - spend);

        double? daysUntilLimit = trailingDailyAverage > 0 ? remaining / trailingDailyAverage : null;

        double projectedAtPeriodEnd;
        switch (rule.Period)
        {
            case BudgetPeriod.Day:
            {
                double elapsedHours = ElapsedHoursIntoToday(reference, realClock);
                projectedAtPeriodEnd = elapsedHours > 0
                    ? spend / Math.Max(elapsedHours, 0.1) * 24
                    : spend;
                break;
            }

            case BudgetPeriod.Week:
            case BudgetPeriod.Month:
            {
                DateTimeOffset? windowStart = realClock.WindowStart(rule.Period, reference);
                DateTimeOffset? windowEnd = realClock.NextReset(rule.Period, reference);
                if (windowStart is not DateTimeOffset start || windowEnd is not DateTimeOffset end)
                {
                    projectedAtPeriodEnd = spend;
                    break;
                }

                double totalDays = Math.Max(1.0, (end - start).TotalSeconds / 86_400);
                double elapsedDays = Math.Max(0.01, (reference - start).TotalSeconds / 86_400);
                double dailyRateSoFar = spend / elapsedDays;
                projectedAtPeriodEnd = dailyRateSoFar * totalDays;
                break;
            }

            case BudgetPeriod.AllTime:
            default:
                projectedAtPeriodEnd = spend;
                break;
        }

        return new BudgetProjection
        {
            RuleId = rule.Id,
            CurrentSpend = spend,
            Limit = limit,
            TrailingDailyAverage = trailingDailyAverage,
            DaysUntilLimit = daysUntilLimit,
            ProjectedAtPeriodEnd = projectedAtPeriodEnd,
            GeneratedAt = reference,
            DataUnavailable = false,
        };
    }

    private static double ElapsedHoursIntoToday(DateTimeOffset reference, BudgetClock clock)
    {
        DateTimeOffset? start = clock.WindowStart(BudgetPeriod.Day, reference);
        if (start is not DateTimeOffset dayStart)
        {
            return 0;
        }

        return (reference - dayStart).TotalSeconds / 3_600;
    }
}
