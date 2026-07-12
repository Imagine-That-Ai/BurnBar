using System;
using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.Insights;

/// <summary>
/// Real tests for the deterministic sample-data generator that populates the Windows template
/// preview. Pins shape (series/point counts, value ranges) and determinism (same seed → same
/// values) so the gallery → canvas render is reproducible.
/// </summary>
public sealed class InsightSampleDataTests
{
    [Fact]
    public void Ranking_IsSortedDescendingAndDeterministic()
    {
        RankingData a = InsightSampleData.Ranking(5);
        RankingData b = InsightSampleData.Ranking(5);

        List<double> values = a.Rows.Select(r => r.Value).ToList();
        Assert.Equal(values.OrderByDescending(v => v).ToList(), values);
        Assert.Equal(values, b.Rows.Select(r => r.Value).ToList());
    }

    [Fact]
    public void TimeSeries_HasThreeSeriesOfFourteenPoints()
    {
        TimeSeriesData ts = InsightSampleData.TimeSeries(3, ValueFormat.Currency);
        Assert.Equal(3, ts.Series.Count);
        Assert.All(ts.Series, s => Assert.Equal(14, s.Points.Count));
    }

    [Fact]
    public void Heatmap_IsSevenByTwentyFour()
    {
        HeatmapData h = InsightSampleData.Heatmap(2);
        Assert.Equal(7, h.Cells.Count);
        Assert.All(h.Cells, row => Assert.Equal(24, row.Count));
        Assert.Equal(7, h.RowLabels.Count);
        Assert.Equal(24, h.ColumnLabels.Count);
    }

    [Fact]
    public void Radar_ValuesWithinUnitBand()
    {
        RadarData r = InsightSampleData.Radar(1);
        Assert.Equal(6, r.Axes.Count);
        Assert.All(r.Series, s =>
        {
            Assert.Equal(r.Axes.Count, s.Values.Count);
            Assert.All(s.Values, v => Assert.InRange(v, 0.0, 1.0));
        });
    }

    [Fact]
    public void Quota_FractionsClampToUnit()
    {
        QuotaData q = InsightSampleData.Quota(4);
        Assert.NotEmpty(q.Buckets);
        Assert.All(q.Buckets, b => Assert.InRange(b.Fraction, 0.0, 1.0));
    }

    [Fact]
    public void ForKind_CoversEveryKind()
    {
        foreach (InsightWidgetKind kind in Enum.GetValues<InsightWidgetKind>())
        {
            Assert.NotNull(InsightSampleData.ForKind(kind, 1));
        }
    }

    [Theory]
    [InlineData(50.0, 100.0, 0.5)]
    [InlineData(150.0, 100.0, 1.0)]  // clamps to 1
    public void QuotaBucket_Fraction_Clamps(double used, double limit, double expected)
    {
        var bucket = new QuotaBucket("id", "P", "b", used, limit);
        Assert.Equal(expected, bucket.Fraction, 6);
    }

    [Fact]
    public void QuotaBucket_NoLimit_IsZeroFraction()
        => Assert.Equal(0, new QuotaBucket("id", "P", "b", 50, null).Fraction, 6);
}
