using System.Collections.Generic;
using OpenBurnBar.App.Dashboard.EasterEgg;
using Xunit;

namespace OpenBurnBar.App.Dashboard.Tests;

/// <summary>
/// Locks the deterministic <see cref="ProceduralGlyphSampler"/> — the portable stand-in
/// for the AppKit glyph raster. The storm's convergence phase springs sprites toward
/// these points, so they must be non-empty, origin-centred, and stable per string.
/// </summary>
public sealed class GlyphSamplerTests
{
    private readonly ProceduralGlyphSampler _sampler = new();

    [Theory]
    [InlineData("$")]
    [InlineData(":)")]
    [InlineData("</>")]
    [InlineData("{ }")]
    public void KnownShapes_ProduceNonEmptyCentredPoints(string shape)
    {
        IReadOnlyList<Vec2> pts = _sampler.Points(shape);
        Assert.NotEmpty(pts);
        foreach (Vec2 p in pts)
        {
            // Authored in a normalised [-0.5, 0.5] box; allow a hair of overshoot.
            Assert.InRange(p.X, -0.6, 0.6);
            Assert.InRange(p.Y, -0.6, 0.6);
        }
    }

    [Fact]
    public void EveryStormShape_IsSampleable()
    {
        foreach (string shape in EasterEggFx.Shapes)
        {
            Assert.NotEmpty(_sampler.Points(shape));
        }
    }

    [Fact]
    public void Points_AreCached_SameReferenceReturned()
    {
        IReadOnlyList<Vec2> first = _sampler.Points("$");
        IReadOnlyList<Vec2> second = _sampler.Points("$");
        Assert.Same(first, second);
    }

    [Fact]
    public void Points_AreDeterministic_AcrossInstances()
    {
        var a = new ProceduralGlyphSampler();
        var b = new ProceduralGlyphSampler();
        IReadOnlyList<Vec2> pa = a.Points("</>");
        IReadOnlyList<Vec2> pb = b.Points("</>");
        Assert.Equal(pa.Count, pb.Count);
        for (int i = 0; i < pa.Count; i++)
        {
            Assert.Equal(pa[i].X, pb[i].X, 12);
            Assert.Equal(pa[i].Y, pb[i].Y, 12);
        }
    }

    [Fact]
    public void UnknownShape_IsEmpty_SoStormFallsBackToBurst()
    {
        Assert.Empty(_sampler.Points("unmapped-glyph"));
    }
}
