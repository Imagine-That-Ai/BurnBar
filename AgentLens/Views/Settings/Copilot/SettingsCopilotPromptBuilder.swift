import Foundation

// MARK: - Settings Copilot Prompt Builder

/// Builds the system prompt for the Settings Copilot. The prompt carries:
/// 1. The action grammar (what the copilot can do)
/// 2. A live snapshot of current settings state
/// 3. A compact summary of the settings manifest (so it knows what exists)
///
/// The LLM is instructed to emit action proposals as JSON envelopes wrapped
/// in ```action fences so the controller can parse them safely.
enum SettingsCopilotPromptBuilder {

    static func build(
        actionCatalog: [String: String],
        settingsSnapshot: String,
        manifestSummary: String
    ) -> String {
        var sections: [String] = []

        // Role + behavior
        sections.append("""
        You are the OpenBurnBar Settings Copilot. Your job is to help users find and change settings quickly. You answer questions, explain what settings do, and propose changes.

        RULES:
        - Be concise. One or two sentences for simple answers.
        - When the user asks you to change something, propose the matching action(s) from the catalog below.
        - You CANNOT set secrets (API keys, tokens, passwords). For those, tell the user where to go and what to do.
        - You CAN change: appearance, skin, indexing, model proxy, controller runtime, summaries, refresh interval, daily digest, cloud sync.
        - You CAN navigate the user to any settings page.
        - Always explain what you're about to do before proposing the action.
        """)

        // Action catalog
        var actionLines: [String] = ["AVAILABLE ACTIONS:"]
        for (id, description) in actionCatalog.sorted(by: { $0.key < $1.key }) {
            actionLines.append("- \(id): \(description)")
        }
        sections.append(actionLines.joined(separator: "\n"))

        // Settings snapshot
        sections.append("CURRENT SETTINGS STATE:\n\(settingsSnapshot)")

        // Manifest summary (compact)
        sections.append("SETTINGS PAGES (for navigation):\n\(manifestSummary)")

        // Action envelope format
        sections.append("""
        ACTION FORMAT:
        When you propose actions, emit them AFTER your text explanation, wrapped in a fenced block:

        ```action
        [{"id":"<action_id>","reason":"<why>"}]
        ```

        Only propose actions from the catalog above. If the user asks for something you cannot do, explain what page to visit instead.
        """)

        return sections.joined(separator: "\n\n---\n\n")
    }

    /// A compact summary of the settings manifest — tab titles + subtitles,
    /// not the full keyword set. Keeps the prompt token count reasonable.
    static func manifestSummary() -> String {
        var lines: [String] = []
        for tab in SettingsTab.visibleTabs {
            lines.append("- \(tab.title): \(tab.subtitle)")
        }
        return lines.joined(separator: "\n")
    }

    /// Strips ```action ... ``` fences from text so the user doesn't see
    /// raw JSON in the copilot bubble.
    static func stripActionFences(from text: String) -> String {
        let pattern = #"```action\s*\n[\s\S]*?\n```"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        let mutable = NSMutableString(string: text)
        regex.replaceMatches(
            in: mutable,
            options: [],
            range: NSRange(location: 0, length: mutable.length),
            withTemplate: ""
        )
        // Trim trailing whitespace left by the removal.
        return (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
