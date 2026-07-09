using System;
using System.Linq;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Production-mode empty widgets must never look like demo series (H0 honesty).
/// </summary>
public sealed class InsightEmptyDataTests
{
    [Fact]
    public void ForKind_NonKpi_IsEmptyData_NeverSampleSeries()
    {
        foreach (InsightWidgetKind kind in Enum.GetValues<InsightWidgetKind>())
        {
            if (kind is InsightWidgetKind.KpiTile or InsightWidgetKind.Error)
            {
                continue;
            }

            InsightWidgetData data = InsightEmptyData.ForKind(kind, seed: 7);
            Assert.IsType<EmptyData>(data);
            Assert.False(data is RankingData or TimeSeriesData or DistributionData or HeatmapData
                or ScatterData or SankeyData or RadarData or FunnelData or QuotaData
                or NarrativeData or RecommendationData);
        }
    }

    [Fact]
    public void ForKind_Kpi_IsZeroedShell_WithReason()
    {
        KpiData kpi = Assert.IsType<KpiData>(InsightEmptyData.ForKind(InsightWidgetKind.KpiTile, seed: 1));
        Assert.Equal(0, kpi.Value);
        Assert.Contains("SQLCipher", kpi.ContextLabel ?? string.Empty, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ForKind_CoversEveryWidgetKind()
    {
        Assert.All(
            Enum.GetValues<InsightWidgetKind>(),
            kind => Assert.NotNull(InsightEmptyData.ForKind(kind, 0)));
    }
}
