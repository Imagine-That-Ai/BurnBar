// PORTED (hand-authored, parity-tested) from the macOS brand tables:
//   AgentLens/Theme/DesignSystem.swift  — Colors.primary(for:)/accent(for:)/colorForModel
//   AgentLens/Theme/LLMModelBrand.swift  — LLMModelBrand.emblemColor
//
// This is the Windows peer of those tables. It is NOT emitted by the design-token
// pipeline because provider/model brand colors live in DesignSystem.swift, not in
// tokens/pensieve.tokens.json. Parity with the Swift source is enforced by a
// cross-language test — see Theme/ProviderBrand.parity.test.mjs, which regex-
// extracts every `case .x: return Color(hex: "RRGGBB")` arm from the Swift and
// asserts it equals the matching C# arm here (provider-by-provider, plus the
// ordered colorForModel if-chain + the LLMModelBrand emblem table). Run it with
// `node --test windows/app/OpenBurnBar.App/Theme/ProviderBrand.parity.test.mjs`.
//
// Adaptive Swift colors (Color.adaptive / Colors.ember / Colors.blaze) have no
// single hex; the Windows shell is dark-first (Mica dark), so those resolve to
// their DARK value here, annotated inline. The parity test knows this mapping.

using System;
using System.Text;

namespace OpenBurnBar.App.Theme;

/// <summary>Coding-agent providers. Mirrors OpenBurnBarCore.AgentProvider (36 cases).</summary>
public enum AgentProviderBrand
{
    Factory,
    ClaudeCode,
    Copilot,
    Aider,
    Cursor,
    OpenAI,
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
    OpenBurnBar,
}

/// <summary>LLM vendor behind a model id. Mirrors AgentLens LLMModelBrand.</summary>
public enum LLMModelBrand
{
    Anthropic,
    OpenAI,
    Google,
    DeepSeek,
    Kimi,
    MiniMax,
    Meta,
    Mistral,
    Qwen,
    XAI,
    Cohere,
    Perplexity,
    Apple,
    Amazon,
    Alibaba,
    Ollama,
    OpenBurnBar,
    Zai,
    Unknown,
}

/// <summary>
/// Provider / model brand color tables, byte-for-byte with the macOS DesignSystem.
/// Every method returns an uppercase <c>#RRGGBB</c> string (the source of truth).
/// A <c>#if WINDOWS</c> layer converts those to <see cref="Windows.UI.Color"/> for
/// XAML consumers; the hex tables themselves compile on any platform so the parity
/// test and a plain <c>dotnet build</c> can verify them off-Windows.
/// </summary>
public static class ProviderBrand
{
    // MARK: primary(for:) — DesignSystem.Colors.primary
    public static string PrimaryHex(AgentProviderBrand p) => p switch
    {
        AgentProviderBrand.Factory => "#8B5CF6",
        AgentProviderBrand.ClaudeCode => "#CC785C",
        AgentProviderBrand.Copilot => "#23EA3B",
        AgentProviderBrand.Aider => "#FF6B35",
        AgentProviderBrand.Cursor => "#AC8C57",
        AgentProviderBrand.OpenAI => "#00A67E",
        AgentProviderBrand.DeepSeek => "#6366F1",
        AgentProviderBrand.Codex => "#2563EB",
        AgentProviderBrand.OpenCode => "#2563EB",
        AgentProviderBrand.Zai => "#8B5CF6",
        AgentProviderBrand.MiniMax => "#F59E0B",
        AgentProviderBrand.Kimi => "#6366F1",
        AgentProviderBrand.Cline => "#D4A373",
        AgentProviderBrand.KiloCode => "#10B981",
        AgentProviderBrand.RooCode => "#EC4899",
        AgentProviderBrand.ForgeDev => "#F97316",
        AgentProviderBrand.Augment => "#3B82F6",
        AgentProviderBrand.Hermes => "#A855F7",
        AgentProviderBrand.PiAgent => "#7C3AED",
        AgentProviderBrand.GeminiCLI => "#4285F4",
        AgentProviderBrand.Antigravity => "#6C63FF",
        AgentProviderBrand.Goose => "#0D9488",
        AgentProviderBrand.OpenClaw => "#FF6B6B",
        AgentProviderBrand.OpenClaude => "#D97757",
        AgentProviderBrand.Omp => "#EC4899",
        AgentProviderBrand.Ollama => "#6B7280",
        AgentProviderBrand.Windsurf => "#06B6D4",
        AgentProviderBrand.Devin => "#0A84FF",
        AgentProviderBrand.Warp => "#DDE4EA",
        AgentProviderBrand.XAI => "#1A1A1A",
        AgentProviderBrand.Mimo => "#FF6900",
        AgentProviderBrand.CursorAgent => "#00E5FF",
        AgentProviderBrand.Junie => "#48E054",
        AgentProviderBrand.PrimeAgent => "#582CFF",
        AgentProviderBrand.Muse => "#0668E1",
        AgentProviderBrand.Fx => "#A1A1AA",
        AgentProviderBrand.OpenBurnBar => "#FA5053", // Colors.ember (dark)
        _ => "#8B5CF6",
    };

