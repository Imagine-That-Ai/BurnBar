import Foundation

struct ChatCompletionsRequest: Decodable {
    let model: String
    let stream: Bool?
    /// OpenRouter-compatible plugin configs. Optional → backward-compatible:
    /// existing clients that omit it decode unchanged. The Elder Wand
    /// model-fusion router rides on `{ "id": "fusion", ... }`.
    let plugins: [FusionPluginConfig]?

    /// The active OpenRouter "fusion" plugin, if one is present and not
    /// explicitly disabled (`enabled: false` bypasses for a single request).
    var activeFusionPlugin: FusionPluginConfig? {
        plugins?.first { $0.id == "fusion" && ($0.enabled ?? true) }
    }
}

/// OpenRouter "Fusion" plugin config carried on `/v1/chat/completions`.
/// Mirrors https://openrouter.ai/docs/guides/features/plugins/fusion :
/// `analysis_models` (1–8) answer in parallel, `model` is the judge that
/// compares them into a structured verdict, the originating model writes the
/// final answer, and `max_tool_calls` (1–16, default 8) caps each model's
/// tool-loop steps.
struct FusionPluginConfig: Decodable {
    let id: String
    let enabled: Bool?
    let analysisModels: [String]?
    let model: String?
    let maxToolCalls: Int?

    enum CodingKeys: String, CodingKey {
        case id, enabled, model
        case analysisModels = "analysis_models"
        case maxToolCalls = "max_tool_calls"
    }
}

struct ResponsesRequest: Decodable {
    let model: String
    let stream: Bool?
}

struct AnthropicMessagesRequest: Decodable {
    let model: String
    let stream: Bool?
}

struct EmbeddingsRequest: Decodable {
    let model: String
}
