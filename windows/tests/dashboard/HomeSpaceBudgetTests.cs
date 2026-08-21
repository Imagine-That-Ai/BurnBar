using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Dashboard.Layout;
using Xunit;

namespace OpenBurnBar.App.Dashboard.Tests;

/// <summary>
/// The living-layout arithmetic tests — port of AgentLensTests/Active/HomeSpaceBudgetTests.swift.
/// Pins all 24 layout solver rules.
/// </summary>
public sealed class HomeSpaceBudgetTests
{
    // MARK: - Helpers

    private static HomeSlot Slot(
        string id,
        int rank = 0,
        double floor = 100,
        double? ideal = null,
        double stretch = 0,
        HomeSlot.RowAppetite? rows = null,
        bool ambient = false,
        bool spans = false) =>
        new(
            id: id,
            rank: rank,
            floor: floor,
            ideal: ideal,
            stretch: stretch,
            rows: rows,
            isAmbient: ambient,
            spans: spans);

    private static HomeSlot.RowAppetite Appetite(
        int available,
        int baseline = 0,
        double unit = 20,
        int ceiling = 99) =>
        new(available: available, baseline: baseline, unit: unit, ceiling: ceiling);

    // MARK: - Columns

    [Fact]
    public void Test_ColumnThresholds()
    {
        Assert.Equal(1, HomeSpaceBudget.Columns(width: 900, current: 1, slots: 4));
        Assert.Equal(2, HomeSpaceBudget.Columns(width: 1200, current: 1, slots: 4));
        Assert.Equal(3, HomeSpaceBudget.Columns(width: 1700, current: 2, slots: 4));
    }

    /// <summary>
    /// The same dead-band contract the rail keeps: a drag parked on a threshold
    /// reports sub-pixel changes, and a hard cutoff makes the composition snap
    /// between one and two columns on every frame.
    /// </summary>
    [Fact]
    public void Test_ColumnDeadBandsHoldTheCurrentCount()
    {
        // Inside the 1<->2 band (1080 +/- 60).
        Assert.Equal(1, HomeSpaceBudget.Columns(width: 1080, current: 1, slots: 4));
        Assert.Equal(2, HomeSpaceBudget.Columns(width: 1080, current: 2, slots: 4));
        // Inside the 2<->3 band (1580 +/- 60).
        Assert.Equal(2, HomeSpaceBudget.Columns(width: 1580, current: 2, slots: 4));
        Assert.Equal(3, HomeSpaceBudget.Columns(width: 1580, current: 3, slots: 4));
    }

    /// <summary>
    /// Three columns for two slots is one empty column — the exact dead space
    /// this engine exists to remove.
    /// </summary>
    [Fact]
    public void Test_ColumnsNeverExceedSlotCount()
    {
        Assert.Equal(2, HomeSpaceBudget.Columns(width: 2400, current: 3, slots: 2));
        Assert.Equal(1, HomeSpaceBudget.Columns(width: 2400, current: 3, slots: 1));
    }

    [Fact]
    public void Test_ZeroWidthHoldsRatherThanCollapsing()
    {
        // The first layout pass can report zero before the window has a frame.
        Assert.Equal(3, HomeSpaceBudget.Columns(width: 0, current: 3, slots: 4));
    }

    // MARK: - Feed before Breathe

