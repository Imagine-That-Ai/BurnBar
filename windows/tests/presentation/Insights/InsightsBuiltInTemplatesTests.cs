using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the built-in template gallery + the <c>Instantiate()</c> stamping ported from
/// the macOS <c>InsightsBuiltInTemplates</c> / <c>InsightCanvasTemplate</c>: the gallery is the
/// expected eight canvases, and stamping renumbers widgets, auto-places them without overlap,
/// and is deterministic across two stampings.
/// </summary>
public sealed class InsightsBuiltInTemplatesTests : IDisposable
{
    public InsightsBuiltInTemplatesTests()
    {
        ResetTemplates(sampleFallback: false);
    }

    public void Dispose() => ResetTemplates(sampleFallback: false);

    private static void ResetTemplates(bool sampleFallback)
    {
        InsightsBuiltInTemplates.SampleFallbackEnabled = sampleFallback;
        InsightsBuiltInTemplates.RealDataResolver = null;
    }

    [Fact]
    public void SampleFallbackEnabled_DefaultsFalse_FailClosed()
    {
        // Fresh process may have been mutated by other tests; ResetTemplates in ctor sets false.
        Assert.False(InsightsBuiltInTemplates.SampleFallbackEnabled);
        InsightCanvas canvas = InsightsBuiltInTemplates.Find("today")!.Instantiate();
        Assert.All(canvas.Widgets, w => Assert.IsType<EmptyData>(w.Data));
    }

    [Fact]
    public void All_ContainsEightUniqueTemplates()
    {
        Assert.Equal(8, InsightsBuiltInTemplates.All.Count);
        Assert.Equal(8, InsightsBuiltInTemplates.All.Select(t => t.Id).Distinct().Count());
    }

    [Theory]
    [InlineData("today", 8)]
    [InlineData("cost-audit-7d", 8)]
    [InlineData("agent-focus", 4)]
    [InlineData("model-focus", 4)]
    [InlineData("use-case-library", 3)]
    [InlineData("quota-health", 3)]
    [InlineData("quarterly-review", 6)]
    [InlineData("anomalies", 4)]
    public void Template_HasExpectedWidgetCount(string id, int count)
    {
        InsightCanvasTemplate? template = InsightsBuiltInTemplates.Find(id);
        Assert.NotNull(template);
        Assert.Equal(count, template!.WidgetCount);
    }

    [Fact]
    public void Find_UnknownId_ReturnsNull()
        => Assert.Null(InsightsBuiltInTemplates.Find("does-not-exist"));

    [Fact]
    public void Instantiate_PlacesEveryWidgetWithoutOverlap()
    {
        foreach (InsightCanvasTemplate template in InsightsBuiltInTemplates.All)
        {
            InsightCanvas canvas = template.Instantiate();

            Assert.Equal(template.Id, canvas.OriginTemplateId);
            Assert.Equal(template.WidgetCount, canvas.Widgets.Count);
            Assert.Equal(canvas.Widgets.Count, canvas.Layout.Placements.Count);

            foreach (InsightWidget widget in canvas.Widgets)
            {
                Assert.True(canvas.Layout.Placements.ContainsKey(widget.Id), $"{template.Id}: widget unplaced");
                Assert.True(canvas.Layout.Placements[widget.Id].ColSpan <= canvas.Layout.ColumnCount);
            }

            AssertNoOverlap(canvas.Layout);
        }
    }

    [Fact]
    public void Instantiate_RenumbersWidgetsPerStamping()
    {
        InsightCanvasTemplate template = InsightsBuiltInTemplates.Find("today")!;
        InsightCanvas a = template.Instantiate();
        InsightCanvas b = template.Instantiate();

        Assert.NotEqual(a.Id, b.Id);
        Assert.Empty(a.Widgets.Select(w => w.Id).Intersect(b.Widgets.Select(w => w.Id)));

        List<CellPlacement> placementsA = a.Widgets.Select(w => a.Layout.Placements[w.Id]).ToList();
        List<CellPlacement> placementsB = b.Widgets.Select(w => b.Layout.Placements[w.Id]).ToList();
        Assert.Equal(placementsA, placementsB);
    }

    [Fact]
    public void Instantiate_CarriesSampleDataForRendering_WhenSampleFallbackEnabled()
    {
        ResetTemplates(sampleFallback: true);
        InsightCanvas canvas = InsightsBuiltInTemplates.Find("cost-audit-7d")!.Instantiate();
        Assert.All(canvas.Widgets, w => Assert.NotNull(w.Data));
        Assert.Contains(canvas.Widgets, w => w.Data is RankingData or TimeSeriesData or DistributionData);
    }

    [Fact]
    public void ProductionDefault_DoesNotFabricateSampleSeries_AndKpisAreEmptyChrome()
    {
        ResetTemplates(sampleFallback: false);

        foreach (InsightCanvasTemplate template in InsightsBuiltInTemplates.All)
        {
            InsightCanvas canvas = template.Instantiate();
            Assert.All(canvas.Widgets, w => Assert.IsType<EmptyData>(w.Data));
            Assert.DoesNotContain(
                canvas.Widgets,
                w => w.Data is RankingData or TimeSeriesData or DistributionData or ScatterData
                    or NarrativeData or RecommendationData or KpiData or QuotaData or HeatmapData
                    or RadarData or FunnelData or SankeyData);
        }
    }

    [Fact]
    public void RealDataResolver_RebuildsCachedTemplatesAfterInitialSampleAccess()
    {
        try
        {
            ResetTemplates(sampleFallback: true);
            _ = InsightsBuiltInTemplates.All.Count;
            InsightsBuiltInTemplates.RealDataResolver = (kind, seed) =>
                kind == InsightWidgetKind.KpiTile
                    ? new KpiData(
                        MetricLabel: $"Real KPI {seed}",
                        Value: seed,
                        ValueFormat: ValueFormat.Count,
                        Delta: null,
                        Sparkline: null,
                        ContextLabel: "resolver")
                    : null;

            InsightCanvas canvas = InsightsBuiltInTemplates.Find("today")!.Instantiate();
            List<KpiData> kpis = canvas.Widgets
                .Where(w => w.Kind == InsightWidgetKind.KpiTile)
                .Select(w => Assert.IsType<KpiData>(w.Data))
                .ToList();

            Assert.Equal(4, kpis.Count);
            Assert.All(kpis, data => Assert.Equal("resolver", data.ContextLabel));
            Assert.Contains(kpis, data => data.MetricLabel == "Real KPI 1");
        }
        finally
        {
            ResetTemplates(sampleFallback: false);
        }
    }

    private static void AssertNoOverlap(InsightLayout layout)
    {
        var occupied = new HashSet<(int Col, int Row)>();
        foreach (CellPlacement p in layout.Placements.Values)
        {
            for (int r = p.Row; r < p.Row + p.RowSpan; r++)
            {
                for (int c = p.Column; c < p.Column + p.ColSpan; c++)
                {
                    Assert.True(occupied.Add((c, r)), $"overlap at ({c},{r})");
                }
            }
        }
    }
}
