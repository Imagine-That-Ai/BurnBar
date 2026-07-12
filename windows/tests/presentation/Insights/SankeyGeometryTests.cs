using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using OpenBurnBar.App.Presentation.Insights.Charts;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the compact two-column sankey layout: sources/targets are grouped, summed,
/// ordered by descending weight, and their heights are normalized to each column's total.
/// </summary>
public sealed class SankeyGeometryTests
{
    private static SankeyData Data() => new(
        new List<SankeyNode>
        {
            new("a", "Alpha"),
            new("b", "Beta"),
            new("c", "Gamma"),
            new("d", "Delta"),
        },
        new List<SankeyLink>
        {
            new("a", "c", 30),
            new("a", "d", 10),
            new("b", "c", 5),
        });

    [Fact]
    public void OrderColumns_ProducesTwoColumns()
    {
        SankeyGeometryResult result = SankeyGeometry.OrderColumns(Data(), new PlotRect(0, 0, 200, 100));
        Assert.Equal(2, result.Columns.Count);
        Assert.Equal("source", result.Columns[0].Id);
        Assert.Equal("target", result.Columns[1].Id);
    }

    [Fact]
    public void OrderColumns_SumsAndSortsSources()
    {
        SankeyColumn source = SankeyGeometry.OrderColumns(Data(), new PlotRect(0, 0, 200, 100)).Columns[0];
        Assert.Equal(45, source.Total, 3);            // 30 + 10 + 5
        Assert.Equal("a", source.Nodes[0].Id);        // weight 40 first
        Assert.Equal(40, source.Nodes[0].Weight, 3);
        Assert.Equal("b", source.Nodes[1].Id);        // weight 5 second
        Assert.Equal(40.0 / 45.0, source.Nodes[0].NormalizedHeight, 6);
        Assert.Equal(5.0 / 45.0, source.Nodes[1].NormalizedHeight, 6);
    }

    [Fact]
    public void OrderColumns_SumsAndSortsTargets()
    {
        SankeyColumn target = SankeyGeometry.OrderColumns(Data(), new PlotRect(0, 0, 200, 100)).Columns[1];
        Assert.Equal("c", target.Nodes[0].Id); // 30 + 5 = 35
        Assert.Equal(35, target.Nodes[0].Weight, 3);
        Assert.Equal("d", target.Nodes[1].Id); // 10
        Assert.Equal(10, target.Nodes[1].Weight, 3);
    }

    [Fact]
    public void OrderColumns_PositionsColumnsAtRectEdges()
    {
        SankeyGeometryResult result = SankeyGeometry.OrderColumns(Data(), new PlotRect(0, 0, 200, 100));
        Assert.Equal(0, result.Columns[0].Nodes[0].X, 3);     // left column at rect.X
        Assert.Equal(188, result.Columns[1].Nodes[0].X, 3);   // right column at rect.Right − nodeWidth(12)
        Assert.All(result.Columns[0].Nodes, n => Assert.Equal(12, n.Width, 3));
    }
}
