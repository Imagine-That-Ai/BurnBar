using System;
using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the twin-ring dial model against QuotaArcDial.swift +
/// ProviderQuotaTypes.swift golden values.</summary>
public sealed class QuotaArcDialModelTests
{
    private static readonly DateTimeOffset Now = new(2026, 7, 3, 12, 0, 0, TimeSpan.Zero);

    // ── QuotaDialBucket: remaining/progress semantics (ProviderQuotaTypes.swift) ─────────────

    [Fact]
    public void DialBucket_usedPercent_drives_remaining_and_progress()
    {
        var b = new QuotaDialBucket(QuotaWindowKind.Weekly, usedPercent: 25);
        Assert.Equal(75, b.RemainingPercent!.Value, 6);
        Assert.Equal(0.75, b.RemainingFraction, 6);
        Assert.Equal(0.25, b.ProgressFraction, 6);
        Assert.Equal("7d", b.WindowLabel);
    }

    [Fact]
    public void DialBucket_limit_and_remaining_ratio()
    {
        var b = new QuotaDialBucket(QuotaWindowKind.Monthly, remainingValue: 200_000, limitValue: 1_000_000);
        Assert.Equal(20, b.RemainingPercent!.Value, 6);
        Assert.Equal(0.20, b.RemainingFraction, 6);
        Assert.Equal(0.80, b.ProgressFraction, 6);
        Assert.Equal("30d", b.WindowLabel);
    }

    [Fact]
    public void DialBucket_percent_unit_remaining_value()
    {
        var b = new QuotaDialBucket(QuotaWindowKind.Daily, remainingValue: 35, isPercentUnit: true);
        Assert.Equal(35, b.RemainingPercent!.Value, 6);
        Assert.Equal(0.35, b.RemainingFraction, 6);
        Assert.Equal("24h", b.WindowLabel);
    }

    [Fact]
    public void DialBucket_uncomputable_defaults_to_full()
    {
        // No usedPercent / remaining / limit → remainingPercent null → 1 - progressFraction(0) = 1.
        var b = new QuotaDialBucket(QuotaWindowKind.Custom, label: "Fast Queries");
        Assert.Null(b.RemainingPercent);
        Assert.Equal(1.0, b.RemainingFraction, 6);
        Assert.Equal("Fast Queries", b.WindowLabel);
    }

    [Fact]
    public void DialBucket_lifetime_label()
    {
        var b = new QuotaDialBucket(QuotaWindowKind.Lifetime, remainingValue: 50);
        Assert.Equal("Lifetime", b.WindowLabel);
    }

    // ── Ring: band + pace marker ────────────────────────────────────────────────────────────

    [Theory]
    [InlineData(80, QuotaFillBand.Wide)]        // remaining 80% → Wide (>= .75)
    [InlineData(60, QuotaFillBand.Comfortable)] // 60% → Comfortable
    [InlineData(35, QuotaFillBand.Narrowing)]   // 35% → Narrowing
    [InlineData(12, QuotaFillBand.Edge)]        // 12% → Edge
    public void Ring_band_from_remaining(double remainingPct, QuotaFillBand expected)
    {
        var b = new QuotaDialBucket(QuotaWindowKind.Weekly, usedPercent: 100 - remainingPct);
        QuotaRingModel ring = QuotaRingModel.From(b, Now);
        Assert.True(ring.IsAvailable);
        Assert.Equal(expected, ring.Band);
    }

    [Fact]
    public void Ring_unavailable_when_bucket_missing()
    {
        QuotaRingModel ring = QuotaRingModel.From(null, Now);
        Assert.False(ring.IsAvailable);
        Assert.Equal(0, ring.RemainingFraction, 6);
        Assert.Null(ring.MarkerFraction);
        Assert.Null(ring.MarkerAngleDegrees);
    }

    [Fact]
    public void Ring_pace_marker_angle_is_fuel_gauge_edge()
    {
        // Daily window ending 12h from now → 50% elapsed → fuel-gauge marker at 1-0.5 = 0.5.
        var reset = Now.AddHours(12);
        var b = new QuotaDialBucket(QuotaWindowKind.Daily, usedPercent: 50, resetsAt: reset);
        QuotaRingModel ring = QuotaRingModel.From(b, Now);

        Assert.NotNull(ring.Pace);
        Assert.Equal(0.5, ring.MarkerFraction!.Value, 6);
        Assert.Equal(90.0, ring.MarkerAngleDegrees!.Value, 6); // -90 + 360*0.5
    }

