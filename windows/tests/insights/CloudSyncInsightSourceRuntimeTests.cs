using System;
using System.Linq;
using OpenBurnBar.App.Configuration;
using OpenBurnBar.App.Insights;
using OpenBurnBar.App.Presentation.Dashboard;
using OpenBurnBar.App.Presentation.Insights;
using Xunit;

namespace OpenBurnBar.App.Insights.Tests;

/// <summary>
/// H0 honesty: production mode must not construct non-KPI <see cref="InsightSampleData"/>.
/// Env mutations are isolated per test via try/finally.
/// </summary>
public sealed class CloudSyncInsightSourceRuntimeTests
{
    private const string SampleEnv = "OPENBURNBAR_SAMPLE_MODE";

    private static void ClearSampleMode() => Environment.SetEnvironmentVariable(SampleEnv, null);

    private static void EnableSampleMode() => Environment.SetEnvironmentVariable(SampleEnv, "1");

    [Fact]
    public void ProductionMode_AllNonKpiKinds_ReturnEmpty_NotSampleSeries()
    {
        try
        {
            ClearSampleMode();
            Assert.False(RuntimeDataMode.SampleModeEnabled);

            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            foreach (InsightWidgetKind kind in Enum.GetValues<InsightWidgetKind>())
            {
                if (kind is InsightWidgetKind.KpiTile or InsightWidgetKind.Error)
                {
                    continue;
                }

                InsightWidgetData data = CloudSyncInsightSource.Resolve(kind, seed: 16, empty);
                Assert.IsType<EmptyData>(data);
                Assert.False(data is RankingData or TimeSeriesData or DistributionData or HeatmapData
                    or ScatterData or SankeyData or RadarData or FunnelData or QuotaData
                    or NarrativeData or RecommendationData or KpiData);
            }
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void ProductionMode_KpiWithoutUsage_ReturnsEmptyChrome(int seed)
    {
        try
        {
            ClearSampleMode();
            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);

            EmptyData noData = Assert.IsType<EmptyData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed, empty));
            Assert.Contains("SQLCipher", noData.Reason, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void ProductionMode_KpiWithUsage_MapsLiveSeeds()
    {
        try
        {
            ClearSampleMode();
            var live = new DashboardUsageSummary(
                TotalCostUsd: 12.5,
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
            ClearSampleMode();
        }
    }

    [Fact]
    public void ProductionMode_UnmappedKpiSeed_IsEmpty_NotSample()
    {
        try
        {
            ClearSampleMode();
            var live = new DashboardUsageSummary(1, 1, 1, HasData: true, DashboardUsageOrigin.Local);

            EmptyData cache = Assert.IsType<EmptyData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 3, live));
            Assert.Contains("SQLCipher", cache.Reason, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void SampleMode_WithoutLive_NonKpi_ReturnsDeterministicSampleSeries()
    {
        try
        {
            EnableSampleMode();
            Assert.True(RuntimeDataMode.SampleModeEnabled);

            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            InsightWidgetData ranking = CloudSyncInsightSource.Resolve(InsightWidgetKind.BarRanking, seed: 16, empty);
            Assert.IsType<RankingData>(ranking);
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void SampleMode_WithoutLive_Kpi_ReturnsSampleKpiShell()
    {
        try
        {
            EnableSampleMode();
            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            KpiData kpi = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 1, empty));
            // InsightSampleData.Kpi paints a non-zero fabricated cost (~120–1020).
            Assert.True(kpi.Value > 1);
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void SampleMode_WithLive_PrefersLiveKpiSeeds_OverSample()
    {
        try
        {
            EnableSampleMode();
            var live = new DashboardUsageSummary(
                TotalCostUsd: 4.2,
                TotalTokens: 100,
                SessionCount: 2,
                HasData: true,
                Origin: DashboardUsageOrigin.Local);

            KpiData cost = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 1, live));
            KpiData sessions = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 2, live));
            KpiData tokens = Assert.IsType<KpiData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 4, live));

            Assert.Equal(4.2, cost.Value);
            Assert.Equal(2, sessions.Value);
            Assert.Equal(100, tokens.Value);
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void SampleMode_WithLive_NeverInjectsFabricatedNonKpiSeries()
    {
        try
        {
            EnableSampleMode();
            var live = new DashboardUsageSummary(1, 1, 1, HasData: true, DashboardUsageOrigin.Local);

            // Fail-closed hybrid: live present ⇒ empty unwired kinds (no RankingData fiction).
            Assert.IsType<EmptyData>(
                CloudSyncInsightSource.Resolve(InsightWidgetKind.BarRanking, seed: 16, live));
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void SampleMode_WithLive_ChipAndEmptyCopy_DoNotClaimSamplePreview()
    {
        try
        {
            EnableSampleMode();
            var live = new DashboardUsageSummary(1, 1, 1, HasData: true, DashboardUsageOrigin.Local);
            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);

            Assert.False(CloudSyncInsightSource.InstallsSamplePayloads(live));
            Assert.False(CloudSyncInsightSource.ShowsSamplePreviewChip(live));
            Assert.True(CloudSyncInsightSource.InstallsSamplePayloads(empty));
            Assert.True(CloudSyncInsightSource.ShowsSamplePreviewChip(empty));

            EmptyData hybridEmpty = Assert.IsType<EmptyData>(
                CloudSyncInsightSource.Resolve(InsightWidgetKind.BarRanking, seed: 16, live));
            // Must not use sample-mode "Demo data is labeled" copy when samples were withheld.
            Assert.DoesNotContain("Demo data is labeled", hybridEmpty.Reason, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("Connect", hybridEmpty.Reason, StringComparison.OrdinalIgnoreCase);

            // Unmapped KPI under live still uses connect/engine reason, not demo-labeled copy.
            EmptyData unmappedKpi = Assert.IsType<EmptyData>(
                CloudSyncInsightSource.ResolveKpi(InsightWidgetKind.KpiTile, seed: 3, live));
            Assert.DoesNotContain("Demo data is labeled", unmappedKpi.Reason, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void ProductionMode_EmptyCopy_UsesConnectWording()
    {
        try
        {
            ClearSampleMode();
            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            EmptyData noSample = Assert.IsType<EmptyData>(
                CloudSyncInsightSource.Resolve(InsightWidgetKind.BarRanking, seed: 1, empty));
            Assert.Contains("Connect", noSample.Reason, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("Demo data is labeled", noSample.Reason, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            ClearSampleMode();
        }
    }

    [Fact]
    public void Composition_SampleFallbackFalse_ResolverEmptySummary_YieldsEmptyNonKpi()
    {
        // Mirrors InsightsPage production wiring without WinUI.
        try
        {
            ClearSampleMode();
            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            InsightsProductionComposition.Install(empty);

            InsightCanvas canvas = InsightsBuiltInTemplates.Find("cost-audit-7d")!.Instantiate();
            Assert.All(canvas.Widgets, w => Assert.IsType<EmptyData>(w.Data));
            Assert.DoesNotContain(canvas.Widgets, w => w.Data is RankingData or KpiData or TimeSeriesData);
        }
        finally
        {
            InsightsBuiltInTemplates.RealDataResolver = null;
            InsightsBuiltInTemplates.SampleFallbackEnabled = false;
            ClearSampleMode();
        }
    }

    [Fact]
    public void Composition_ReinstallWithLiveSummary_UpdatesStampedKpis()
    {
        // Guards the audit fix: stamp must not freeze the first empty snapshot forever.
        try
        {
            ClearSampleMode();
            var empty = new DashboardUsageSummary(0, 0, 0, HasData: false, DashboardUsageOrigin.Empty);
            InsightsProductionComposition.Install(empty);
            InsightCanvas emptyCanvas = InsightsBuiltInTemplates.Find("today")!.Instantiate();
            Assert.Contains(emptyCanvas.Widgets, w => w.Kind == InsightWidgetKind.KpiTile && w.Data is EmptyData);

            var live = new DashboardUsageSummary(
                TotalCostUsd: 42.5,
                TotalTokens: 1000,
                SessionCount: 7,
                HasData: true,
                Origin: DashboardUsageOrigin.Local);
            InsightsProductionComposition.Install(live);
            InsightCanvas liveCanvas = InsightsBuiltInTemplates.Find("today")!.Instantiate();

            KpiData cost = Assert.IsType<KpiData>(
                liveCanvas.Widgets.First(w => w.Title == "Cost").Data);
            Assert.Equal(42.5, cost.Value);
            Assert.False(CloudSyncInsightSource.ShowsSamplePreviewChip(live));
        }
        finally
        {
            InsightsBuiltInTemplates.RealDataResolver = null;
            InsightsBuiltInTemplates.SampleFallbackEnabled = false;
            ClearSampleMode();
        }
    }
}
