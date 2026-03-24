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
    case unknown

    private static let lobeBase =
        "https://raw.githubusercontent.com/lobehub/lobe-icons/refs/heads/master/packages/static-png/light"

    /// Remote brand mark (nil for `unknown`).
    var logoURL: URL? {
        let name: String
        switch self {
        case .anthropic: name = "anthropic.png"
        case .openAI: name = "openai.png"
        case .google: name = "gemini-color.png"
        case .deepSeek: name = "deepseek-color.png"
        case .kimi: name = "kimi-color.png"
        case .miniMax: name = "minimax-color.png"
        case .meta: name = "meta-color.png"
        case .mistral: name = "mistral-color.png"
        case .qwen: name = "qwen-color.png"
        case .xAI: name = "grok.png"
        case .cohere: name = "cohere-color.png"
        case .perplexity: name = "perplexity-color.png"
        case .apple: name = "apple.png"
        case .unknown: return nil
        }
        return URL(string: "\(Self.lobeBase)/\(name)")
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
        if key.contains("mlx-community") || key.contains("mlx_community") || key.hasPrefix("mlx") { return .apple }
        return .unknown
    }
}
