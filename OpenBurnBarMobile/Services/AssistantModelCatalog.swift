import Foundation
import OpenBurnBarCore

// MARK: - Assistant Model Catalog
//
// EVERY harness in OpenBurnBar is an *agent harness* that routes prompts
// to a real frontier LLM. Hermes and Pi are general-purpose harnesses
// that can run on any model the relay can reach. Codex / Claude Code /
// OpenClaw are CLI harnesses constrained by the vendor's binary (Codex
// runs on OpenAI, Claude Code runs on Anthropic, OpenClaw runs on local
// models).
//
// The catalog below is the source of truth for "what models can each
// harness reasonably be pointed at." When a harness's relay advertises a
// model list of its own (Hermes / Pi) we merge that in; when it doesn't,
// the catalog is what the user sees. That replaces the previous broken
// state where Hermes' picker only offered "Hermes Agent" — a self-loop
// that wasn't a model at all.

/// One row in the catalog. Mirrors `HermesRuntimeModelOption` in shape so
/// the same UI rows can render either source.
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

public enum AssistantModelCatalog {

    // MARK: - Master catalog (sorted by provider)
    //
    // Hermes and Pi both route to everything in this list. Order within
    // each provider is "newest, most capable first" so the default
    // selection feels right when a user hasn't picked anything yet.

    private static let anthropicModels: [AssistantModelOption] = [
        .init(providerID: "anthropic", providerName: "Anthropic",
              modelID: "claude-opus-4-7",   displayName: "Claude Opus 4.7"),
        .init(providerID: "anthropic", providerName: "Anthropic",
              modelID: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        .init(providerID: "anthropic", providerName: "Anthropic",
              modelID: "claude-haiku-4-5",  displayName: "Claude Haiku 4.5"),
    ]

    private static let openAIModels: [AssistantModelOption] = [
        .init(providerID: "openai", providerName: "OpenAI",
              modelID: "gpt-5.5",       displayName: "GPT-5.5"),
        .init(providerID: "openai", providerName: "OpenAI",
              modelID: "gpt-5",         displayName: "GPT-5"),
        .init(providerID: "openai", providerName: "OpenAI",
              modelID: "gpt-5-codex",   displayName: "GPT-5 Codex"),
        .init(providerID: "openai", providerName: "OpenAI",
              modelID: "o3",            displayName: "o3"),
        .init(providerID: "openai", providerName: "OpenAI",
              modelID: "o4-mini",       displayName: "o4-mini"),
    ]

    private static let googleModels: [AssistantModelOption] = [
        .init(providerID: "google", providerName: "Google",
              modelID: "gemini-2.5-pro",   displayName: "Gemini 2.5 Pro"),
        .init(providerID: "google", providerName: "Google",
              modelID: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
    ]

    private static let minimaxModels: [AssistantModelOption] = [
        .init(providerID: "minimax", providerName: "MiniMax",
              modelID: "minimax-2.7",  displayName: "MiniMax 2.7"),
        .init(providerID: "minimax", providerName: "MiniMax",
              modelID: "minimax-m2",   displayName: "MiniMax M2"),
    ]

    private static let zaiModels: [AssistantModelOption] = [
        .init(providerID: "zai", providerName: "Z.ai",
              modelID: "glm-5.1",  displayName: "GLM 5.1"),
        .init(providerID: "zai", providerName: "Z.ai",
              modelID: "glm-4.6",  displayName: "GLM 4.6"),
    ]

    private static let moonshotModels: [AssistantModelOption] = [
        .init(providerID: "kimi", providerName: "Moonshot",
              modelID: "kimi-k2.6",  displayName: "Kimi K2.6"),
        .init(providerID: "kimi", providerName: "Moonshot",
              modelID: "kimi-k2",    displayName: "Kimi K2"),
    ]

    private static let deepseekModels: [AssistantModelOption] = [
        .init(providerID: "deepseek", providerName: "DeepSeek",
              modelID: "deepseek-v3.1",  displayName: "DeepSeek V3.1"),
        .init(providerID: "deepseek", providerName: "DeepSeek",
              modelID: "deepseek-r1",    displayName: "DeepSeek R1"),
    ]

    private static let xaiModels: [AssistantModelOption] = [
        .init(providerID: "xai", providerName: "xAI",
              modelID: "grok-4",  displayName: "Grok 4"),
    ]

    private static let qwenModels: [AssistantModelOption] = [
        .init(providerID: "ollama", providerName: "Qwen (local)",
              modelID: "qwen3-coder:480b",  displayName: "Qwen 3 Coder 480B"),
        .init(providerID: "ollama", providerName: "Qwen (local)",
              modelID: "qwen3:235b",        displayName: "Qwen 3 235B"),
    ]

    private static let metaModels: [AssistantModelOption] = [
        .init(providerID: "ollama", providerName: "Meta (local)",
              modelID: "llama3.3:70b",  displayName: "Llama 3.3 70B"),
    ]

    private static let localOllamaModels: [AssistantModelOption] = [
        .init(providerID: "ollama", providerName: "Qwen (local)",
              modelID: "qwen3-coder:30b",   displayName: "Qwen 3 Coder 30B"),
        .init(providerID: "ollama", providerName: "Meta (local)",
              modelID: "llama3.3:70b",      displayName: "Llama 3.3 70B"),
        .init(providerID: "ollama", providerName: "DeepSeek (local)",
              modelID: "deepseek-r1:32b",   displayName: "DeepSeek R1 32B"),
        .init(providerID: "ollama", providerName: "Google (local)",
              modelID: "gemma3:27b",        displayName: "Gemma 3 27B"),
    ]

    /// Routable models for Hermes / Pi — the "anything goes" set. These
    /// harnesses ride on the OpenBurnBar relay which routes to any
    /// connected provider, so the catalog is intentionally broad.
    private static let universalCatalog: [AssistantModelOption] = {
        anthropicModels
            + openAIModels
            + googleModels
            + xaiModels
            + minimaxModels
            + zaiModels
            + moonshotModels
            + deepseekModels
            + qwenModels
            + metaModels
    }()

    public static func options(for runtime: AssistantRuntimeID) -> [AssistantModelOption] {
        switch runtime {
        case .hermes, .pi, .codex, .claude, .openClaw:
            // Every harness is exactly that — a harness. The underlying
            // LLM is a separate, orthogonal choice routed through the
            // OpenBurnBar relay, so the catalog is the same broad set
            // across all of them. The harness defines the prompt + tool
            // semantics, the model defines the brain.
            return universalCatalog
        }
    }

    /// Default selection used when the user hasn't expressed a preference
    /// yet. First entry in the catalog — newest, most capable.
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

    /// Resolve a saved `modelID` back to a catalog entry. Used by the
    /// picker to highlight which model the user is on regardless of which
    /// harness happens to have advertised it.
    public static func option(forModelID modelID: String,
                              in runtime: AssistantRuntimeID) -> AssistantModelOption? {
        options(for: runtime).first { $0.modelID == modelID }
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
