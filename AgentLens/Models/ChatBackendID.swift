import Foundation
import SwiftUI

/// User-selected chat engine (replaces the old Index vs Hermes mode split).
enum ChatBackendID: String, Identifiable, Codable {
    case codex
    case claude
    case hermes
    case openclaw
    case openClaude = "openclaude"
    case omp = "omp"
    case piAgent
    case droid
    case forge
    case antigravity
    case cursorAgent
    case junie
    case grok
    case kimi

    var id: String { rawValue }

    static var allCases: [ChatBackendID] {
        var backends: [ChatBackendID] = []
        backends.append(.codex)
        backends.append(.claude)
        backends.append(.hermes)
        backends.append(.piAgent)
        backends.append(.openclaw)
        backends.append(.openClaude)
        backends.append(.omp)
        backends.append(.droid)
        backends.append(.forge)
        backends.append(.antigravity)
        backends.append(.cursorAgent)
        backends.append(.junie)
        backends.append(.grok)
        backends.append(.kimi)
        return backends
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .hermes: return "Hermes"
        case .openclaw: return "OpenClaw"
        case .openClaude: return "OpenClaude"
        case .omp: return "OMP"
        case .piAgent: return "Pi Agent"
        case .droid: return "Droid"
        case .forge: return "Forge"
        case .antigravity: return "Antigravity"
        case .cursorAgent: return "Cursor Agent"
        case .junie: return "Junie"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        }
    }

    /// Short label for compact toggles.
    var shortLabel: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .hermes: return "Hermes"
        case .openclaw: return "Claw"
        case .openClaude: return "OClaude"
        case .omp: return "OMP"
        case .piAgent: return "Pi"
        case .droid: return "Droid"
        case .forge: return "Forge"
        case .antigravity: return "AGY"
        case .cursorAgent: return "Cursor"
        case .junie: return "Junie"
        case .grok: return "Grok"
        case .kimi: return "Kimi"
        }
    }

    // MARK: - Visual identity (Plan 2 parity)

    /// Caduceus ☿ for Hermes, π for Pi, sparkle for CLI/Claw.
    var glyph: String {
        switch self {
        case .hermes:    return "\u{263F}"
        case .piAgent:   return "\u{03C0}"
        case .codex:     return "\u{21BB}"
        case .claude:    return "\u{2726}"
        case .openclaw:  return "\u{26A1}"
        case .openClaude: return "\u{2738}"
        case .omp: return "\u{2318}"
        case .droid:     return "\u{25C6}"
        case .forge:     return "\u{25B0}"
        case .antigravity: return "\u{2727}"
        case .cursorAgent: return "\u{27A4}"
        case .junie:     return "\u{273D}"
        case .grok:      return "\u{26A1}"
        case .kimi:      return "\u{263E}"
        }
    }

    /// Gradient fill for the active backend pill / hero emblem.
    var gradient: any ShapeStyle {
        switch self {
        case .hermes:
            return DesignSystem.Colors.mercuryGradient
        case .piAgent:
            return DesignSystem.Colors.piGradient
        case .codex, .claude, .openclaw, .openClaude, .omp, .droid, .forge, .antigravity, .cursorAgent, .junie, .grok, .kimi:
            return DesignSystem.Colors.accentGradient
        }
    }

    /// Foreground color rendered over the gradient fill.
    var activeForeground: Color {
        switch self {
        case .hermes: return Color(hex: "151210")
        default:      return .white
        }
    }

    /// The agent provider whose logo represents this backend in UI.
    var agentProvider: AgentProvider? {
        switch self {
        case .codex: return .codex
        case .claude: return .claudeCode
        case .hermes: return .hermes
        case .openclaw: return .openClaw
        case .openClaude: return .openClaude
        case .omp: return .omp
        case .piAgent: return .piAgent
        case .droid: return .factory
        case .forge: return .forgeDev
        case .antigravity: return .antigravity
        case .cursorAgent: return .cursorAgent
        case .junie: return .junie
        case .grok: return .xAI
        case .kimi: return nil
        }
    }

    /// Whether this backend uses the local Codex/Claude CLIs (privacy-gated).
    var requiresCLIAssistantConsent: Bool {
        switch self {
        case .codex, .claude, .droid, .forge, .antigravity, .cursorAgent, .junie, .grok, .kimi: return true
        case .openClaude, .omp: return true
        case .hermes, .openclaw, .piAgent: return false
        }
    }

    /// Lossless comma-separated order of enabled backends (Settings order preserved).
    static func decodeEnabledList(fromCSV csv: String) -> [ChatBackendID] {
        csv
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { ChatBackendID(rawValue: $0) }
    }

    static func encodeEnabledList(_ backends: [ChatBackendID]) -> String {
        backends.map(\.rawValue).joined(separator: ",")
    }
}
