import Foundation
import OpenBurnBarCore

// MARK: - Assistant Model Catalog
//
// Today only Hermes and Pi advertise their model options over the wire
// (`HermesService.modelOptions` / `PiService.modelOptions`). The three CLI
// harnesses — Codex, Claude Code, OpenClaw — run on the user's Mac and
// don't broadcast a live list to mobile. To resolve the misrepresentation
// where iOS pretends "Hermes" is a model and stays silent about everyone
// else, we keep a small static catalog of the canonical models each CLI
// harness can reasonably be pointed at, and let the user pick one.
//
// The user's choice is persisted via `CLIAgentModelPreferences` and surfaced
// up the assistant tab. A future Mac-side change can read the preference
// from the mobile session record and pass `--model {id}` to the underlying
// CLI binary. Until then the iOS app is at least *truthful*: it shows what
// the harness has been using (from the most-recent session) and gives the
// user a real preference toggle for the next chat.

/// One row in the canonical model catalog. Mirrors `HermesRuntimeModelOption`
/// in shape so the same UI rows can render either source.
public struct AssistantModelOption: Hashable, Identifiable, Sendable {
    public var id: String { providerID + ":" + modelID }
    public let providerID: String
    public let providerName: String
    public let modelID: String
    public let displayName: String

    public init(providerID: String, providerName: String, modelID: String, displayName: String) {
        self.providerID = providerID
        self.providerName = providerName
        self.modelID = modelID
        self.displayName = displayName
    }
}

/// Static catalog of canonical models each CLI harness commonly runs on.
/// Intentionally short — the goal is "name the realistic choices a user
/// would pick", not "every model the CLI ever shipped".
public enum AssistantModelCatalog {

    public static func options(for runtime: AssistantRuntimeID) -> [AssistantModelOption] {
        switch runtime {
        case .hermes, .pi:
            // Hermes and Pi advertise their catalog live — the static list
            // is unused for them. Return [] so callers fall back to the
            // live `modelOptions` array.
            return []
        case .codex:
            return [
                AssistantModelOption(providerID: "openai", providerName: "OpenAI",
                                     modelID: "gpt-5-codex",
                                     displayName: "GPT-5 Codex"),
                AssistantModelOption(providerID: "openai", providerName: "OpenAI",
                                     modelID: "gpt-5",
                                     displayName: "GPT-5"),
                AssistantModelOption(providerID: "openai", providerName: "OpenAI",
                                     modelID: "o4-mini",
                                     displayName: "o4-mini"),
                AssistantModelOption(providerID: "openai", providerName: "OpenAI",
                                     modelID: "o3",
                                     displayName: "o3"),
            ]
        case .claude:
            return [
                AssistantModelOption(providerID: "anthropic", providerName: "Anthropic",
                                     modelID: "claude-opus-4-7",
                                     displayName: "Claude Opus 4.7"),
                AssistantModelOption(providerID: "anthropic", providerName: "Anthropic",
                                     modelID: "claude-sonnet-4-6",
                                     displayName: "Claude Sonnet 4.6"),
                AssistantModelOption(providerID: "anthropic", providerName: "Anthropic",
                                     modelID: "claude-haiku-4-5",
                                     displayName: "Claude Haiku 4.5"),
            ]
        case .openClaw:
            return [
                AssistantModelOption(providerID: "ollama", providerName: "Ollama",
                                     modelID: "qwen3-coder:30b",
                                     displayName: "Qwen3 Coder 30B"),
                AssistantModelOption(providerID: "ollama", providerName: "Ollama",
                                     modelID: "llama3.3:70b",
                                     displayName: "Llama 3.3 70B"),
                AssistantModelOption(providerID: "ollama", providerName: "Ollama",
                                     modelID: "deepseek-r1:32b",
                                     displayName: "DeepSeek R1 32B"),
                AssistantModelOption(providerID: "ollama", providerName: "Ollama",
                                     modelID: "gemma3:27b",
                                     displayName: "Gemma 3 27B"),
            ]
        }
    }

    /// Default selection used when the user hasn't expressed a preference
    /// yet. First entry in the catalog.
    public static func defaultOption(for runtime: AssistantRuntimeID) -> AssistantModelOption? {
        options(for: runtime).first
    }

    /// CLI harnesses where the iOS-side preference is honored "on the next
    /// session" rather than instantly applied (because the Mac CLI is the
    /// one that actually invokes the model). Used to surface honest copy
    /// in the picker UI.
    public static func appliesNextSession(_ runtime: AssistantRuntimeID) -> Bool {
        switch runtime {
        case .hermes, .pi: return false
        case .codex, .claude, .openClaw: return true
        }
    }
}

// MARK: - Preferences

/// Persistent storage for the user's preferred model for runtimes that
/// don't broadcast a live model list. Keyed per-runtime so a fresh install
/// can fall back to a sensible default without forgetting prior choices.
public enum CLIAgentModelPreferences {
    private static func key(for runtime: AssistantRuntimeID) -> String {
        "assistants.preferredModelID.\(runtime.rawValue)"
    }

    public static func preferredModelID(for runtime: AssistantRuntimeID,
                                        defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(for: runtime))
    }

    public static func setPreferredModelID(_ modelID: String?,
                                           for runtime: AssistantRuntimeID,
                                           defaults: UserDefaults = .standard) {
        if let modelID, !modelID.isEmpty {
            defaults.set(modelID, forKey: key(for: runtime))
        } else {
            defaults.removeObject(forKey: key(for: runtime))
        }
    }

    public static func preferredOption(for runtime: AssistantRuntimeID,
                                       defaults: UserDefaults = .standard) -> AssistantModelOption? {
        let options = AssistantModelCatalog.options(for: runtime)
        if let preferredID = preferredModelID(for: runtime, defaults: defaults),
           let match = options.first(where: { $0.modelID == preferredID }) {
            return match
        }
        return options.first
    }
}