    [Fact]
    public void Ring_no_marker_for_lifetime()
    {
        var b = new QuotaDialBucket(QuotaWindowKind.Lifetime, usedPercent: 30, resetsAt: Now.AddHours(12));
        QuotaRingModel ring = QuotaRingModel.From(b, Now);
        Assert.Null(ring.Pace);
        Assert.Null(ring.MarkerAngleDegrees);
    }

    // ── Dial composition ────────────────────────────────────────────────────────────────────

    [Fact]
    public void Dial_both_rings_dominant_is_outer()
    {
        var outer = new QuotaDialBucket(QuotaWindowKind.Weekly, usedPercent: 25);       // 75%
        var inner = new QuotaDialBucket(QuotaWindowKind.RollingHours, usedPercent: 40); // 60%
        QuotaArcDialModel dial = QuotaArcDialModel.Build(outer, inner, Now);

        Assert.True(dial.HasSignal);
        Assert.Equal(0.75, dial.DominantRemainingFraction, 6);
        Assert.Equal("75%", dial.CenterText);
        Assert.Equal("left in 7d", dial.CenterSubtitle);
        Assert.True(dial.Outer.IsAvailable);
        Assert.True(dial.Inner.IsAvailable);
        Assert.Equal(QuotaFillBand.Wide, dial.Outer.Band);
        Assert.Equal(QuotaFillBand.Comfortable, dial.Inner.Band);
    }

    [Fact]
    public void Dial_outer_missing_falls_back_to_inner_window()
    {
        var inner = new QuotaDialBucket(QuotaWindowKind.RollingHours, usedPercent: 40); // 60%
        QuotaArcDialModel dial = QuotaArcDialModel.Build(null, inner, Now);

        Assert.True(dial.HasSignal);
        Assert.Equal("60%", dial.CenterText);
        Assert.Equal("left in 5h", dial.CenterSubtitle);
        Assert.False(dial.Outer.IsAvailable); // renders dashed-muted
        Assert.True(dial.Inner.IsAvailable);
    }

    [Fact]
    public void Dial_no_buckets_reads_no_signal()
    {
        QuotaArcDialModel dial = QuotaArcDialModel.Build(null, null, Now);
        Assert.False(dial.HasSignal);
        Assert.Equal("—", dial.CenterText);
        Assert.Equal("no signal", dial.CenterSubtitle);
        Assert.False(dial.Outer.IsAvailable);
        Assert.False(dial.Inner.IsAvailable);
    }

    [Fact]
    public void Dial_near_edge_rounds_center_percent()
    {
        var outer = new QuotaDialBucket(QuotaWindowKind.Weekly, usedPercent: 88); // 12%
        QuotaArcDialModel dial = QuotaArcDialModel.Build(outer, null, Now);
        Assert.Equal("12%", dial.CenterText);
        Assert.Equal(QuotaFillBand.Edge, dial.Outer.Band);
    }

    // ── Arc geometry (fill-edge points the WinUI ArcSegment path uses) ───────────────────────

    [Fact]
    public void ArcGeometry_angle_starts_at_top_and_sweeps_clockwise()
    {
        Assert.Equal(-90, QuotaArcGeometry.AngleDegrees(0.0), 6);   // 12 o'clock
        Assert.Equal(0, QuotaArcGeometry.AngleDegrees(0.25), 6);    // 3 o'clock
        Assert.Equal(90, QuotaArcGeometry.AngleDegrees(0.5), 6);    // 6 o'clock
        Assert.Equal(180, QuotaArcGeometry.AngleDegrees(0.75), 6);  // 9 o'clock
    }

    [Fact]
    public void ArcGeometry_point_on_ring_at_cardinals()
    {
        // Center (50,50), radius 40.
        (double x0, double y0) = QuotaArcGeometry.PointOnRing(50, 50, 40, 0.0);
        Assert.Equal(50, x0, 6);
        Assert.Equal(10, y0, 6); // top

        (double x1, double y1) = QuotaArcGeometry.PointOnRing(50, 50, 40, 0.25);
        Assert.Equal(90, x1, 6); // right
        Assert.Equal(50, y1, 6);

        (double x2, double y2) = QuotaArcGeometry.PointOnRing(50, 50, 40, 0.5);
        Assert.Equal(50, x2, 6);
        Assert.Equal(90, y2, 6); // bottom
    }

    [Theory]
    [InlineData(0.25, false)]
    [InlineData(0.50, false)]
    [InlineData(0.51, true)]
    [InlineData(0.99, true)]
    public void ArcGeometry_large_arc_flag(double fraction, bool expected) =>
        Assert.Equal(expected, QuotaArcGeometry.IsLargeArc(fraction));
}
