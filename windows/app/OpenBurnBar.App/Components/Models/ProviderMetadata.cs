// PORTED (hand-authored, parity-with-Swift) from the macOS provider metadata tables:
//   OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AgentProvider.swift
//     — .displayName (rawValue), .bundledLogoName, .iconName (SF Symbol fallback)
//   OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/AgentProvider+LogoBackdrop.swift
//     — .needsMonochromeLogoBackdrop(colorScheme:)
//
// This is the pure, platform-agnostic vocabulary the shared provider-logo control
// (Components/ProviderLogoView) reads. It targets `System` only (no WinUI), so it
// compiles + runs on the macOS authoring host and is asserted by
// windows/tests/components/ProviderMetadataTests.cs against the Swift golden tables.
//
// ── Accepted drift (documented, gated at G3 against macOS goldens) ─────────────
//   • FallbackGlyph maps each provider's macOS SF-Symbol fallback to a Segoe glyph
//     from a small, category-based palette. SF Symbols do not exist on Windows, so
//     the fallback is APPROXIMATE by construction — the parity-true path is the
//     bundled logo asset (BundledLogoName), which ProviderLogoView prefers.
//   • BundledLogoName returns the SAME base name the macOS asset catalog uses; the
//     Windows asset pipeline (a separate lane) drops `Assets/ProviderLogos/<name>.png`
//     so the control resolves `ms-appx:///Assets/ProviderLogos/<name>.png`.

using System;

namespace OpenBurnBar.App.Components;

/// <summary>
/// Provider identity metadata (display name, bundled-logo asset base name, monochrome
/// backdrop decision, and a Segoe fallback glyph) for the shared provider-logo control.
/// Mirrors <c>OpenBurnBarCore.AgentProvider</c>; keyed by <see cref="Theme.AgentProviderBrand"/>
/// so it shares the single 36-case enum with <see cref="Theme.ProviderBrand"/>.
/// </summary>
public static class ProviderMetadata
{
    /// <summary>Human-facing name. Swift: <c>AgentProvider.displayName</c> (the rawValue).</summary>
    public static string DisplayName(Theme.AgentProviderBrand p) => p switch
    {
        Theme.AgentProviderBrand.Factory => "Factory",
        Theme.AgentProviderBrand.ClaudeCode => "Claude Code",
        Theme.AgentProviderBrand.Copilot => "Copilot",
        Theme.AgentProviderBrand.Aider => "Aider",
        Theme.AgentProviderBrand.Cursor => "Cursor",
        Theme.AgentProviderBrand.OpenAI => "OpenAI",
        Theme.AgentProviderBrand.OpenBurnBar => "OpenBurnBar",
        Theme.AgentProviderBrand.DeepSeek => "DeepSeek",
        Theme.AgentProviderBrand.Codex => "Codex",
        Theme.AgentProviderBrand.OpenCode => "OpenCode",
        Theme.AgentProviderBrand.Zai => "Zai",
        Theme.AgentProviderBrand.MiniMax => "MiniMax",
        Theme.AgentProviderBrand.Kimi => "Kimi",
        Theme.AgentProviderBrand.Cline => "Cline",
        Theme.AgentProviderBrand.KiloCode => "Kilo Code",
        Theme.AgentProviderBrand.RooCode => "Roo Code",
        Theme.AgentProviderBrand.ForgeDev => "Forge",
        Theme.AgentProviderBrand.Augment => "Augment",
        Theme.AgentProviderBrand.Hermes => "Hermes",
        Theme.AgentProviderBrand.PiAgent => "Pi Agent",
        Theme.AgentProviderBrand.GeminiCLI => "Gemini CLI",
        Theme.AgentProviderBrand.Antigravity => "Antigravity",
        Theme.AgentProviderBrand.Goose => "Goose",
        Theme.AgentProviderBrand.OpenClaw => "OpenClaw",
        Theme.AgentProviderBrand.OpenClaude => "OpenClaude",
        Theme.AgentProviderBrand.Omp => "OMP",
        Theme.AgentProviderBrand.Ollama => "Ollama",
        Theme.AgentProviderBrand.Windsurf => "Windsurf",
        Theme.AgentProviderBrand.Devin => "Devin",
        Theme.AgentProviderBrand.Warp => "Warp",
        Theme.AgentProviderBrand.XAI => "xAI",
        Theme.AgentProviderBrand.Mimo => "MiMo",
        Theme.AgentProviderBrand.CursorAgent => "Cursor Agent",
        _ => "OpenBurnBar",
    };

