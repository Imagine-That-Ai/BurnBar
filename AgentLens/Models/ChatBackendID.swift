import Foundation

/// User-selected chat engine (replaces the old Index vs Hermes mode split).
enum ChatBackendID: String, CaseIterable, Identifiable, Codable {
    case codex
    case claude
    case hermes
    case openclaw

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .hermes: return "Hermes"
        case .openclaw: return "OpenClaw"
        }
    }

    /// Short label for compact toggles.
    var shortLabel: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .hermes: return "Hermes"
        case .openclaw: return "Claw"
        }
    }

    /// The agent provider whose logo represents this backend in UI.
    var agentProvider: AgentProvider? {
        switch self {
        case .codex: return .codex
        case .claude: return .claudeCode
        case .hermes: return .hermes
        case .openclaw: return .openClaw
        }
    }

    /// Whether this backend uses the local Codex/Claude CLIs (privacy-gated).
    var requiresCLIAssistantConsent: Bool {
        switch self {
        case .codex, .claude: return true
        case .hermes, .openclaw: return false
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
