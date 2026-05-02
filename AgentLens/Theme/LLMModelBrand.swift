import SwiftUI

/// LLM vendor behind a model id (distinct from `AgentProvider`, which is the coding agent).
enum LLMModelBrand: Hashable {
    case anthropic
    case openAI
    case google
    case deepSeek
    case kimi
    case miniMax
    case meta
    case mistral
    case qwen
    case xAI
    case cohere
    case perplexity
    case apple      // Apple MLX models (mlx-community/)
    case amazon
    case alibaba
    case ollama     // Ollama local models
    case unknown

    /// Bundled asset catalog image name for every brand.
    var bundledLogoName: String {
        switch self {
        case .anthropic:  return "AnthropicLogo"
        case .openAI:     return "OpenAILogo"
        case .google:     return "GeminiCLILogo"
        case .deepSeek:   return "DeepSeekLogo"
        case .kimi:       return "KimiLogo"
        case .miniMax:    return "MiniMaxLogo"
        case .meta:       return "MetaLogo"
        case .mistral:    return "MistralLogo"
        case .qwen:       return "QwenLogo"
        case .xAI:        return "GrokLogo"
        case .cohere:     return "CohereLogo"
        case .perplexity: return "PerplexityLogo"
        case .apple:      return "AppleLogo"
        case .amazon:     return "AmazonLogo"
        case .alibaba:    return "AlibabaLogo"
        case .ollama:     return "OllamaLogo"
        case .unknown:    return ""
        }
    }

    /// Whether this brand has a real bundled logo asset.
    var hasBundledLogo: Bool {
        self != .unknown && NSImage(named: bundledLogoName) != nil
    }

    /// Matches dashboard tints in `DesignSystem.Colors.colorForModel`.
    var emblemColor: Color {
        switch self {
        case .anthropic: return Color(hex: "CC785C")
        case .openAI: return Color(hex: "00A67E")
        case .google: return Color(hex: "4285F4")
        case .deepSeek, .kimi: return Color(hex: "6366F1")
        case .miniMax: return Color(hex: "F59E0B")
        case .meta: return Color(hex: "0668E1")
        case .mistral: return Color(hex: "FF7000")
        case .qwen: return Color(hex: "615EFF")
        case .xAI: return Color.primary
        case .cohere: return Color(hex: "39594D")
        case .perplexity: return Color(hex: "20808D")
        case .apple: return Color(hex: "A2AAAD")   // Apple Silver
        case .amazon: return Color(hex: "FF9900")
        case .alibaba: return Color(hex: "FF6A00")
        case .ollama: return Color(hex: "8B8589")
        case .unknown: return DesignSystem.Colors.textSecondary
        }
    }

    var sfSymbolFallback: String { "cube.transparent" }

    static func infer(fromModelKey key: String) -> LLMModelBrand {
        let key = key.lowercased()
        if key.contains("claude") || key.contains("anthropic") { return .anthropic }
        if key.contains("gpt")
            || key.contains("openai")
            || key.contains("chatgpt")
            || key.contains("davinci")
            || key.contains("o1-")
            || key.contains("o3-")
            || key.contains("o4-")
            || key.hasPrefix("o1")
            || key.hasPrefix("o3")
            || key.hasPrefix("o4") { return .openAI }
        if key.contains("gemini") || key.contains("google/") || key.contains("palm") { return .google }
        if key.contains("deepseek") { return .deepSeek }
        if key.contains("kimi") || key.contains("moonshot") { return .kimi }
        if key.contains("minimax") { return .miniMax }
        if key.contains("llama") || key.contains("meta-") || key.contains("meta/") { return .meta }
        if key.contains("mistral") { return .mistral }
        if key.contains("qwen") { return .qwen }
        if key.contains("grok") || key.contains("xai") { return .xAI }
        if key.contains("cohere") { return .cohere }
        if key.contains("perplexity") || key.contains("sonar") { return .perplexity }
        if key.contains("nova") || key.contains("amazon") { return .amazon }
        if key.contains("dashscope") || key.contains("alibaba") || key.contains("qwq") { return .alibaba }
        if key.contains("mlx-community") || key.contains("mlx_community") || key.hasPrefix("mlx") { return .apple }
        return .unknown
    }
}
