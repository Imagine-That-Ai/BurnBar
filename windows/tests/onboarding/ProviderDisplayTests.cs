using System;
using OpenBurnBar.App.Onboarding;
using OpenBurnBar.App.Theme;
using Xunit;

namespace OpenBurnBar.App.Onboarding.Tests;

/// <summary>Coverage for the provider display-name table (parity with the macOS
/// <c>AgentProvider</c> raw values).</summary>
public sealed class ProviderDisplayTests
{
    [Theory]
    [InlineData(AgentProviderBrand.ClaudeCode, "Claude Code")]
    [InlineData(AgentProviderBrand.KiloCode, "Kilo Code")]
    [InlineData(AgentProviderBrand.RooCode, "Roo Code")]
    [InlineData(AgentProviderBrand.ForgeDev, "Forge")]
    [InlineData(AgentProviderBrand.PiAgent, "Pi Agent")]
    [InlineData(AgentProviderBrand.GeminiCLI, "Gemini CLI")]
    [InlineData(AgentProviderBrand.Omp, "OMP")]
    [InlineData(AgentProviderBrand.XAI, "xAI")]
    [InlineData(AgentProviderBrand.Mimo, "MiMo")]
    [InlineData(AgentProviderBrand.CursorAgent, "Cursor Agent")]
    public void DisplayName_MatchesSwiftRawValue(AgentProviderBrand provider, string expected)
    {
        Assert.Equal(expected, ProviderDisplay.DisplayName(provider));
    }

    [Fact]
    public void EveryProvider_HasANonEmptyDisplayName()
    {
        foreach (AgentProviderBrand provider in Enum.GetValues<AgentProviderBrand>())
        {
            Assert.False(string.IsNullOrWhiteSpace(ProviderDisplay.DisplayName(provider)));
        }
    }
}
