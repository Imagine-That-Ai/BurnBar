import Foundation

// MARK: - Hermes System Prompt Builder
//
// One canonical builder for the system prompt the Hermes chat client sends
// alongside user turns. Both iOS and macOS apps share this builder so the
// atom directive stays in lockstep with the parser.
//
// The directive instructs Hermes to wrap entities the user can navigate to
// in `[label](burnbar://...)` markdown links. Client-side, `HermesAtomParser`
// decodes those links into typed `HermesAtom` chips.

public struct HermesSystemPromptBuilder: Sendable {

    /// User's live OpenBurnBar context — costs, providers, sessions —
    /// rendered as plain prose. Each app builds its own snapshot text.
    public var dashboardContext: String?

    /// Whether to include the atom directive. Defaults to `true`. Useful to
    /// disable for benchmarking or when the user explicitly turns off rich
    /// rendering app-wide.
    public var includesAtomDirective: Bool

    /// Optional caller-supplied prefix (e.g. a personality preamble).
    public var preamble: String?

    public init(
        dashboardContext: String? = nil,
        includesAtomDirective: Bool = true,
        preamble: String? = nil
    ) {
        self.dashboardContext = dashboardContext
        self.includesAtomDirective = includesAtomDirective
        self.preamble = preamble
    }

    /// Compose the final system prompt string, ready to send.
    public func build() -> String {
        var sections: [String] = []
        if let preamble, !preamble.isEmpty {
            sections.append(preamble)
        }
        if includesAtomDirective {
            sections.append(Self.atomDirective)
        }
        if let dashboardContext, !dashboardContext.isEmpty {
            sections.append(dashboardContext)
        }
        return sections.joined(separator: "\n\n")
    }

    /// The atom directive Hermes consumes. Stable wording — keep in sync
    /// with `HermesAtomURL` and `HermesAtomParser`.
    public static let atomDirective: String = """
    You are talking to a user inside the OpenBurnBar app. The app has rich
    native UI for entities like costs, providers, sessions, models, time
    windows, projects, tools, token totals, quota usage, and Hermes runtime
    profiles. When you reference any of these entities in your replies,
    wrap them in markdown links using the `burnbar://` URL scheme so the
    user can tap and drill into the matching native view.

    Atom URL forms:
      - Cost in a window:  burnbar://burn?window=today&amount=2.34
      - Specific session:  burnbar://session?id=<persistent_id>
      - Provider:          burnbar://provider?token=<anthropic|openai|kimi|minimax|zai|deepseek|google|hermes|...>
      - Model:             burnbar://model?id=<model_identifier>
      - Time window:       burnbar://window?value=<today|yesterday|7d|30d|90d|all>
      - Tool call:         burnbar://tool?name=<ToolName>
      - Project:           burnbar://project?id=<project_id>
      - Token total:       burnbar://tokens?value=<integer>&scope=<today|session|run|lifetime>
      - Quota:             burnbar://quota?provider=<provider>&percent=<integer 0-100>
      - Hermes runtime:    burnbar://runtime?profile=<profile_name>

    Examples:
      - Today you spent [$2.34 today](burnbar://burn?window=today&amount=2.34) across [3 sessions](burnbar://window?value=today).
      - Your biggest run used [Claude Sonnet 4.7](burnbar://model?id=claude-sonnet-4.7) and burned [12.4k tokens](burnbar://tokens?value=12400&scope=session).
      - [Anthropic](burnbar://provider?token=anthropic) is at [78% quota](burnbar://quota?provider=anthropic&percent=78).
      - Open [session abc-123](burnbar://session?id=abc-123) for the diff.

    Rules:
      - Atoms are atomic — they will never wrap across lines, so keep labels
        short (~30 chars max) when possible.
      - Use atoms only for entities the user can navigate to. Do not make
        up IDs you didn't see in the conversation context. Do not link
        ambient prose like "your fleet" or "today's burn" without a real
        target.
      - Prefer atoms for the first mention of an entity; subsequent
        mentions in the same paragraph can be plain text to keep the
        message readable.
      - Never wrap atoms inside other atoms.
    """
}
