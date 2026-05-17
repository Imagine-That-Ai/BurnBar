import Foundation

// MARK: - Credential Method Kind

/// How a user provides credentials for a given provider. The wizard renders
/// a different UX per kind: API key fields for `apiKey`/`bearerToken`,
/// monospaced JWT-style entry for `sessionToken`, paste-cookie text editor
/// for `cookie`, guided sign-in for `browserLogin`, and "detect runtime"
/// affordance for `localRuntime`.
public enum BurnBarProviderAuthMethodKind: String, Codable, CaseIterable, Hashable, Sendable {
    case apiKey
    case bearerToken
    case sessionToken
    case cookie
    case browserLogin
    case localRuntime

    /// SF Symbol used by the wizard auth-method card.
    public var symbolName: String {
        switch self {
        case .apiKey: return "key.fill"
        case .bearerToken: return "key.horizontal.fill"
        case .sessionToken: return "lock.shield.fill"
        case .cookie: return "doc.text.below.ecg"
        case .browserLogin: return "person.badge.key.fill"
        case .localRuntime: return "cpu"
        }
    }

    /// Short human label used in capability chips ("Key", "Cookie", "Session").
    public var shortLabel: String {
        switch self {
        case .apiKey, .bearerToken: return "Key"
        case .sessionToken: return "Session"
        case .cookie: return "Cookie"
        case .browserLogin: return "Login"
        case .localRuntime: return "Runtime"
        }
    }
}

// MARK: - Storage Scope

/// Where the wizard should persist a credential entered for a method.
public enum BurnBarProviderSecretStorageScope: Codable, Hashable, Sendable {
    /// Stored only on the daemon credential slot keychain account.
    case daemonSlot
    /// Stored on the daemon credential slot AND mirrored to a named app
    /// keychain account so quota adapters that read from a fixed account
    /// (e.g. `kimi_auth_token`) keep working.
    case daemonSlotMirroredToKeychain(account: String)
    /// Stored only in a named app keychain account (no daemon proxy slot).
    case appKeychain(account: String)

    public var mirrorAccountIdentifier: String? {
        switch self {
        case .daemonSlot: return nil
        case .daemonSlotMirroredToKeychain(let account): return account
        case .appKeychain(let account): return account
        }
    }

    public var usesDaemonSlot: Bool {
        switch self {
        case .daemonSlot, .daemonSlotMirroredToKeychain: return true
        case .appKeychain: return false
        }
    }
}

// MARK: - Auth Method Descriptor

public struct BurnBarProviderAuthMethod: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let kind: BurnBarProviderAuthMethodKind
    public let displayName: String
    public let summary: String
    public let helperText: String
    public let placeholder: String
    public let prefixHint: String?
    public let dashboardURL: String?
    public let dashboardLabel: String?
    public let storage: BurnBarProviderSecretStorageScope
    public let unlocksProxyRouting: Bool
    public let unlocksQuotaRefresh: Bool

    public init(
        id: String,
        kind: BurnBarProviderAuthMethodKind,
        displayName: String,
        summary: String,
        helperText: String,
        placeholder: String,
        prefixHint: String? = nil,
        dashboardURL: String? = nil,
        dashboardLabel: String? = nil,
        storage: BurnBarProviderSecretStorageScope = .daemonSlot,
        unlocksProxyRouting: Bool = true,
        unlocksQuotaRefresh: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.summary = summary
        self.helperText = helperText
        self.placeholder = placeholder
        self.prefixHint = prefixHint
        self.dashboardURL = dashboardURL
        self.dashboardLabel = dashboardLabel
        self.storage = storage
        self.unlocksProxyRouting = unlocksProxyRouting
        self.unlocksQuotaRefresh = unlocksQuotaRefresh
    }

    /// Real-time validation result for the wizard's credential entry chip.
    public func validate(_ rawValue: String) -> BurnBarProviderAuthValidation {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }

        if let prefix = prefixHint,
           !trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            return .warning("Expected this credential to start with \(prefix).")
        }

        switch kind {
        case .apiKey, .bearerToken:
            if trimmed.count < 12 { return .warning("API keys are usually longer than 12 characters.") }
        case .sessionToken:
            if !trimmed.contains(".") || trimmed.count < 40 {
                return .warning("Session tokens are typically long JWT strings with dots.")
            }
        case .cookie:
            if trimmed.count < 16 { return .warning("Cookie payloads are usually longer than 16 characters.") }
        case .browserLogin, .localRuntime:
            break
        }

        return .ok
    }
}

