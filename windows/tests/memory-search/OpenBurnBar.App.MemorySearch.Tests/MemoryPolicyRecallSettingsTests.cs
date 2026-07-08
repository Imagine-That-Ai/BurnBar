using System.Collections.Generic;
using System.Linq;
using OpenBurnBar.App.MemorySearch.Memory;
using Xunit;

namespace OpenBurnBar.App.MemorySearch.Tests;

/// <summary>
/// Policy constants/clamps, kill switch, recall budget math, and the settings snapshot
/// derivations. Swift: <c>MemoryExtractionPolicy</c> / <c>MemoryRecallBudget</c> /
/// <c>MemoryExtractionSettingsSnapshot</c>.
/// </summary>
public sealed class MemoryPolicyRecallSettingsTests
{
    [Fact]
    public void Policy_ConstantsMatchSwift()
    {
        Assert.Equal(16_000, MemoryExtractionPolicy.MaxPromptChars);
        Assert.Equal(512, MemoryExtractionPolicy.MaxOutputTokens);
        Assert.Equal(12, MemoryExtractionPolicy.MaxCandidatesPerJob);
        Assert.Equal(8, MemoryExtractionPolicy.MaxJobsPerPump);
        Assert.Equal(240, MemoryExtractionPolicy.MaxPumpDurationSeconds);
        Assert.Equal(0.50, MemoryExtractionPolicy.DefaultDailyCapUsd);
        Assert.Equal(60, MemoryExtractionPolicy.DefaultRequestTimeoutSeconds);
    }

    [Theory]
    [InlineData(100, 4_000)]
    [InlineData(9_000, 9_000)]
    [InlineData(99_999, 16_000)]
    public void Policy_ClampedPromptChars(int input, int expected)
    {
        Assert.Equal(expected, MemoryExtractionPolicy.ClampedPromptChars(input));
    }

    [Theory]
    [InlineData(0, 120)]
    [InlineData(300, 300)]
    [InlineData(9_000, 512)]
    public void Policy_ClampedOutputTokens(int input, int expected)
    {
        Assert.Equal(expected, MemoryExtractionPolicy.ClampedOutputTokens(input));
    }

    [Fact]
    public void KillSwitch_DefaultsFailSafeToDisallowed()
    {
        Assert.False(new MemoryExtractionKillSwitch().IsAllowed());
        var gate = new MemoryExtractionKillSwitch();
        gate.Set(true);
        Assert.True(gate.IsAllowed());
        gate.Set(false);
        Assert.False(gate.IsAllowed());
    }

    [Fact]
    public void RecallBudget_ForReply_HighRecallWidensLimitNotBudget()
    {
        var normal = MemoryRecallBudget.ForReply(500, highRecall: false);
        var high = MemoryRecallBudget.ForReply(500, highRecall: true);
        Assert.Equal(8, normal.Limit);
        Assert.Equal(16, high.Limit);
        Assert.Equal(500, normal.TokenBudget);
        Assert.Equal(500, high.TokenBudget);
    }

    [Fact]
    public void RecallBudget_TokenBudgetFlooredAtOne()
    {
        Assert.Equal(1, MemoryRecallBudget.ForReply(0, false).TokenBudget);
        Assert.Equal(1, MemoryRecallBudget.ForReply(-5, false).TokenBudget);
    }

    [Fact]
    public void RecallBudget_TokenEstimation_CeilAtProseRatio()
    {
        Assert.Equal(0, MemoryRecallBudget.EstimatedTokenCount(0, 3.5));
        Assert.Equal(2, MemoryRecallBudget.EstimatedTokenCount(7, 3.5)); // 7/3.5 = 2
        Assert.Equal(3, MemoryRecallBudget.EstimatedTokenCount(8, 3.5)); // 8/3.5 = 2.28 → 3
    }

