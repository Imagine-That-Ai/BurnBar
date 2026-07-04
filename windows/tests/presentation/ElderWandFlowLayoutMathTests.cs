using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.ElderWand;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests;

/// <summary>
/// Real, macOS-runnable tests for the ported flow-layout math
/// (windows/app/OpenBurnBar.App.Presentation/ElderWand/ElderWandFlowLayoutMath.cs), parity
/// with the computeRows / sizeThatFits logic in ElderWandFlowLayout.swift. The Windows
/// ElderWandFlowPanel delegates to this, so the wrap behavior is proven here on macOS.
/// </summary>
public sealed class ElderWandFlowLayoutMathTests
{
    private static List<FlowSize> Chips(int count, double width, double height = 30) =>
        Enumerable.Range(0, count).Select(_ => new FlowSize(width, height)).ToList();

    [Fact]
    public void ComputeRows_Empty_ReturnsEmpty()
    {
        Assert.Empty(ElderWandFlowLayoutMath.ComputeRows(200, 8, System.Array.Empty<FlowSize>()));
    }

    [Fact]
    public void ComputeRows_AllFitOnOneRow()
    {
        var sizes = Chips(3, 50); // 3*50 + 2*8 spacing = 166 <= 200
        var rows = ElderWandFlowLayoutMath.ComputeRows(200, 8, sizes);
        Assert.Single(rows);
        Assert.Equal(new[] { 0, 1, 2 }, rows[0]);
    }

    [Fact]
    public void ComputeRows_WrapsOnOverflow()
    {
        var sizes = Chips(4, 60); // 60,+68,+68 => third would exceed 200 at index 2? check: row 0: 60; +68=128; +68=196 (<=200) idx2 fits; +68=264 wraps at idx3
        var rows = ElderWandFlowLayoutMath.ComputeRows(200, 8, sizes);
        Assert.Equal(2, rows.Count);
        Assert.Equal(new[] { 0, 1, 2 }, rows[0]);
        Assert.Equal(new[] { 3 }, rows[1]);
    }

    [Fact]
    public void ComputeRows_OversizedItem_StaysAloneNeverDropped()
    {
        var sizes = new List<FlowSize> { new(50, 30), new(500, 30), new(50, 30) };
        var rows = ElderWandFlowLayoutMath.ComputeRows(200, 8, sizes);
        // Each of the three lands on its own row (item 1 overflows; item 2 then overflows off item 1's row).
        Assert.Equal(3, rows.Count);
        Assert.Equal(new[] { 0 }, rows[0]);
        Assert.Equal(new[] { 1 }, rows[1]);
        Assert.Equal(new[] { 2 }, rows[2]);
    }

    [Fact]
    public void Measure_Empty_IsZero()
    {
        var size = ElderWandFlowLayoutMath.Measure(200, 8, 8, System.Array.Empty<FlowSize>());
        Assert.Equal(0, size.Width);
        Assert.Equal(0, size.Height);
    }

    [Fact]
    public void Measure_ConstrainedWidth_SumsRowHeights()
    {
        var sizes = Chips(4, 60, height: 30); // wraps to 2 rows
        var size = ElderWandFlowLayoutMath.Measure(200, 8, 10, sizes);
        Assert.Equal(200, size.Width);
        Assert.Equal(70, size.Height); // 30 + 10 vSpacing + 30
    }

    [Fact]
    public void Measure_UnconstrainedWidth_IsWidestRow()
    {
        var sizes = Chips(3, 50, height: 20);
        var size = ElderWandFlowLayoutMath.Measure(double.PositiveInfinity, 8, 8, sizes);
        Assert.Equal(50 + 8 + 50 + 8 + 50, size.Width); // single row, natural width
        Assert.Equal(20, size.Height);
    }
}
