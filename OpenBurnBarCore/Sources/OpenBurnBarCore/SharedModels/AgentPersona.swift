import Foundation

// MARK: - Agent Persona (Hermes Square §6.5)
//
// A persona extends an agent's identity with a scoped *role*. Same
// underlying runtime, scoped tools, scoped files, scoped shell prefixes,
// optional system-prompt additions, optional temperature / model overrides.
//
// At dispatch, the persona becomes a scope on the resulting Mac-side
// session: the listener (`CLIAgentMissionRequestListener`) reads
// `request.personaScopeJSON` and applies it to the spawned subprocess via
// the existing tool-allow / file-allow infrastructure.
//
// This is the [Cequence Agent Personas](https://www.cequence.ai/blog/ai/agent-personas-missing-agentic-security-layer/)
// pattern translated to consumer mobile.

public struct AgentPersona: Codable, Sendable, Hashable, Identifiable {
    /// Stable persona ID. Combined with the agent URI gives a globally
    /// unique scope (e.g., `agent://burnbar/claude#tech-reviewer`).
    public let id: String

    /// Display name in the brand-zone persona picker.
    public let name: String

    /// One-line description shown beneath the name.
    public let description: String

    /// System-prompt prefix injected at dispatch. Optional — `nil` means
    /// the agent's default prompt is unmodified.
    public let systemPromptAdditions: String?

    /// Strict allow-list of tool names the agent may invoke under this
    /// persona. Empty means "all tools allowed" (the default). Tools not
    /// in the list are rejected at dispatch time.
    public let permittedTools: [String]

    /// Strict allow-list of file globs the agent may read or write. Empty
    /// means "no path restriction".
    public let permittedFileGlobs: [String]

    /// Strict allow-list of shell command prefixes. Empty means "no shell
    /// allowed" if `permitShell` is false; if `permitShell` is true and
    /// the list is empty, all shell commands are allowed.
    public let permittedShellPrefixes: [String]

    /// Top-level toggle: may the agent invoke any shell command at all?
    public let permitShell: Bool

    /// Top-level toggle: may the agent edit files at all?
    public let permitFileEdits: Bool

    /// Optional temperature override (0…2). `nil` = use agent default.
    public let temperatureOverride: Double?

    /// Optional preferred model. `nil` = use agent default.
    public let preferredModel: String?

    /// Whether this persona is the default for a fresh dispatch on the
    /// owning agent. Exactly one persona per agent should have this true
    /// (enforced by `AgentIdentity.personasSanitized`).
    public let isDefault: Bool

    public init(
        id: String,
        name: String,
        description: String,
        systemPromptAdditions: String? = nil,
        permittedTools: [String] = [],
        permittedFileGlobs: [String] = [],
        permittedShellPrefixes: [String] = [],
        permitShell: Bool = true,
        permitFileEdits: Bool = true,
        temperatureOverride: Double? = nil,
        preferredModel: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.systemPromptAdditions = systemPromptAdditions
        self.permittedTools = permittedTools
        self.permittedFileGlobs = permittedFileGlobs
        self.permittedShellPrefixes = permittedShellPrefixes
        self.permitShell = permitShell
        self.permitFileEdits = permitFileEdits
        self.temperatureOverride = temperatureOverride
        self.preferredModel = preferredModel
        self.isDefault = isDefault
    }
}

// MARK: - Default Personas

extension AgentPersona {
    /// The default "do everything" persona shipped for every built-in
    /// agent. Marked `isDefault: true` so the brand-zone picker selects it
    /// on first install.
    public static let defaultPersona = AgentPersona(
        id: "default",
        name: "Default",
        description: "Full capability. No additional constraints beyond the agent's own defaults.",
        isDefault: true
    )

