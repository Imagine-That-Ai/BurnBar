using System;
using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Theme.Tests;

/// <summary>
/// Parity assertions for <see cref="LiquidGlassTransparency"/> against independently
/// hand-computed values from the Swift source (AgentLens/Theme/LiquidGlass.swift). Every
/// expected number is derived from the Swift formula, NOT from the C# under test, so a
/// drift between the two ports fails the build.
/// </summary>
public sealed class LiquidGlassTransparencyTests
{
    private const int Precision = 10;

    // MARK: - effective(_:reduceTransparency:)

    [Theory]
    // Swift: raw passes through when finite, in-range, and not clamped by reduce.
    [InlineData(0.0, false, 0.0)]
    [InlineData(0.5, false, 0.5)]
    [InlineData(-0.5, false, -0.5)]
    // Swift: clamp to [-1, 1].
    [InlineData(1.5, false, 1.0)]
    [InlineData(-1.5, false, -1.0)]
    // Swift: reduce-transparency clamps POSITIVE t to 0 (never more see-through than allowed)…
    [InlineData(0.5, true, 0.0)]
    [InlineData(2.0, true, 0.0)]
    // …but leaves NEGATIVE (frostier) t untouched — frost only adds opacity.
    [InlineData(-0.5, true, -0.5)]
    [InlineData(-2.0, true, -1.0)]
    public void Effective_MatchesSwiftGolden(double raw, bool reduce, double expected)
    {
        Assert.Equal(expected, LiquidGlassTransparency.Effective(raw, reduce), Precision);
    }

    [Theory]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    [InlineData(double.NegativeInfinity)]
    public void Effective_NonFinite_ResolvesToZero(double raw)
    {
        // Swift: `guard raw.isFinite else { return 0 }`.
        Assert.Equal(0.0, LiquidGlassTransparency.Effective(raw, reduceTransparency: false), Precision);
        Assert.Equal(0.0, LiquidGlassTransparency.Effective(raw, reduceTransparency: true), Precision);
    }

    // MARK: - usesClearGlass(_:) — strict `t > 0.001`

    [Theory]
    [InlineData(0.0, false)]
    [InlineData(-0.5, false)]
    [InlineData(0.001, false)] // strictly greater — boundary is NOT clear
    [InlineData(0.002, true)]
    [InlineData(1.0, true)]
    public void UsesClearGlass_MatchesSwiftGolden(double t, bool expected)
    {
        Assert.Equal(expected, LiquidGlassTransparency.UsesClearGlass(t));
    }

    // MARK: - frostScrimOpacity(_:) — `t < 0 ? 0.9 * -t : 0`

    [Theory]
    [InlineData(-1.0, 0.9)]
    [InlineData(-0.5, 0.45)]
    [InlineData(0.0, 0.0)]
    [InlineData(0.5, 0.0)]
    public void FrostScrimOpacity_MatchesSwiftGolden(double t, double expected)
    {
        Assert.Equal(expected, LiquidGlassTransparency.FrostScrimOpacity(t), Precision);
    }

    // MARK: - clearBridgeScrimOpacity(_:) — `usesClear ? max(0.06, 0.14 * (1 - t)) : 0`

    [Theory]
    [InlineData(0.0, 0.0)]     // not clear -> 0
    [InlineData(-0.5, 0.0)]    // not clear -> 0
    [InlineData(0.5, 0.07)]    // max(0.06, 0.14*0.5=0.07) = 0.07
    [InlineData(1.0, 0.06)]    // max(0.06, 0.0) = 0.06 floor
    public void ClearBridgeScrimOpacity_MatchesSwiftGolden(double t, double expected)
    {
        Assert.Equal(expected, LiquidGlassTransparency.ClearBridgeScrimOpacity(t), Precision);
    }

    [Fact]
    public void ClearBridgeScrimOpacity_JustPastCenter_IsNearlyFullBridge()
    {
        // t = 0.002 is clear; 0.14 * (1 - 0.002) = 0.13972, above the 0.06 floor.
        Assert.Equal(0.13972, LiquidGlassTransparency.ClearBridgeScrimOpacity(0.002), Precision);
    }

    // MARK: - fallbackPlateOpacity(_:) — `t > 0 ? 1 - 0.78 * t : 1`

    [Theory]
    [InlineData(0.0, 1.0)]
    [InlineData(-0.5, 1.0)]   // t not > 0 -> full opacity
    [InlineData(0.5, 0.61)]   // 1 - 0.39
    [InlineData(1.0, 0.22)]   // 1 - 0.78
    public void FallbackPlateOpacity_MatchesSwiftGolden(double t, double expected)
    {
        Assert.Equal(expected, LiquidGlassTransparency.FallbackPlateOpacity(t), Precision);
    }

    // MARK: - Storage keys + range (shared spelling with the Swift/iOS mirror)

    [Fact]
    public void StorageKeys_MatchSwiftSpelling()
    {
        Assert.Equal("liquidGlassTransparency", LiquidGlassTransparency.StorageKey);
        Assert.Equal("liquidGlassContentSurfacesEnabled", LiquidGlassTransparency.ContentSurfacesEnabledKey);
    }

    [Fact]
    public void Range_IsSymmetricUnit()
    {
        Assert.Equal(-1.0, LiquidGlassTransparency.RangeLowerBound, Precision);
        Assert.Equal(1.0, LiquidGlassTransparency.RangeUpperBound, Precision);
    }

    // MARK: - Reduce-Transparency invariant (the accessibility contract)

    [Fact]
    public void ReduceTransparency_NeverIncreasesSeeThrough()
    {
        // For every raw preference, the reduced value must be <= the un-reduced value:
        // the flag may only make glass MORE opaque, never more transparent.
        for (double raw = -1.5; raw <= 1.5; raw += 0.1)
        {
            double open = LiquidGlassTransparency.Effective(raw, reduceTransparency: false);
            double reduced = LiquidGlassTransparency.Effective(raw, reduceTransparency: true);
            Assert.True(reduced <= open + 1e-12, $"raw={raw}: reduced {reduced} exceeded open {open}");
        }
    }
}
