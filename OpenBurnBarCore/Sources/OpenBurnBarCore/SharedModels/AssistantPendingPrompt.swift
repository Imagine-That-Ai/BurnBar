import Foundation
import Observation

// MARK: - AssistantPendingPrompt
//
// Process-wide singleton that holds the next prompt destined for any assistant
// runtime. Writers:
//   • The `AskAssistantIntent` AppIntent (fired by widget chips) stashes a
//     value here when the host app launches.
//   • The `OpenBurnBarMobileApp.onOpenURL` deep-link parser also writes here
//     when the URL carries a `?prompt=` query item. URL-origin prompts are
//     marked confirmation-required so consumers do not auto-submit them.
//
// Readers:
//   • `HermesConversationListView` / `PiConversationListView` (and any future
//     runtime list views) observe their respective slots and consume + clear
//     on appear / change.
//
// Per-process semantics are sufficient because every writer runs in the
// host app's process. We do *not* try to share across processes (no App
// Group + UD) because the widget never reads the slot — it just publishes
// intents.

@MainActor
@Observable
public final class AssistantPendingPrompt {
    public static let shared = AssistantPendingPrompt()

    public enum Source: String, Hashable, Sendable {
        case inApp
        case appIntent
        case deepLink
    }

    public struct Request: Hashable, Sendable {
        public let prompt: String
        public let source: Source
        public let requiresConfirmation: Bool

        public init(prompt: String, source: Source, requiresConfirmation: Bool) {
            self.prompt = prompt
            self.source = source
            self.requiresConfirmation = requiresConfirmation
        }
    }

    /// Per-runtime pending prompt slots. Stored as a dictionary so adding a
    /// new `AssistantRuntimeID` case never touches this file.
    private var requests: [AssistantRuntimeID: Request] = [:]

    public var slots: [AssistantRuntimeID: String] {
        get { requests.mapValues(\.prompt) }
        set {
            requests = newValue.compactMapValues { prompt in
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return Request(prompt: trimmed, source: .inApp, requiresConfirmation: false)
            }
        }
    }

    // Back-compat convenience accessors (legacy call sites read `.hermes` / `.pi`).
    public var hermes: String? {
        get { requests[.hermes]?.prompt }
        set { slots[.hermes] = newValue }
    }
    public var pi: String? {
        get { requests[.pi]?.prompt }
        set { slots[.pi] = newValue }
    }

    private init() {}

    /// Internal hook for tests that need isolated prompt state without exposing
    /// additional construction API to app targets outside OpenBurnBarCore.
    static func makeIsolatedForTesting() -> AssistantPendingPrompt {
        AssistantPendingPrompt()
    }

    /// Stash a prompt for the named assistant. Empty / whitespace-only
    /// strings clear the slot — useful for "Ask <X>" chips that want to
    /// *focus the composer* without pre-filling.
    public func stash(
        assistant: AssistantRuntimeID,
        prompt: String?,
        source: Source = .inApp,
        requiresConfirmation: Bool = false
    ) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            requests[assistant] = Request(
                prompt: trimmed,
                source: source,
                requiresConfirmation: requiresConfirmation || source == .deepLink
            )
        } else {
            requests[assistant] = nil
        }
    }

    public func clear(_ assistant: AssistantRuntimeID) {
        requests[assistant] = nil
    }

    public func consumeRequest(_ assistant: AssistantRuntimeID) -> Request? {
        let value = requests[assistant]
        requests[assistant] = nil
        return value
    }

    /// Read + clear in one shot — what consumers want on appear.
    public func consume(_ assistant: AssistantRuntimeID) -> String? {
        consumeRequest(assistant)?.prompt
    }
}
