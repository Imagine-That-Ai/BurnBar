import Foundation
import OpenBurnBarCore

// MARK: - Agents column routing (compact Hermes Square)
//
// Pure mapping so deep links and overflow stay testable without a device.
// Compact Agents is still Hermes Square — this does not invent a second root.

enum HermesSquareAgentsColumnRouting {
    /// Compact tray selection for any Agents-family OS destination.
    static func compactDestination(
        for destination: MobileOsDestination
    ) -> AuroraNavDestination? {
        switch destination {
        case .hermes, .pi, .assistants, .mission:
            return .hermes
        default:
            return nil
        }
    }

    /// `ShowAssistantsTab` used to keep the current tab unless the runtime
    /// was Hermes. Pi / Codex / Claude replies must still land on Agents, so
    /// the runtime is deliberately ignored — the parameter stays to keep the
    /// call site honest about what it is no longer allowed to gate on.
    static func selectsAgentsTab(notificationRuntime _: String?) -> Bool {
        true
    }

    static func inboxID(runtime: AssistantRuntimeID, threadID: String?) -> String? {
        guard let trimmed = threadID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        switch runtime {
        case .hermes:
            return "hermes:\(trimmed)"
        case .pi:
            return "pi:\(trimmed)"
        case .codex, .claude, .openClaw, .droid, .forge, .antigravity, .grok,
                .cursorAgent, .openClaude, .omp, .junie, .fx:
            return "cli:\(trimmed)"
        }
    }

    static func runtime(fromInboxID id: String) -> AssistantRuntimeID? {
        let prefix = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        switch prefix {
        case "hermes":
            return .hermes
        case "pi":
            return .pi
        case "cli", "cli_mirror":
            return nil
        default:
            return AssistantRuntimeID(rawValue: prefix)
        }
    }

    /// Future Mac-only path. Named so the IA table can point at it.
    /// Not implemented on iOS — no loopback `:1337`, no daemon socket.
    static let grokdRelayOperationName = "HermesRelayOperation.grokdLocalBox"

    static var includesGrokdOnPhone: Bool { false }

    static var grokdMobileAddress: String {
        "Mac only until sealed \(grokdRelayOperationName) exists (Developer ID). Not iOS loopback :1337. Not openburnbar-daemon.sock."
    }

    enum OverflowDestination: String, CaseIterable, Hashable {
        case wand
        case missions
        case resumeHandoff
        case capabilityGrants
        case rollback
        case search
        case pinned
        case projectMemory
        case subscriptions
        case discover
        case voice
        case switcher
    }

    static var overflowDestinations: [OverflowDestination] {
        OverflowDestination.allCases
    }

    /// You → Ask to Mirror, or the Agents button, before Agents is on screen.
    @MainActor
    enum AskToMirrorPending {
        static var isPending = false

        static func stash() { isPending = true }

        @discardableResult
        static func consume() -> Bool {
            let value = isPending
            isPending = false
            return value
        }
    }
}