    /// <summary>Asset catalog base name (no extension). Swift: <c>AgentProvider.bundledLogoName</c>.
    /// The Windows control resolves <c>ms-appx:///Assets/ProviderLogos/{name}.png</c>.</summary>
    public static string BundledLogoName(Theme.AgentProviderBrand p) => p switch
    {
        Theme.AgentProviderBrand.Factory => "FactoryLogo",
        Theme.AgentProviderBrand.ClaudeCode => "ClaudeCodeLogo",
        Theme.AgentProviderBrand.Copilot => "CopilotLogo",
        Theme.AgentProviderBrand.Aider => "AiderLogo",
        Theme.AgentProviderBrand.Cursor => "CursorLogo",
        Theme.AgentProviderBrand.OpenAI => "OpenAILogo",
        Theme.AgentProviderBrand.OpenBurnBar => "AppLogo",
        Theme.AgentProviderBrand.DeepSeek => "DeepSeekLogo",
        Theme.AgentProviderBrand.Codex => "CodexLogo",
        Theme.AgentProviderBrand.Zai => "ZaiLogo",
        Theme.AgentProviderBrand.MiniMax => "MiniMaxLogo",
        Theme.AgentProviderBrand.Kimi => "KimiLogo",
        Theme.AgentProviderBrand.Cline => "ClineLogo",
        Theme.AgentProviderBrand.KiloCode => "KiloCodeLogo",
        Theme.AgentProviderBrand.RooCode => "RooCodeLogo",
        Theme.AgentProviderBrand.ForgeDev => "ForgeLogo",
        Theme.AgentProviderBrand.Augment => "AugmentLogo",
        Theme.AgentProviderBrand.Hermes => "HermesLogo",
        Theme.AgentProviderBrand.PiAgent => "PiAgentLogo",
        Theme.AgentProviderBrand.GeminiCLI => "GeminiCLILogo",
        Theme.AgentProviderBrand.Antigravity => "AntigravityLogo",
        Theme.AgentProviderBrand.Goose => "GooseLogo",
        Theme.AgentProviderBrand.OpenClaw => "OpenClawLogo",
        Theme.AgentProviderBrand.OpenClaude => "OpenClaudeLogo",
        Theme.AgentProviderBrand.Omp => "OMPLogo",
        Theme.AgentProviderBrand.Ollama => "OllamaLogo",
        Theme.AgentProviderBrand.Windsurf => "WindsurfLogo",
        Theme.AgentProviderBrand.Devin => "DevinLogo",
        Theme.AgentProviderBrand.Warp => "WarpLogo",
        Theme.AgentProviderBrand.OpenCode => "OpenCodeLogo",
        Theme.AgentProviderBrand.XAI => "GrokLogo",
        Theme.AgentProviderBrand.Mimo => "MimoLogo",
        Theme.AgentProviderBrand.CursorAgent => "CursorLogo",
        _ => "AppLogo",
    };

    /// <summary>
    /// Whether the provider's logo ships as a solid dark glyph that needs a light disc
    /// behind it for legibility. Byte-for-byte port of Swift
    /// <c>AgentProvider.needsMonochromeLogoBackdrop(colorScheme:)</c>.
    /// The Windows shell is dark-first, so <paramref name="isDark"/> defaults true.
    /// </summary>
    public static bool NeedsMonochromeLogoBackdrop(Theme.AgentProviderBrand p, bool isDark = true)
    {
        if (isDark)
        {
            return p switch
            {
                Theme.AgentProviderBrand.OpenAI or Theme.AgentProviderBrand.Codex
                    or Theme.AgentProviderBrand.Cursor or Theme.AgentProviderBrand.CursorAgent
                    or Theme.AgentProviderBrand.ForgeDev or Theme.AgentProviderBrand.ClaudeCode
                    or Theme.AgentProviderBrand.Factory or Theme.AgentProviderBrand.Windsurf
                    or Theme.AgentProviderBrand.Copilot or Theme.AgentProviderBrand.Aider
                    or Theme.AgentProviderBrand.Ollama or Theme.AgentProviderBrand.OpenClaw
                    or Theme.AgentProviderBrand.OpenClaude or Theme.AgentProviderBrand.Omp
                    or Theme.AgentProviderBrand.GeminiCLI or Theme.AgentProviderBrand.Antigravity
                    or Theme.AgentProviderBrand.Goose or Theme.AgentProviderBrand.Augment
                    or Theme.AgentProviderBrand.Cline or Theme.AgentProviderBrand.KiloCode
                    or Theme.AgentProviderBrand.RooCode or Theme.AgentProviderBrand.Hermes
                    or Theme.AgentProviderBrand.XAI => true,
                _ => false,
            };
        }

        return p switch
        {
            Theme.AgentProviderBrand.Kimi or Theme.AgentProviderBrand.Goose
                or Theme.AgentProviderBrand.Augment => true,
            _ => false,
        };
    }