public enum BurnBarProviderAuthValidation: Hashable, Sendable {
    case empty
    case ok
    case warning(String)

    public var message: String? {
        switch self {
        case .empty: return nil
        case .ok: return "Looks good — this credential format is valid."
        case .warning(let text): return text
        }
    }

    public var isWarning: Bool {
        if case .warning = self { return true }
        return false
    }

    public var isOK: Bool {
        if case .ok = self { return true }
        return false
    }
}

// MARK: - Provider Auth Descriptor

public struct BurnBarProviderAuthDescriptor: Codable, Hashable, Sendable, Identifiable {
    /// Catalog provider ID this descriptor applies to (e.g. "moonshot").
    public let providerID: String
    /// User-facing brand name (may differ from catalog name, e.g. "Kimi (Moonshot)").
    public let displayName: String
    /// Other catalog or persisted IDs that should resolve to this descriptor.
    public let aliasProviderIDs: [String]
    /// Available credential methods, ordered by recommendation.
    public let methods: [BurnBarProviderAuthMethod]
    /// `methods.first` is the primary; explicit override allowed.
    public let primaryMethodID: String?
    /// One-line summary for the provider tile / wizard header.
    public let summary: String
    /// Optional longer copy explaining proxy behaviour.
    public let proxyHint: String?
    /// Optional longer copy explaining quota behaviour.
    public let quotaHint: String?

    public var id: String { providerID }

    public init(
        providerID: String,
        displayName: String,
        aliasProviderIDs: [String] = [],
        methods: [BurnBarProviderAuthMethod],
        primaryMethodID: String? = nil,
        summary: String,
        proxyHint: String? = nil,
        quotaHint: String? = nil
    ) {
        precondition(!methods.isEmpty, "Provider auth descriptor must declare at least one method.")
        self.providerID = providerID
        self.displayName = displayName
        self.aliasProviderIDs = aliasProviderIDs
        self.methods = methods
        self.primaryMethodID = primaryMethodID
        self.summary = summary
        self.proxyHint = proxyHint
        self.quotaHint = quotaHint
    }

    public func method(id: String) -> BurnBarProviderAuthMethod? {
        methods.first { $0.id == id }
    }

    public var primaryMethod: BurnBarProviderAuthMethod {
        if let primaryMethodID, let match = method(id: primaryMethodID) { return match }
        return methods[0]
    }

    public var supportsProxyRouting: Bool {
        methods.contains { $0.unlocksProxyRouting }
    }

    public var supportsQuotaRefresh: Bool {
        methods.contains { $0.unlocksQuotaRefresh }
    }

    /// Catalog provider ID used by the host app to bridge a daemon slot to
    /// an `AgentProvider` quota adapter (e.g. moonshot → `.kimi`).
    /// Defaults to `providerID` when nil.
    public var quotaProviderAlias: String { providerID }
}

// MARK: - Registry

public enum BurnBarProviderAuthRegistry {

    public static let descriptors: [BurnBarProviderAuthDescriptor] = [
        zaiDescriptor,
        minimaxDescriptor,
        moonshotKimiDescriptor,
        ollamaDescriptor,
        openAIDescriptor,
        openCodeDescriptor,
        anthropicDescriptor,
        googleDescriptor,
        xaiDescriptor,
        deepseekDescriptor,
        mistralDescriptor,
        cohereDescriptor,
        alibabaDescriptor,
        amazonDescriptor,
        metaDescriptor
    ]

    public static func descriptor(forCatalogProviderID providerID: String) -> BurnBarProviderAuthDescriptor? {
        let normalized = normalize(providerID)
        return descriptors.first { descriptor in
            descriptor.providerID == normalized
                || descriptor.aliasProviderIDs.contains(normalized)
        }
    }

    public static func descriptorOrFallback(
        forCatalogProviderID providerID: String,
        displayName: String,
        supportsProxyRouting: Bool = true
    ) -> BurnBarProviderAuthDescriptor {
        if let descriptor = descriptor(forCatalogProviderID: providerID) {
            return descriptor
        }
        return defaultDescriptor(
            providerID: providerID,
            displayName: displayName,
            supportsProxyRouting: supportsProxyRouting
        )
    }

