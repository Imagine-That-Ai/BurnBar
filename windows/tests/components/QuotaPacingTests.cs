using System;
using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the pacing math against ProviderQuotaPacing.swift +
/// OpenBurnBarCoreTests/ProviderQuotaPacingTests.swift golden values.</summary>
public sealed class QuotaPacingTests
{
    private static readonly DateTimeOffset Reset = new(2026, 7, 4, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void WindowDuration_fixed_windows()
    {
        Assert.Equal(TimeSpan.FromHours(5), PacingMath.WindowDuration(QuotaWindowKind.RollingHours, Reset));
        Assert.Equal(TimeSpan.FromHours(24), PacingMath.WindowDuration(QuotaWindowKind.Daily, Reset));
        Assert.Equal(TimeSpan.FromDays(7), PacingMath.WindowDuration(QuotaWindowKind.Weekly, Reset));
        Assert.Equal(TimeSpan.FromDays(7), PacingMath.WindowDuration(QuotaWindowKind.RollingDays, Reset));
    }

    [Fact]
    public void WindowDuration_monthly_uses_calendar_arithmetic()
    {
        // Reset on 2026-03-01 → previous month starts 2026-02-01; Feb 2026 is 28 days (not a leap year).
        var marchReset = new DateTimeOffset(2026, 3, 1, 0, 0, 0, TimeSpan.Zero);
        Assert.Equal(TimeSpan.FromDays(28), PacingMath.WindowDuration(QuotaWindowKind.Monthly, marchReset));

        // Reset on 2026-05-01 → April is 30 days.
        var mayReset = new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero);
        Assert.Equal(TimeSpan.FromDays(30), PacingMath.WindowDuration(QuotaWindowKind.Monthly, mayReset));
    }

    [Fact]
    public void WindowDuration_null_for_unbounded_kinds()
    {
        Assert.Null(PacingMath.WindowDuration(QuotaWindowKind.Lifetime, Reset));
        Assert.Null(PacingMath.WindowDuration(QuotaWindowKind.Custom, Reset));
    }

    [Fact]
    public void Pace_null_without_reset_or_window()
    {
        Assert.Null(PacingMath.Pace(QuotaWindowKind.Daily, null, 0.5, Reset));
        Assert.Null(PacingMath.Pace(QuotaWindowKind.Lifetime, Reset, 0.5, Reset.AddHours(-1)));
        Assert.Null(PacingMath.Pace(QuotaWindowKind.Custom, Reset, 0.5, Reset.AddHours(-1)));
    }

    [Fact]
    public void Pace_on_pace_when_usage_tracks_elapsed_time()
    {
        // Daily window, halfway through (12h elapsed of 24h), 50% used → delta 0 → on pace.
        var now = Reset.AddHours(-12);
        IdealPace pace = PacingMath.Pace(QuotaWindowKind.Daily, Reset, 0.5, now)!.Value;

        Assert.Equal(0.5, pace.ElapsedFraction, 6);
        Assert.Equal(0.5, pace.UsedFraction, 6);
        Assert.Equal(0.0, pace.Delta, 6);
        Assert.Equal(PaceSeverity.OnPace, pace.Severity);
        Assert.Equal("on pace", pace.HumanLabel);
        Assert.Equal(Reset, pace.WindowEnd);
        Assert.Equal(Reset.AddHours(-24), pace.WindowStart);
    }

    [Fact]
    public void Pace_within_threshold_is_still_on_pace()
    {
        // 51% used at 50% elapsed → delta 0.01 < 0.03 threshold.
        var now = Reset.AddHours(-12);
        IdealPace pace = PacingMath.Pace(QuotaWindowKind.Daily, Reset, 0.51, now)!.Value;
        Assert.Equal(PaceSeverity.OnPace, pace.Severity);
        Assert.Equal("on pace", pace.HumanLabel);
    }

    [Fact]
    public void Pace_ahead_of_budget_burning_fast()
    {
        var now = Reset.AddHours(-12); // 50% elapsed
        IdealPace pace = PacingMath.Pace(QuotaWindowKind.Daily, Reset, 0.82, now)!.Value;

        Assert.Equal(0.32, pace.Delta, 6);
        Assert.Equal(PaceSeverity.AheadOfBudget, pace.Severity);
        Assert.Equal("+32% pace", pace.HumanLabel);
    }

    [Fact]
    public void Pace_behind_budget_has_headroom()
    {
        var now = Reset.AddHours(-12); // 50% elapsed
        IdealPace pace = PacingMath.Pace(QuotaWindowKind.Daily, Reset, 0.21, now)!.Value;

        Assert.Equal(-0.29, pace.Delta, 6);
        Assert.Equal(PaceSeverity.BehindBudget, pace.Severity);
        Assert.Equal("-29% pace", pace.HumanLabel);
    }

    [Fact]
    public void Pace_stale_snapshot_resets_to_start_of_next_window()
    {
        // now is PAST resetsAt → assume next window just began; elapsed = 0.
        var now = Reset.AddHours(1);
        IdealPace pace = PacingMath.Pace(QuotaWindowKind.Daily, Reset, 0.40, now)!.Value;

        Assert.Equal(0.0, pace.ElapsedFraction, 6);
        Assert.Equal(0.40, pace.UsedFraction, 6);
        Assert.Equal(0.40, pace.Delta, 6);
        Assert.Equal(PaceSeverity.AheadOfBudget, pace.Severity);
        Assert.Equal("+40% pace", pace.HumanLabel);
        Assert.Equal(Reset, pace.WindowStart);
        Assert.Equal(Reset.AddHours(24), pace.WindowEnd);
    }

    [Fact]
    public void Pace_clamps_elapsed_and_used_to_unit_range()
    {
        // now far before windowStart would give negative elapsed → clamp to 0; used > 1 → clamp to 1.
        var now = Reset.AddHours(-48); // before the 24h window even opened
        IdealPace pace = PacingMath.Pace(QuotaWindowKind.Daily, Reset, 1.5, now)!.Value;
        Assert.Equal(0.0, pace.ElapsedFraction, 6);
        Assert.Equal(1.0, pace.UsedFraction, 6);
    }
}
