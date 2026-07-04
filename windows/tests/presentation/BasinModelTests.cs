using System;
using System.Linq;
using OpenBurnBar.App.Presentation.DataControlCenter;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real tests for the mercury-basin geometry ported from
/// AgentLens/Views/Settings/DataControlCenter/DataControlCenterBasin.swift. The macOS Canvas is a
/// GPU render; the parity-critical part is the wave/sheen/bead math, pinned here without a WinUI
/// or Win2D host so the Windows CanvasAnimatedControl host paints identical geometry.
/// </summary>
public sealed class BasinModelTests
{
    [Fact]
    public void SwirlPhase_IsInUnitInterval_OverTime()
    {
        foreach (var t in new[] { 0.0, 4.0, 9.0, 17.999, 18.0, 100.0 })
        {
            double phase = BasinModel.SwirlPhase(t);
            Assert.InRange(phase, 0.0, 1.0);
        }
    }

    [Fact]
    public void SwirlPhase_WrapsAtPeriod()
    {
        // At exactly one period the phase returns to 0.
        Assert.Equal(0.0, BasinModel.SwirlPhase(18.0, 18.0), 9);
        // Halfway through.
        Assert.Equal(0.5, BasinModel.SwirlPhase(9.0, 18.0), 9);
    }

    [Fact]
    public void SwirlPhase_ReduceMotion_FreezesAtRepresentativePhase()
    {
        Assert.Equal(BasinModel.ReducedMotionPhase, BasinModel.SwirlPhase(7.3, reduceMotion: true));
        Assert.Equal(0.35, BasinModel.SwirlPhase(0.0, reduceMotion: true));
    }

    [Fact]
    public void SwirlPhase_NonPositivePeriod_FallsBackToDefault()
    {
        // period<=0 must not divide-by-zero; falls back to the 18s default.
        double phase = BasinModel.SwirlPhase(9.0, 0.0);
        Assert.Equal(0.5, phase, 9);
    }

    [Fact]
    public void SurfaceY_RisesAsFillIncreases()
    {
        const double height = 168;
        double empty = BasinModel.SurfaceY(height, 0.0);
        double half = BasinModel.SurfaceY(height, 0.5);
        double full = BasinModel.SurfaceY(height, 1.0);

        // Higher fill → smaller Y (the surface line climbs toward the top).
        Assert.True(full < half);
        Assert.True(half < empty);
    }

    [Fact]
    public void SurfaceY_ClampsFillOutOfRange()
    {
        const double height = 168;
        Assert.Equal(BasinModel.SurfaceY(height, 0.0), BasinModel.SurfaceY(height, -5));
        Assert.Equal(BasinModel.SurfaceY(height, 1.0), BasinModel.SurfaceY(height, 5));
    }

    [Fact]
    public void MercuryOutline_IsClosedPolygon_WithExpectedEndpoints()
    {
        const double width = 300, height = 168;
        double surfaceY = BasinModel.SurfaceY(height, 0.6);
        var outline = BasinModel.MercuryOutline(width, height, surfaceY, phase: 0.25);

        // move + line + (steps+1 wave points) + bottom-right = steps + 4 points.
        Assert.Equal(BasinModel.WaveSteps + 4, outline.Count);
        Assert.Equal(new BasinPoint(0, height), outline[0]);
        Assert.Equal(new BasinPoint(0, surfaceY), outline[1]);
        Assert.Equal(new BasinPoint(width, height), outline[^1]);
    }

    [Fact]
    public void MercuryOutline_WavePoints_StayWithinAmplitudeBand()
    {
        const double width = 300, height = 168;
        double surfaceY = BasinModel.SurfaceY(height, 0.5);
        var outline = BasinModel.MercuryOutline(width, height, surfaceY, phase: 0.4);

        // The wave points (indices 2..count-2) deviate from surfaceY by at most amplitude*1.5.
        double maxDeviation = BasinModel.WaveAmplitude * 1.5;
        foreach (var p in outline.Skip(2).Take(BasinModel.WaveSteps + 1))
        {
            Assert.InRange(p.Y - surfaceY, -maxDeviation - 1e-9, maxDeviation + 1e-9);
            Assert.InRange(p.X, 0, width);
        }
    }

    [Fact]
    public void SheenBand_TravelsAcrossWidth_WithPhase()
    {
        const double width = 300;
        double surfaceY = 40;
        var atStart = BasinModel.SheenBand(width, surfaceY, phase: 0.0);
        var atEnd = BasinModel.SheenBand(width, surfaceY, phase: 1.0);

        double bandWidth = width * 0.35;
        Assert.Equal(-bandWidth, atStart.X, 6);   // begins off the left edge
        Assert.Equal(width, atEnd.X, 6);           // ends at the right edge
        Assert.Equal(bandWidth, atStart.Width, 6);
        Assert.Equal(5, atStart.Height);
    }

    [Fact]
    public void Beads_AreFiveAndOnCanvas()
    {
        const double width = 300;
        double surfaceY = 40;
        var beads = BasinModel.Beads(width, surfaceY, phase: 0.3);

        Assert.Equal(BasinModel.BeadCount, beads.Count);
        Assert.All(beads, b =>
        {
            Assert.InRange(b.X, 0, width);
            Assert.True(b.Radius >= 2.5);
            Assert.True(b.Y > surfaceY); // beads drift below the surface line
        });
    }

    [Theory]
    [InlineData(0.0, "0% sealed")]
    [InlineData(0.5, "50% sealed")]
    [InlineData(0.754, "75% sealed")]
    [InlineData(1.0, "100% sealed")]
    [InlineData(1.4, "100% sealed")]
    public void SealedCaption_FormatsPercent(double fill, string expected)
    {
        Assert.Equal(expected, BasinModel.SealedCaption(fill));
    }
}
