import Foundation

// MARK: - Assistant Runtime ID
//
// Stable identity for the chat runtimes OpenBurnBar exposes in the Assistants
// surface. Used by:
//   • Mobile RuntimePill (`OpenBurnBarMobile/Views/Hermes/AssistantsTabRoot.swift`)
//   • Android pill (`android/.../ui/hermes/AssistantsScreen.kt`)
//   • macOS ChatBackendID bridge (`AgentLens/Models/ChatBackendID.swift`)
//   • Cloud Functions relay discriminator
//
// rawValues `"hermes"` and `"pi"` MUST remain stable — they're persisted in
// UserDefaults (`assistants.activeRuntime`) and Android DataStore.

public enum AssistantRuntimeID: String, Codable, CaseIterable, Hashable, Sendable {
    case hermes
    case pi
    case codex
    case claude
    case openClaw = "openclaw"

    public var displayName: String {
        switch self {
        case .hermes:   return "Hermes"
        case .pi:       return "Pi"
        case .codex:    return "Codex"
        case .claude:   return "Claude"
        case .openClaw: return "OpenClaw"
        }
    }

    /// Defaults used by `AssistantConnectionSheet` when seeding the Direct URL section.
    public var defaultGatewayURL: URL {
        switch self {
        case .hermes:   return URL(string: "http://127.0.0.1:8642")!
        case .pi:       return URL(string: "http://127.0.0.1:8765")!
        case .codex:    return URL(string: "http://127.0.0.1:8642")!
        case .claude:   return URL(string: "http://127.0.0.1:8642")!
        case .openClaw: return URL(string: "http://127.0.0.1:18789")!
        }
    }

    /// Caduceus or hex glyph rendered in the runtime pill.
    public var glyph: String {
        switch self {
        case .hermes:   return "\u{263F}" // ☿ Mercury / caduceus shorthand
        case .pi:       return "\u{03C0}" // π
        case .codex:    return "\u{21BB}" // ⟳
        case .claude:   return "\u{2726}" // ✦
        case .openClaw: return "\u{26A1}" // ⚡
        }
    }

    /// Runtimes that today have a first-class mobile surface. Hermes and Pi
    /// can start native mobile threads; Codex, Claude Code, and OpenClaw open
    /// their Mac-backed mirrored session lists.
    public var hasMobileChatSurface: Bool {
        switch self {
        case .hermes, .pi, .codex, .claude, .openClaw: return true
        }
    }

    /// Default set surfaced to a fresh install. All five runtimes are visible
    /// so Codex and Claude Code are first-class alongside Hermes, Pi, and
    /// OpenClaw.
    public static let defaultEnabledTiles: Set<AssistantRuntimeID> = Set(AssistantRuntimeID.allCases)
}
