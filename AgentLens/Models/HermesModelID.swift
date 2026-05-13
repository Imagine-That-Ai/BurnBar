import Foundation
import OpenBurnBarCore
import SwiftUI

// MARK: - Hermes Model
//
// Hermes is a multi-runtime chat backend: under the hood it can route to
// Codex, Claude, Z.ai, Kimi, MiniMax, or Ollama. This enum is the
// user-selectable list of those underlying runtimes — separate from the
// outer chat surface picker (`ChatBackendID`) which decides which app
// drives the conversation.
//
// Surfaced as a second-level row beneath the ChatEngineBackendStrip when
// the active surface is `.hermes`. The choice is persisted via
// `ChatBackendSettings.selectedHermesModelIDRaw` and reflected through
// `hermesChatModelOverride` so the chat session controller picks it up
// without a new routing path.

enum HermesModelID: String, Identifiable, Codable, CaseIterable {
    case codex
    case claude
    case zai
    case kimi
    case minimax
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:   return "Codex"
        case .claude:  return "Claude"
        case .zai:     return "Z.ai"
        case .kimi:    return "Kimi"
        case .minimax: return "MiniMax"
        case .ollama:  return "Ollama"
        }
    }

    /// Short label for the compact row.
    var shortLabel: String { displayName }

    /// Provider logo that represents this model in UI. Pulls from the
    /// shared AgentProvider catalog so the popover, strip, and Settings
    /// pull the same icon.
    var agentProvider: AgentProvider {
        switch self {
        case .codex:   return .codex
        case .claude:  return .claudeCode
        case .zai:     return .zai
        case .kimi:    return .kimi
        case .minimax: return .minimax
        case .ollama:  return .ollama
        }
    }

    /// Model identifier wired into Hermes Gateway when this row is selected.
    /// Mirrors the CLI bridge's canonical names so
    /// `ChatBackendSettings.resolvedHermesChatModel` does the right thing
    /// without a separate switch.
    var hermesModelOverride: String {
        switch self {
        case .codex:   return "codex"
        case .claude:  return "claude"
        case .zai:     return "zai"
        case .kimi:    return "kimi"
        case .minimax: return "minimax"
        case .ollama:  return "ollama"
        }
    }

    // MARK: - CSV encode/decode (mirrors ChatBackendID pattern)

    static func decodeEnabledList(fromCSV csv: String) -> [HermesModelID] {
        csv
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { HermesModelID(rawValue: $0) }
    }

    static func encodeEnabledList(_ models: [HermesModelID]) -> String {
        models.map(\.rawValue).joined(separator: ",")
    }

    /// Default visible models when the user hasn't customized the list.
    /// Per product call: minimum-default (matches the original three the
    /// strip showed) so existing users see the same shape on upgrade.
    static var defaultEnabled: [HermesModelID] {
        [.codex, .claude, .ollama]
    }
}