    /// <summary>
    /// The thesis. A canvas with room answers more questions; it does not print
    /// the same three answers in a taller box.
    /// </summary>
    [Fact]
    public void Test_SlackBecomesRowsBeforeItBecomesSpace()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 600,
            slots: new[] { Slot("list", floor: 100, rows: Appetite(available: 40, baseline: 2)) },
            gutter: 12);

        // 500pt of slack at 20pt a row: the list should have eaten it as rows.
        Assert.Equal(2 + 25, plan.RowCount("list"));
        Assert.Equal(600.0, plan.Height("list") ?? 0, precision: 2);
    }

    /// <summary>
    /// Round-robin, not first-come. A six-row ladder must not swallow the budget
    /// before a two-row ladder is granted a single line.
    /// </summary>
    [Fact]
    public void Test_RowsAreFedRoundRobinAcrossSlots()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 260,
            slots: new[]
            {
                Slot("greedy", rank: 0, floor: 100, rows: Appetite(available: 40, baseline: 0)),
                Slot("modest", rank: 1, floor: 100, rows: Appetite(available: 40, baseline: 0)),
            },
            gutter: 20);

        // 260 - 200 floors - 20 gutter = 40pt of slack = two rows, one each.
        Assert.Equal(1, plan.RowCount("greedy"));
        Assert.Equal(1, plan.RowCount("modest"));
    }

    /// <summary>
    /// "Fill the space" must never become "invent filler". A slot can only be fed
    /// rows the data actually has.
    /// </summary>
    [Fact]
    public void Test_RowsNeverExceedAvailableData()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 2000,
            slots: new[] { Slot("list", floor: 100, rows: Appetite(available: 3, baseline: 0)) },
            gutter: 12);

        Assert.Equal(3, plan.RowCount("list"));
        // Everything the rows could not absorb still becomes height, so the
        // canvas is filled rather than left with a hole under the last row.
        Assert.Equal(2000.0, plan.Height("list") ?? 0, precision: 2);
    }

    /// <summary>
    /// Past a point a glance becomes a different surface, and the honest move is
    /// to send the user to the full inbox rather than print 400 rows on Home.
    /// </summary>
    [Fact]
    public void Test_RowCeilingCapsAnEnormousCanvas()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 4000,
            slots: new[] { Slot("list", floor: 100, rows: Appetite(available: 500, baseline: 0, ceiling: 12)) },
            gutter: 12);

        Assert.Equal(12, plan.RowCount("list"));
    }

    // MARK: - Overflow

    /// <summary>
    /// A short window makes the surface scroll. It never makes an inbox item
    /// disappear — Home would be lying about what is waiting.
    /// </summary>
    [Fact]
    public void Test_ShortCanvasOverflowsRatherThanDroppingContent()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 150,
            slots: new[]
            {
                Slot("a", rank: 0, floor: 100),
                Slot("b", rank: 1, floor: 100),
                Slot("c", rank: 2, floor: 100),
            },
            gutter: 12);

        Assert.True(plan.Overflows);
        Assert.Equal(3, plan.Placements.Count);
        Assert.All(plan.Placements, p => Assert.True(p.IsVisible));
        Assert.All(plan.Placements, p => Assert.Null(p.Height));
    }

    /// <summary>
    /// Ambient furniture is the one thing that yields, and it yields before
    /// the surface resorts to scrolling.
    /// </summary>
    [Fact]
    public void Test_AmbientSlotYieldsBeforeOverflow()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 230,
            slots: new[]
            {
                Slot("ribbon", rank: 9, floor: 60, ambient: true),
                Slot("a", rank: 0, floor: 100),
                Slot("b", rank: 1, floor: 100),
            },
            gutter: 12);

        Assert.False(plan.Overflows);
        Assert.False(plan.IsVisible("ribbon"));
        Assert.True(plan.IsVisible("a"));
        Assert.DoesNotContain("ribbon", plan.ColumnGroups.SelectMany(g => g));
    }

    // MARK: - No dead space

    /// <summary>
    /// The invariant the whole engine exists for: resolved heights plus gutters
    /// account for every point of the canvas. Any shortfall is a visible hole.
    /// </summary>
    [Fact]
    public void Test_ResolvedHeightsConsumeTheWholeCanvas()
    {
        double canvasHeight = 777;
        double gutter = 14;
        var slots = new[]
        {
            Slot("head", rank: 0, floor: 90, ideal: 120),
            Slot("list", rank: 1, floor: 80, ideal: 300, stretch: 1, rows: Appetite(available: 5, baseline: 1, unit: 26)),
            Slot("tail", rank: 2, floor: 70, ideal: 90),
        };

        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: canvasHeight,
            slots: slots,
            gutter: gutter);

        Assert.False(plan.Overflows);
        double total = plan.Placements.Where(p => p.Height.HasValue).Sum(p => p.Height!.Value);
        Assert.Equal(canvasHeight, total + gutter * (slots.Length - 1), precision: 2);
    }

    /// <summary>
    /// Even when no slot volunteered to stretch, the leftover has to go
    /// somewhere or it is the original hole with extra steps.
    /// </summary>
    [Fact]
    public void Test_ResidualIsSpreadWhenNothingStretches()
    {
        double canvasHeight = 500;
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: canvasHeight,
            slots: new[]
            {
                Slot("a", rank: 0, floor: 100, ideal: 100),
                Slot("b", rank: 1, floor: 100, ideal: 300),
            },
            gutter: 0);

        double a = plan.Height("a") ?? 0;
        double b = plan.Height("b") ?? 0;
        Assert.Equal(canvasHeight, a + b, precision: 2);
        Assert.True(b > a, "Residual spreads in proportion to ideal, preserving the composition's weights");
    }

    [Fact]
    public void Test_StretchTakesTheResidual()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 500,
            slots: new[]
            {
                Slot("rigid", rank: 0, floor: 100, stretch: 0),
                Slot("elastic", rank: 1, floor: 100, stretch: 1),
            },
            gutter: 0);

        Assert.Equal(100.0, plan.Height("rigid") ?? 0, precision: 2);
        Assert.Equal(400.0, plan.Height("elastic") ?? 0, precision: 2);
    }

    // MARK: - Column dealing

    [Fact]
    public void Test_DealBalancesColumnsByIdealHeight()
    {
        Dictionary<string, int> assignment = HomeSpaceBudget.Deal(
            slots: new[]
            {
                Slot("tall", rank: 0, floor: 100, ideal: 300),
                Slot("short", rank: 1, floor: 100, ideal: 100),
                Slot("mid", rank: 2, floor: 100, ideal: 150),
            },
            columns: 2);

        Assert.Equal(0, assignment["tall"]);
        Assert.Equal(1, assignment["short"]);
        Assert.Equal(1, assignment["mid"]);
    }

    /// <summary>
    /// A layout that reshuffles on identical input reads as a bug, so ties go
    /// left and the deal is deterministic.
    /// </summary>
    [Fact]
    public void Test_DealIsDeterministicOnTies()
    {
        var slots = Enumerable.Range(0, 4)
            .Select(i => Slot($"s{i}", rank: i, floor: 100, ideal: 100))
            .ToList();
        var first = HomeSpaceBudget.Deal(slots, columns: 2);
        var second = HomeSpaceBudget.Deal(slots, columns: 2);
        Assert.Equal(first, second);
        Assert.Equal(0, first["s0"]);
        Assert.Equal(1, first["s1"]);
    }

    [Fact]
    public void Test_SingleColumnPutsEverythingInColumnZero()
    {
        var assignment = HomeSpaceBudget.Deal(new[] { Slot("a"), Slot("b") }, columns: 1);
        Assert.Equal(0, assignment["a"]);
        Assert.Equal(0, assignment["b"]);
    }

    /// <summary>
    /// Columns get a full canvas height each, so a two-column composition fits
    /// content that a single column would have had to scroll.
    /// </summary>
    [Fact]
    public void Test_ColumnsEachGetTheFullHeight()
    {
        var slots = new[]
        {
            Slot("a", rank: 0, floor: 400, ideal: 400),
            Slot("b", rank: 1, floor: 400, ideal: 400),
        };

        HomeSpacePlan stacked = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 500,
            slots: slots,
            gutter: 12,
            requestedColumns: 1);
        Assert.True(stacked.Overflows);

        HomeSpacePlan sideBySide = HomeSpaceBudget.Resolve(
            canvasWidth: 1400,
            canvasHeight: 500,
            slots: slots,
            gutter: 12,
            requestedColumns: 2);
        Assert.False(sideBySide.Overflows);
        Assert.Equal(500.0, sideBySide.Height("a") ?? 0, precision: 2);
        Assert.Equal(500.0, sideBySide.Height("b") ?? 0, precision: 2);
    }

    // MARK: - Ordering

    /// <summary>
    /// Dealing into columns filters the slot list per column, which scrambles the
    /// declared order. The plan has to hand it back intact or a shell renders its
    /// sections in resolution order instead of reading order.
    /// </summary>
    [Fact]
    public void Test_PlacementsKeepTheDeclaredOrder()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 1400,
            canvasHeight: 900,
            slots: new[]
            {
                Slot("first", rank: 2, floor: 100),
                Slot("second", rank: 0, floor: 100),
                Slot("third", rank: 1, floor: 100),
            },
            gutter: 12,
            requestedColumns: 2);

        Assert.Equal(new[] { "first", "second", "third" }, plan.Placements.Select(p => p.Id));
    }

    // MARK: - Spanning band

    /// <summary>
    /// Ask's enforced rule is that the question field is first and largest. A
    /// plain two-column deal would drop it into a half-width box beside a list.
    /// </summary>
    [Fact]
    public void Test_SpanningSlotKeepsFullWidthAboveTheColumns()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 1400,
            canvasHeight: 800,
            slots: new[]
            {
                Slot("field", rank: 0, floor: 92, ideal: 104, spans: true),
                Slot("context", rank: 1, floor: 90, stretch: 1, rows: Appetite(available: 20, baseline: 3, unit: 30)),
                Slot("suggestions", rank: 2, floor: 60, rows: Appetite(available: 5, baseline: 2, unit: 28)),
            },
            gutter: 16,
            requestedColumns: 2);

        Assert.Equal(new[] { "field" }, plan.SpanningIDs);
        Assert.DoesNotContain("field", plan.ColumnGroups.SelectMany(g => g));
        Assert.Equal(2, plan.ColumnGroups.Count);
        Assert.All(plan.ColumnGroups, group => Assert.NotEmpty(group));
    }

    /// <summary>
    /// The band is rigid at ideal and the columns get everything it leaves.
    /// </summary>
    [Fact]
    public void Test_SpanningBandIsRigidAndColumnsTakeTheRemainder()
    {
        double canvasHeight = 800;
        double gutter = 16;
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 1400,
            canvasHeight: canvasHeight,
            slots: new[]
            {
                Slot("field", rank: 0, floor: 92, ideal: 104, spans: true),
                Slot("context", rank: 1, floor: 90, stretch: 1, rows: Appetite(available: 20, baseline: 3, unit: 30)),
                Slot("suggestions", rank: 2, floor: 60, rows: Appetite(available: 5, baseline: 2, unit: 28)),
            },
            gutter: gutter,
            requestedColumns: 2);

        Assert.Equal(104.0, plan.Height("field") ?? 0, precision: 2);
        double columnBudget = canvasHeight - 104 - gutter;
        Assert.Equal(columnBudget, plan.Height("context") ?? 0, precision: 2);
        Assert.Equal(columnBudget, plan.Height("suggestions") ?? 0, precision: 2);
    }

    /// <summary>
    /// In one column everything is already full width, so marking a slot as
    /// spanning would only make it needlessly rigid.
    /// </summary>
    [Fact]
    public void Test_SpanningIsInertInASingleColumn()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 800,
            slots: new[]
            {
                Slot("field", rank: 0, floor: 92, ideal: 104, spans: true),
                Slot("context", rank: 1, floor: 90, stretch: 1),
            },
            gutter: 16,
            requestedColumns: 1);

        Assert.Empty(plan.SpanningIDs);
        Assert.Equal(new[] { "field", "context" }, plan.ColumnGroups[0]);
        double total = plan.Placements.Where(p => p.Height.HasValue).Sum(p => p.Height!.Value);
        Assert.Equal(800.0, total + 16, precision: 2);
    }

    // MARK: - Degenerate input

    [Fact]
    public void Test_EmptySlotsResolveToTheEmptyPlan()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 600,
            slots: Array.Empty<HomeSlot>(),
            gutter: 12);
        Assert.Equal(HomeSpacePlan.Empty, plan);
    }

    /// <summary>
    /// The first layout pass can report a zero-height canvas. Resolving that into
    /// pinned zero-height frames would flash an empty surface on every launch.
    /// </summary>
    [Fact]
    public void Test_ZeroHeightCanvasHugsContent()
    {
        HomeSpacePlan plan = HomeSpaceBudget.Resolve(
            canvasWidth: 900,
            canvasHeight: 0,
            slots: new[] { Slot("a", rows: Appetite(available: 9, baseline: 3)) },
            gutter: 12);

        Assert.True(plan.Overflows);
        Assert.Null(plan.Height("a"));
        Assert.Equal(3, plan.RowCount("a"));
    }

    /// <summary>
    /// A baseline larger than the data is a caller mistake that would otherwise
    /// render phantom rows.
    /// </summary>
    [Fact]
    public void Test_AppetiteClampsBaselineToAvailable()
    {
        var clamped = new HomeSlot.RowAppetite(available: 2, baseline: 8, unit: 20, ceiling: 10);
        Assert.Equal(2, clamped.Baseline);
        Assert.Equal(2, clamped.Cap);
    }
}
