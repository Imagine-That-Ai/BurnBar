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
    case openClaude = "openclaude"
    case omp = "omp"
    case droid
    case forge
    case antigravity
    case grok
    case cursorAgent = "cursorAgent"
    case junie
    case fx
    case muse

    public var displayName: String {
        switch self {
        case .hermes:   return "Hermes"
        case .pi:       return "Pi"
        case .codex:    return "Codex"
        case .claude:   return "Claude"
        case .openClaw: return "OpenClaw"
        case .openClaude: return "OpenClaude"
        case .omp: return "OMP"
        case .droid:    return "Droid"
        case .forge:    return "Forge"
        case .antigravity: return "Antigravity"
        case .grok:     return "Grok Build"
        case .cursorAgent: return "Cursor Agent"
        case .junie:    return "Junie"
        case .fx:       return "fx"
        case .muse:     return "Muse Code"
        }
    }

    /// Defaults used by `AssistantConnectionSheet` when seeding the Direct URL section.
    public var defaultGatewayURL: URL {
        // Grouped by port instead of one arm per runtime: the arms were fourteen
        // copies of the same force-unwrapped literal. Still exhaustive with no
        // `default:`, so a new runtime has to name its port rather than silently
        // inheriting the Hermes gateway.
        switch self {
        case .hermes, .codex, .claude, .openClaude, .omp, .droid, .forge, .antigravity, .grok, .cursorAgent, .junie, .fx, .muse:
            return URL(string: "http://127.0.0.1:8642")!
        case .pi:
            return URL(string: "http://127.0.0.1:8765")!
        case .openClaw:
            return URL(string: "http://127.0.0.1:18789")!
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
        case .openClaude: return "\u{2738}" // ✸ (Claude-fork spark)
        case .omp: return "\u{2318}" // ⌘ Oh My Pi / OMP
        case .droid:    return "\u{25C6}" // ◆
        case .forge:    return "\u{25B0}" // ▰
        case .antigravity: return "\u{2727}" // ✧
        case .grok:     return "\u{03A8}" // Ψ
        case .cursorAgent: return "\u{27A4}" // ➤
        case .junie:    return "\u{273D}" // ✽ (Junie bloom)
        case .fx:       return "\u{0192}" // ƒ (fx)
        case .muse:     return "\u{25C8}" // ◈ (Muse spark)
        }
    }

    /// Runtimes that today have a first-class mobile surface. Hermes and Pi
    /// run through the mobile relay; CLI runtimes use the same native thread
    /// model while execution stays on the trusted Mac.
    public var hasMobileChatSurface: Bool {
        switch self {
        case .hermes, .pi, .codex, .claude, .openClaw, .openClaude, .omp, .droid, .forge, .antigravity, .grok, .cursorAgent, .junie, .fx, .muse: return true
        }
    }

    /// Default set surfaced to a fresh install. All built-in runtimes are
    /// visible so local Mac CLIs are first-class alongside Hermes and Pi.
    public static let defaultEnabledTiles: Set<AssistantRuntimeID> = Set(AssistantRuntimeID.allCases)
}

// MARK: - WandPolicy

/// A routing policy the fan-out dispatcher consults to choose a model per
/// runtime. Maps directly to the Ministry's `selector` field (highest
/// capability or best quality per quota signal).
///
/// When a `WandPolicy` is passed to `dispatchFanOut`, each child mission's
/// `requestedModelID` is resolved via `routedModelID(for:)` instead of the
/// user's static `CLIAgentModelPreferences`. The routing table can be
/// populated by the app-side `WandModelRouter` from live model catalogs, or by
/// the Ministry's `ministry_select_models_for_wand` MCP tool when richer
/// provider quota telemetry is available. This type is the in-memory carrier
/// for those per-runtime results.
public struct WandPolicy: Codable, Hashable, Sendable {
    public let selector: Selector
    public let routedModels: [AssistantRuntimeID: String]

    public enum Selector: String, Codable, Hashable, Sendable, CaseIterable {
        case highestCapability = "headmaster"
        case pareto
    }

    public init(selector: Selector, routedModels: [AssistantRuntimeID: String]) {
        self.selector = selector
        self.routedModels = routedModels
    }

    /// Returns the wand-routed model id for a runtime, or `nil` to fall
    /// through to the user's preferred model (the safe default when no router
    /// produced a proven model for this runtime).
    public func routedModelID(for runtime: AssistantRuntimeID) -> String? {
        routedModels[runtime]
    }
}
