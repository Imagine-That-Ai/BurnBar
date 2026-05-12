import Foundation
import Observation

// MARK: - AssistantPendingPrompt
//
// Process-wide singleton that holds the next prompt destined for Hermes or
// Pi. Writers:
//   • The `AskAssistantIntent` AppIntent (fired by widget chips) stashes a
//     value here when the host app launches.
//   • The `OpenBurnBarMobileApp.onOpenURL` deep-link parser also writes here
//     when the URL carries a `?prompt=` query item.
//
// Readers:
//   • `HermesConversationListView` and `PiConversationListView` observe
//     their respective slots and auto-send + clear on appear / change.
//
// Per-process semantics are sufficient because every writer runs in the
// host app's process — AppIntent.perform() is invoked in the main app
// when `openAppWhenRun = true`, and the deep-link path is obviously
// in-app. We do *not* try to share across processes (no App Group + UD)
// because the widget never reads the slot — it just publishes intents.

@MainActor
@Observable
public final class AssistantPendingPrompt {
    public static let shared = AssistantPendingPrompt()

    public var hermes: String?
    public var pi: String?

    private init() {}

    /// Stash a prompt for the named assistant. Empty / whitespace-only
    /// strings clear the slot — useful for the "Ask Hermes" / "Ask Pi"
    /// chips that want to *focus the composer* without pre-filling.
    public func stash(assistant: AssistantRuntimeID, prompt: String?) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = (trimmed?.isEmpty == false) ? trimmed : nil
        switch assistant {
        case .hermes: hermes = value
        case .pi:     pi = value
        }
    }

    public func clear(_ assistant: AssistantRuntimeID) {
        switch assistant {
        case .hermes: hermes = nil
        case .pi:     pi = nil
        }
    }

    /// Read + clear in one shot — what consumers want on appear.
    public func consume(_ assistant: AssistantRuntimeID) -> String? {
        let value: String?
        switch assistant {
        case .hermes: value = hermes; hermes = nil
        case .pi:     value = pi;     pi = nil
        }
        return value
    }
}