    public static func defaultDescriptor(
        providerID: String,
        displayName: String,
        supportsProxyRouting: Bool = true
    ) -> BurnBarProviderAuthDescriptor {
        let method = BurnBarProviderAuthMethod(
            id: "\(providerID)-api-key",
            kind: .apiKey,
            displayName: "\(displayName) API Key",
            summary: "Standard bearer-token credential.",
            helperText: "Paste a bearer token from your \(displayName) dashboard. OpenBurnBar stores it in your Mac Keychain.",
            placeholder: "sk-...",
            storage: .daemonSlot,
            unlocksProxyRouting: supportsProxyRouting,
            unlocksQuotaRefresh: false
        )
        return BurnBarProviderAuthDescriptor(
            providerID: providerID,
            displayName: displayName,
            methods: [method],
            summary: "\(displayName) account credentials.",
            proxyHint: supportsProxyRouting
                ? "Connect once and OpenBurnBar will route requests through this provider."
                : "Tracking only — proxy routing isn't enabled for this provider yet.",
            quotaHint: nil
        )
    }

    private static func normalize(_ providerID: String) -> String {
        providerID
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Descriptor Catalog

    private static let zaiDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "zai",
        displayName: "Z.ai",
        aliasProviderIDs: ["z-ai", "z.ai", "glm"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "zai-coding-plan",
                kind: .apiKey,
                displayName: "Z.ai Coding Plan Key",
                summary: "Routes GLM coding plan traffic and reads live quota.",
                helperText: "Generate a key from your GLM coding plan dashboard. The same key powers proxy routing and quota.",
                placeholder: "sk-...",
                dashboardURL: "https://bigmodel.cn/usercenter/glm-coding/usage",
                dashboardLabel: "Open Z.ai usage dashboard",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: true
            )
        ],
        summary: "GLM coding plans via Z.ai. One key powers both proxy and quota.",
        proxyHint: "Routed via api.z.ai (OpenAI-compatible).",
        quotaHint: "Live quota windows pulled from the Z.ai usage dashboard."
    )

    private static let minimaxDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "minimax",
        displayName: "MiniMax",
        aliasProviderIDs: ["mini-max", "abab"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "minimax-coding-plan",
                kind: .apiKey,
                displayName: "MiniMax Coding Plan Key",
                summary: "Coding plan keys unlock proxy routing AND live quota.",
                helperText: "Coding-plan keys start with sk-cp-… and bleed quota straight into OpenBurnBar.",
                placeholder: "sk-cp-…",
                prefixHint: "sk-cp-",
                dashboardURL: "https://platform.minimax.io/docs/token-plan/faq",
                dashboardLabel: "Get a coding plan key",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: true
            ),
            BurnBarProviderAuthMethod(
                id: "minimax-open-platform",
                kind: .apiKey,
                displayName: "MiniMax Open Platform Key",
                summary: "Standard sk-api keys can route requests but cannot read quota.",
                helperText: "Open-platform keys start with sk-api-… and only support proxy routing.",
                placeholder: "sk-api-…",
                prefixHint: "sk-api-",
                dashboardURL: "https://platform.minimax.io/docs/api-reference",
                dashboardLabel: "MiniMax open platform docs",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            )
        ],
        primaryMethodID: "minimax-coding-plan",
        summary: "MiniMax coding plans for routing and quota in one place.",
        proxyHint: "Routed via api.minimax.io (OpenAI-compatible).",
        quotaHint: "Live coding plan quota requires the sk-cp- key."
    )

    private static let moonshotKimiDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "moonshot",
        displayName: "Kimi (Moonshot)",
        aliasProviderIDs: ["kimi", "moonshot.cn"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "kimi-session-token",
                kind: .sessionToken,
                displayName: "Kimi Browser Session Token",
                summary: "Reads coding plan quota from the kimi.com console.",
                helperText: "Sign in at kimi.com/code/console, copy the kimi-auth cookie value, and paste it here. We mirror it to your Mac Keychain so quota refresh keeps working.",
                placeholder: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9…",
                dashboardURL: "https://kimi.com/code/console",
                dashboardLabel: "Open Kimi console",
                storage: .daemonSlotMirroredToKeychain(account: "kimi_auth_token"),
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: true
            ),
            BurnBarProviderAuthMethod(
                id: "moonshot-api-key",
                kind: .apiKey,
                displayName: "Moonshot API Key",
                summary: "Standard Moonshot platform key for tracking.",
                helperText: "Moonshot platform keys start with sk-… and are tracked for usage. Proxy routing for Moonshot is not yet wired into the daemon.",
                placeholder: "sk-…",
                dashboardURL: "https://platform.moonshot.cn/console/api-keys",
                dashboardLabel: "Moonshot API keys",
                storage: .daemonSlot,
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: false
            )
        ],
        primaryMethodID: "kimi-session-token",
        summary: "Kimi coding plan quota and Moonshot API tracking in one connection.",
        proxyHint: "Proxy routing for Kimi/Moonshot is not yet enabled in the daemon — connect for tracking and quota only.",
        quotaHint: "Live quota uses your kimi.com session token. Refresh in OpenBurnBar if it expires."
    )

    private static let ollamaDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "ollama",
        displayName: "Ollama Cloud",
        aliasProviderIDs: ["ollama-cloud"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "ollama-cloud-key",
                kind: .apiKey,
                displayName: "Ollama Cloud Key",
                summary: "Routes CLI traffic through the Ollama Cloud gateway.",
                helperText: "Generate a key at ollama.com/settings/keys. Signing in to Ollama Cloud shows quota and account state; this API key is what makes BurnBar proxy requests.",
                placeholder: "sk-ollama-…",
                dashboardURL: "https://ollama.com/settings/keys",
                dashboardLabel: "Ollama Cloud keys",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: true
            )
        ],
        summary: "Ollama Cloud — managed inference for open models.",
        proxyHint: "Proxy routing requires an Ollama Cloud API key; browser sign-in alone is quota/account visibility.",
        quotaHint: "Quota windows come from the Ollama Cloud dashboard sign-in."
    )

    private static let openAIDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "openai",
        displayName: "OpenAI",
        methods: [
            BurnBarProviderAuthMethod(
                id: "openai-api-key",
                kind: .apiKey,
                displayName: "OpenAI API Key",
                summary: "Routes ChatGPT-compatible traffic via api.openai.com.",
                helperText: "Project keys start with sk-proj-…; user keys start with sk-…. Both work for proxy routing.",
                placeholder: "sk-proj-…",
                dashboardURL: "https://platform.openai.com/api-keys",
                dashboardLabel: "OpenAI API keys",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            ),
            BurnBarProviderAuthMethod(
                id: "openai-admin-key",
                kind: .apiKey,
                displayName: "OpenAI Admin Key",
                summary: "Reads usage reporting via the admin endpoint.",
                helperText: "Org admin keys start with sk-admin-… and unlock the OpenAI usage dashboard.",
                placeholder: "sk-admin-…",
                prefixHint: "sk-admin-",
                dashboardURL: "https://platform.openai.com/settings/organization/admin-keys",
                dashboardLabel: "OpenAI admin keys",
                storage: .daemonSlot,
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: true
            ),
            BurnBarProviderAuthMethod(
                id: "openai-codex-oauth",
                kind: .browserLogin,
                displayName: "Sign in with OpenAI / Codex",
                summary: "Use your local Codex ChatGPT login for account and quota visibility.",
                helperText: "Launch Codex login from Account Switcher or run `codex login`; OpenBurnBar detects the OAuth session locally. OpenAI API proxy routing still requires an API key because ChatGPT OAuth tokens are not OpenAI API keys.",
                placeholder: "Codex ChatGPT OAuth session",
                dashboardURL: "https://chatgpt.com/",
                dashboardLabel: "Open ChatGPT sign-in",
                storage: .appKeychain(account: "codex_oauth_session"),
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: true
            )
        ],
        primaryMethodID: "openai-api-key",
        summary: "OpenAI — API-key routing plus Codex OAuth sign-in for plan visibility.",
        proxyHint: "Routed through api.openai.com (OpenAI-compatible).",
        quotaHint: "Usage reporting requires an org admin key; Codex OAuth quota comes from your local ChatGPT login."
    )

    private static let anthropicDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "anthropic",
        displayName: "Anthropic",
        aliasProviderIDs: ["claude", "claude-code"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "anthropic-api-key",
                kind: .apiKey,
                displayName: "Anthropic API Key",
                summary: "Routes Claude Messages API traffic and records usage.",
                helperText: "Anthropic keys start with sk-ant-…. OpenBurnBar routes Claude Code through the Anthropic-family /v1/messages gateway without translating request shape.",
                placeholder: "sk-ant-…",
                prefixHint: "sk-ant-",
                dashboardURL: "https://console.anthropic.com/settings/keys",
                dashboardLabel: "Anthropic API keys",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            ),
            BurnBarProviderAuthMethod(
                id: "anthropic-claude-oauth",
                kind: .bearerToken,
                displayName: "Claude OAuth Bearer",
                summary: "Routes Claude Pro/Team OAuth bearer traffic through /v1/messages.",
                helperText: "Paste a Claude Code or claude.ai OAuth access token. OAuth bearers are sent as Authorization: Bearer for Anthropic-family routing; use the Claude Code sign-in flow when you only need local CLI account switching.",
                placeholder: "Bearer access token",
                dashboardURL: "https://claude.ai/",
                dashboardLabel: "Open Claude sign-in",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: true
            ),
            BurnBarProviderAuthMethod(
                id: "anthropic-claude-code-login",
                kind: .browserLogin,
                displayName: "Sign in with Claude Code",
                summary: "Use local Claude Code OAuth for CLI account and quota visibility.",
                helperText: "Launch Claude Code login from Account Switcher or run `claude auth login`; OpenBurnBar detects the local CLI account and status-line quota bridge. Use Claude OAuth Bearer above when you want the gateway to route Claude Code requests.",
                placeholder: "Claude Code OAuth session",
                dashboardURL: "https://claude.ai/",
                dashboardLabel: "Open Claude sign-in",
                storage: .appKeychain(account: "claude_code_oauth_session"),
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: true
            )
        ],
        summary: "Anthropic Claude — API keys, OAuth bearers, and Claude Code sign-in.",
        proxyHint: "Routed through the Anthropic-family /v1/messages gateway for Claude Code and other Anthropic-shape clients.",
        quotaHint: "Claude Code sign-in feeds local quota visibility; OAuth bearers can also route through the gateway."
    )

    private static let openCodeDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "opencode",
        displayName: "OpenCode",
        aliasProviderIDs: ["open-code", "open code", "opencode-go", "open-code-go", "open code go"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "opencode-auth-json",
                kind: .sessionToken,
                displayName: "OpenCode auth.json",
                summary: "Routes OpenCode Go models and tracks local/self-hosted quota stats.",
                helperText: "Paste the opencode-go entry from ~/.local/share/opencode/auth.json, or the full auth.json. OpenBurnBar extracts the route key and sends requests to OpenCode Go's OpenAI-compatible gateway.",
                placeholder: "{\"opencode-go\":{\"type\":\"...\",\"key\":\"...\"}}",
                dashboardURL: "https://opencode.ai/docs/go/",
                dashboardLabel: "OpenCode Go docs",
                storage: .daemonSlotMirroredToKeychain(account: "opencode_auth_json"),
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: true
            )
        ],
        summary: "OpenCode Go routing, quota, and account tracking.",
        proxyHint: "Routed through OpenCode Go's OpenAI-compatible /zen/go/v1 gateway.",
        quotaHint: "Local/self-hosted quota refresh reads OpenCode CLI stats; route credentials can be added as separate BurnBar accounts."
    )

    private static let googleDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "google",
        displayName: "Google Gemini",
        aliasProviderIDs: ["gemini"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "google-api-key",
                kind: .apiKey,
                displayName: "Google AI API Key",
                summary: "Tracks Gemini usage.",
                helperText: "Get a key from Google AI Studio. Proxy routing for Gemini uses the native protocol and isn't enabled yet.",
                placeholder: "AIza…",
                prefixHint: "AIza",
                dashboardURL: "https://aistudio.google.com/app/apikey",
                dashboardLabel: "Google AI Studio keys",
                storage: .daemonSlot,
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "Google Gemini — tracking and accounting only.",
        proxyHint: "Tracking only — Gemini uses a non-OpenAI protocol the proxy doesn't speak yet.",
        quotaHint: nil
    )

    private static let xaiDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "xai",
        displayName: "xAI (Grok)",
        aliasProviderIDs: ["grok"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "xai-api-key",
                kind: .apiKey,
                displayName: "xAI API Key",
                summary: "Routes Grok traffic via api.x.ai.",
                helperText: "Generate a key at console.x.ai. xAI is OpenAI-compatible so the proxy can route requests.",
                placeholder: "xai-…",
                prefixHint: "xai-",
                dashboardURL: "https://console.x.ai",
                dashboardLabel: "xAI console",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "xAI Grok — OpenAI-compatible routing.",
        proxyHint: "Routed via api.x.ai (OpenAI-compatible).",
        quotaHint: nil
    )

    private static let deepseekDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "deepseek",
        displayName: "DeepSeek",
        methods: [
            BurnBarProviderAuthMethod(
                id: "deepseek-api-key",
                kind: .apiKey,
                displayName: "DeepSeek API Key",
                summary: "Routes DeepSeek traffic via api.deepseek.com.",
                helperText: "Generate a key from your DeepSeek console. DeepSeek is OpenAI-compatible.",
                placeholder: "sk-…",
                dashboardURL: "https://platform.deepseek.com/api_keys",
                dashboardLabel: "DeepSeek API keys",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "DeepSeek — OpenAI-compatible routing.",
        proxyHint: "Routed via api.deepseek.com (OpenAI-compatible).",
        quotaHint: nil
    )

    private static let mistralDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "mistral",
        displayName: "Mistral",
        methods: [
            BurnBarProviderAuthMethod(
                id: "mistral-api-key",
                kind: .apiKey,
                displayName: "Mistral API Key",
                summary: "Routes Mistral traffic via api.mistral.ai.",
                helperText: "Generate a key at console.mistral.ai. Mistral is OpenAI-compatible.",
                placeholder: "…",
                dashboardURL: "https://console.mistral.ai/api-keys",
                dashboardLabel: "Mistral API keys",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "Mistral — OpenAI-compatible routing.",
        proxyHint: "Routed via api.mistral.ai (OpenAI-compatible).",
        quotaHint: nil
    )

    private static let cohereDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "cohere",
        displayName: "Cohere",
        methods: [
            BurnBarProviderAuthMethod(
                id: "cohere-api-key",
                kind: .apiKey,
                displayName: "Cohere API Key",
                summary: "Tracks Cohere usage.",
                helperText: "Cohere uses its own non-OpenAI protocol. Tracking only for now.",
                placeholder: "…",
                dashboardURL: "https://dashboard.cohere.com/api-keys",
                dashboardLabel: "Cohere API keys",
                storage: .daemonSlot,
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "Cohere — tracking only.",
        proxyHint: "Tracking only — Cohere isn't OpenAI-compatible.",
        quotaHint: nil
    )

    private static let alibabaDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "alibaba",
        displayName: "Alibaba Qwen",
        aliasProviderIDs: ["qwen", "dashscope"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "alibaba-api-key",
                kind: .apiKey,
                displayName: "DashScope API Key",
                summary: "Routes Qwen traffic via DashScope.",
                helperText: "DashScope keys come from the Alibaba Cloud console. The international endpoint is OpenAI-compatible.",
                placeholder: "sk-…",
                dashboardURL: "https://dashscope.console.aliyun.com/apiKey",
                dashboardLabel: "Alibaba DashScope keys",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "Alibaba Qwen — DashScope OpenAI-compatible routing.",
        proxyHint: "Routed via DashScope international (OpenAI-compatible).",
        quotaHint: nil
    )

    private static let amazonDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "amazon",
        displayName: "Amazon Bedrock",
        aliasProviderIDs: ["bedrock", "aws"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "amazon-bedrock-key",
                kind: .bearerToken,
                displayName: "Bedrock Bearer Token",
                summary: "Tracks Bedrock usage.",
                helperText: "Bedrock uses AWS SigV4 auth and isn't OpenAI-compatible. Save a bearer token here for tracking.",
                placeholder: "AKIA…",
                dashboardURL: "https://console.aws.amazon.com/bedrock",
                dashboardLabel: "Bedrock console",
                storage: .daemonSlot,
                unlocksProxyRouting: false,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "Amazon Bedrock — tracking only.",
        proxyHint: "Tracking only — Bedrock requires AWS SigV4 the proxy doesn't speak yet.",
        quotaHint: nil
    )

    private static let metaDescriptor = BurnBarProviderAuthDescriptor(
        providerID: "meta",
        displayName: "Meta Llama",
        aliasProviderIDs: ["llama", "together"],
        methods: [
            BurnBarProviderAuthMethod(
                id: "meta-together-key",
                kind: .apiKey,
                displayName: "Together / Llama API Key",
                summary: "Routes Llama traffic via Together (OpenAI-compatible).",
                helperText: "Use a Together.ai key to route Llama models. Direct Meta API access isn't generally available.",
                placeholder: "…",
                dashboardURL: "https://api.together.xyz/settings/api-keys",
                dashboardLabel: "Together API keys",
                storage: .daemonSlot,
                unlocksProxyRouting: true,
                unlocksQuotaRefresh: false
            )
        ],
        summary: "Meta Llama via Together — OpenAI-compatible routing.",
        proxyHint: "Routed via api.together.xyz (OpenAI-compatible).",
        quotaHint: nil
    )
}
