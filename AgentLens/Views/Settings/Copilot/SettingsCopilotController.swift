import Foundation
import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Copilot Controller

/// Drives the Settings Copilot: a two-tier system that combines instant
/// manifest search (Tier 1, zero-latency, offline) with agentic propose-and-
/// confirm (Tier 2, streams through the shared `ChatSessionController`).
///
/// **Tier 1** — literal search: delegates to `SettingsSearchEngine` and
/// returns ranked manifest items the user can tap to navigate.
///
/// **Tier 2** — natural-language: sends the query + a settings snapshot + the
/// action grammar to the shared `ChatSessionController`. The LLM can respond
/// with text AND propose actions (parsed as JSON envelopes). Proposed actions
/// render as **confirm chips** — nothing mutates until the user taps Confirm.
///
/// If no backend (Hermes, CLI) is available, Tier 2 gracefully falls back to
/// Tier 1 results with an "Ask Copilot unavailable" notice.
@MainActor
@Observable
final class SettingsCopilotController {

    // MARK: - State

    enum Phase: Equatable {
        case idle
        case streaming
        case complete
        case error(String)
    }

    /// Current conversation phase.
    private(set) var phase: Phase = .idle

    /// Streamed assistant text (accumulated from the backend).
    private(set) var streamedText: String = ""

    /// Tier 1 instant results (populated on every query change).
    private(set) var searchResults: [SettingsItem] = []

    /// Proposed actions parsed from the LLM response, pending user confirmation.
    private(set) var proposedActions: [SettingsActionRegistry.Action] = []

    /// Actions that the user has confirmed and applied.
    private(set) var appliedActionIDs: Set<String> = []

    /// Whether Tier 2 is available (a chat backend is detected).
    private(set) var copilotAvailable: Bool = false

    // MARK: - Collaborators

    private let registry: SettingsActionRegistry
    private let cliBridge: CLIBridge?

    init(
        registry: SettingsActionRegistry,
        cliBridge: CLIBridge? = nil
    ) {
        self.registry = registry
        self.cliBridge = cliBridge
    }

    // MARK: - Tier 1: Instant Search

    /// Updates instant search results for the given query. Called on every
    /// keystroke from the search field.
    func updateSearchResults(query: String) {
        searchResults = SettingsSearchEngine.search(query, in: SettingsManifest.all)
    }

    // MARK: - Tier 2: Agentic Ask

    /// Sends a natural-language query through the copilot backend. The
    /// response is streamed into `streamedText`; any proposed actions are
    /// parsed into `proposedActions`.
    ///
    /// Falls back to Tier 1 with an error notice if no backend is available.
    func ask(_ query: String) async {
        // Reset state.
        streamedText = ""
        proposedActions = []
        appliedActionIDs = []
        phase = .streaming

        // Check backend availability.
        guard let bridge = cliBridge else {
            phase = .error("No chat backend available. Use search results below to navigate.")
            return
        }

        await bridge.detect()
        guard bridge.detectedBackend != nil else {
            phase = .error("No CLI agent detected. Install Claude Code or Codex to enable the copilot, or use search to navigate.")
            return
        }

        // Build the system prompt with the action grammar + settings snapshot.
        let systemPrompt = SettingsCopilotPromptBuilder.build(
            actionCatalog: SettingsActionRegistry.actionCatalog,
            settingsSnapshot: registry.settingsSnapshot(),
            manifestSummary: SettingsCopilotPromptBuilder.manifestSummary()
        )

        // Stream the response via CLIBridge.
        do {
            let stream = bridge.chat(systemPrompt: systemPrompt, userMessage: query)
            for try await event in stream {
                switch event {
                case .text(let chunk):
                    streamedText += chunk
                case .reasoning(let chunk):
                    // Ignore reasoning tokens in the copilot UI.
                    _ = chunk
                case .refusal(let text):
                    streamedText += text
                case .toolUse, .toolResult, .usage, .sessionID:
                    // Ignore tool, usage and session-handle events — the
                    // copilot operates via text + action envelopes.
                    break
                }
            }
        } catch {
            phase = .error("The copilot encountered an error: \(error.localizedDescription)")
            return
        }

        // Parse proposed actions from the full response.
        proposedActions = parseProposedActions(from: streamedText)

        // Strip action envelopes from the visible text.
        if !proposedActions.isEmpty {
            streamedText = SettingsCopilotPromptBuilder.stripActionFences(from: streamedText)
        }

        phase = streamedText.isEmpty && proposedActions.isEmpty
            ? .error("The copilot could not generate a response. Try rephrasing or use the search results.")
            : .complete
    }

    // MARK: - Confirm / Apply

    /// User confirmed a proposed action — apply it through the registry.
    @discardableResult
    func confirmAction(id: String) -> Bool {
        guard let action = registry.apply(actionID: id) else { return false }
        appliedActionIDs.insert(id)
        // Remove from proposed list.
        proposedActions.removeAll { $0.id == id }
        return true
    }

    /// Dismiss a proposed action without applying.
    func dismissAction(id: String) {
        proposedActions.removeAll { $0.id == id }
    }

    // MARK: - Reset

    func reset() {
        phase = .idle
        streamedText = ""
        proposedActions = []
        appliedActionIDs = []
        searchResults = []
    }

    // MARK: - Action Envelope Parsing

    /// Parses action proposals from the LLM response text. The system prompt
    /// instructs the model to emit JSON envelopes wrapped in ```action fences:
    ///
    /// ```action
    /// [{"id":"setAppearanceDark","reason":"You asked for dark mode"}]
    /// ```
    ///
    /// Unknown action IDs are silently filtered (the registry is the
    /// whitelist gate).
    func parseProposedActions(from text: String) -> [SettingsActionRegistry.Action] {
        // Extract content between ```action ... ``` fences.
        let pattern = #"```action\s*\n([\s\S]*?)\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        var actions: [SettingsActionRegistry.Action] = []
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges >= 2,
                  let jsonRange = Range(match.range(at: 1), in: text) else { return }
            let jsonStr = String(text[jsonRange])
            // Parse the JSON array.
            if let data = jsonStr.data(using: .utf8),
               let envelopes = try? JSONDecoder().decode([ActionEnvelope].self, from: data) {
                for envelope in envelopes {
                    if let action = registry.action(for: envelope.id) {
                        actions.append(action)
                    }
                }
            }
        }
        return actions
    }

    /// Used by tests to inject raw text and verify parsing.
    func testParseProposedActions(from text: String) -> [SettingsActionRegistry.Action] {
        parseProposedActions(from: text)
    }
}

// MARK: - Action Envelope (JSON model)

private struct ActionEnvelope: Decodable {
    let id: String
    let reason: String?
}

// MARK: - Copilot Availability Probe

extension SettingsCopilotController {

    /// Probes whether a chat backend is available for Tier 2 queries.
    func probeAvailability() async {
        guard let bridge = cliBridge else {
            copilotAvailable = false
            return
        }
        await bridge.detect()
        copilotAvailable = bridge.detectedBackend != nil
    }
}
