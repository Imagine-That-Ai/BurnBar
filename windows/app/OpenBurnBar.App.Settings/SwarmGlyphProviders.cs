// PORTED (portable, unit-tested) from:
//   OpenBurnBarCore/Sources/OpenBurnBarProviderModels/AgentProvider.swift
//     AgentProvider.swarmGlyphProviders
//
// Dependency-free (System-only). Providers that participate in the
// cross-platform swarm-logo cycle, in the explicit Swift order (grouped
// desktop formations start with the primary agent runtimes instead of raw
// enum declaration order). This is the default `selectedGlyphs` of the swarm
// background preferences on every platform.

using System.Collections.Generic;

namespace OpenBurnBar.App.Settings;

/// <summary>Swarm-logo provider cycle order, parity with Swift.</summary>
public static class SwarmGlyphProviders
{
    /// <summary>
    /// Swift <c>AgentProvider.swarmGlyphProviders</c> in order. The default
    /// <c>selectedGlyphs</c> of <c>SwarmBackgroundPreferences</c> on iOS,
    /// Android, and Windows.
    /// </summary>
    public static readonly IReadOnlyList<AgentProvider> Ordered =
        new[]
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
}
