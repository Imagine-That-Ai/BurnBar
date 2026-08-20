import Foundation
import Observation
import OpenBurnBarCore

// MARK: - Agent Brand Zone Store (audit wave 4, item 15)
//
// Intent layer for `AgentBrandZoneView`. The brand zone's quick actions used
// to read `MobileChatHistoryStore` / `CLIAgentChatReader` and dispatch
// missions straight from the View body's helper methods; this store owns
// that persistence and networking so the view renders state and sends
// intents only. Dependencies arrive via `init` (item 16) and default to the
// existing long-lived instances — the same idiom as
// `CLIAgentMobileChatService(historyStore:relayChatTransport:)`.

/// The navigation side-effect the view should perform after a forward
/// completes. Navigation stays in the view (it owns the split-layout /
/// NavigationStack callbacks); the store just names the destination.
enum AgentBrandForwardResolution: Equatable, Sendable {
    case openRuntimeThread(AssistantRuntimeID)
    case openRuntimeList(AssistantRuntimeID)
    case none
}

/// Outcome of a forward intent: the user-facing status text plus the
/// navigation the view should perform.
struct AgentBrandForwardResult: Equatable, Sendable {
    let message: String
    let resolution: AgentBrandForwardResolution
}

/// Subscription intents the brand zone's subscribe sheet emits.
enum AgentSubscriptionAction {
    case subscribe(AgentManifest.PushTopic.Cadence, SkillRunDeliveryMode)
    case unsubscribe
    case setMuted(Bool)
    case setDeliveryMode(SkillRunDeliveryMode)
}

@MainActor
@Observable
final class AgentBrandZoneStore {
    private let historyStore: MobileChatHistoryStore
    private let cliReader: CLIAgentChatReader
    private let subscriptionTopics: AgentSubscriptionTopicStore
    private let pendingPrompt: AssistantPendingPrompt

    init(
        historyStore: MobileChatHistoryStore = .shared,
        cliReader: CLIAgentChatReader = .shared,
        subscriptionTopics: AgentSubscriptionTopicStore = .shared,
        pendingPrompt: AssistantPendingPrompt = .shared
    ) {
        self.historyStore = historyStore
        self.cliReader = cliReader
        self.subscriptionTopics = subscriptionTopics
        self.pendingPrompt = pendingPrompt
    }

    /// The dispatch-runtime token for an identity, or nil when the agent's
    /// transport can't take a forward/dispatch. Pure; exposed so the view can
    /// gate the Forward quick action without owning transport logic.
    static func runtimeToken(for identity: AgentIdentity) -> String? {
        if let runtime = identity.runtimeID {
            return runtime.rawValue
        }
        switch identity.dispatchTransport {
        case .macRelay(let runtime):
            return runtime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankPreservingWhitespace
        case .nativeRelay, .httpGateway, .mcpServer:
            return nil
        }
    }

    /// Reads the most recent conversation for `identity` — the local mobile
    /// thread for native runtimes, or the freshly-refreshed Mac-mirrored CLI
    /// session for relay runtimes — as the context a Forward carries.
    func forwardContextSnapshot(for identity: AgentIdentity) async -> AgentForwardContextSnapshot? {
        guard let runtime = identity.runtimeID else { return nil }
        switch runtime {
        case .hermes, .pi:
            guard let thread = historyStore.threads(for: runtime).first else { return nil }
            let preview = thread.preview.nilIfBlankPreservingWhitespace ?? thread.messages.last?.text.nilIfBlankPreservingWhitespace ?? "No preview available."
            return AgentForwardContextSnapshot(
                title: thread.title.nilIfBlankPreservingWhitespace ?? "(untitled)",
                preview: preview,
                sourceLabel: "mobile thread",
                updatedAt: thread.updatedAt
            )
        case .claude, .codex, .openClaw, .droid, .forge, .antigravity,
             .grok, .cursorAgent, .openClaude, .omp, .junie:
            guard let cliRuntime = CLIAgentRuntime(assistant: runtime) else { return nil }
            await cliReader.refresh()
            guard let session = cliReader.sessions(for: cliRuntime).first else { return nil }
            return AgentForwardContextSnapshot(
                title: session.title.nilIfBlankPreservingWhitespace ?? "(untitled)",
                preview: session.preview.nilIfBlankPreservingWhitespace ?? "No preview available.",
                sourceLabel: "Mac mirrored session",
                updatedAt: session.updatedAt
            )
        }
    }