    // MARK: accent(for:) — DesignSystem.Colors.accent
    public static string AccentHex(AgentProviderBrand p) => p switch
    {
        AgentProviderBrand.Factory => "#FA5053", // ember (dark)
        AgentProviderBrand.ClaudeCode => "#D4A574",
        AgentProviderBrand.Copilot => "#0969DA",
        AgentProviderBrand.Aider => "#E86100", // blaze (dark)
        AgentProviderBrand.Cursor => "#007AFF",
        AgentProviderBrand.OpenAI => "#00C48C",
        AgentProviderBrand.DeepSeek => "#818CF8",
        AgentProviderBrand.Codex => "#60A5FA",
        AgentProviderBrand.OpenCode => "#93C5FD",
        AgentProviderBrand.Zai => "#A78BFA",
        AgentProviderBrand.MiniMax => "#FCD34D",
        AgentProviderBrand.Kimi => "#818CF8",
        AgentProviderBrand.Cline => "#E8C4A0",
        AgentProviderBrand.KiloCode => "#34D399",
        AgentProviderBrand.RooCode => "#F472B6",
        AgentProviderBrand.ForgeDev => "#FB923C",
        AgentProviderBrand.Augment => "#60A5FA",
        AgentProviderBrand.Hermes => "#C084FC",
        AgentProviderBrand.PiAgent => "#A78BFA",
        AgentProviderBrand.GeminiCLI => "#8AB4F8",
        AgentProviderBrand.Antigravity => "#8F8AFF",
        AgentProviderBrand.Goose => "#2DD4BF",
        AgentProviderBrand.OpenClaw => "#F472B6",
        AgentProviderBrand.OpenClaude => "#E8855F",
        AgentProviderBrand.Omp => "#F472B6",
        AgentProviderBrand.Ollama => "#9CA3AF",
        AgentProviderBrand.Windsurf => "#22D3EE",
        AgentProviderBrand.Devin => "#1E293B",
        AgentProviderBrand.Warp => "#111111",
        AgentProviderBrand.XAI => "#4A4A4A",
        AgentProviderBrand.Mimo => "#FF8533",
        AgentProviderBrand.CursorAgent => "#33ECFF",
        AgentProviderBrand.Junie => "#6FE87F",
        AgentProviderBrand.PrimeAgent => "#9370FF",
        AgentProviderBrand.Muse => "#3B82F6",
        AgentProviderBrand.Fx => "#D4D4D8", // Color.adaptive (dark)
        AgentProviderBrand.OpenBurnBar => "#FF7578",
        _ => "#FA5053",
    };

