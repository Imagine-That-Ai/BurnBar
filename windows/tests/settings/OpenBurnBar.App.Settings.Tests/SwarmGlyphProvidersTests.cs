using System.Linq;
using OpenBurnBar.App.Settings;
using Xunit;

namespace OpenBurnBar.App.Settings.Tests;

/// <summary>
/// Parity tests for <see cref="SwarmGlyphProviders"/> — the swarm-logo cycle
/// order (OpenBurnBarCore AgentProvider.swarmGlyphProviders), which is the
/// default <c>selectedGlyphs</c> of the swarm preferences on every platform.
/// </summary>
public sealed class SwarmGlyphProvidersTests
{
    [Fact]
    public void Ordered_MatchesTheSwiftGlyphList()
    {
        var expected = new[]
        {
            AgentProvider.Factory,
            AgentProvider.ClaudeCode,
            AgentProvider.Codex,
            AgentProvider.OpenCode,
            AgentProvider.OpenClaw,
            AgentProvider.OpenClaude,
            AgentProvider.Omp,
            AgentProvider.Hermes,
            AgentProvider.PrimeAgent,
            AgentProvider.GeminiCLI,
            AgentProvider.Junie,
            AgentProvider.Antigravity,
            AgentProvider.OpenAI,
            AgentProvider.OpenBurnBar,
            AgentProvider.DeepSeek,
            AgentProvider.MiniMax,
            AgentProvider.Zai,
            AgentProvider.XAI,
            AgentProvider.Mimo,
            AgentProvider.Cursor,
            AgentProvider.Copilot,
            AgentProvider.Kimi,
            AgentProvider.Aider,
            AgentProvider.Cline,
            AgentProvider.KiloCode,
            AgentProvider.RooCode,
            AgentProvider.ForgeDev,
            AgentProvider.Augment,
            AgentProvider.PiAgent,
            AgentProvider.Goose,
            AgentProvider.Ollama,
            AgentProvider.Windsurf,
            AgentProvider.Devin,
            AgentProvider.Warp,
            AgentProvider.CursorAgent,
            AgentProvider.Muse,
            AgentProvider.Fx,
        };
        Assert.Equal(expected, SwarmGlyphProviders.Ordered);
    }

    [Fact]
    public void Ordered_DisplayNames_AreTheGlyphWireTokens()
    {
        var tokens = SwarmGlyphProviders.Ordered.Select(AgentProviderMetadata.DisplayName).ToArray();
        Assert.Equal(37, tokens.Length);
        Assert.Equal("Factory", tokens[0]);
        Assert.Equal("OpenBurnBar", tokens[13]);
        Assert.Equal("Cursor Agent", tokens[34]);
        Assert.Equal("fx", tokens[36]);
        Assert.Equal(tokens.Length, tokens.Distinct().Count());
    }
}
