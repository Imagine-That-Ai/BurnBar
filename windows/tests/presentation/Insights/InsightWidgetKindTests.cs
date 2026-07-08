using System;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the per-kind metadata ported from the macOS <c>InsightWidgetKind</c>: the
/// default grid spans (the numbers the canvas packer relies on), the display names, the glyph
/// mapping totality, and the LLM-authored flags.
/// </summary>
public sealed class InsightWidgetKindTests
{
    [Theory]
    [InlineData(InsightWidgetKind.KpiTile, 3, 2)]
    [InlineData(InsightWidgetKind.TimeSeriesLine, 8, 3)]
    [InlineData(InsightWidgetKind.BarRanking, 4, 4)]
    [InlineData(InsightWidgetKind.Donut, 4, 3)]
    [InlineData(InsightWidgetKind.Heatmap, 6, 3)]
    [InlineData(InsightWidgetKind.Sankey, 12, 4)]
    [InlineData(InsightWidgetKind.Radar, 6, 4)]
    [InlineData(InsightWidgetKind.Funnel, 4, 4)]
    [InlineData(InsightWidgetKind.Error, 4, 2)]
    public void DefaultSpan_MatchesSwift(InsightWidgetKind kind, int cols, int rows)
        => Assert.Equal((cols, rows), InsightWidgetKindInfo.DefaultSpan(kind));

    [Fact]
    public void AllKinds_HaveNonEmptyLabelAndSingleGlyph()
    {
        foreach (InsightWidgetKind kind in Enum.GetValues<InsightWidgetKind>())
        {
            Assert.False(string.IsNullOrWhiteSpace(InsightWidgetKindInfo.DisplayName(kind)));
            Assert.Equal(1, InsightWidgetKindInfo.Glyph(kind).Length);
        }
    }

    [Theory]
    [InlineData(InsightWidgetKind.Narrative, true)]
    [InlineData(InsightWidgetKind.Recommendation, true)]
    [InlineData(InsightWidgetKind.BarRanking, false)]
    [InlineData(InsightWidgetKind.KpiTile, false)]
    public void IsLLMAuthored_FlagsNarrativeAndRecommendation(InsightWidgetKind kind, bool expected)
        => Assert.Equal(expected, InsightWidgetKindInfo.IsLLMAuthored(kind));

    [Fact]
    public void DisplayName_SpecificLabels()
    {
        Assert.Equal("KPI Tile", InsightWidgetKindInfo.DisplayName(InsightWidgetKind.KpiTile));
        Assert.Equal("Sankey Flow", InsightWidgetKindInfo.DisplayName(InsightWidgetKind.Sankey));
        Assert.Equal("Top-N Ranking", InsightWidgetKindInfo.DisplayName(InsightWidgetKind.BarRanking));
    }
}
