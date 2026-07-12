import Foundation

/// Builds the system prompt and serialized payload shipped to the model.
///
/// The prompt enforces:
///   • Only emit JSON matching the canvas schema.
///   • Only use taxonomy tags from the supplied glossary.
///   • Only call read-only tools.
///   • Cite findings with `InsightCitation` chips.
///   • Stay under the requested `maxNewWidgets`.
public struct InsightPromptEngine: Sendable {

    public init() {}

    /// Produce the system prompt for an investigation request.
    public func systemPrompt(for request: InsightInvestigateRequest,
                             actualTier: InsightCapabilityTier) -> String {
        var lines: [String] = []
        lines.append(Self.preamble)
        lines.append("")
        lines.append("# Available widget kinds")
        for k in InsightWidgetKind.allCases where k != .error {
            lines.append("  • `\(k.rawValue)` — \(k.displayName)")
        }
        lines.append("")
        lines.append("# Taxonomy (only allowed tag values)")
        lines.append("## Focuses")
        lines.append(request.digest.glossary.focuses.joined(separator: ", "))
        lines.append("## Use cases")
        lines.append(request.digest.glossary.useCases.joined(separator: ", "))
        lines.append("")
        lines.append("# Response constraints")
        lines.append("- Emit a single JSON object matching the `InsightCanvas` schema.")
        lines.append("- Emit at most \(request.maxNewWidgets) widgets.")
        lines.append("- Every narrative or recommendation widget MUST include at least one citation.")
        lines.append("- Strict tier: \(actualTier.displayName).")
        if !request.allowToolCalls {
            lines.append("- Tool calls are disabled for this investigation.")
        }
        lines.append("")
        lines.append("# Instruction")
        lines.append(Self.instructionDescription(request.instruction))
        return lines.joined(separator: "\n")
    }

    /// JSON-encoded payload to send as the user turn. Includes digest + prompt.
    public func userPayload(for request: InsightInvestigateRequest) throws -> Data {
        struct Payload: Encodable {
            let prompt: String
            let instruction: String
            let existingCanvas: InsightCanvas?
            let widget: InsightWidget?
            let digest: InsightDigest
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Payload(
            prompt: request.prompt,
            instruction: request.instruction.rawValue,
            existingCanvas: request.canvas,
            widget: request.widget,
            digest: request.digest
        ))
    }

    public static let preamble = """
    You are the Insights analyst inside OpenBurnBar — a desktop and mobile
    tool that helps developers understand how they use AI coding agents.
    Your job is to investigate the provided digest and produce a clear,
    beautiful, evidence-driven canvas of widgets that surfaces:

      • usage patterns (when, with whom, what for)
      • per-agent and per-model focuses and use cases
      • cost / efficiency / cache observations
      • risks, anomalies, and surprises
      • crisp, specific, actionable recommendations

    Be specific. Prefer concrete numbers (and cite them via `citations`)
    over generic platitudes. Never fabricate sessions, models, or
    projects that don't appear in the digest. Never include source code,
    credentials, or file paths. Stay within the taxonomy.
    """

    public static func instructionDescription(_ instruction: InsightInvestigateRequest.Instruction) -> String {
        switch instruction {
        case .composeCanvas:
            return "Author a fresh canvas of widgets that explains the prompt using the digest. Aim for a balanced spread: 2 KPI tiles, 1–2 charts, 1 narrative, and (if warranted) 1 recommendation."
        case .refineCanvas:
            return "Refine the existing canvas based on the prompt. Keep widgets the user has clearly relied on; replace or add widgets where the prompt calls for it. Preserve widget ids when reusing them."
        case .refreshNarratives:
            return "Only replace narrative and recommendation widgets. Leave numeric widgets and layout intact."
        case .refineWidget:
            return "Re-emit the supplied widget with improved title, subtitle, and rationale that more directly answer the prompt."
        case .explainBriefly:
            return "Produce a single narrative widget that explains the prompt in 2–4 sentences."
        }
    }
}
