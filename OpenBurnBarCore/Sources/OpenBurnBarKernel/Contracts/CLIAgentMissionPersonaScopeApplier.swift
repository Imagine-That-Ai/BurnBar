import Foundation

// MARK: - CLI Agent Mission Persona Scope Applier (Hermes Square §6.5)
//
// Mac-side helper invoked by `CLIAgentMissionRequestListener` after it
// claims a mission. Reads the optional `personaScopeJSON` field on the
// request and surfaces it as a `PersonaScopeEnvelope` plus a small
// `RuntimeOverrides` struct the launch plumbing consumes.
//
// Phase B scope: the envelope is decoded, validated, and surfaced. Tool
// / file / shell allow-lists are appended to the existing
// `CLIAgentMissionDirectLaunchPlan.extraEnvironment` so the spawned CLI
// subprocess inherits them (read by Claude Code / Codex / OpenClaw via
// their respective envvars). System-prompt additions are similarly
// surfaced via env so the per-runtime adapter can splice them.

public enum CLIAgentMissionPersonaScopeApplier {

    public struct RuntimeOverrides: Equatable, Sendable {
        public let envelope: PersonaScopeEnvelope?
        public let extraEnvironment: [String: String]

        public static let empty = RuntimeOverrides(envelope: nil, extraEnvironment: [:])
    }

    /// Decode any `personaScopeJSON` carried by the mission request. Returns
    /// `.empty` when no scope is present; throws on malformed JSON so the
    /// listener surfaces a clear error instead of silently dispatching
    /// with default permissions.
    public static func overrides(from requestData: [String: Any]) throws -> RuntimeOverrides {
        guard
            let raw = requestData["personaScopeJSON"] as? String,
            !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .empty
        }
        let envelope = try PersonaScopeEnvelope.from(jsonString: raw)
        let env = buildEnvironment(from: envelope)
        return RuntimeOverrides(envelope: envelope, extraEnvironment: env)
    }

    /// Build a `BURNBAR_PERSONA_*` env namespace the per-runtime CLI
    /// adapter consumes. Keep keys boring so they grep cleanly in logs.
    public static func buildEnvironment(from envelope: PersonaScopeEnvelope) -> [String: String] {
        var env: [String: String] = [
            "BURNBAR_PERSONA_ID": envelope.personaID,
            "BURNBAR_PERSONA_AGENT_URI": envelope.agentURI,
            "BURNBAR_PERSONA_PERMIT_SHELL": envelope.permitShell ? "1" : "0",
            "BURNBAR_PERSONA_PERMIT_FILE_EDITS": envelope.permitFileEdits ? "1" : "0"
        ]
        if !envelope.permittedTools.isEmpty {
            env["BURNBAR_PERSONA_TOOLS_ALLOWLIST"] = envelope.permittedTools.joined(separator: ",")
        }
        if !envelope.permittedFileGlobs.isEmpty {
            env["BURNBAR_PERSONA_FILE_GLOBS"] = envelope.permittedFileGlobs.joined(separator: "\n")
        }
        if !envelope.permittedShellPrefixes.isEmpty {
            env["BURNBAR_PERSONA_SHELL_PREFIXES"] = envelope.permittedShellPrefixes.joined(separator: "\n")
        }
        if let additions = envelope.systemPromptAdditions, !additions.isEmpty {
            env["BURNBAR_PERSONA_SYSTEM_PROMPT"] = additions
        }
        if let model = envelope.preferredModel, !model.isEmpty {
            env["BURNBAR_PERSONA_MODEL"] = model
        }
        if let temp = envelope.temperatureOverride {
            env["BURNBAR_PERSONA_TEMPERATURE"] = String(format: "%.4f", temp)
        }
        return env
    }
}
