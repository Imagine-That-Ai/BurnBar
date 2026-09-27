using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Parity tests for <see cref="SummaryProviderMetadata"/> + the summary/chat
/// defaults (SummarySettings.swift / ChatBackendSettings.swift init rules).
/// </summary>
public sealed class SummaryProviderIdTests
{
    [Fact]
    public void DefaultOrder_MatchesSwift()
    {
        Assert.Equal(
            new[]
            {
                SummaryProviderId.Local,
                SummaryProviderId.Mlx,
                SummaryProviderId.MiniMax,
                SummaryProviderId.OpenRouter,
                SummaryProviderId.Zai,
                SummaryProviderId.Ollama,
            },
            SummaryProviderMetadata.DefaultOrder);
        Assert.Equal("local,mlx,minimax,openrouter,zai,ollama", SummaryProviderMetadata.DefaultCsv);
    }

    [Theory]
    [InlineData(SummaryProviderId.Local, "local")]
    [InlineData(SummaryProviderId.Mlx, "mlx")]
    [InlineData(SummaryProviderId.MiniMax, "minimax")]
    [InlineData(SummaryProviderId.OpenRouter, "openrouter")]
    [InlineData(SummaryProviderId.Zai, "zai")]
    [InlineData(SummaryProviderId.Ollama, "ollama")]
    public void RawValue_MatchesSwiftRawValue(SummaryProviderId provider, string expected)
    {
        Assert.Equal(expected, provider.RawValue());
        Assert.Equal(provider, SummaryProviderMetadata.FromRawValue(expected));
    }

    [Fact]
    public void Parse_EmptyOrUnknown_ResolvesToDefaultOrder()
    {
        Assert.Equal(SummaryProviderMetadata.DefaultOrder, SummaryProviderMetadata.Parse(string.Empty));
        Assert.Equal(SummaryProviderMetadata.DefaultOrder, SummaryProviderMetadata.Parse("nope,unknown"));
        Assert.Equal(
            SummaryProviderMetadata.DefaultOrder,
            SummaryProviderMetadata.Parse(SummaryProviderMetadata.DefaultCsv));
    }

    [Fact]
    public void Parse_IsCaseInsensitive_DedupesFirstWins_AndCompletes()
    {
        Assert.Equal(
            new[]
            {
                SummaryProviderId.Ollama,
                SummaryProviderId.Local,
                SummaryProviderId.Mlx,
                SummaryProviderId.MiniMax,
                SummaryProviderId.OpenRouter,
                SummaryProviderId.Zai,
            },
            SummaryProviderMetadata.Parse(" ollama ,OLLAMA,zzz"));
        Assert.Equal(
            "ollama,local,mlx,minimax,openrouter,zai",
            SummaryProviderMetadata.Encode(SummaryProviderMetadata.Parse("ollama")));
    }

    [Fact]
    public void SanitizeClamps_MatchSwiftInitRules()
    {
        Assert.Equal(60_000, SummarySettingsDefaults.SanitizeMaxPromptChars(null));
        Assert.Equal(60_000, SummarySettingsDefaults.SanitizeMaxPromptChars(3_999));
        Assert.Equal(4_000, SummarySettingsDefaults.SanitizeMaxPromptChars(4_000));
        Assert.Equal(280, SummarySettingsDefaults.SanitizeMaxOutputTokens(null));
        Assert.Equal(280, SummarySettingsDefaults.SanitizeMaxOutputTokens(119));
        Assert.Equal(120, SummarySettingsDefaults.SanitizeMaxOutputTokens(120));
        Assert.Equal(1, SummarySettingsDefaults.SanitizeRetryCount(null));
        Assert.Equal(0, SummarySettingsDefaults.SanitizeRetryCount(-3));
        Assert.Equal(25, SummarySettingsDefaults.SanitizeBatchSize(null));
        Assert.Equal(1, SummarySettingsDefaults.SanitizeBatchSize(0));
        Assert.Equal(120, SummarySettingsDefaults.SanitizeFirstLoadBatchSize(null));
        Assert.Equal(1, SummarySettingsDefaults.SanitizeFirstLoadBatchSize(-1));
        Assert.Equal(20, SummarySettingsDefaults.SanitizeRequestTimeoutSeconds(null));
        Assert.Equal(20, SummarySettingsDefaults.SanitizeRequestTimeoutSeconds(0));
        Assert.Equal(20, SummarySettingsDefaults.SanitizeRequestTimeoutSeconds(-2));
        Assert.Equal(8, SummarySettingsDefaults.SanitizeMaxConcurrency(null));
        Assert.Equal(1, SummarySettingsDefaults.SanitizeMaxConcurrency(0));
        Assert.Equal(0, SummarySettingsDefaults.SanitizeTimeLimitMinutes(null));
        Assert.Equal(0, SummarySettingsDefaults.SanitizeTimeLimitMinutes(-5));
    }

    [Fact]
    public void GatewayAndSummaryDefaults_MatchSwift()
    {
        Assert.Equal("http://127.0.0.1:18789", ChatBackendDefaults.OpenClawGatewayBaseUrl);
        Assert.Equal("http://127.0.0.1:8642", ChatBackendDefaults.HermesGatewayBaseUrl);
        Assert.Equal("http://127.0.0.1:8765", ChatBackendDefaults.PiAgentGatewayBaseUrl);
        Assert.Equal(ChatBackendDefaults.RealtimeRelayUrl, string.Empty);
        Assert.True(ChatBackendDefaults.ComputerUseKillSwitch);
        Assert.True(ChatBackendDefaults.MediaKillSwitch);
        Assert.True(ChatBackendDefaults.WarRoomKillSwitch);
        Assert.Equal("qwen/qwen3.5-9b", SummarySettingsDefaults.OpenRouterPrimaryModel);
        Assert.Equal("openai/gpt-5-nano", SummarySettingsDefaults.OpenRouterFallbackModel);
        Assert.Equal("mlx-community/Qwen3-4B-4bit", SummarySettingsDefaults.MlxModel);
    }
}
