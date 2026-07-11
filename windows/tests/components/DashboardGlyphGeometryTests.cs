using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Components;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts the dashboard-glyph geometry + grid→rect transform
/// (DashboardActionGlyphs.swift).</summary>
public sealed class DashboardGlyphGeometryTests
{
    [Fact]
    public void ImportFromLogs_has_the_expected_figures()
    {
        IReadOnlyList<GlyphFigure> figures = DashboardGlyphGeometry.Figures(DashboardActionGlyphKind.ImportFromLogs);
        // 3 log lines + lens ellipse + handle + 2 sparkle strokes = 7.
        Assert.Equal(7, figures.Count);
        // The magnifier lens is the only ellipse, radius 5.1 in grid units.
        GlyphFigure ellipse = Assert.Single(figures, f => f.IsEllipse);
        Assert.Equal(5.1, ellipse.Radius, 6);
        Assert.Equal(15.4, ellipse.Center.X, 6);
        Assert.Equal(8.9, ellipse.Center.Y, 6);
    }

    [Fact]
    public void SweepRecount_has_the_expected_figures()
    {
        IReadOnlyList<GlyphFigure> figures = DashboardGlyphGeometry.Figures(DashboardActionGlyphKind.SweepRecount);
        // 4 tally sticks + broom head + handle + 3 bristles + whimsy line = 10.
        Assert.Equal(10, figures.Count);
        // The broom head is the only closed figure.
        GlyphFigure closed = Assert.Single(figures, f => f.IsClosed);
        Assert.Equal(3, closed.Segments.Count);
        Assert.Contains(closed.Segments, s => s.Kind == GlyphSegmentKind.Quad);
    }

    [Fact]
    public void Transform_maps_grid_corners_into_a_square_rect()
    {
        var t = new GlyphTransform(0, 0, 48, 48); // s = 48, centered at origin
        (double X, double Y) origin = t.Map(new GlyphPoint(0, 0));
        Assert.Equal(0, origin.X, 6);
        Assert.Equal(0, origin.Y, 6);

        (double X, double Y) corner = t.Map(new GlyphPoint(24, 24));
        Assert.Equal(48, corner.X, 6);
        Assert.Equal(48, corner.Y, 6);

        (double X, double Y) mid = t.Map(new GlyphPoint(12, 12));
        Assert.Equal(24, mid.X, 6);
        Assert.Equal(24, mid.Y, 6);

        Assert.Equal(48, t.Scale(24), 6); // a full-grid length spans the square
    }

    [Fact]
    public void Transform_centers_within_a_non_square_rect()
    {
        // Wider than tall: s = 20; the 20×20 square is centered horizontally in the 40-wide rect.
        var t = new GlyphTransform(0, 0, 40, 20);
        (double X, double Y) origin = t.Map(new GlyphPoint(0, 0));
        Assert.Equal(10, origin.X, 6); // ox = 0 + 40/2 - 20/2
        Assert.Equal(0, origin.Y, 6);  // oy = 0 + 20/2 - 20/2
    }
}
