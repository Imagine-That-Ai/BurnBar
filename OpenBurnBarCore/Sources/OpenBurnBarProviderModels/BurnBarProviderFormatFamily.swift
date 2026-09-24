import Foundation

/// Provider format family (3.2: extracted from the catalog; the runtime failover types are its sole consumer).

/// Wire-format family a provider speaks at the OpenBurnBar local gateway.
///
/// The router uses this to keep native upstream selection honest. Gateway
/// endpoints may expose explicit compatibility bridges, such as serving a
/// Claude model through the local OpenAI-style endpoints, but those bridges
/// are declared at the HTTP layer and still route to a provider in its native
/// format family.
public enum BurnBarProviderFormatFamily: String, Codable, Hashable, Sendable {
    /// OpenAI-shape Chat Completions API. Covers OpenAI, Z.ai, MiniMax, Kimi,
    /// Ollama Cloud, Ollama Local, xAI, DeepSeek, Mistral, Meta, Cohere,
    /// Alibaba, MLX, and other OpenAI-compatible upstreams.
    case openaiCompat = "openai_compat"
    /// Anthropic Messages API. Covers Anthropic Console API keys and
    /// Anthropic Pro/Team OAuth bearers — anything that speaks `/v1/messages`.
    case anthropic
}
