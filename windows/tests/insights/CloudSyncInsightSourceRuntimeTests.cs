using System;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Insights;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Insights.Tests;

/// <summary>
/// H0 honesty: production mode must not construct non-KPI <see cref="InsightSampleData"/>.
/// </summary>
public sealed class CloudSyncInsightSourceRuntimeTests
{
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";

    [Fact]
    public void ProductionMode_NonKpi_ReturnsEmpty_NotSampleSeries()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            Assert.False(RuntimeDataMode.SampleModeEnabled);

            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            InsightWidgetData ranking = CloudSyncInsightSource.Resolve(InsightWidgetKind.BarRanking, seed: 16, empty);
            InsightWidgetData series = CloudSyncInsightSource.Resolve(InsightWidgetKind.TimeSeriesLine, seed: 5, empty);
            InsightWidgetData narrative = CloudSyncInsightSource.Resolve(InsightWidgetKind.Narrative, seed: 7, empty);

            Assert.IsType<EmptyData>(ranking);
            Assert.IsType<EmptyData>(series);
            Assert.IsType<EmptyData>(narrative);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void ProductionMode_KpiWithoutUsage_ReturnsZeroedEmptyShell()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);

            KpiData cost = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 1, empty));
            Assert.Equal(0, cost.Value);
            Assert.Contains("SQLCipher", cost.ContextLabel ?? string.Empty, StringComparison.OrdinalIgnoreCase);
            // Must not look like InsightSampleData.Kpi (which paints ~120–1020 cost).
            Assert.True(cost.Value < 1);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void ProductionMode_KpiWithUsage_MapsLiveSeeds()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            var live = new DashboardUsageSummary(
                SpendThisMonthUsd: 12.5,
                TotalTokens: 9001,
                SessionCount: 3,
                HasData: true,
                Origin: DashboardUsageOrigin.Local);

            KpiData cost = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 1, live));
            KpiData sessions = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 2, live));
            KpiData tokens = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 4, live));

            Assert.Equal(12.5, cost.Value);
            Assert.Equal(3, sessions.Value);
            Assert.Equal(9001, tokens.Value);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void ProductionMode_UnmappedKpiSeed_IsEmpty_NotSample()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
            var live = new DashboardUsageSummary(1, 1, 1, HasData: true, DashboardUsageOrigin.Local);

            // Seed 3 = cache hit — Engine path not wired; production stays empty.
            KpiData cache = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 3, live));
            Assert.Equal(0, cache.Value);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }

    [Fact]
    public void SampleMode_NonKpi_ReturnsDeterministicSampleSeries()
    {
        try
        {
            Environment.SetEnvironmentVariable(SampleEnv, "1");
            Assert.True(RuntimeDataMode.SampleModeEnabled);

            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            InsightWidgetData ranking = CloudSyncInsightSource.Resolve(InsightWidgetKind.BarRanking, seed: 16, empty);
            Assert.IsType<RankingData>(ranking);
        }
        finally
        {
            Environment.SetEnvironmentVariable(SampleEnv, null);
        }
    }
}
