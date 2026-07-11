// Live budget envelope + deterministic projector.
//
// Port of ComputerUseBudgetEnvelope.swift. The hourly cloud function drives
// `level` (normal / soft_cap / hard_cap) and the tightened caps; the projector
// reproduces the same envelope from a month-end projection so the coordinator
// and the cloud agree.

using System;

namespace OpenBurnBar.ComputerUse.Core.Gate;

/// <summary>Budget severity level.</summary>
public enum BudgetLevel
{
    Normal,
    SoftCap,
    HardCap,
}

/// <summary>Wire strings for <see cref="BudgetLevel"/>.</summary>
public static class BudgetLevelWire
{
    public static string ToWire(this BudgetLevel level) => level switch
    {
        BudgetLevel.Normal => "normal",
        BudgetLevel.SoftCap => "soft_cap",
        BudgetLevel.HardCap => "hard_cap",
        _ => throw new ArgumentOutOfRangeException(nameof(level), level, null),
    };
}

/// <summary>The action footprint the session/day may spend.</summary>
public sealed class ComputerUseBudgetEnvelope
{
    public ComputerUseBudgetEnvelope(
        BudgetLevel level,
        double projectedMonthEndUsd,
        double monthToDateUsd,
        int activeActionsPerRun,
        int activeActionsPerDay,
        int activeSessionsPerDay,
        double perUserDailySpendCeilingUsd,
        DateTimeOffset updatedAt)
    {
        Level = level;
        ProjectedMonthEndUsd = projectedMonthEndUsd;
        MonthToDateUsd = monthToDateUsd;
        ActiveActionsPerRun = activeActionsPerRun;
        ActiveActionsPerDay = activeActionsPerDay;
        ActiveSessionsPerDay = activeSessionsPerDay;
        PerUserDailySpendCeilingUsd = perUserDailySpendCeilingUsd;
        UpdatedAt = updatedAt;
    }

    public BudgetLevel Level { get; }

    public double ProjectedMonthEndUsd { get; }

    public double MonthToDateUsd { get; }

    public int ActiveActionsPerRun { get; }

    public int ActiveActionsPerDay { get; }

    public int ActiveSessionsPerDay { get; }

    public double PerUserDailySpendCeilingUsd { get; }

    public DateTimeOffset UpdatedAt { get; }

    /// <summary>The conservative default when no budget document exists yet.</summary>
    public static ComputerUseBudgetEnvelope InitialNormal { get; } = new(
        BudgetLevel.Normal,
        projectedMonthEndUsd: 0,
        monthToDateUsd: 0,
        activeActionsPerRun: 50,
        activeActionsPerDay: 200,
        activeSessionsPerDay: 4,
        perUserDailySpendCeilingUsd: 5.0,
        updatedAt: DateTimeOffset.FromUnixTimeSeconds(0));

    /// <summary>The tightened envelope applied at the soft-cap boundary.</summary>
    public static ComputerUseBudgetEnvelope SoftCapEnvelope(double projectedMonthEndUsd, double monthToDateUsd, DateTimeOffset updatedAt)
        => new(BudgetLevel.SoftCap, projectedMonthEndUsd, monthToDateUsd, 25, 100, 2, 2.5, updatedAt);

    /// <summary>The zeroed envelope after the hard-cap kill switch fires.</summary>
    public static ComputerUseBudgetEnvelope HardCapEnvelope(double projectedMonthEndUsd, double monthToDateUsd, DateTimeOffset updatedAt)
        => new(BudgetLevel.HardCap, projectedMonthEndUsd, monthToDateUsd, 0, 0, 0, 0, updatedAt);
}

/// <summary>Deterministic envelope projector shared by the coordinator and cloud.</summary>
public static class ComputerUseBudgetProjector
{
    /// <summary>Soft cap engages at ≥ $1500/mo projected.</summary>
    public const double SoftCapThresholdUsd = 1500;

    /// <summary>Hard cap engages at ≥ $2500/mo projected.</summary>
    public const double HardCapThresholdUsd = 2500;

    public static ComputerUseBudgetEnvelope Envelope(double projectedMonthEnd, double monthToDate, DateTimeOffset now)
    {
        if (projectedMonthEnd >= HardCapThresholdUsd)
        {
            return ComputerUseBudgetEnvelope.HardCapEnvelope(projectedMonthEnd, monthToDate, now);
        }

        if (projectedMonthEnd >= SoftCapThresholdUsd)
        {
            return ComputerUseBudgetEnvelope.SoftCapEnvelope(projectedMonthEnd, monthToDate, now);
        }

        return new ComputerUseBudgetEnvelope(
            BudgetLevel.Normal,
            projectedMonthEnd,
            monthToDate,
            activeActionsPerRun: 50,
            activeActionsPerDay: 200,
            activeSessionsPerDay: 4,
            perUserDailySpendCeilingUsd: 5.0,
            updatedAt: now);
    }

    /// <summary>Linear month-to-date → month-end extrapolation, clamped to avoid /0.</summary>
    public static double ProjectMonthEnd(double monthToDateUsd, int daysElapsed, int daysInMonth)
    {
        var elapsed = Math.Max(daysElapsed, 1);
        var total = Math.Max(daysInMonth, elapsed);
        return monthToDateUsd * total / elapsed;
    }
}
