import Foundation

enum CrossEncoderProviderID: String, CaseIterable, Codable, Identifiable {
    case codexCLI = "codex_cli"
    case claudeCLI = "claude_cli"
    case minimax
    case zai
    case openrouter
    case ollama
    case hermes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codexCLI:
            return "Codex CLI"
        case .claudeCLI:
            return "Claude"
        case .minimax:
            return "MiniMax"
        case .zai:
            return "Z.ai"
        case .openrouter:
            return "OpenRouter"
        case .ollama:
            return "Ollama"
        case .hermes:
            return "Hermes"
        }
    }

    var requiresCLIConsent: Bool {
        switch self {
        case .codexCLI, .claudeCLI:
            return true
        case .minimax, .zai, .openrouter, .ollama, .hermes:
            return false
        }
    }

    var apiKeyAccount: String? {
        switch self {
        case .minimax:
            return "minimax"
        case .zai:
            return "zai"
        case .openrouter:
            return "openrouter"
        case .ollama:
            return "ollama"
        case .codexCLI, .claudeCLI, .hermes:
            return nil
        }
    }

    var baseURL: String? {
        switch self {
        case .minimax:
            return "https://api.minimax.io/v1"
        case .zai:
            return "https://api.z.ai/api/coding/paas/v4"
        case .openrouter:
            return "https://openrouter.ai/api/v1"
        case .ollama:
            return "http://localhost:11434/v1"
        case .hermes:
            return "http://localhost:8642/v1"
        case .codexCLI, .claudeCLI:
            return nil
        }
    }

    var includesOpenRouterHeaders: Bool {
        self == .openrouter
    }

    var requirementDescription: String {
        switch self {
        case .codexCLI:
            return "Uses your local `codex` binary. Requires the CLI permission toggle above and `codex` on PATH."
        case .claudeCLI:
            return "Uses your local `claude` binary. Requires the CLI permission toggle above and `claude` on PATH."
        case .minimax:
            return "Requires a MiniMax API key in OpenBurnBar’s provider settings."
        case .zai:
            return "Requires a Z.ai API key in OpenBurnBar’s provider settings."
        case .openrouter:
            return "Requires an OpenRouter API key in OpenBurnBar’s provider settings."
        case .ollama:
            return "Local Ollama server. Ensure `ollama serve` is running on the configured host."
        case .hermes:
            return "Hermes gateway on `http://localhost:8642` — enable API_SERVER_ENABLED in ~/.hermes/.env, run hermes gateway run. Token in OpenBurnBar only if you set API_SERVER_KEY in that file."
        }
    }
}

struct CrossEncoderModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

enum CrossEncoderCatalog {
    private static let modelsByProvider: [CrossEncoderProviderID: [CrossEncoderModelOption]] = [
        .codexCLI: [
            CrossEncoderModelOption(id: "gpt-5.5", displayName: "GPT-5.5"),
            CrossEncoderModelOption(id: "gpt-5.5-mini", displayName: "GPT-5.5 Mini"),
            CrossEncoderModelOption(id: "gpt-5.5-nano", displayName: "GPT-5.5 Nano"),
            CrossEncoderModelOption(id: "gpt-5.5-pro", displayName: "GPT-5.5 Pro"),
            CrossEncoderModelOption(id: "gpt-5.4", displayName: "GPT-5.4"),
            CrossEncoderModelOption(id: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
            CrossEncoderModelOption(id: "gpt-5.4-nano", displayName: "GPT-5.4 Nano"),
            CrossEncoderModelOption(id: "gpt-5.4-pro", displayName: "GPT-5.4 Pro"),
            CrossEncoderModelOption(id: "gpt-5.3-codex", displayName: "GPT-5.3 Codex"),
            CrossEncoderModelOption(id: "gpt-5.2-codex", displayName: "GPT-5.2 Codex"),
            CrossEncoderModelOption(id: "gpt-5.2-pro", displayName: "GPT-5.2 Pro"),
            CrossEncoderModelOption(id: "gpt-5.1-codex", displayName: "GPT-5.1 Codex"),
            CrossEncoderModelOption(id: "gpt-5.1-codex-mini", displayName: "GPT-5.1 Codex Mini"),
            CrossEncoderModelOption(id: "gpt-5.1-codex-max", displayName: "GPT-5.1 Codex Max")
        ],
        .claudeCLI: [
            CrossEncoderModelOption(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
            CrossEncoderModelOption(id: "claude-sonnet-4-5", displayName: "Claude Sonnet 4.5"),
            CrossEncoderModelOption(id: "claude-sonnet-4", displayName: "Claude Sonnet 4"),
            CrossEncoderModelOption(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
            CrossEncoderModelOption(id: "claude-opus-4-7", displayName: "Claude Opus 4.7"),
            CrossEncoderModelOption(id: "claude-opus-4-6", displayName: "Claude Opus 4.6"),
            CrossEncoderModelOption(id: "claude-opus-4-5", displayName: "Claude Opus 4.5"),
            CrossEncoderModelOption(id: "claude-opus-4", displayName: "Claude Opus 4")
        ],
        .minimax: [
            CrossEncoderModelOption(id: "minimax-m2.7-highspeed", displayName: "MiniMax M2.7 Highspeed")
        ],
        .zai: [
            CrossEncoderModelOption(id: "glm-5", displayName: "GLM-5"),
            CrossEncoderModelOption(id: "glm-5-code", displayName: "GLM-5 Code"),
            CrossEncoderModelOption(id: "glm-5-turbo", displayName: "GLM-5 Turbo")
        ],
        .openrouter: [
            CrossEncoderModelOption(id: "qwen/qwen3.5-9b", displayName: "Qwen 3.5 9B"),
            CrossEncoderModelOption(id: "openai/gpt-5-nano", displayName: "GPT-5 Nano"),
            CrossEncoderModelOption(id: "openai/gpt-5-mini", displayName: "GPT-5 Mini"),
            CrossEncoderModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            CrossEncoderModelOption(id: "z-ai/glm-5", displayName: "GLM-5")
        ],
        .hermes: [
            CrossEncoderModelOption(id: "hermes", displayName: "Hermes")
        ],
        .ollama: [
            CrossEncoderModelOption(id: "llama3.2", displayName: "Llama 3.2"),
            CrossEncoderModelOption(id: "qwen2.5-coder", displayName: "Qwen 2.5 Coder"),
            CrossEncoderModelOption(id: "gemma3", displayName: "Gemma 3")
        ]
    ]

    static func modelOptions(for provider: CrossEncoderProviderID) -> [CrossEncoderModelOption] {
        modelsByProvider[provider] ?? []
    }

    static func defaultModel(for provider: CrossEncoderProviderID) -> String {
        modelOptions(for: provider).first?.id ?? ""
    }

    static func normalizedModel(_ model: String, provider: CrossEncoderProviderID) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return defaultModel(for: provider)
        }

        if let canonical = modelOptions(for: provider).first(where: {
            $0.id.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return canonical.id
        }

        return defaultModel(for: provider)
    }
}
