import Foundation

// MARK: - Assistant Runtime ID
//
// Stable identity for the two messenger-AI runtimes OpenBurnBar exposes in the
// Assistants surface. Used by:
//   • Mobile RuntimePill (`OpenBurnBarMobile/Views/Hermes/HermesTabView.swift`)
//   • Shared `AssistantSettingsRuntime` protocol (this file's neighbour)
//   • `AssistantConnectionSheet` host selection
//   • Cloud Functions relay discriminator (`runtime: 'hermes' | 'pi'`)
//
// This intentionally lives next to `HermesConnectionTypes.swift` and
// `PiConnectionTypes.swift` so every consumer can import a single module.

public enum AssistantRuntimeID: String, Codable, CaseIterable, Hashable, Sendable {
    case hermes
    case pi

    public var displayName: String {
        switch self {
        case .hermes: return "Hermes"
        case .pi:     return "Pi"
        }
    }

    /// Defaults used by `AssistantConnectionSheet` when seeding the Direct URL section.
    public var defaultGatewayURL: URL {
        switch self {
        case .hermes: return URL(string: "http://127.0.0.1:8642")!
        case .pi:     return URL(string: "http://127.0.0.1:8765")!
        }
    }

    /// Caduceus or hex glyph rendered in the runtime pill.
    public var glyph: String {
        switch self {
        case .hermes: return "\u{263F}" // ☿ Mercury / caduceus shorthand
        case .pi:     return "\u{03C0}" // π
        }
    }
}
