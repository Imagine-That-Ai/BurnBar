using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the heatmap binning: intensity is <c>value / max</c> across the whole grid
/// and the fill alpha follows the ramp <c>0.15 + 0.7·t</c>.
/// </summary>
public sealed class HeatmapGeometryTests
{
    [Theory]
    [InlineData(0.0, 0.15)]
    [InlineData(0.5, 0.50)]
    [InlineData(1.0, 0.85)]
    public void AlphaFor_MatchesRamp(double intensity, double expected)
        => Assert.Equal(expected, HeatmapGeometry.AlphaFor(intensity), 6);

    [Fact]
    public void MaxValue_ScansEveryCell()
    {
        var cells = new List<IReadOnlyList<double>>
        {
            new List<double> { 1, 2 },
            new List<double> { 3, 4 },
        };
        Assert.Equal(4, HeatmapGeometry.MaxValue(cells), 6);
    }

    [Fact]
    public void Layout_BinsIntensityAndAlpha()
    {
        var cells = new List<IReadOnlyList<double>> { new List<double> { 0, 50, 100 } };
        IReadOnlyList<HeatmapCellGeometry> laid = HeatmapGeometry.Layout(cells, new PlotRect(0, 0, 300, 100), cellGap: 0);

        Assert.Equal(3, laid.Count);
        Assert.Equal(0.0, laid[0].Intensity, 6);
        Assert.Equal(0.5, laid[1].Intensity, 6);
        Assert.Equal(1.0, laid[2].Intensity, 6);
        Assert.Equal(0.15, laid[0].Alpha, 6);
        Assert.Equal(0.85, laid[2].Alpha, 6);
    }

    [Fact]
    public void Layout_PlacesCellsRowMajor()
    {
        var cells = new List<IReadOnlyList<double>>
        {
            new List<double> { 1, 1 },
            new List<double> { 1, 1 },
        };
        IReadOnlyList<HeatmapCellGeometry> laid = HeatmapGeometry.Layout(cells, new PlotRect(0, 0, 200, 100), cellGap: 0);

        Assert.Equal((0, 0), (laid[0].Row, laid[0].Col));
        Assert.Equal(0, laid[0].X, 3);
        Assert.Equal(0, laid[0].Y, 3);
        Assert.Equal(100, laid[1].X, 3);   // col 1 → x = 1·(200/2)
        Assert.Equal(50, laid[2].Y, 3);    // row 1 → y = 1·(100/2)
        Assert.Equal(100, laid[0].Width, 3);
        Assert.Equal(50, laid[0].Height, 3);
    }

    [Fact]
    public void Layout_Empty_ReturnsEmpty()
        => Assert.Empty(HeatmapGeometry.Layout(new List<IReadOnlyList<double>>(), new PlotRect(0, 0, 100, 100)));
}