    /// Forwards the brand zone's latest context to another agent: native
    /// runtimes get the prompt stashed for their composer; relay runtimes get
    /// a queued mission via the console host. Returns the status message and
    /// the navigation the view should perform.
    ///
    /// `directThreadHandoffAvailable` mirrors the view's optional
    /// `onOpenRuntimeThread` callback: the native stash-and-open path is only
    /// taken when the surface can actually open a runtime thread.
    func forward(
        source: AgentIdentity,
        destination: AgentIdentity,
        context: AgentForwardContextSnapshot?,
        note: String,
        missionHost: any MissionConsoleHost,
        directThreadHandoffAvailable: Bool
    ) async -> AgentBrandForwardResult {
        let prompt = AgentBrandQuickActionComposer.forwardPrompt(
            source: source,
            destination: destination,
            context: context,
            note: note
        )

        if let runtime = destination.runtimeID,
           [.hermes, .pi].contains(runtime),
           directThreadHandoffAvailable {
            pendingPrompt.stash(assistant: runtime, prompt: prompt)
            return AgentBrandForwardResult(
                message: "Forwarded to \(destination.displayName) and opened a new thread.",
                resolution: .openRuntimeThread(runtime)
            )
        }

        guard let runtimeID = Self.runtimeToken(for: destination) else {
            return AgentBrandForwardResult(
                message: "Couldn't resolve a dispatch runtime for \(destination.displayName).",
                resolution: .none
            )
        }

        let request = MissionConsoleDispatchRequest(
            title: "Forward · \(source.displayName) → \(destination.displayName)",
            prompt: prompt,
            kind: .diligence,
            runtimeID: runtimeID,
            targetProject: nil,
            depth: .standard,
            approvalMode: .existingPolicy,
            commandsAllowed: false,
            fileEditsAllowed: false
        )
        switch await missionHost.dispatch(request) {
        case .dispatched(let missionID):
            let resolution: AgentBrandForwardResolution
            if let runtime = destination.runtimeID {
                resolution = .openRuntimeList(runtime)
            } else {
                resolution = .none
            }
            return AgentBrandForwardResult(
                message: "Forwarded to \(destination.displayName). Mission queued (\(missionID)).",
                resolution: resolution
            )
        case .failed(let message):
            return AgentBrandForwardResult(
                message: "Forward failed: \(message)",
                resolution: .none
            )
        }
    }

    /// Applies a subscribe-sheet intent against the subscription topic store
    /// and returns the user-facing status message. Errors are routed into the
    /// message (the view shows it in its status alert), never swallowed.
    func performSubscriptionAction(
        _ action: AgentSubscriptionAction,
        identity: AgentIdentity
    ) async -> String {
        do {
            switch action {
            case .subscribe(let cadence, let deliveryMode):
                let topic = try await subscriptionTopics.subscribe(
                    agent: identity,
                    cadence: cadence,
                    deliveryMode: deliveryMode
                )
                return "Subscribed to \(topic.displayName)."
            case .unsubscribe:
                try await subscriptionTopics.unsubscribe(agentURI: identity.id)
                return "Unsubscribed from \(identity.displayName) updates."
            case .setMuted(let muted):
                try await subscriptionTopics.setMuted(agentURI: identity.id, muted: muted)
                return muted ? "Muted \(identity.displayName) updates." : "Unmuted \(identity.displayName) updates."
            case .setDeliveryMode(let deliveryMode):
                try await subscriptionTopics.setDeliveryMode(agentURI: identity.id, deliveryMode: deliveryMode)
                return "\(identity.displayName) delivery set to \(deliveryMode.displayName.lowercased())."
            }
        } catch {
            return error.localizedDescription
        }
    }
}
