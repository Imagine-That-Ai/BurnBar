using System;
using OpenBurnBar.App.Components;
using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Components.Tests;

/// <summary>Asserts ProviderMetadata against the Swift golden tables in AgentProvider.swift
/// and AgentProvider+LogoBackdrop.swift.</summary>
public sealed class ProviderMetadataTests
{
    [Theory]
    [InlineData(AgentProviderBrand.Factory, "Factory")]
    [InlineData(AgentProviderBrand.ClaudeCode, "Claude Code")]
    [InlineData(AgentProviderBrand.KiloCode, "Kilo Code")]
    [InlineData(AgentProviderBrand.RooCode, "Roo Code")]
    [InlineData(AgentProviderBrand.PiAgent, "Pi Agent")]
    [InlineData(AgentProviderBrand.GeminiCLI, "Gemini CLI")]
    [InlineData(AgentProviderBrand.Omp, "OMP")]
    [InlineData(AgentProviderBrand.XAI, "xAI")]
    [InlineData(AgentProviderBrand.Mimo, "MiMo")]
    [InlineData(AgentProviderBrand.CursorAgent, "Cursor Agent")]
    public void DisplayName_matches_rawValue(AgentProviderBrand p, string expected) =>
        Assert.Equal(expected, ProviderMetadata.DisplayName(p));

    [Theory]
    [InlineData(AgentProviderBrand.Factory, "FactoryLogo")]
    [InlineData(AgentProviderBrand.OpenBurnBar, "AppLogo")]
    [InlineData(AgentProviderBrand.XAI, "GrokLogo")]          // xAI logo asset is GrokLogo
    [InlineData(AgentProviderBrand.CursorAgent, "CursorLogo")] // shares Cursor's asset
    [InlineData(AgentProviderBrand.Omp, "OMPLogo")]
    public void BundledLogoName_matches_asset_catalog(AgentProviderBrand p, string expected) =>
        Assert.Equal(expected, ProviderMetadata.BundledLogoName(p));

    [Fact]
    public void DisplayName_and_logo_cover_every_case()
    {
        foreach (AgentProviderBrand p in Enum.GetValues<AgentProviderBrand>())
        {
            Assert.False(string.IsNullOrEmpty(ProviderMetadata.DisplayName(p)));
            Assert.False(string.IsNullOrEmpty(ProviderMetadata.BundledLogoName(p)));
            Assert.False(string.IsNullOrEmpty(ProviderMetadata.FallbackGlyph(p)));
        }
    }

    [Theory]
    // Dark-mode monochrome-backdrop providers (Swift dark switch).
    [InlineData(AgentProviderBrand.OpenAI, true, true)]
    [InlineData(AgentProviderBrand.Codex, true, true)]
    [InlineData(AgentProviderBrand.ClaudeCode, true, true)]
    [InlineData(AgentProviderBrand.XAI, true, true)]
    [InlineData(AgentProviderBrand.Hermes, true, true)]
    // Not in the dark list.
    [InlineData(AgentProviderBrand.OpenBurnBar, true, false)]
    [InlineData(AgentProviderBrand.DeepSeek, true, false)]
    [InlineData(AgentProviderBrand.Warp, true, false)]
    // Light-mode list is only kimi/goose/augment.
    [InlineData(AgentProviderBrand.Kimi, false, true)]
    [InlineData(AgentProviderBrand.Goose, false, true)]
    [InlineData(AgentProviderBrand.Augment, false, true)]
    [InlineData(AgentProviderBrand.OpenAI, false, false)]
    [InlineData(AgentProviderBrand.ClaudeCode, false, false)]
    public void NeedsMonochromeLogoBackdrop_matches_swift(AgentProviderBrand p, bool isDark, bool expected) =>
        Assert.Equal(expected, ProviderMetadata.NeedsMonochromeLogoBackdrop(p, isDark));

    [Fact]
    public void LogoCornerRadiusFactor_is_the_swift_squircle_ratio() =>
        Assert.Equal(0.2237, ProviderMetadata.LogoCornerRadiusFactor, 6);
}
