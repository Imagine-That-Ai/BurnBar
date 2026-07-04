using OpenBurnBar.App.Presentation.MissionControl;
using Xunit;

namespace OpenBurnBar.App.Presentation.Tests.MissionControl;

/// <summary>Locks the forecast band + recommendation math ported from
/// <c>MissionConsoleForecastComputer</c> and <c>MissionConsoleMacHost.recommendation</c>.</summary>
public sealed class MissionForecastComputerTests
{
    private static MissionRuntime Runtime(double pricingFactor = 1.0, double? median = null) =>
        new("codex", "Codex CLI", "CDX", "codex", RuntimeAvailability.Online, median, median is null ? 0 : 6, null, pricingFactor);

    [Fact]
    public void StandardDiligence_CentersOnBaselineMultipliers()
    {
        // baseline 12000 * kind(1.20) * depth(1.00) * runtime(1.0) = 14400 center, +/-30%.
        MissionForecast f = MissionForecastComputer.Forecast(MissionKind.Diligence, MissionDepth.Standard, Runtime());
        Assert.Equal(10080, f.TokensLow);   // 14400 * 0.70
        Assert.Equal(18720, f.TokensHigh);  // 14400 * 1.30
    }

    [Fact]
    public void CreativeWidensBandTo45Percent()
    {
        // creative kind forces widen = 0.45 regardless of depth.
        MissionForecast f = MissionForecastComputer.Forecast(MissionKind.Creative, MissionDepth.Standard, Runtime());
        // center = 12000 * 1.35 = 16200; low = 16200*0.55 = 8910, high = 16200*1.45 = 23490.
        Assert.Equal(8910, f.TokensLow);
        Assert.Equal(23490, f.TokensHigh);
    }

    [Fact]
    public void DeepDepthWidensBandTo45Percent()
    {
        MissionForecast f = MissionForecastComputer.Forecast(MissionKind.Diligence, MissionDepth.Deep, Runtime());
        // center = 12000 * 1.20 * 2.25 = 32400; low = 32400*0.55 = 17820.
        Assert.Equal(17820, f.TokensLow);
        Assert.Equal(46980, f.TokensHigh);
    }

    [Fact]
    public void RuntimePricingFactorScalesTokens()
    {
        MissionForecast cheap = MissionForecastComputer.Forecast(MissionKind.Diligence, MissionDepth.Standard, Runtime(0.5));
        MissionForecast full = MissionForecastComputer.Forecast(MissionKind.Diligence, MissionDepth.Standard, Runtime(1.0));
        Assert.True(cheap.TokensHigh < full.TokensHigh);
        Assert.Equal(full.TokensHigh / 2, cheap.TokensHigh);
    }

    [Fact]
    public void HistoricalMedianBlendsCostFiftyFifty()
    {
        MissionForecast withMedian = MissionForecastComputer.Forecast(MissionKind.Debt, MissionDepth.Standard, Runtime(median: 5.0));
        MissionForecast noMedian = MissionForecastComputer.Forecast(MissionKind.Debt, MissionDepth.Standard, Runtime());
        // A large median ($5) pulls the projected cost up markedly.
        Assert.True(withMedian.CostHighUsd > noMedian.CostHighUsd);
    }

    [Fact]
    public void CostLowNeverNegative()
    {
        MissionForecast f = MissionForecastComputer.Forecast(MissionKind.CostEfficiency, MissionDepth.Light, Runtime(0.05));
        Assert.True(f.CostLowUsd >= 0);
    }

    [Fact]
    public void ElevatedCostFlagTracksDollarThreshold()
    {
        // A pricey deep-creative on a high-factor runtime breaches the $1 high threshold.
        MissionForecast pricey = MissionForecastComputer.Forecast(MissionKind.Creative, MissionDepth.Deep, Runtime(4.0));
        Assert.True(pricey.IsCostElevated);

        // A trim cost-efficiency light run on a near-free runtime stays under $1.
        MissionForecast cheap = MissionForecastComputer.Forecast(MissionKind.CostEfficiency, MissionDepth.Light, Runtime(0.05));
        Assert.False(cheap.IsCostElevated);
    }

    [Fact]
    public void EtaScalesWithTokens()
    {
        MissionForecast light = MissionForecastComputer.Forecast(MissionKind.Diligence, MissionDepth.Light, Runtime());
        MissionForecast deep = MissionForecastComputer.Forecast(MissionKind.Diligence, MissionDepth.Deep, Runtime());
        Assert.True(deep.EtaHighSeconds > light.EtaHighSeconds);
    }

    [Theory]
    // commands + edits + requireApproval -> escalate.
    [InlineData(MissionDepth.Light, MissionApprovalMode.RequireApproval, true, true, MissionRecommendation.Escalate)]
    // requireApproval (without both perms) -> review.
    [InlineData(MissionDepth.Light, MissionApprovalMode.RequireApproval, false, false, MissionRecommendation.Review)]
    // existing policy + light -> proceed.
    [InlineData(MissionDepth.Light, MissionApprovalMode.ExistingPolicy, false, false, MissionRecommendation.Proceed)]
    // existing policy + standard/deep -> review.
    [InlineData(MissionDepth.Standard, MissionApprovalMode.ExistingPolicy, false, false, MissionRecommendation.Review)]
    [InlineData(MissionDepth.Deep, MissionApprovalMode.ExistingPolicy, true, false, MissionRecommendation.Review)]
    public void Recommendation_MatchesSwiftArms(
        MissionDepth depth,
        MissionApprovalMode mode,
        bool commands,
        bool edits,
        MissionRecommendation expected) =>
        Assert.Equal(expected, MissionForecastComputer.Recommendation(depth, mode, commands, edits));
}
