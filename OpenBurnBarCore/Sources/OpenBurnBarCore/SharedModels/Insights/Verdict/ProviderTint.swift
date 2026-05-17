import Foundation

/// The dominant accent identity of a verdict — drives a single accent
/// color on the hero card, the ring stroke, and the provenance chip.
///
/// One accent per provider keeps the surface from becoming a sea of
/// indigo gradients. The renderer maps a tint to concrete colors per
/// platform; the schema only carries the semantic identity so a verdict
/// authored on iOS renders consistently on Android.
public enum ProviderTint: String, Codable, Hashable, Sendable, CaseIterable {
    /// Anthropic / Claude family.
    case ember
    /// OpenAI / GPT family.
    case whimsy
    /// Local-only (Pi, Ollama).
    case silver
    /// Hermes self-hosted relay.
    case mercury
    /// OpenRouter pass-through.
    case prism
    /// BurnBar-hosted fallback.
    case ember2 = "ember_alt"
    /// Neutral — used when the verdict spans multiple providers.
    case neutral

    /// Best-guess tint for a provider key. Returns `.neutral` for unknowns.
    public static func forProviderKey(_ key: String?) -> ProviderTint {
        guard let key = key?.lowercased() else { return .neutral }
        switch key {
        case "anthropic", "claude": return .ember
        case "openai", "gpt": return .whimsy
        case "pi", "ollama", "local": return .silver
        case "hermes": return .mercury
        case "openrouter": return .prism
        case "burnbar", "burnbar-hosted", "hosted": return .ember2
        default: return .neutral
        }
    }
}