    [Fact]
    public void RecallBudget_WrapperOverhead_MatchesPinnedDerivation()
    {
        // 202 = EstimateProseTokens(701) + 1 (the pinned wrapper-envelope derivation).
        Assert.Equal(202, MemoryRecallBudget.WrapperTokenOverhead);
        Assert.Equal(201, MemoryRecallBudget.EstimateProseTokens(new string('x', 701)));
        Assert.Equal(MemoryRecallBudget.WrapperTokenOverhead, MemoryRecallBudget.EstimateProseTokens(new string('x', 701)) + 1);
    }

    [Fact]
    public void Settings_LocalFirstOrder_KeepsOnDeviceProvidersDeduped()
    {
        var order = MemoryExtractionSettingsSnapshot.LocalFirstProviderOrder(new[]
        {
            MemorySummaryProvider.OpenRouter,
            MemorySummaryProvider.Ollama,
            MemorySummaryProvider.Local,
            MemorySummaryProvider.Ollama, // dup
            MemorySummaryProvider.MiniMax, // cloud → dropped
        });

        Assert.Equal(new[] { MemorySummaryProvider.Ollama, MemorySummaryProvider.Local }, order);
    }

    [Fact]
    public void Settings_LocalFirstOrder_NoOnDeviceSurvivors_ForcesLocal()
    {
        var order = MemoryExtractionSettingsSnapshot.LocalFirstProviderOrder(new[] { MemorySummaryProvider.Zai });
        Assert.Equal(new[] { MemorySummaryProvider.Local }, order);
    }

    [Theory]
    [InlineData(0, 60)]
    [InlineData(-3, 60)]
    [InlineData(45, 45)]
    public void Settings_EffectiveRequestTimeout(double configured, double expected)
    {
        Assert.Equal(expected, MemoryExtractionSettingsSnapshot.EffectiveRequestTimeout(configured));
    }

    [Fact]
    public void Settings_EffectiveDailyCap_NilDefaults_ZeroIsExplicit_ElseClamped()
    {
        Assert.Equal(0.50, MemoryExtractionSettingsSnapshot.EffectiveDailyCapUsd(null));
        Assert.Equal(0.0, MemoryExtractionSettingsSnapshot.EffectiveDailyCapUsd(0));
        Assert.Equal(0.25, MemoryExtractionSettingsSnapshot.EffectiveDailyCapUsd(0.25));
        Assert.Equal(0.50, MemoryExtractionSettingsSnapshot.EffectiveDailyCapUsd(5.0));
    }

    [Fact]
    public void Settings_Build_AppliesClampsAndPins()
    {
        var snapshot = MemoryExtractionSettingsSnapshot.Build(
            summaryProviderOrder: new[] { MemorySummaryProvider.MiniMax, MemorySummaryProvider.Local },
            localBaseUrl: "http://localhost",
            localModel: "llama",
            mlxBaseUrl: "http://mlx",
            mlxModel: "mlx-model",
            miniMaxModel: "mm",
            openRouterPrimaryModel: "or-primary",
            openRouterFallbackModel: "or-fallback",
            zaiModel: "zai",
            ollamaBaseUrl: "http://ollama",
            ollamaModel: "ollama-model",
            configuredRequestTimeoutSeconds: 0,
            summaryMaxPromptChars: 100,
            summaryMaxOutputTokens: 9_000,
            summaryDailyCapUsd: null,
            summaryRetryCount: -2);

        Assert.Equal(new[] { MemorySummaryProvider.Local }, snapshot.ProviderOrder);
        Assert.Equal(60, snapshot.RequestTimeoutSeconds);
        Assert.Equal(4_000, snapshot.MaxPromptChars);
        Assert.Equal(512, snapshot.MaxOutputTokens);
        Assert.Equal(0.50, snapshot.DailyCapUsd);
        Assert.Equal(0, snapshot.RetryCount);
        Assert.Equal(12, snapshot.MaxCandidatesPerJob);
        Assert.Equal("openburnbar-prompt-v1", snapshot.PromptVersion);
    }
}
