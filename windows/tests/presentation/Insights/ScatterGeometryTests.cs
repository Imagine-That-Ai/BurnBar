using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the scatter/bubble geometry: x/y min–max normalization into the plot rect
/// (with y inverted) and radius scaling by point size.
/// </summary>
public sealed class ScatterGeometryTests
{
    private static readonly IReadOnlyList<ScatterPoint> Points = new List<ScatterPoint>
    {
        new("a", "A", 0, 0, 1),
        new("b", "B", 100, 50, 3),
        new("c", "C", 50, 25, 2),
    };

    [Fact]
    public void Layout_NormalizesIntoRectWithInvertedY()
    {
        IReadOnlyList<ScatterBubble> bubbles = ScatterGeometry.Layout(Points, new PlotRect(0, 0, 200, 100), minRadius: 4, maxRadius: 12);

        // A: min x, min y → left edge, bottom.
        Assert.Equal(0, bubbles[0].CenterX, 3);
        Assert.Equal(100, bubbles[0].CenterY, 3);
        // B: max x, max y → right edge, top.
        Assert.Equal(200, bubbles[1].CenterX, 3);
        Assert.Equal(0, bubbles[1].CenterY, 3);
        // C: mid x, mid y → center.
        Assert.Equal(100, bubbles[2].CenterX, 3);
        Assert.Equal(50, bubbles[2].CenterY, 3);
    }

    [Fact]
    public void Layout_ScalesRadiusBySize()
    {
        IReadOnlyList<ScatterBubble> bubbles = ScatterGeometry.Layout(Points, new PlotRect(0, 0, 200, 100), minRadius: 4, maxRadius: 12);
        Assert.Equal(4, bubbles[0].Radius, 3);   // smallest size → min radius
        Assert.Equal(12, bubbles[1].Radius, 3);  // largest size → max radius
        Assert.Equal(8, bubbles[2].Radius, 3);   // mid size → mid radius
    }

    [Fact]
    public void Layout_Empty_ReturnsEmpty()
        => Assert.Empty(ScatterGeometry.Layout(new List<ScatterPoint>(), new PlotRect(0, 0, 200, 100)));
}
