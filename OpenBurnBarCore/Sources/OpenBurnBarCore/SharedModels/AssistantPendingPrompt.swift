import Foundation
import Observation

// MARK: - AssistantPendingPrompt
//
// Process-wide singleton that holds the next prompt destined for any assistant
// runtime. Writers:
//   • The `AskAssistantIntent` AppIntent (fired by widget chips) stashes a
//     value here when the host app launches.
//   • The `OpenBurnBarMobileApp.onOpenURL` deep-link parser also writes here
//     when the URL carries a `?prompt=` query item.
//
// Readers:
//   • `HermesConversationListView` / `PiConversationListView` (and any future
//     runtime list views) observe their respective slots and auto-send +
//     clear on appear / change.
//
// Per-process semantics are sufficient because every writer runs in the
// host app's process. We do *not* try to share across processes (no App
// Group + UD) because the widget never reads the slot — it just publishes
// intents.

@MainActor
@Observable
public final class AssistantPendingPrompt {
    public static let shared = AssistantPendingPrompt()

    /// Per-runtime pending prompt slots. Stored as a dictionary so adding a
    /// new `AssistantRuntimeID` case never touches this file.
    public var slots: [AssistantRuntimeID: String] = [:]

    // Back-compat convenience accessors (legacy call sites read `.hermes` / `.pi`).
    public var hermes: String? {
        get { slots[.hermes] }
        set { slots[.hermes] = newValue }
    }
    public var pi: String? {
        get { slots[.pi] }
        set { slots[.pi] = newValue }
    }

    private init() {}

    /// Stash a prompt for the named assistant. Empty / whitespace-only
    /// strings clear the slot — useful for "Ask <X>" chips that want to
    /// *focus the composer* without pre-filling.
    public func stash(assistant: AssistantRuntimeID, prompt: String?) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            slots[assistant] = trimmed
        } else {
            slots[assistant] = nil
        }
    }

    public func clear(_ assistant: AssistantRuntimeID) {
        slots[assistant] = nil
    }

    /// Read + clear in one shot — what consumers want on appear.
    public func consume(_ assistant: AssistantRuntimeID) -> String? {
        let value = slots[assistant]
        slots[assistant] = nil
        return value
    }
}
