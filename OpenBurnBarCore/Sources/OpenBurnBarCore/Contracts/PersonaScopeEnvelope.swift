import Foundation

// MARK: - Persona Scope Envelope (Hermes Square §6.5)
//
// Wire format for the persona-scoped dispatch. Mobile builds it from the
// active `AgentPersona`; Firestore carries it as a single JSON string
// (`personaScopeJSON`) on the mission request; the Mac listener
// (`CLIAgentMissionRuntimePlanner`) decodes it and applies the scope to the
// spawned subprocess via the existing tool-allow / file-allow / shell-allow
// infrastructure.
//
// Kept separate from `AgentPersona` so changes to mobile-side persona
// editing don't ripple through the wire. The envelope strips fields the
// Mac doesn't need (`name`, `description`, `isDefault`) and adds the
// dispatch-time metadata (`appliedAt`, `agentURI`).

public struct PersonaScopeEnvelope: Codable, Sendable, Hashable {
    /// Wire format schema version.
    public let schemaVersion: Int

    /// The agent this scope is being applied to (e.g.,
    /// `agent://burnbar/claude`). Lets the Mac validate that the runtime
    /// matches what the phone thought it was dispatching to.
    public let agentURI: String

    /// Persona ID (e.g., `tech-reviewer`).
    public let personaID: String

    /// Optional system-prompt prefix to inject before the agent's default
    /// system prompt.
    public let systemPromptAdditions: String?

    /// Strict allow-list of tool names. Empty = no tool restriction.
    public let permittedTools: [String]

    /// Strict allow-list of file globs the agent may read / write.
    public let permittedFileGlobs: [String]

    /// Strict allow-list of shell command prefixes. Empty AND
    /// `permitShell == true` means "no prefix restriction"; empty AND
    /// `permitShell == false` means "shell entirely disabled".
    public let permittedShellPrefixes: [String]

    public let permitShell: Bool
    public let permitFileEdits: Bool

    /// Optional temperature override (0…2).
    public let temperatureOverride: Double?

    /// Optional preferred model.
    public let preferredModel: String?

    /// ISO-8601 timestamp the phone built the envelope.
    public let appliedAt: Date

    public init(
        schemaVersion: Int = 1,
        agentURI: String,
        personaID: String,
        systemPromptAdditions: String? = nil,
        permittedTools: [String] = [],
        permittedFileGlobs: [String] = [],
        permittedShellPrefixes: [String] = [],
        permitShell: Bool = true,
        permitFileEdits: Bool = true,
        temperatureOverride: Double? = nil,
        preferredModel: String? = nil,
        appliedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.agentURI = agentURI
        self.personaID = personaID
        self.systemPromptAdditions = systemPromptAdditions
        self.permittedTools = permittedTools
        self.permittedFileGlobs = permittedFileGlobs
        self.permittedShellPrefixes = permittedShellPrefixes
        self.permitShell = permitShell
        self.permitFileEdits = permitFileEdits
        self.temperatureOverride = temperatureOverride
        self.preferredModel = preferredModel
        self.appliedAt = appliedAt
    }
}

// MARK: - Persona → Envelope bridge

extension PersonaScopeEnvelope {
    public init(persona: AgentPersona, agentURI: String, appliedAt: Date = Date()) {
        self.init(
            schemaVersion: 1,
            agentURI: agentURI,
            personaID: persona.id,
            systemPromptAdditions: persona.systemPromptAdditions,
            permittedTools: persona.permittedTools,
            permittedFileGlobs: persona.permittedFileGlobs,
            permittedShellPrefixes: persona.permittedShellPrefixes,
            permitShell: persona.permitShell,
            permitFileEdits: persona.permitFileEdits,
            temperatureOverride: persona.temperatureOverride,
            preferredModel: persona.preferredModel,
            appliedAt: appliedAt
        )
    }
}

// MARK: - JSON convenience

extension PersonaScopeEnvelope {
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func from(jsonString raw: String) throws -> PersonaScopeEnvelope {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw NSError(domain: "PersonaScopeEnvelope", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Empty JSON for persona scope."
            ])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PersonaScopeEnvelope.self, from: data)
    }
}
