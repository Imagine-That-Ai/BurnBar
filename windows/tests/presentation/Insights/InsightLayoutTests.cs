using System;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the pure grid math ported from the macOS <c>InsightLayout</c>: row-major
/// first-fit packing, clamping on move/resize, and the deterministic column reflow. Uses fixed
/// GUIDs so the packing order and the projection tie-breaks are exact.
/// </summary>
public sealed class InsightLayoutTests
{
    private static Guid G(int n) => new($"00000000-0000-0000-0000-0000000000{n:00}");

    [Fact]
    public void PlaceNew_PacksRowMajorAcrossTwelveColumns()
    {
        var layout = new InsightLayout();
        layout.PlaceNew(G(1), (4, 2));
        layout.PlaceNew(G(2), (4, 2));
        layout.PlaceNew(G(3), (4, 2));
        layout.PlaceNew(G(4), (4, 2));

        AssertCell(layout, G(1), 0, 0, 4, 2);
        AssertCell(layout, G(2), 4, 0, 4, 2);
        AssertCell(layout, G(3), 8, 0, 4, 2);
        AssertCell(layout, G(4), 0, 2, 4, 2); // wraps below the full first band
        Assert.Equal(4, layout.RowCount);
        Assert.Equal(4, layout.Revision);
    }

    [Fact]
    public void PlaceNew_ClampsSpanToColumnCount()
    {
        var layout = new InsightLayout();
        layout.PlaceNew(G(1), (20, 3)); // 20 cols requested → clamped to 12
        AssertCell(layout, G(1), 0, 0, 12, 3);
    }

    [Fact]
    public void Move_ClampsColumnSoSpanStaysInside()
    {
        var layout = new InsightLayout();
        layout.PlaceNew(G(1), (4, 2));
        layout.Move(G(1), 10, 5); // col 10 + span 4 = 14 > 12 → clamp column to 8
        AssertCell(layout, G(1), 8, 5, 4, 2);
    }

    [Fact]
    public void Resize_ClampsSpanAndColumn()
    {
        var layout = new InsightLayout();
        layout.PlaceNew(G(1), (4, 2));
        layout.Move(G(1), 8, 0);
        layout.Resize(G(1), 8, 3); // col was 8; 12-8=4 → column clamps to 4
        AssertCell(layout, G(1), 4, 0, 8, 3);

        layout.Resize(G(1), 30, 3); // span clamps to 12
        Assert.Equal(12, layout.Placements[G(1)].ColSpan);
    }

    [Fact]
    public void Remove_BumpsRevisionOnlyWhenPresent()
    {
        var layout = new InsightLayout();
        layout.PlaceNew(G(1), (4, 2));
        int rev = layout.Revision;
        layout.Remove(G(1));
        Assert.Equal(rev + 1, layout.Revision);
        layout.Remove(G(1)); // already gone
        Assert.Equal(rev + 1, layout.Revision);
        Assert.Empty(layout.Placements);
    }

    [Fact]
    public void Projected_HalvesSpansAndKeepsOrder()
    {
        var layout = new InsightLayout();
        layout.Placements[G(1)] = new CellPlacement(0, 0, 8, 3);
        layout.Placements[G(2)] = new CellPlacement(8, 0, 4, 3);

        InsightLayout six = layout.Projected(6);
        Assert.Equal(6, six.ColumnCount);
        AssertCell(six, G(1), 0, 0, 4, 3); // 8·6/12 = 4
        AssertCell(six, G(2), 4, 0, 2, 3); // 4·6/12 = 2
    }

    [Fact]
    public void Projected_WrapsWhenRowOverflows()
    {
        var layout = new InsightLayout();
        layout.Placements[G(1)] = new CellPlacement(0, 0, 8, 3);
        layout.Placements[G(2)] = new CellPlacement(8, 0, 4, 3);
        layout.Placements[G(3)] = new CellPlacement(0, 3, 6, 2);

        InsightLayout four = layout.Projected(4);
        AssertCell(four, G(1), 0, 0, 3, 3); // round(8·4/12=2.67)=3
        AssertCell(four, G(2), 3, 0, 1, 3); // round(4·4/12=1.33)=1
        AssertCell(four, G(3), 0, 3, 2, 2); // wraps to a new band below the 3-tall first band
    }

    [Fact]
    public void Projected_SameColumnCount_ReturnsSelf()
    {
        var layout = new InsightLayout(columnCount: 12);
        Assert.Same(layout, layout.Projected(12));
    }

    private static void AssertCell(InsightLayout layout, Guid id, int col, int row, int colSpan, int rowSpan)
    {
        Assert.True(layout.Placements.TryGetValue(id, out CellPlacement? p), $"missing placement for {id}");
        Assert.Equal(col, p!.Column);
        Assert.Equal(row, p.Row);
        Assert.Equal(colSpan, p.ColSpan);
        Assert.Equal(rowSpan, p.RowSpan);
    }
}
