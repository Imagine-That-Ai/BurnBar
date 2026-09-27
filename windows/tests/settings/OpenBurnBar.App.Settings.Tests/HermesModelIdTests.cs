using System.Linq;
using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Parity tests for <see cref="HermesModelId"/> — the Hermes runtime picker
/// (AgentLens/Models/HermesModelID.swift). Raw values + CSV round-trip +
/// default triple must match macOS.
/// </summary>
public sealed class HermesModelIdTests
{
    [Fact]
    public void DefaultEnabled_IsTheMinimumDefaultTriple()
    {
        Assert.Equal(
            new[] { HermesModelId.Codex, HermesModelId.Claude, HermesModelId.Ollama },
            HermesModelMetadata.DefaultEnabled);
    }

    [Theory]
    [InlineData(HermesModelId.Codex, "codex")]
    [InlineData(HermesModelId.Claude, "claude")]
    [InlineData(HermesModelId.Zai, "zai")]
    [InlineData(HermesModelId.Kimi, "kimi")]
    [InlineData(HermesModelId.MiniMax, "minimax")]
    [InlineData(HermesModelId.Ollama, "ollama")]
    public void RawValue_MatchesSwiftRawValue(HermesModelId model, string expected)
    {
        Assert.Equal(expected, model.RawValue());
        Assert.Equal(model, HermesModelMetadata.FromRawValue(expected));
    }

    [Fact]
    public void FromRawValue_UnknownToken_IsNull()
    {
        Assert.Null(HermesModelMetadata.FromRawValue("not-a-model"));
        Assert.Null(HermesModelMetadata.FromRawValue(null));
    }

    [Fact]
    public void DisplayMetadata_MatchesSwift()
    {
        Assert.Equal("Z.ai", HermesModelId.Zai.DisplayName());
        Assert.Equal("Z.ai", HermesModelId.Zai.ShortLabel());
        Assert.Equal("zai", HermesModelId.Zai.HermesModelOverride());
        Assert.Equal(AgentProvider.Ollama, HermesModelId.Ollama.AgentProvider());
        Assert.Equal(AgentProvider.ClaudeCode, HermesModelId.Claude.AgentProvider());
    }

    [Fact]
    public void CsvRoundTrip_PreservesOrderAndDropsUnknowns()
    {
        var models = new[] { HermesModelId.Kimi, HermesModelId.MiniMax };
        Assert.Equal(models, HermesModelMetadata.DecodeEnabledList(
            HermesModelMetadata.EncodeEnabledList(models)));
        Assert.Equal(string.Empty, HermesModelMetadata.EncodeEnabledList(
            System.Array.Empty<HermesModelId>()));
        Assert.Equal(
            new[] { HermesModelId.Codex },
            HermesModelMetadata.DecodeEnabledList(" codex ,,unknown "));
    }

    [Fact]
    public void EnabledOrDefault_EmptyCsvResolvesToTriple()
    {
        Assert.Equal(
            HermesModelMetadata.DefaultEnabled,
            HermesModelMetadata.EnabledOrDefault(string.Empty));
        Assert.Equal(
            new[] { HermesModelId.Zai },
            HermesModelMetadata.EnabledOrDefault("zai"));
    }

    [Fact]
    public void WithEnabled_AppendsDeduped_AndRemoves()
    {
        var start = new[] { HermesModelId.Codex };
        Assert.Equal(
            new[] { HermesModelId.Codex, HermesModelId.Zai },
            HermesModelMetadata.WithEnabled(start, HermesModelId.Zai, true));
        Assert.Equal(
            start,
            HermesModelMetadata.WithEnabled(start, HermesModelId.Codex, true));
        Assert.Equal(
            System.Array.Empty<HermesModelId>(),
            HermesModelMetadata.WithEnabled(start, HermesModelId.Codex, false));
    }

    [Fact]
    public void SelectionOverride_MirrorsIntoHermesChatModelOverride()
    {
        Assert.Equal(
            "ollama",
            HermesModelMetadata.HermesModelOverrideForSelection(HermesModelId.Ollama));
        Assert.Equal(string.Empty, HermesModelMetadata.HermesModelOverrideForSelection(null));
    }
}