    // MARK: colorForModel — DesignSystem.Colors.colorForModel
    // Deterministic model tint. Known families get brand colors; unknown model
    // keys hash (djb2) into the fallback palette. Mirrors the Swift order exactly.
    private static readonly string[] ModelFallbackPalette =
    {
        "#D4A373", "#10B981", "#EC4899",
        "#F97316", "#3B82F6", "#A855F7",
        "#EF4444", "#14B8A6", "#F59E0B",
        "#8B5CF6", "#06B6D4", "#84CC16",
    };

    public static string ColorForModel(string modelName)
    {
        string key = (modelName ?? string.Empty).ToLowerInvariant();

        if (key.Contains("claude") || key.Contains("anthropic")) return "#CC785C";
        if (key.Contains("gpt") || key.Contains("openai") || key.Contains("chatgpt")) return "#00A67E";
        if (key.Contains("gemini") || key.Contains("google")) return "#4285F4";
        if (key.Contains("deepseek")) return "#6366F1";
        if (key.Contains("kimi") || key.Contains("moonshot")) return "#6366F1";
        if (key.Contains("minimax") || key.Contains("abab")) return "#F59E0B";
        if (key.Contains("llama") || key.Contains("meta")) return "#0668E1";
        if (key.Contains("mistral") || key.Contains("mixtral")) return "#FF7000";
        if (key.Contains("qwen") || key.Contains("qwq")) return "#615EFF";
        if (key.Contains("grok") || key.Contains("xai")) return "#1A1A1A";
        if (key.Contains("cohere") || key.Contains("command")) return "#39594D";
        if (key.Contains("perplexity") || key.Contains("sonar")) return "#20808D";
        if (key.Contains("mlx") || key.Contains("apple")) return "#A2AAAD";
        if (key.Contains("nova") || key.Contains("amazon") || key.Contains("bedrock")) return "#FF9900";
        if (key.Contains("alibaba") || key.Contains("tongyi")) return "#FF6A00";
        if (key.Contains("ollama")) return "#8B8589";

        // djb2 (matches the Swift &+ wrapping hash on the UTF-8 bytes of `key`).
        ulong hash = 5381UL;
        foreach (byte b in Encoding.UTF8.GetBytes(key))
        {
            unchecked { hash = ((hash << 5) + hash) + b; }
        }
        return ModelFallbackPalette[(int)(hash % (ulong)ModelFallbackPalette.Length)];
    }

    // MARK: LLMModelBrand.emblemColor
    // Two arms are adaptive in Swift: .xAI => Color.primary (label) and
    // .unknown => DesignSystem.Colors.textSecondary. Dark-shell resolutions below.
    public static string EmblemHex(LLMModelBrand b) => b switch
    {
        LLMModelBrand.Anthropic => "#CC785C",
        LLMModelBrand.OpenAI => "#00A67E",
        LLMModelBrand.Google => "#4285F4",
        LLMModelBrand.DeepSeek => "#6366F1",
        LLMModelBrand.Kimi => "#6366F1",
        LLMModelBrand.MiniMax => "#F59E0B",
        LLMModelBrand.Meta => "#0668E1",
        LLMModelBrand.Mistral => "#FF7000",
        LLMModelBrand.Qwen => "#615EFF",
        LLMModelBrand.XAI => "#FFFFFF", // Color.primary (dark label)
        LLMModelBrand.Cohere => "#39594D",
        LLMModelBrand.Perplexity => "#20808D",
        LLMModelBrand.Apple => "#A2AAAD",
        LLMModelBrand.Amazon => "#FF9900",
        LLMModelBrand.Alibaba => "#FF6A00",
        LLMModelBrand.Ollama => "#8B8589",
        LLMModelBrand.OpenBurnBar => "#FA5053",
        LLMModelBrand.Zai => "#8B5CF6",
        LLMModelBrand.Unknown => "#8B949E", // textSecondary (dark)
        _ => "#8B949E",
    };

