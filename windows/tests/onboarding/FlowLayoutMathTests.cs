using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Onboarding;
using Xunit;

namespace OpenBurnBar.App.Onboarding.Tests;

/// <summary>
/// Parity tests for the wrapping-flow layout math ported from <c>FlowLayout.swift</c>:
/// row partitioning, measured size, centered placement, and the "over-wide single chip
/// starts at the left edge" clamp.
/// </summary>
public sealed class FlowLayoutMathTests
{
    private static IReadOnlyList<FlowSize> Chips(params (double w, double h)[] sizes) =>
        sizes.Select(s => new FlowSize(s.w, s.h)).ToList();

    [Fact]
    public void ComputeRows_WrapsWhenRowWouldOverflow()
    {
        // Three 40-wide chips, 10 spacing, max 100: row1 = [40, 40] (=90), row2 = [40].
        var items = Chips((40, 20), (40, 20), (40, 20));
        var rows = FlowLayoutMath.ComputeRows(items, horizontalSpacing: 10, maxWidth: 100);

        Assert.Equal(2, rows.Count);
        Assert.Equal(new[] { 0, 1 }, rows[0]);
        Assert.Equal(new[] { 2 }, rows[1]);
    }

    [Fact]
    public void ComputeRows_SingleOverWideItem_StaysOnItsOwnRow()
    {
        // A chip wider than maxWidth must not be dropped — it occupies its own row.
        var items = Chips((200, 20), (30, 20));
        var rows = FlowLayoutMath.ComputeRows(items, horizontalSpacing: 8, maxWidth: 100);

        Assert.Equal(2, rows.Count);
        Assert.Equal(new[] { 0 }, rows[0]);
        Assert.Equal(new[] { 1 }, rows[1]);
    }

    [Fact]
    public void ComputeRows_AllFitOnOneRow()
    {
        var items = Chips((20, 10), (20, 10), (20, 10));
        var rows = FlowLayoutMath.ComputeRows(items, horizontalSpacing: 5, maxWidth: 1000);
        Assert.Single(rows);
        Assert.Equal(new[] { 0, 1, 2 }, rows[0]);
    }

    [Fact]
    public void Measure_SumsRowHeightsPlusInterRowSpacing()
    {
        // Two rows: row1 tallest = 20, row2 tallest = 30, vSpacing = 6 => 20 + 6 + 30 = 56.
        var items = Chips((40, 20), (40, 20), (40, 30));
        FlowSize size = FlowLayoutMath.Measure(items, horizontalSpacing: 10, verticalSpacing: 6, proposedWidth: 100);

        Assert.Equal(56, size.Height, 6);
        Assert.Equal(100, size.Width, 6); // proposed width is honored
    }

    [Fact]
    public void Measure_EmptyInput_IsZero()
    {
        FlowSize size = FlowLayoutMath.Measure(Chips(), horizontalSpacing: 10, verticalSpacing: 10, proposedWidth: 100);
        Assert.Equal(0, size.Width, 6);
        Assert.Equal(0, size.Height, 6);
    }

    [Fact]
    public void Measure_UnconstrainedWidth_UsesWidestNaturalRow()
    {
        var items = Chips((40, 20), (60, 20));
        FlowSize size = FlowLayoutMath.Measure(items, horizontalSpacing: 10, verticalSpacing: 10, proposedWidth: null);
        // One row (unbounded): 40 + 10 + 60 = 110.
        Assert.Equal(110, size.Width, 6);
        Assert.Equal(20, size.Height, 6);
    }

    [Fact]
    public void Arrange_CentersRowsWithinBounds()
    {
        // Single 40-wide chip in a 100-wide bounds -> x offset = (100-40)/2 = 30.
        var items = Chips((40, 20));
        var placements = FlowLayoutMath.Arrange(items, horizontalSpacing: 10, verticalSpacing: 10, boundsWidth: 100);

        Assert.Single(placements);
        Assert.Equal(30, placements[0].X, 6);
        Assert.Equal(0, placements[0].Y, 6);
    }

    [Fact]
    public void Arrange_OverWideRow_ClampsToLeftEdge()
    {
        // A 200-wide chip in a 100 bounds: centering offset would be negative -> clamp to 0.
        var items = Chips((200, 20));
        var placements = FlowLayoutMath.Arrange(items, horizontalSpacing: 10, verticalSpacing: 10, boundsWidth: 100);

        Assert.Equal(0, placements[0].X, 6);
    }

    [Fact]
    public void Arrange_VerticallyCentersShorterChipsWithinRowHeight()
    {
        // Row height = 30 (tallest). The 20-tall chip gets yOffset (30-20)/2 = 5.
        var items = Chips((30, 30), (30, 20));
        var placements = FlowLayoutMath.Arrange(items, horizontalSpacing: 5, verticalSpacing: 5, boundsWidth: 1000);

        Assert.Equal(2, placements.Count);
        FlowPlacement tall = placements.First(p => p.Index == 0);
        FlowPlacement shortChip = placements.First(p => p.Index == 1);
        Assert.Equal(0, tall.Y, 6);
        Assert.Equal(5, shortChip.Y, 6);
    }

    [Fact]
    public void Arrange_AdvancesRowsByRowHeightPlusSpacing()
    {
        // Two chips that wrap: row1 y=0 (height 20), row2 y = 20 + vSpacing(8) = 28.
        var items = Chips((80, 20), (80, 25));
        var placements = FlowLayoutMath.Arrange(items, horizontalSpacing: 10, verticalSpacing: 8, boundsWidth: 100);

        Assert.Equal(0, placements.First(p => p.Index == 0).Y, 6);
        Assert.Equal(28, placements.First(p => p.Index == 1).Y, 6);
    }

    [Fact]
    public void Arrange_ReturnsOnePlacementPerItem_InInputIndexing()
    {
        var items = Chips((30, 20), (30, 20), (30, 20), (30, 20));
        var placements = FlowLayoutMath.Arrange(items, horizontalSpacing: 10, verticalSpacing: 10, boundsWidth: 80);
        Assert.Equal(4, placements.Count);
        Assert.Equal(new[] { 0, 1, 2, 3 }, placements.Select(p => p.Index).OrderBy(i => i));
    }
}
