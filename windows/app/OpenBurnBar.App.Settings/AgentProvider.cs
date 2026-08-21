// PORTED (identity subset) from OpenBurnBarCore/.../SharedModels/AgentProvider.swift.
//
// The macOS Settings manifest builds one search row per AgentProvider case, using
// three members of the Swift enum: displayName, persistedToken, and
// providerID.rawValue. This is the Windows peer of exactly that subset — declared
// in the SAME order as the Swift `case` list so `AllCases` matches
// `AgentProvider.allCases`, and carrying the SAME display strings so the generated
// provider rows are byte-identical after sorting.
//
// Brand *colors* for these providers live separately in
// Theme/ProviderBrand.cs (AgentProviderBrand) — that is a different concern
// (parity-tested against DesignSystem.swift) and is intentionally NOT reused here:
// the search index needs identity + labels, not palette. Parity of THIS table with
// the Swift source is enforced by AgentProviderMetadataTests.

namespace OpenBurnBar.App.Settings;

/// <summary>
/// Coding-agent provider identity. Mirrors <c>OpenBurnBarCore.AgentProvider</c>
/// (36 cases, declaration order preserved so <see cref="AgentProviderMetadata.AllCases"/>
/// equals the Swift <c>allCases</c>).
/// </summary>
public enum AgentProvider
{
    Factory,
    ClaudeCode,
    Copilot,
    Aider,
    Cursor,
    OpenAI,
    OpenBurnBar,
    DeepSeek,
    Codex,
    OpenCode,
    Zai,
    MiniMax,
    Kimi,
    Cline,
    KiloCode,
    RooCode,
    ForgeDev,
    Augment,
    Hermes,
    PiAgent,
    GeminiCLI,
    Antigravity,
    Goose,
    OpenClaw,
    OpenClaude,
    Omp,
    Ollama,
    Windsurf,
    Devin,
    Warp,
    XAI,
    Mimo,
    CursorAgent,
    Junie,
    PrimeAgent,
    Muse,
    Fx,
}

/// <summary>
/// The three <see cref="AgentProvider"/> members the Settings manifest consumes:
/// the display name (Swift <c>rawValue</c>/<c>displayName</c>), the persisted token
/// (Swift <c>persistedToken</c>), and the catalog provider id raw value
/// (Swift <c>providerID.rawValue</c>).
/// </summary>
public static class AgentProviderMetadata
{
    /// <summary>Every provider in Swift <c>allCases</c> declaration order.</summary>
    public static readonly IReadOnlyList<AgentProvider> AllCases =
        (AgentProvider[])Enum.GetValues(typeof(AgentProvider));

    /// <summary>Swift <c>rawValue</c> (== <c>displayName</c>).</summary>
    public static string DisplayName(AgentProvider p) => p switch
    {
        AgentProvider.Factory => "Factory",
        AgentProvider.ClaudeCode => "Claude Code",
        AgentProvider.Copilot => "Copilot",
        AgentProvider.Aider => "Aider",
        AgentProvider.Cursor => "Cursor",
        AgentProvider.OpenAI => "OpenAI",
        AgentProvider.OpenBurnBar => "OpenBurnBar",
        AgentProvider.DeepSeek => "DeepSeek",
        AgentProvider.Codex => "Codex",
        AgentProvider.OpenCode => "OpenCode",
        AgentProvider.Zai => "Zai",
        AgentProvider.MiniMax => "MiniMax",
        AgentProvider.Kimi => "Kimi",
        AgentProvider.Cline => "Cline",
        AgentProvider.KiloCode => "Kilo Code",
        AgentProvider.RooCode => "Roo Code",
        AgentProvider.ForgeDev => "Forge",
        AgentProvider.Augment => "Augment",
        AgentProvider.Hermes => "Hermes",
        AgentProvider.PiAgent => "Pi Agent",
        AgentProvider.GeminiCLI => "Gemini CLI",
        AgentProvider.Antigravity => "Antigravity",
        AgentProvider.Goose => "Goose",
        AgentProvider.OpenClaw => "OpenClaw",
        AgentProvider.OpenClaude => "OpenClaude",
        AgentProvider.Omp => "OMP",
        AgentProvider.Ollama => "Ollama",
        AgentProvider.Windsurf => "Windsurf",
        AgentProvider.Devin => "Devin",
        AgentProvider.Warp => "Warp",
        AgentProvider.XAI => "xAI",
        AgentProvider.Mimo => "MiMo",
        AgentProvider.CursorAgent => "Cursor Agent",
        AgentProvider.Junie => "Junie",
        AgentProvider.PrimeAgent => "Prime Agent",
        AgentProvider.Muse => "Muse",
        AgentProvider.Fx => "fx",
        _ => throw new ArgumentOutOfRangeException(nameof(p), p, null),
    };

    /// <summary>
    /// Swift <c>persistedToken</c>: <c>rawValue.lowercased().replacingOccurrences(of: " ", with: "")</c>.
    /// </summary>
    public static string PersistedToken(AgentProvider p) =>
        DisplayName(p).ToLowerInvariant().Replace(" ", string.Empty);

    /// <summary>
    /// Swift <c>providerID.rawValue</c>. Most providers use their persisted token;
    /// the explicit arms below mirror the Swift <c>providerID</c> switch exactly.
    /// </summary>
    public static string ProviderIdRawValue(AgentProvider p) => p switch
    {
        AgentProvider.OpenAI => "openai",
        AgentProvider.OpenBurnBar => "openburnbar",
        AgentProvider.DeepSeek => "deepseek",
        AgentProvider.ClaudeCode => "claude-code",
        AgentProvider.Codex => "codex",
        AgentProvider.OpenCode => "opencode",
        AgentProvider.Kimi => "kimi",
        AgentProvider.XAI => "xai",
        AgentProvider.CursorAgent => "cursor-agent",
        AgentProvider.PrimeAgent => "prime-agent",
        _ => PersistedToken(p),
    };
}
