import Foundation

// MARK: - Memory Pro cloud providers

/// What a provider promises to do with memory text it receives.
enum MemoryProviderRetention: String, Codable, Sendable {
    /// The request is sent with retention disabled (OpenRouter `data_collection: deny`).
    case deny
    /// The provider's own policy applies; OpenBurnBar cannot enforce more.
    case providerPolicy
    /// The user's own subscription, through the official CLI, on this Mac.
    case localQuota
}

/// The providers a member can consent to for Memory Pro (extraction, judge,
/// embeddings, rerank, answers). Raw values are what the daemon policy stores:
/// the CLI ids match the courier's `cli` block, the API ids match daemon
/// provider ids. `MemoryProviderRetention` is the only thing the consent UI
/// promises about data handling; the daemon enforces it on every request.
enum MemoryCloudProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claudeCLI = "claude_cli"
    case codexCLI = "codex_cli"
    case openrouter
    case vercelAIGateway = "vercel-ai-gateway"
    case anthropic
    case openai

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCLI: "Claude Code (subscription)"
        case .codexCLI: "Codex CLI (subscription)"
        case .openrouter: "OpenRouter"
        case .vercelAIGateway: "Vercel AI Gateway"
        case .anthropic: "Anthropic"
        case .openai: "OpenAI"
        }
    }

    var retention: MemoryProviderRetention {
        switch self {
        case .claudeCLI, .codexCLI: .localQuota
        case .openrouter: .deny
        case .vercelAIGateway, .anthropic, .openai: .providerPolicy
        }
    }

    var retentionLabel: String {
        switch retention {
        case .deny: "No retention"
        case .providerPolicy: "Provider policy"
        case .localQuota: "Your subscription"
        }
    }

    /// CLI providers ride the existing "Use Mac CLI agents" consent.
    var requiresCLIConsent: Bool {
        switch self {
        case .claudeCLI, .codexCLI: true
        case .openrouter, .vercelAIGateway, .anthropic, .openai: false
        }
    }

    /// The daemon provider id whose credential slot must exist; nil for CLIs.
    var daemonProviderID: String? {
        switch self {
        case .claudeCLI, .codexCLI: nil
        case .openrouter, .vercelAIGateway, .anthropic, .openai: rawValue
        }
    }

    var requirementDescription: String {
        switch self {
        case .claudeCLI:
            "Runs `claude -p` on this Mac with your Claude subscription. Needs the Claude Code CLI installed and Mac CLI agents allowed."
        case .codexCLI:
            "Runs `codex exec` on this Mac with your ChatGPT subscription. Needs the Codex CLI installed and Mac CLI agents allowed."
        case .openrouter:
            "Uses your OpenRouter key from the daemon's Keychain store. Requests are sent with data collection denied, so only zero-retention routes are used."
        case .vercelAIGateway:
            "Uses your Vercel AI Gateway key from the daemon's Keychain store. Vercel's and the routed provider's retention policy apply."
        case .anthropic:
            "Uses your Anthropic API key from the daemon's Keychain store. Anthropic's API retention policy applies."
        case .openai:
            "Uses your OpenAI API key from the daemon's Keychain store. OpenAI's API retention policy applies."
        }
    }

    /// Decode a persisted JSON array of raw values, ignoring unknown ids.
    static func decodeList(_ json: String) -> [MemoryCloudProviderID] {
        guard let data = json.data(using: .utf8) else { return [] }
        let raw: [String]
        do {
            raw = try JSONDecoder().decode([String].self, from: data)
        } catch {
            return []  // a torn or foreign value means "no consented providers", never a crash
        }
        var seen: Set<MemoryCloudProviderID> = []
        return raw.compactMap { MemoryCloudProviderID(rawValue: $0) }.filter { seen.insert($0).inserted }
    }

    static func encodeList(_ ids: [MemoryCloudProviderID]) -> String {
        do {
            let data = try JSONEncoder().encode(ids.map(\.rawValue))
            return String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            return "[]"
        }
    }
}