    /// <summary>
    /// Corner-radius factor for the squircle logo clip. Swift uses <c>size * 0.2237</c>
    /// (the continuous-corner "superellipse" ratio) in both ProviderLogoView variants.
    /// </summary>
    public const double LogoCornerRadiusFactor = 0.2237;

    // Confident Segoe MDL2 Assets / Segoe Fluent Icons codepoints used by FallbackGlyph.
    // A deliberately small, category-based palette — the exact per-provider SF Symbol has
    // no Windows equivalent, so we group by semantic family rather than fabricate 32
    // precise codepoints (see file header: fallback is APPROXIMATE; assets are parity-true).
    private const string GlyphCommandPrompt = "\uE756"; // terminal / CLI family
    private const string GlyphMessage = "\uE8BD";       // chat / assistant family
    private const string GlyphRobot = "\uE99A";         // model / brain / AI family (Segoe Fluent)
    private const string GlyphFavoriteStar = "\uE734";  // spark / star family
    private const string GlyphCloud = "\uE753";         // cloud / server family
    private const string GlyphCode = "\uE943";          // code / dev family
    private const string GlyphLightningBolt = "\uE945"; // energy / bolt family

    /// <summary>
    /// Segoe fallback glyph — the Windows stand-in for the macOS SF-Symbol fallback
    /// (<c>AgentProvider.iconName</c>). APPROXIMATE by construction (see file header);
    /// shown only when the bundled logo asset is absent.
    /// </summary>
    public static string FallbackGlyph(Theme.AgentProviderBrand p) => p switch
    {
        Theme.AgentProviderBrand.Factory => GlyphCode,
        Theme.AgentProviderBrand.ClaudeCode => GlyphMessage,
        Theme.AgentProviderBrand.Copilot => GlyphFavoriteStar,
        Theme.AgentProviderBrand.Aider => GlyphCommandPrompt,
        Theme.AgentProviderBrand.Cursor => GlyphCode,
        Theme.AgentProviderBrand.OpenAI => GlyphFavoriteStar,
        Theme.AgentProviderBrand.OpenBurnBar => GlyphFavoriteStar,
        Theme.AgentProviderBrand.DeepSeek => GlyphRobot,
        Theme.AgentProviderBrand.Codex => GlyphCommandPrompt,
        Theme.AgentProviderBrand.Zai => GlyphLightningBolt,
        Theme.AgentProviderBrand.MiniMax => GlyphFavoriteStar,
        Theme.AgentProviderBrand.Kimi => GlyphRobot,
        Theme.AgentProviderBrand.Cline => GlyphRobot,
        Theme.AgentProviderBrand.KiloCode => GlyphCode,
        Theme.AgentProviderBrand.RooCode => GlyphFavoriteStar,
        Theme.AgentProviderBrand.ForgeDev => GlyphLightningBolt,
        Theme.AgentProviderBrand.Augment => GlyphRobot,
        Theme.AgentProviderBrand.Hermes => GlyphFavoriteStar,
        Theme.AgentProviderBrand.PiAgent => GlyphRobot,
        Theme.AgentProviderBrand.GeminiCLI => GlyphCommandPrompt,
        Theme.AgentProviderBrand.Antigravity => GlyphFavoriteStar,
        Theme.AgentProviderBrand.Goose => GlyphRobot,
        Theme.AgentProviderBrand.OpenClaw => GlyphMessage,
        Theme.AgentProviderBrand.OpenClaude => GlyphMessage,
        Theme.AgentProviderBrand.Omp => GlyphCommandPrompt,
        Theme.AgentProviderBrand.Ollama => GlyphCloud,
        Theme.AgentProviderBrand.Windsurf => GlyphCode,
        Theme.AgentProviderBrand.Devin => GlyphCode,
        Theme.AgentProviderBrand.Warp => GlyphCommandPrompt,
        Theme.AgentProviderBrand.OpenCode => GlyphCode,
        Theme.AgentProviderBrand.XAI => GlyphLightningBolt,
        Theme.AgentProviderBrand.Mimo => GlyphFavoriteStar,
        Theme.AgentProviderBrand.CursorAgent => GlyphCode,
        _ => GlyphFavoriteStar,
    };
}
