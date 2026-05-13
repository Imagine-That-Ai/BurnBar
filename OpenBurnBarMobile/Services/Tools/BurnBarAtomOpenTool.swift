import Foundation
import OpenBurnBarCore

// MARK: - burnbar_atom_open
//
// Lets Hermes / Pi navigate the iOS app on the user's behalf. The model
// emits a single argument — a fully-formed `burnbar://...` URL — and the
// tool decodes it to a typed `HermesAtom` and fires the atom router so
// the chat surface presents the matching detail sheet.
//
// We re-use the existing `HermesAtomURL.decode(_:)` from OpenBurnBarCore
// to keep the URL grammar in lockstep with the prose atom directive that
// `HermesSystemPromptBuilder` already ships to the model.

@MainActor
public struct BurnBarAtomOpenTool: MobileTool {

    public init() {}

    public static let name = "burnbar_atom_open"

    public var displayName: String { "Open in BurnBar" }

    public var description: String {
        """
        Open a screen inside the OpenBurnBar iOS app. Use this when the user \
        asks to "go to", "show me", or "open" any of the entities that \
        OpenBurnBar has a native surface for — costs, providers, sessions, \
        models, time windows, projects, tools, token totals, quotas, or \
        Hermes runtime profiles.

        Pass a fully-formed `burnbar://` URL in `atom_url`. See the atom \
        directive in the system prompt for the URL grammar and examples. \
        Returns a short confirmation string the assistant can echo to the \
        user, plus a brief description of which screen was opened.

        Only call this for entities the user has actually referenced in \
        the conversation. Do not invent session ids, project ids, or model \
        ids you have not seen in context.
        """
    }

    public var parametersSchema: [String: Any] {
        MobileToolJSONSchema.object(
            properties: [
                "atom_url": MobileToolJSONSchema.string(
                    description: """
                    Canonical burnbar:// URL identifying the screen to open. \
                    Examples: \
                    `burnbar://session?id=abc-123`, \
                    `burnbar://window?value=7d`, \
                    `burnbar://provider?token=anthropic`, \
                    `burnbar://quota?provider=openai&percent=78`.
                    """
                )
            ],
            required: ["atom_url"],
            description: "Navigate the iOS app to a specific BurnBar surface."
        )
    }

    public func execute(
        arguments: String,
        context: any MobileToolContext
    ) async throws -> String {
        guard let urlString = try stringArgument("atom_url", in: arguments) else {
            throw MobileToolError.invalidArguments(
                "missing required argument `atom_url`"
            )
        }

        guard let atom = HermesAtomURL.decode(urlString) else {
            throw MobileToolError.invalidArguments(
                "could not decode `\(urlString)` — expected a burnbar:// URL"
            )
        }

        guard let navigator = context.atomNavigator else {
            throw MobileToolError.toolDisabled(
                "atom navigation is not available in this context"
            )
        }

        navigator.open(atom)

        // Hand the model a structured, predictable confirmation it can
        // paraphrase back to the user. We deliberately echo the
        // canonical URL so multi-tool transcripts stay grep-able.
        let payload: [String: Any] = [
            "opened": true,
            "atom_kind": atom.kind.rawValue,
            "label": atom.fallbackLabel,
            "atom_url": HermesAtomURL.encode(atom).absoluteString
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "Opened \(atom.kind.rawValue): \(atom.fallbackLabel)"
    }
}