    /// Read-only tech reviewer. Common preset shipped for code-focused
    /// CLI agents (Claude / Codex / OpenClaw). Disables shell and file
    /// edits; allows file reads and search.
    public static let techReviewer = AgentPersona(
        id: "tech-reviewer",
        name: "Tech Reviewer",
        description: "Read-only. Reviews code, runs grep / lsp, never edits files or executes shells.",
        systemPromptAdditions: "You are reviewing only. Do not modify files. Do not execute commands. Cite file:line for every claim.",
        permittedTools: ["read_file", "grep", "ls", "lsp", "tree"],
        permittedFileGlobs: [],
        permittedShellPrefixes: [],
        permitShell: false,
        permitFileEdits: false
    )

    /// Documentation writer. Allows file edits scoped to docs/* and *.md.
    /// Disables shell.
    public static let docWriter = AgentPersona(
        id: "doc-writer",
        name: "Doc Writer",
        description: "Edits docs only. Markdown, RST, and inline comments. No shell.",
        systemPromptAdditions: "You write and improve documentation. Keep the editorial vocabulary of the project. Never edit source code.",
        permittedTools: ["read_file", "edit_file", "grep", "ls"],
        permittedFileGlobs: ["docs/**", "**/*.md", "**/*.rst", "README*"],
        permittedShellPrefixes: [],
        permitShell: false,
        permitFileEdits: true
    )

    /// Triage persona. Reads ticket / issue context, never edits.
    public static let triage = AgentPersona(
        id: "triage",
        name: "Triage",
        description: "Reads, classifies, and proposes. Never modifies code or state.",
        systemPromptAdditions: "You triage issues. Classify, propose next steps, but do not implement.",
        permittedTools: ["read_file", "grep", "ls", "lsp"],
        permittedFileGlobs: [],
        permittedShellPrefixes: ["git log", "git diff", "git blame", "gh"],
        permitShell: true,
        permitFileEdits: false
    )

    /// Convenience: the default seed set for a fresh built-in code-aware
    /// agent (Claude / Codex / OpenClaw). Hermes / Pi only ship the
    /// default persona (no shell, no file-edits — they don't need scopes).
    public static let defaultCLISeedSet: [AgentPersona] = [
        .defaultPersona,
        .techReviewer,
        .docWriter,
        .triage
    ]

    public static let defaultChatSeedSet: [AgentPersona] = [
        .defaultPersona
    ]
}

// MARK: - Sanitisation

extension Array where Element == AgentPersona {
    /// Ensures exactly one persona is `isDefault`. If none are marked, the
    /// first is promoted; if multiple are marked, only the first stays.
    public func personasSanitized() -> [AgentPersona] {
        guard !isEmpty else { return [] }
        let defaultCount = filter { $0.isDefault }.count
        if defaultCount == 1 { return self }
        var seenDefault = false
        return map { persona -> AgentPersona in
            if persona.isDefault && !seenDefault {
                seenDefault = true
                return persona
            }
            if !seenDefault && persona == first {
                seenDefault = true
                return AgentPersona(
                    id: persona.id,
                    name: persona.name,
                    description: persona.description,
                    systemPromptAdditions: persona.systemPromptAdditions,
                    permittedTools: persona.permittedTools,
                    permittedFileGlobs: persona.permittedFileGlobs,
                    permittedShellPrefixes: persona.permittedShellPrefixes,
                    permitShell: persona.permitShell,
                    permitFileEdits: persona.permitFileEdits,
                    temperatureOverride: persona.temperatureOverride,
                    preferredModel: persona.preferredModel,
                    isDefault: true
                )
            }
            return AgentPersona(
                id: persona.id,
                name: persona.name,
                description: persona.description,
                systemPromptAdditions: persona.systemPromptAdditions,
                permittedTools: persona.permittedTools,
                permittedFileGlobs: persona.permittedFileGlobs,
                permittedShellPrefixes: persona.permittedShellPrefixes,
                permitShell: persona.permitShell,
                permitFileEdits: persona.permitFileEdits,
                temperatureOverride: persona.temperatureOverride,
                preferredModel: persona.preferredModel,
                isDefault: false
            )
        }
    }
}
