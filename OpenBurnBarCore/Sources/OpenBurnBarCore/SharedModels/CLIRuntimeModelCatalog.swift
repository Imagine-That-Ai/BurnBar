import Foundation

public enum OpenBurnBarModelDisplayName {
    public static func compose(
        modelName: String,
        providerName: String? = nil,
        providerID: String? = nil,
        routeName: String? = "OpenBurnBar",
        reasoningLevel: String? = nil,
        defaultReasoning: String = "default"
    ) -> String {
        let model = cleaned(modelName) ?? "Unknown model"
        let provider = providerLabel(providerID: providerID, providerName: providerName)
        let route = cleaned(routeName).map { "via \($0)" }
        let reasoning = "Reasoning: \(reasoningLabel(reasoningLevel, fallback: defaultReasoning))"

        var segments: [String] = []
        append(model, to: &segments)
        if let provider, !containsSegment(model, provider) {
            append(provider, to: &segments)
        }
        if let route, !containsSegment(model, route) {
            append(route, to: &segments)
        }
        if !containsSegment(model, "Reasoning:") {
            append(reasoning, to: &segments)
        }
        return segments.joined(separator: " · ")
    }

    public static func providerLabel(providerID: String?, providerName: String? = nil) -> String? {
        let trimmedName = cleaned(providerName)
        let normalizedName = trimmedName?.lowercased() ?? ""
        if let trimmedName,
           !normalizedName.contains("via openburnbar"),
           !normalizedName.contains("openburnbar proxy"),
           !normalizedName.contains("api/oauth") {
            return trimmedName
        }

        guard let providerID = cleaned(providerID)?.lowercased() else {
            return trimmedName
        }

        switch providerID {
        case "anthropic", "claude":
            return "Anthropic"
        case "openai", "codex":
            return "OpenAI"
        case "google", "gemini":
            return "Google"
        case "zai", "z.ai", "glm":
            return "Z.ai"
        case "kimi", "moonshot":
            return "Moonshot Kimi"
        case "kimicoding":
            return "KimiCoding"
        case "deepseek":
            return "DeepSeek"
        case "minimax":
            return "MiniMax"
        case "mistral":
            return "Mistral"
        case "qwen", "alibaba":
            return "Alibaba Qwen"
        case "nvidia", "nemotron":
            return "NVIDIA"
        case "xai", "grok":
            return "xAI"
        case "factory", "factory-custom":
            return "Factory"
        case "openrouter":
            return "OpenRouter"
        case "ollama":
            return "Ollama"
        case "forge-dev":
            return "Forge"
        case "openburnbar":
            return "OpenBurnBar"
        default:
            return providerID
                .split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    public static func reasoningLabel(_ raw: String?, fallback: String = "default") -> String {
        let value = cleaned(raw) ?? fallback
        let normalized = value
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        switch normalized {
        case "cli-default":
            return "CLI default"
        case "agent-default":
            return "agent default"
        case "xhigh", "extra-high", "extra-high-reasoning":
            return "extra high"
        case "high":
            return "high"
        case "medium", "med":
            return "medium"
        case "low":
            return "low"
        case "max":
            return "max"
        case "none", "no-reasoning", "not-applicable":
            return "none"
        case "default":
            return "default"
        default:
            return value
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func append(_ value: String, to segments: inout [String]) {
        let normalized = normalize(value)
        guard !segments.contains(where: { normalize($0) == normalized }) else { return }
        segments.append(value)
    }

    private static func containsSegment(_ haystack: String, _ needle: String) -> Bool {
        normalize(haystack).contains(normalize(needle))
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CLIRuntimeModelSource: String, Codable, Hashable, Sendable {
    case cliProfile
    case droidStandardQuota
    case droidCoreQuota
    case droidCustomModel
    case openBurnBarProxy
    case forgeAgent
    case antigravityProfile
    case cursorAgentProfile
    case codexModelCatalog
    case grokModelCatalog

    public var displayLabel: String {
        switch self {
        case .cliProfile:
            return "CLI profile"
        case .droidStandardQuota:
            return "Droid Standard quota"
        case .droidCoreQuota:
            return "Droid Core quota"
        case .droidCustomModel:
            return "Droid custom model"
        case .openBurnBarProxy:
            return "OpenBurnBar proxy"
        case .forgeAgent:
            return "Forge agent"
        case .antigravityProfile:
            return "Antigravity CLI profile"
        case .cursorAgentProfile:
            return "Cursor Agent CLI profile"
        case .codexModelCatalog:
            return "Codex live catalog"
        case .grokModelCatalog:
            return "Grok live catalog"
        }
    }

    public var detailLabel: String {
        switch self {
        case .cliProfile:
            return "Uses this Mac CLI profile's subscription or auth."
        case .droidStandardQuota:
            return "Consumes Droid Standard quota."
        case .droidCoreQuota:
            return "Consumes Droid Core quota."
        case .droidCustomModel:
            return "Uses a custom model configured in this Mac's Droid CLI."
        case .openBurnBarProxy:
            return "Uses API/OAuth through OpenBurnBar, not Droid quota."
        case .forgeAgent:
            return "Runs the selected Forge agent."
        case .antigravityProfile:
            return "Uses this Mac's Google Antigravity CLI auth and quota."
        case .cursorAgentProfile:
            return "Uses this Mac's Cursor Agent CLI auth and quota."
        case .codexModelCatalog:
            return "Discovered from this Mac's Codex CLI model catalog."
        case .grokModelCatalog:
            return "Discovered from this Mac's Grok Build CLI model catalog."
        }
    }

    public var showsOpenBurnBarProxyBadge: Bool {
        self == .openBurnBarProxy
    }
}

public struct CLIRuntimeModelOption: Codable, Hashable, Identifiable, Sendable {
    public var id: String { modelID }

    public let modelID: String
    public let displayName: String
    public let providerID: String
    public let providerName: String
    public let tier: String
    public let source: CLIRuntimeModelSource

    public init(
        modelID: String,
        displayName: String,
        providerID: String,
        providerName: String,
        tier: String = "mid",
        source: CLIRuntimeModelSource = .cliProfile
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.tier = tier
        self.source = source
    }
}

public struct CLIRuntimeModelCatalogRequest: Codable, Hashable, Sendable {
    public let runtime: String

    public init(runtime: String) {
        self.runtime = runtime
    }
}

public struct CLIRuntimeModelCatalogResponse: Codable, Hashable, Sendable {
    public let runtime: String
    public let machineName: String?
    public let generatedAtEpochMillis: Int64
    public let options: [CLIRuntimeModelOption]

    public init(
        runtime: String,
        machineName: String? = nil,
        generatedAtEpochMillis: Int64,
        options: [CLIRuntimeModelOption]
    ) {
        self.runtime = runtime
        self.machineName = machineName
        self.generatedAtEpochMillis = generatedAtEpochMillis
        self.options = options
    }
}

public enum CLIRuntimeModelCatalog {
    public static func defaultProfileOption(for runtime: AssistantRuntimeID) -> CLIRuntimeModelOption? {
        switch runtime {
        case .codex:
            return option(
                "",
                OpenBurnBarModelDisplayName.compose(
                    modelName: "Codex CLI default",
                    providerName: "OpenAI",
                    providerID: "openai",
                    reasoningLevel: "CLI default"
                ),
                "openai",
                "OpenAI via Codex CLI"
            )
        case .claude:
            return option(
                "",
                OpenBurnBarModelDisplayName.compose(
                    modelName: "Claude Code default",
                    providerName: "Anthropic",
                    providerID: "anthropic",
                    reasoningLevel: "CLI default"
                ),
                "anthropic",
                "Anthropic via Claude Code CLI"
            )
        case .antigravity:
            return antigravityProfileOption(modelName: nil)
        case .grok:
            return option(
                "grok-build-0.1",
                OpenBurnBarModelDisplayName.compose(
                    modelName: "Grok Build 0.1",
                    providerName: "xAI",
                    providerID: "xai",
                    reasoningLevel: "CLI default"
                ),
                "xai",
                "xAI via Grok Build CLI"
            )
        case .cursorAgent:
            return option(
                "",
                OpenBurnBarModelDisplayName.compose(
                    modelName: "Cursor Agent default",
                    providerName: "Cursor",
                    providerID: "cursor",
                    reasoningLevel: "CLI default"
                ),
                "cursor",
                "Cursor via Cursor Agent CLI",
                source: .cursorAgentProfile
            )
        case .droid, .forge, .hermes, .pi, .openClaw:
            return nil
        }
    }

    public static func parseDroidExecHelp(_ text: String) -> [CLIRuntimeModelOption] {
        enum Section {
            case none
            case available
            case custom
        }

        var section = Section.none
        var rows: [CLIRuntimeModelOption] = []
        var seen = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "Available Models:" {
                section = .available
                continue
            }
            if trimmed == "Custom Models:" {
                section = .custom
                continue
            }
            if trimmed.hasSuffix(":"),
               section != .none,
               trimmed != "Available Models:",
               trimmed != "Custom Models:" {
                section = .none
                continue
            }
            guard section != .none,
                  let parsed = parseCatalogLine(rawLine),
                  seen.insert(parsed.modelID).inserted else {
                continue
            }

            switch section {
            case .available:
                rows.append(droidAvailableOption(modelID: parsed.modelID, displayName: parsed.displayName))
            case .custom:
                rows.append(droidCustomOption(modelID: parsed.modelID, displayName: parsed.displayName))
            case .none:
                break
            }
        }

        return rows
    }

    public static func parseForgeAgentList(_ text: String) -> [CLIRuntimeModelOption] {
        var rows: [CLIRuntimeModelOption] = []
        var current: [String: String] = [:]
        var seen = Set<String>()

        func flush() {
            guard let id = current["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty,
                  seen.insert(id).inserted else {
                current = [:]
                return
            }
            let title = current["title"]?.nonEmpty ?? id.capitalized
            let provider = current["provider"]?.nonEmpty ?? "forge-dev"
            let model = current["model"]?.nonEmpty
            let providerName = model.map { "\(provider) / \($0)" } ?? provider
            rows.append(option(
                id,
                OpenBurnBarModelDisplayName.compose(
                    modelName: title,
                    providerName: providerName,
                    providerID: provider.lowercased(),
                    reasoningLevel: "agent default"
                ),
                provider.lowercased(),
                providerName,
                source: .forgeAgent
            ))
            current = [:]
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                flush()
                continue
            }
            for key in ["id", "title", "provider", "model"] {
                if let value = fieldValue(from: trimmed, key: key) {
                    current[key] = value
                    break
                }
            }
        }
        flush()
        return rows
    }

    public static func parseCodexDebugModels(_ data: Data) -> [CLIRuntimeModelOption] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else {
            return []
        }
        var rows: [CLIRuntimeModelOption] = []
        var seen = Set<String>()
        for model in models {
            let visibility = (model["visibility"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard visibility != "hide" else { continue }
            let rawSlug = ((model["slug"] as? String)
                ?? (model["id"] as? String)
                ?? (model["model"] as? String)
                ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = normalizedCodexModel(rawSlug)
            guard !modelID.isEmpty, seen.insert(modelID.lowercased()).inserted else { continue }
            let display = ((model["display_name"] as? String)
                ?? (model["name"] as? String)
                ?? modelID)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoning = (model["default_reasoning_level"] as? String)?.nonEmpty ?? "CLI default"
            rows.append(option(
                modelID,
                OpenBurnBarModelDisplayName.compose(
                    modelName: display.isEmpty ? modelID : display,
                    providerName: "OpenAI",
                    providerID: "openai",
                    reasoningLevel: reasoning
                ),
                "openai",
                "OpenAI via Codex CLI",
                tier: inferredTier(modelID: modelID, displayName: display),
                source: .codexModelCatalog
            ))
        }
        return rows
    }

    public static func parseGrokModels(_ text: String) -> [CLIRuntimeModelOption] {
        var rows: [CLIRuntimeModelOption] = []
        var seen = Set<String>()
        var inModels = false

        for rawLine in text.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased() == "available models:" {
                inModels = true
                continue
            }
            guard inModels else { continue }
            let stripped = trimmed
                .replacingOccurrences(of: #"^[*\-•]\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let modelID = stripped
                .replacingOccurrences(of: #"\s+\(default\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelID.isEmpty, seen.insert(modelID.lowercased()).inserted else { continue }
            rows.append(option(
                modelID,
                OpenBurnBarModelDisplayName.compose(
                    modelName: modelID,
                    providerName: "xAI",
                    providerID: "xai",
                    reasoningLevel: "CLI default"
                ),
                "xai",
                "xAI via Grok Build CLI",
                tier: inferredTier(modelID: modelID, displayName: modelID),
                source: .grokModelCatalog
            ))
        }
        return rows
    }

    public static func antigravityProfileOption(modelName: String?) -> CLIRuntimeModelOption {
        let selected = modelName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "Antigravity default"
        return option(
            selected == "Antigravity default" ? "" : selected,
            OpenBurnBarModelDisplayName.compose(
                modelName: selected,
                providerName: "Google",
                providerID: "google",
                reasoningLevel: "CLI default"
            ),
            "google",
            "Google via Antigravity CLI",
            source: .antigravityProfile
        )
    }

    public static func normalizedCodexModel(_ model: String, fallback: String = "") -> String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return fallback }
        return slugAliases[trimmedModel.lowercased()] ?? trimmedModel
    }

    private static let slugAliases: [String: String] = [
        "gpt-5-5": "gpt-5.5",
        "gpt-5-5-mini": "gpt-5.5-mini",
        "gpt-5-5-nano": "gpt-5.5-nano",
        "gpt-5-5-pro": "gpt-5.5-pro",
        "gpt-5-4": "gpt-5.4",
        "gpt-5-4-mini": "gpt-5.4-mini",
        "gpt-5-4-nano": "gpt-5.4-nano",
        "gpt-5-4-pro": "gpt-5.4-pro",
        "gpt-5-3-codex": "gpt-5.3-codex",
        "gpt-5-3-codex-spark": "gpt-5.3-codex-spark",
        "gpt-5-3-codex-fast": "gpt-5.3-codex-fast",
        "gpt-5-2-codex": "gpt-5.2-codex",
        "gpt-5-2-pro": "gpt-5.2-pro",
        "gpt-5-1-codex": "gpt-5.1-codex",
        "gpt-5-1-codex-mini": "gpt-5.1-codex-mini",
        "gpt-5-1-codex-max": "gpt-5.1-codex-max",
        "glm-5-1": "glm-5.1",
        "kimi-k2-6": "kimi-k2.6",
        "kimi-k2-5": "kimi-k2.5",
        "minimax-m2-7": "minimax-m2.7",
        "minimax-m2-5": "minimax-m2.5"
    ]

    private static func parseCatalogLine(_ line: String) -> (modelID: String, displayName: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: .whitespaces)
        guard let modelID = parts.first, !modelID.isEmpty else { return nil }
        let rest = trimmed.dropFirst(modelID.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return nil }
        return (modelID, cleanupDisplayName(rest))
    }

    private static func cleanupDisplayName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s+\(default\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fieldValue(from line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let remainder = line.dropFirst(key.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : String(remainder)
    }

    private static func droidAvailableOption(
        modelID: String,
        displayName: String
    ) -> CLIRuntimeModelOption {
        if displayName.lowercased().hasPrefix("droid core") {
            return droidCoreOption(modelID, displayName, tier: inferredTier(modelID: modelID, displayName: displayName))
        }
        return droidStandardOption(modelID, displayName, tier: inferredTier(modelID: modelID, displayName: displayName))
    }

    private static func droidCustomOption(
        modelID: String,
        displayName: String
    ) -> CLIRuntimeModelOption {
        let isOpenBurnBar = modelID.localizedCaseInsensitiveContains("OpenBurnBar")
            || modelID.localizedCaseInsensitiveContains("Open-Code-Go")
            || displayName.localizedCaseInsensitiveContains("OpenBurnBar")
        let cleanedDisplay = displayName
            .replacingOccurrences(of: #"^OpenBurnBar\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = inferredProviderID(modelID: modelID, displayName: displayName)
        if isOpenBurnBar {
            return openBurnBarProxyOption(
                modelID,
                cleanedDisplay.isEmpty ? displayName : cleanedDisplay,
                providerID,
                tier: inferredTier(modelID: modelID, displayName: displayName)
            )
        }
        return option(
            modelID,
            OpenBurnBarModelDisplayName.compose(
                modelName: displayName,
                providerName: "Droid custom model",
                providerID: providerID == "openburnbar" ? "factory-custom" : providerID,
                reasoningLevel: "CLI default"
            ),
            providerID == "openburnbar" ? "factory-custom" : providerID,
            "Droid custom model",
            tier: inferredTier(modelID: modelID, displayName: displayName),
            source: .droidCustomModel
        )
    }

    private static func inferredProviderID(modelID: String, displayName: String) -> String {
        let haystack = "\(modelID) \(displayName)".lowercased()
        if haystack.contains("claude") || haystack.contains("anthropic") { return "anthropic" }
        if haystack.contains("gpt") || haystack.contains("openai") || haystack.contains("codex") { return "openai" }
        if haystack.contains("gemini") || haystack.contains("gemma") || haystack.contains("google") { return "google" }
        if haystack.contains("glm") || haystack.contains("zai") { return "zai" }
        if haystack.contains("kimi") { return "kimi" }
        if haystack.contains("deepseek") { return "deepseek" }
        if haystack.contains("minimax") { return "minimax" }
        if haystack.contains("mistral") || haystack.contains("ministral") || haystack.contains("devstral") { return "mistral" }
        if haystack.contains("qwen") { return "qwen" }
        if haystack.contains("nemotron") || haystack.contains("nvidia") { return "nvidia" }
        return "openburnbar"
    }

    private static func inferredTier(modelID: String, displayName: String) -> String {
        let haystack = "\(modelID) \(displayName)".lowercased()
        if haystack.contains("opus")
            || haystack.contains("pro")
            || haystack.contains("max")
            || haystack.contains("xhigh") {
            return "flagship"
        }
        if haystack.contains("mini")
            || haystack.contains("nano")
            || haystack.contains("flash")
            || haystack.contains("haiku") {
            return "small"
        }
        return "mid"
    }

    private static func option(
        _ modelID: String,
        _ displayName: String,
        _ providerID: String,
        _ providerName: String,
        tier: String = "mid",
        source: CLIRuntimeModelSource = .cliProfile
    ) -> CLIRuntimeModelOption {
        CLIRuntimeModelOption(
            modelID: modelID,
            displayName: displayName,
            providerID: providerID,
            providerName: providerName,
            tier: tier,
            source: source
        )
    }

    private static func droidStandardOption(
        _ modelID: String,
        _ displayName: String,
        tier: String = "mid"
    ) -> CLIRuntimeModelOption {
        option(
            modelID,
            OpenBurnBarModelDisplayName.compose(
                modelName: displayName,
                providerName: "Factory Droid Standard",
                providerID: "factory",
                reasoningLevel: "CLI default"
            ),
            "factory",
            "Factory Droid Standard quota",
            tier: tier,
            source: .droidStandardQuota
        )
    }

    private static func droidCoreOption(
        _ modelID: String,
        _ displayName: String,
        tier: String = "mid"
    ) -> CLIRuntimeModelOption {
        option(
            modelID,
            OpenBurnBarModelDisplayName.compose(
                modelName: displayName,
                providerName: "Factory Droid Core",
                providerID: "factory",
                reasoningLevel: "CLI default"
            ),
            "factory",
            "Factory Droid Core quota",
            tier: tier,
            source: .droidCoreQuota
        )
    }

    private static func openBurnBarProxyOption(
        _ modelID: String,
        _ displayName: String,
        _ providerID: String,
        tier: String = "mid"
    ) -> CLIRuntimeModelOption {
        let providerName = OpenBurnBarModelDisplayName.providerLabel(
            providerID: providerID,
            providerName: nil
        ) ?? providerID
        return option(
            modelID,
            OpenBurnBarModelDisplayName.compose(
                modelName: displayName,
                providerName: providerName,
                providerID: providerID
            ),
            providerID,
            "\(providerName) via OpenBurnBar API/OAuth",
            tier: tier,
            source: .openBurnBarProxy
        )
    }
}
