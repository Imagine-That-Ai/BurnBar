import Foundation
import SwiftUI

/// User-selected chat engine (replaces the old Index vs Hermes mode split).
enum ChatBackendID: String, Identifiable, Codable {
    case codex
    case claude
    case hermes
    case openclaw
    case piAgent
    case droid
    case forge
    case antigravity

    var id: String { rawValue }

    static var allCases: [ChatBackendID] {
        var backends: [ChatBackendID] = []
        backends.append(.codex)
        backends.append(.claude)
        backends.append(.hermes)
        backends.append(.piAgent)
        backends.append(.openclaw)
        backends.append(.droid)
        backends.append(.forge)
        backends.append(.antigravity)
        return backends
    }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .hermes: return "Hermes"
        case .openclaw: return "OpenClaw"
        case .piAgent: return "Pi Agent"
        case .droid: return "Droid"
        case .forge: return "Forge"
        case .antigravity: return "Antigravity"
        }
    }

    /// Short label for compact toggles.
    var shortLabel: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .hermes: return "Hermes"
        case .openclaw: return "Claw"
        case .piAgent: return "Pi"
        case .droid: return "Droid"
        case .forge: return "Forge"
        case .antigravity: return "AGY"
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
        case .droid:     return "\u{25C6}"
        case .forge:     return "\u{25B0}"
        case .antigravity: return "\u{2727}"
        }
    }

    /// Gradient fill for the active backend pill / hero emblem.
    var gradient: any ShapeStyle {
        switch self {
        case .hermes:
            return DesignSystem.Colors.mercuryGradient
        case .piAgent:
            return DesignSystem.Colors.piGradient
        case .codex, .claude, .openclaw, .droid, .forge, .antigravity:
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
        case .piAgent: return .piAgent
        case .droid: return .factory
        case .forge: return .forgeDev
        case .antigravity: return .antigravity
        }
    }

    /// Whether this backend uses the local Codex/Claude CLIs (privacy-gated).
    var requiresCLIAssistantConsent: Bool {
        switch self {
        case .codex, .claude, .droid, .forge, .antigravity: return true
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
