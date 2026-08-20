// PORTED (portable, unit-tested) display-name table for AgentProviderBrand.
// Source of truth: OpenBurnBarCore AgentProvider raw values (displayName == rawValue).
// Dependency-free (System-only, NO WinUI) so the onboarding views (pills, connect,
// scan) share one table and it is covered by a real `dotnet test`.

using System;
using OpenBurnBar.App.Theme;

namespace OpenBurnBar.App.Onboarding;

/// <summary>Human-readable provider names, mirroring <c>AgentProvider.displayName</c>
/// (which is the enum's raw string value on macOS).</summary>
public static class ProviderDisplay
{
    /// <summary>The display name for a provider. Byte-for-byte with the macOS raw values.</summary>
    public static string DisplayName(AgentProviderBrand provider) => provider switch
    {
        AgentProviderBrand.Factory => "Factory",
        AgentProviderBrand.ClaudeCode => "Claude Code",
        AgentProviderBrand.Copilot => "Copilot",
        AgentProviderBrand.Aider => "Aider",
        AgentProviderBrand.Cursor => "Cursor",
        AgentProviderBrand.OpenAI => "OpenAI",
        AgentProviderBrand.DeepSeek => "DeepSeek",
        AgentProviderBrand.Codex => "Codex",
        AgentProviderBrand.OpenCode => "OpenCode",
        AgentProviderBrand.Zai => "Zai",
        AgentProviderBrand.MiniMax => "MiniMax",
        AgentProviderBrand.Kimi => "Kimi",
        AgentProviderBrand.Cline => "Cline",
        AgentProviderBrand.KiloCode => "Kilo Code",
        AgentProviderBrand.RooCode => "Roo Code",
        AgentProviderBrand.ForgeDev => "Forge",
        AgentProviderBrand.Augment => "Augment",
        AgentProviderBrand.Hermes => "Hermes",
        AgentProviderBrand.PiAgent => "Pi Agent",
        AgentProviderBrand.GeminiCLI => "Gemini CLI",
        AgentProviderBrand.Antigravity => "Antigravity",
        AgentProviderBrand.Goose => "Goose",
        AgentProviderBrand.OpenClaw => "OpenClaw",
        AgentProviderBrand.OpenClaude => "OpenClaude",
        AgentProviderBrand.Omp => "OMP",
        AgentProviderBrand.Ollama => "Ollama",
        AgentProviderBrand.Windsurf => "Windsurf",
        AgentProviderBrand.Devin => "Devin",
        AgentProviderBrand.Warp => "Warp",
        AgentProviderBrand.XAI => "xAI",
        AgentProviderBrand.Mimo => "MiMo",
        AgentProviderBrand.CursorAgent => "Cursor Agent",
        AgentProviderBrand.OpenBurnBar => "OpenBurnBar",
        AgentProviderBrand.Junie => "Junie",
        AgentProviderBrand.PrimeAgent => "Prime Agent",
        AgentProviderBrand.Muse => "Muse",
        AgentProviderBrand.Fx => "fx",
        _ => throw new ArgumentOutOfRangeException(nameof(provider), provider, null),
    };
}
