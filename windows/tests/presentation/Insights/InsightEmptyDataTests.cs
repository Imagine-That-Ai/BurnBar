using System;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Production-mode empty widgets must never look like demo series or live zero KPI (H0 honesty).
/// </summary>
public sealed class InsightEmptyDataTests
{
    [Fact]
    public void ForKind_NonError_IsEmptyData_NeverSampleSeriesOrZeroKpi()
    {
        foreach (InsightWidgetKind kind in Enum.GetValues<InsightWidgetKind>())
        {
            if (kind == InsightWidgetKind.Error)
            {
                continue;
            }

            InsightWidgetData data = InsightEmptyData.ForKind(kind, seed: 7);
            Assert.IsType<EmptyData>(data);
            Assert.False(data is RankingData or TimeSeriesData or DistributionData or HeatmapData
                or ScatterData or SankeyData or RadarData or FunnelData or QuotaData
                or NarrativeData or RecommendationData or KpiData);
        }
    }

    [Fact]
    public void ForKind_Error_IsErrorData()
    {
        ErrorData err = Assert.IsType<ErrorData>(
            InsightEmptyData.ForKind(InsightWidgetKind.Error, seed: 0, reason: "boom"));
        Assert.Equal("boom", err.Message);
    }

    [Fact]
    public void ForKind_CustomReason_EmbedsInEmptyData()
    {
        EmptyData empty = Assert.IsType<EmptyData>(
            InsightEmptyData.ForKind(InsightWidgetKind.BarRanking, seed: 1, reason: "custom-no-data"));
        Assert.Equal("custom-no-data", empty.Reason);
    }

    [Fact]
    public void ForKind_DefaultReason_MentionsSqlCipherOrSampleMode()
    {
        EmptyData empty = Assert.IsType<EmptyData>(InsightEmptyData.ForKind(InsightWidgetKind.KpiTile));
        Assert.Contains("SQLCipher", empty.Reason, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("SAMPLE_MODE", empty.Reason, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void ForKind_KpiSeeds_UseEmptyData_NotNumericZeroShell(int seed)
    {
        InsightWidgetData data = InsightEmptyData.ForKind(InsightWidgetKind.KpiTile, seed);
        Assert.IsType<EmptyData>(data);
        Assert.False(data is KpiData);
    }

    [Fact]
    public void ForKind_CoversEveryWidgetKind()
    {
        Assert.All(
            Enum.GetValues<InsightWidgetKind>(),
            kind => Assert.NotNull(InsightEmptyData.ForKind(kind, 0)));
    }
}