    // MARK: LLMModelBrand.infer(fromModelKey:) — vendor inference (parity-tested)
    public static LLMModelBrand InferBrand(string modelKey)
    {
        string key = (modelKey ?? string.Empty).ToLowerInvariant();
        if (key.Contains("openburnbar") || key.Contains("burnbar")) return LLMModelBrand.OpenBurnBar;
        if (key.Contains("claude") || key.Contains("anthropic")) return LLMModelBrand.Anthropic;
        if (key.Contains("gpt") || key.Contains("openai") || key.Contains("chatgpt")
            || key.Contains("davinci") || key.Contains("o1-") || key.Contains("o3-")
            || key.Contains("o4-") || key.StartsWith("o1") || key.StartsWith("o3")
            || key.StartsWith("o4")) return LLMModelBrand.OpenAI;
        if (key.Contains("gemini") || key.Contains("google/") || key.Contains("palm")) return LLMModelBrand.Google;
        if (key.Contains("deepseek")) return LLMModelBrand.DeepSeek;
        if (key.Contains("kimi") || key.Contains("moonshot")) return LLMModelBrand.Kimi;
        if (key.Contains("minimax")) return LLMModelBrand.MiniMax;
        if (key.Contains("llama") || key.Contains("meta-") || key.Contains("meta/")) return LLMModelBrand.Meta;
        if (key.Contains("mistral")) return LLMModelBrand.Mistral;
        if (key.Contains("qwen")) return LLMModelBrand.Qwen;
        if (key.Contains("grok") || key.Contains("xai")) return LLMModelBrand.XAI;
        if (key.Contains("cohere")) return LLMModelBrand.Cohere;
        if (key.Contains("perplexity") || key.Contains("sonar")) return LLMModelBrand.Perplexity;
        if (key.Contains("nova") || key.Contains("amazon")) return LLMModelBrand.Amazon;
        if (key.Contains("dashscope") || key.Contains("alibaba") || key.Contains("qwq")) return LLMModelBrand.Alibaba;
        if (key.Contains("mlx-community") || key.Contains("mlx_community") || key.StartsWith("mlx")) return LLMModelBrand.Apple;
        if (key.Contains("zai") || key.Contains("glm")) return LLMModelBrand.Zai;
        return LLMModelBrand.Unknown;
    }

#if WINDOWS
    /// <summary>Primary brand color for XAML consumers.</summary>
    public static Windows.UI.Color Primary(AgentProviderBrand p) => HexToColor(PrimaryHex(p));

    /// <summary>Accent brand color for XAML consumers.</summary>
    public static Windows.UI.Color Accent(AgentProviderBrand p) => HexToColor(AccentHex(p));

    /// <summary>Deterministic model tint for XAML consumers.</summary>
    public static Windows.UI.Color ColorForModelBrush(string modelName) => HexToColor(ColorForModel(modelName));

    /// <summary>Vendor emblem color for XAML consumers.</summary>
    public static Windows.UI.Color Emblem(LLMModelBrand b) => HexToColor(EmblemHex(b));

    /// <summary>Parse "#RRGGBB" / "#AARRGGBB" into an opaque-by-default Color.</summary>
    private static Windows.UI.Color HexToColor(string hex)
    {
        string s = hex.TrimStart('#');
        byte a = 0xFF, r, g, b;
        if (s.Length == 8)
        {
            a = Convert.ToByte(s.Substring(0, 2), 16);
            r = Convert.ToByte(s.Substring(2, 2), 16);
            g = Convert.ToByte(s.Substring(4, 2), 16);
            b = Convert.ToByte(s.Substring(6, 2), 16);
        }
        else
        {
            r = Convert.ToByte(s.Substring(0, 2), 16);
            g = Convert.ToByte(s.Substring(2, 2), 16);
            b = Convert.ToByte(s.Substring(4, 2), 16);
        }
        return Windows.UI.Color.FromArgb(a, r, g, b);
    }
#endif
}
