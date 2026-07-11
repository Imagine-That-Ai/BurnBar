using System;
using System.Collections.Generic;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the render-plan dispatcher — the portable analog of the exhaustive macOS
/// <c>InsightWidgetRenderer</c> switch. Proves every data variant maps to a renderer and that a
/// null payload resolves to the skeleton.
/// </summary>
public sealed class InsightRenderPlanTests
{
    [Fact]
    public void Resolve_NullData_IsSkeleton()
        => Assert.Equal(InsightRenderKind.Skeleton, InsightRenderPlan.Resolve(null));

    public static IEnumerable<object[]> Cases()
    {
        yield return new object[] { new KpiData("m", 1, ValueFormat.Count), InsightRenderKind.Kpi };
        yield return new object[]
        {
            new TimeSeriesData(new List<TimeSeriesSeries>(), "x", "y", ValueFormat.Count), InsightRenderKind.Line,
        };
        yield return new object[] { new RankingData(new List<RankingRow>(), ValueFormat.Count, "d"), InsightRenderKind.Bar };
        yield return new object[] { new DistributionData(new List<DistributionSlice>(), ValueFormat.Count, 0), InsightRenderKind.Donut };
        yield return new object[]
        {
            new HeatmapData(new List<string>(), new List<string>(), new List<IReadOnlyList<double>>(), ValueFormat.Count),
            InsightRenderKind.Heatmap,
        };
        yield return new object[]
        {
            new ScatterData(new List<ScatterPoint>(), "x", "y", ValueFormat.Count, ValueFormat.Count), InsightRenderKind.Scatter,
        };
        yield return new object[] { new SankeyData(new List<SankeyNode>(), new List<SankeyLink>()), InsightRenderKind.Sankey };
        yield return new object[] { new RadarData(new List<string>(), new List<RadarSeries>()), InsightRenderKind.Radar };
        yield return new object[] { new FunnelData(new List<FunnelStep>()), InsightRenderKind.Funnel };
        yield return new object[] { new QuotaData(new List<QuotaBucket>()), InsightRenderKind.Quota };
        yield return new object[] { new NarrativeData("h", "b"), InsightRenderKind.Narrative };
        yield return new object[] { new RecommendationData("h", "r", "a"), InsightRenderKind.Recommendation };
        yield return new object[] { new EmptyData("none"), InsightRenderKind.Empty };
        yield return new object[] { new ErrorData("boom"), InsightRenderKind.Error };
    }

    [Theory]
    [MemberData(nameof(Cases))]
    public void Resolve_MapsEveryDataVariant(InsightWidgetData data, InsightRenderKind expected)
        => Assert.Equal(expected, InsightRenderPlan.Resolve(data));
}
