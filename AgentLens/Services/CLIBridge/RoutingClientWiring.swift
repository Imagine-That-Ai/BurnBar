import CryptoKit
import Foundation
import OpenBurnBarCore

// MARK: - Public types

/// Identifies which routed-client target a wiring action applies to.
///
/// The router runs locally on the user's Mac at `127.0.0.1:<gatewayPort>`.
/// Each target speaks one local gateway endpoint shape. The gateway may
/// satisfy that endpoint with a native upstream or with an explicit
/// compatibility bridge, but the advertised model row must say which local
/// endpoints it actually serves.
///
///   - `.claudeCode` — Anthropic Messages shape (`/v1/messages`). Reads
///     `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` and lives at
///     `~/.claude/settings.json` (`env` block).
///   - `.codex` — OpenAI Responses shape (`/v1/responses`). Reads the
///     configured provider `env_key` and lives at `~/.codex/config.toml`
///     (sentinel-fenced `[model_providers.…]` block).
///   - `.opencode` — OpenAI-compatible provider entry in
///     `~/.config/opencode/opencode.json`.
///   - `.forge` — OpenAI Chat Completions shape (`/v1/chat/completions`).
///     Reads an OpenBurnBar-owned Forge `[[providers]]` entry at
///     `~/forge/.forge.toml`.
///   - `.droid` — Factory Droid custom-model overrides in
///     `~/.factory/settings.local.json`, `~/.factory/settings.json`, and
///     `~/.factory/config.json` (`customModels` / `custom_models` entries).
///   - `.grok` — Grok Build custom model block in `~/.grok/config.toml`.
///   - `.antigravity` — Google Antigravity profile switching. The CLI is
///     launched through profile-scoped config directories; it does not expose
///     a file-based OpenAI-compatible routing config that OpenBurnBar can
///     safely rewrite yet.
enum RoutingClientWiringTarget: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case opencode
    case forge
    case droid
    case grok
    case antigravity
    case cursorAgent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .opencode: return "OpenCode CLI"
        case .forge: return "Forge CLI"
        case .droid: return "Droid CLI"
        case .grok: return "Grok Build CLI"
        case .antigravity: return "Antigravity CLI"
        case .cursorAgent: return "Cursor Agent CLI"
        }
    }

    /// Which local endpoint family this client feeds.
    var poolDisplayName: String {
        switch self {
        case .claudeCode: return "Anthropic Messages"
        case .codex, .opencode, .forge, .droid, .grok: return "OpenAI-style gateway"
        case .antigravity: return "Profile-scoped Antigravity"
        case .cursorAgent: return "Profile-scoped Cursor Agent"
        }
    }

    /// The local gateway probe path this target tests against, shown to the
    /// user when a probe fails so they know exactly what was tested.
    /// Returns `nil` for targets that cannot be probed (profile-scoped CLIs).
    var probeEndpointLabel: String? {
        switch self {
        case .claudeCode: return "POST /v1/messages"
        case .codex: return "POST /v1/responses"
        case .opencode, .forge, .droid, .grok: return "POST /v1/chat/completions"
        case .antigravity, .cursorAgent: return nil
        }
    }

    /// True when the target supports BurnBar model catalog sync — the UI
    /// uses this to decide whether to offer "Sync models" and surface
    /// native + OpenBurnBar model counts.
    var supportsModelSync: Bool {
        switch self {
        case .droid, .codex, .claudeCode: return true
        case .opencode, .forge, .grok, .antigravity, .cursorAgent: return false
        }
    }

    /// Short, one-line description of the endpoint shape the client speaks.
    /// Used as restrained secondary copy in the row.
    var endpointDescription: String {
        switch self {
        case .claudeCode:
            return "Anthropic Messages (/v1/messages)"
        case .codex:
            return "OpenAI Responses (/v1/responses)"
        case .opencode, .forge, .droid, .grok:
            return "OpenAI Chat Completions (/v1/chat/completions)"
        case .antigravity:
            return "Profile-scoped (no file-based gateway)"
        case .cursorAgent:
            return "Profile-scoped (no file-based gateway)"
        }
    }

    /// Compact badge label for the endpoint shape badge in the routing
    /// cockpit row. Shorter than `endpointDescription` since it sits inside
    /// a capsule next to the client name.
    var endpointBadgeLabel: String {
        switch self {
        case .claudeCode: return "Messages"
        case .codex: return "Responses"
        case .opencode, .forge, .droid, .grok: return "Chat Completions"
        case .antigravity: return "Profile-scoped"
        case .cursorAgent: return "Profile-scoped"
        }
    }

    /// True when this target's wire format can serve the given advertised
    /// model's endpoints. Used by the UI to count models per target without
    /// touching the wiring service.
    func gatewayServes(model: ProxyAdvertisedModel) -> Bool {
        guard model.advertised && model.routeEligible else { return false }
        if model.servedEndpoints.isEmpty {
            // Older gateway catalogs did not include endpoint metadata. Treat
            // gateway-shaped clients as bridge-compatible, matching
            // `isGatewayServedModelCandidate(for:)` so UI counts cannot drift
            // from the wiring service's own filtering.
            switch self {
            case .claudeCode, .codex, .opencode, .forge, .droid, .grok:
                return true
            case .antigravity, .cursorAgent:
                return false
            }
        }
        switch self {
        case .claudeCode:
            return model.servedEndpoints.contains("/v1/messages")
        case .codex:
            return model.servedEndpoints.contains("/v1/responses")
        case .opencode, .forge, .droid, .grok:
            return model.servedEndpoints.contains("/v1/chat/completions")
                || model.servedEndpoints.contains("/v1/responses")
        case .antigravity, .cursorAgent:
            return false
        }
    }
}

/// Snapshot describing the local gateway endpoint a routed client should
/// be pointed at. Mirrors the daemon's `gatewayHost` / `gatewayPort` /
/// `gatewayAuthToken` settings so the helper has a single struct to consume.
struct RoutingClientGateway: Sendable {
    let host: String
    let port: Int
    let authToken: String

    init(host: String, port: Int, authToken: String) {
        self.host = host
        self.port = port
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip a credential down so the UI can show "is configured" without
    /// rendering the secret itself. Surfaces are responsible for handling the
    /// empty-string case (unconfigured gateway).
    var redactedAuthToken: String {
        let trimmed = authToken
        guard trimmed.count >= 4 else { return trimmed.isEmpty ? "" : "…" }
        return "…\(trimmed.suffix(4))"
    }

    /// Local loopback gateways may intentionally run without auth. CLI tools
    /// still expect an API-key string, so we give them a harmless
    /// OpenBurnBar-local placeholder.
    var effectiveClientToken: String {
        authToken.isEmpty ? "openburnbar-local" : authToken
    }

    var isLoopbackHost: Bool {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedHost.isEmpty
            || normalizedHost == "127.0.0.1"
            || normalizedHost == "localhost"
            || normalizedHost == "::1"
    }

    /// URL with **no** trailing slash, suitable for both
    /// `ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL`.
    var baseURL: String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1"
            : host
        return "http://\(normalizedHost):\(port)"
    }
}

struct RoutingClientAdvertisedModel: Sendable, Equatable {
    let id: String
    let displayName: String
    let providerID: String
    let providerName: String
    let formatFamily: String
    let servedEndpoints: [String]
    let capabilities: [String]
    let contextWindowTokens: Int?
    let inputModalities: [String]
    let routeEligible: Bool

    init(
        id: String,
        displayName: String,
        providerID: String,
        providerName: String,
        formatFamily: String = "openai_compat",
        servedEndpoints: [String] = [],
        capabilities: [String] = [],
        contextWindowTokens: Int? = nil,
        inputModalities: [String] = ["text"],
        routeEligible: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.formatFamily = formatFamily
        self.servedEndpoints = servedEndpoints
        self.capabilities = capabilities
        self.contextWindowTokens = contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
        self.inputModalities = inputModalities.isEmpty ? ["text"] : inputModalities
        self.routeEligible = routeEligible
    }

    var isGatewayServedModelCandidate: Bool {
        guard routeEligible else { return false }
        return servedEndpoints.isEmpty
            || servedEndpoints.contains("/v1/chat/completions")
            || servedEndpoints.contains("/v1/responses")
    }

    func isGatewayServedModelCandidate(for target: RoutingClientWiringTarget) -> Bool {
        guard routeEligible else { return false }
        switch target {
        case .claudeCode:
            if servedEndpoints.isEmpty {
                return true
            }
            return servedEndpoints.contains("/v1/messages")
        case .codex:
            return servedEndpoints.isEmpty || servedEndpoints.contains("/v1/responses")
        case .opencode, .forge, .droid, .grok:
            return isGatewayServedModelCandidate
        case .antigravity, .cursorAgent:
            return false
        }
    }

    /// Factory Droid has distinct BYOK provider adapters. BurnBar's gateway
    /// supports both `/v1/responses` and `/v1/chat/completions`, so models
    /// served by OpenAI-owned upstream accounts should use Factory's `openai`
    /// adapter while the rest of BurnBar's gateway-served catalog stays on
    /// the generic chat-completions adapter. Provider identity, not the model
    /// string alone, is the safe discriminator: non-OpenAI providers can
    /// legitimately serve models with `gpt` in the name.
    var droidProviderType: String {
        let providerText = "\(providerID) \(providerName)".lowercased()
        let modelText = id.lowercased()
        if formatFamily.lowercased() == "anthropic"
            || capabilities.map({ $0.lowercased() }).contains("anthropic")
            || providerText.contains("anthropic")
            || providerText.contains("claude")
            || modelText.contains("claude")
            || modelText.contains("anthropic") {
            return "anthropic"
        }
        if providerText.contains("openai") || providerText.contains("azure openai") {
            return "openai"
        }
        return "generic-chat-completion-api"
    }

    /// Factory Droid's BYOK adapters expect different base URL shapes:
    /// Anthropic points at the host root and appends `/v1/messages`, while
    /// OpenAI and generic chat-completions adapters point at `/v1`.
    func droidBaseURL(gateway: RoutingClientGateway) -> String {
        droidProviderType == "anthropic" ? gateway.baseURL : "\(gateway.baseURL)/v1"
    }
}

/// Why a wiring operation could not complete. Surfaces should display
/// `localizedDescription` directly — never echo the auth token.
enum RoutingClientWiringError: LocalizedError, Sendable, Equatable {
    case gatewayMisconfigured(detail: String)
    case configReadFailed(path: String, detail: String)
    case configWriteFailed(path: String, detail: String)
    case backupFailed(path: String, detail: String)
    case probeFailed(detail: String)
    case alreadyEnabled
    case notEnabled

    var errorDescription: String? {
        switch self {
        case .gatewayMisconfigured(let detail):
            return "The OpenBurnBar gateway is not ready: \(detail)"
        case .configReadFailed(let path, let detail):
            return "Could not read \(path): \(detail)"
        case .configWriteFailed(let path, let detail):
            return "Could not update \(path): \(detail)"
        case .backupFailed(let path, let detail):
            return "Could not back up \(path) before writing: \(detail)"
        case .probeFailed(let detail):
            return "Probe failed: \(detail)"
        case .alreadyEnabled:
            return "This client is already wired through the OpenBurnBar gateway."
        case .notEnabled:
            return "This client is not currently wired through the OpenBurnBar gateway."
        }
    }
}

/// Snapshot describing what file (if any) the helper actually wrote.
struct RoutingClientWiringChange: Sendable {
    let target: RoutingClientWiringTarget
    let configURL: URL
    let backupURL: URL?
    let appliedAt: Date
}

/// Verdict from the 1-token probe that confirms the local gateway will
/// actually serve the target's traffic. The helper executes the probe before
/// reporting "wired" so we don't lie to the user about the wiring being
/// functional.
enum RoutingClientWiringProbe: Sendable, Equatable {
    case skipped(reason: String)
    case ok(modelID: String)
    case failed(status: Int, message: String)
}

enum RoutingClientModelSyncStatus: Sendable, Equatable {
    case notWired
    case current(modelIDs: [String])
    case stale(installedModelIDs: [String], expectedModelIDs: [String])

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }

    var userMessage: String {
        switch self {
        case .notWired:
            return "Droid is not wired through OpenBurnBar yet."
        case .current:
            return "Droid models match BurnBar's live catalog."
        case .stale(let installedModelIDs, let expectedModelIDs):
            if Set(installedModelIDs) == Set(expectedModelIDs) {
                // Same model IDs but stale — caused by gateway token rotation.
                // The sentry will auto-repair; the message explains why without
                // showing an identical and confusing installed vs. expected diff.
                return "Droid's BurnBar authentication credential is stale (gateway token rotated). Press Sync models to update."
            }
            let installed = installedModelIDs.isEmpty ? "none" : installedModelIDs.joined(separator: ", ")
            let expected = expectedModelIDs.isEmpty ? "none" : expectedModelIDs.joined(separator: ", ")
            return "Droid's BurnBar model list is stale. Installed: \(installed). Live now: \(expected). Press Sync models to rewrite Droid from /v1/models."
        }
    }
}

// MARK: - Service

/// Reusable wiring service for routed CLI clients. Surfaces (Settings cards,
/// onboarding flows) consume this directly. The service is `Sendable` so it
/// can be created per-call inside a `@MainActor` view-model.
///
/// Two modes are supported:
///
///   1. **Config-file mode** (`wire(...)` / `unwire(...)`): the helper writes
///      a sentinel-fenced block to the client's config file with a
///      timestamped backup. Removing the wiring restores the prior block
///      (or removes the OpenBurnBar block entirely when no prior config
///      existed).
///   2. **Snippet mode** (`shellSnippet(...)`): the helper returns a
///      copy/pasteable `export` block for users on bespoke shell setups.
///      No file writes.
struct RoutingClientWiring {

    static let sentinelStart = "# openburnbar:routing — start"
    static let sentinelEnd = "# openburnbar:routing — end"
    static let claudeCodeClientHeader = "X-OpenBurnBar-Client: claude-code"
    static let claudeCatalogFingerprintKey = "OPENBURNBAR_MODEL_CATALOG_FINGERPRINT"
    static let claudeCatalogIDsKey = "OPENBURNBAR_MODEL_CATALOG_IDS"
    static let claudeDiscoveryFlagKey = "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"
    static let codexProfileName = "openburnbar"
    static let codexCatalogFileName = "openburnbar-model-catalog.json"
    let fileManager: FileManager
    let home: URL
    let now: () -> Date

    init(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping () -> Date = { Date() }
    ) {
        self.fileManager = fileManager
        self.home = home
        self.now = now
    }

    // MARK: - File-mode wiring

    @discardableResult
    func wire(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel] = []
    ) throws -> RoutingClientWiringChange {
        try assertGatewayConfigured(gateway)
        switch target {
        case .claudeCode:
            return try wireClaudeCode(gateway: gateway, advertisedModels: advertisedModels)
        case .codex:
            return try wireCodex(gateway: gateway, advertisedModels: advertisedModels)
        case .opencode:
            return try wireOpenCode(gateway: gateway, advertisedModels: advertisedModels)
        case .forge:
            return try wireForge(gateway: gateway)
        case .droid:
            return try wireDroid(gateway: gateway, advertisedModels: advertisedModels)
        case .grok:
            return try wireGrok(gateway: gateway)
        case .antigravity:
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "Antigravity profile switching is supported, but Antigravity does not expose a file-based OpenAI-compatible routing config for OpenBurnBar to rewrite yet."
            )
        case .cursorAgent:
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "Cursor Agent profile switching is supported, but Cursor Agent does not expose a file-based OpenAI-compatible routing config for OpenBurnBar to rewrite yet."
            )
        }
    }

    @discardableResult
    func migrateFromVibeProxy(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel] = []
    ) throws -> RoutingClientWiringChange {
        try assertGatewayConfigured(gateway)
        switch target {
        case .claudeCode:
            return try wireClaudeCode(
                gateway: gateway,
                advertisedModels: advertisedModels,
                migrateExistingVibeProxy: true
            )
        case .codex:
            return try wireCodex(
                gateway: gateway,
                advertisedModels: advertisedModels,
                migrateExistingVibeProxy: true
            )
        case .opencode:
            return try wireOpenCode(
                gateway: gateway,
                advertisedModels: advertisedModels,
                migrateExistingVibeProxy: true
            )
        case .forge:
            return try wireForge(gateway: gateway, migrateExistingVibeProxy: true)
        case .droid:
            return try wireDroid(gateway: gateway, advertisedModels: advertisedModels)
        case .grok:
            return try wireGrok(gateway: gateway, migrateExistingVibeProxy: true)
        case .antigravity:
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "Antigravity uses profile-scoped local login state. Reconnect it in OpenBurnBar after migration."
            )
        case .cursorAgent:
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "Cursor Agent does not expose a file-based OpenAI-compatible routing config for OpenBurnBar to rewrite yet."
            )
        }
    }

    func unwire(target: RoutingClientWiringTarget) throws {
        switch target {
        case .claudeCode:
            try unwireClaudeCode()
        case .codex:
            try unwireCodex()
        case .opencode:
            try unwireOpenCode()
        case .forge:
            try unwireForge()
        case .droid:
            try unwireDroid()
        case .grok:
            try unwireGrok()
        case .antigravity:
            throw RoutingClientWiringError.notEnabled
        case .cursorAgent:
            throw RoutingClientWiringError.notEnabled
        }
    }

    /// Returns the path the helper would write to for the given target. Useful
    /// for the UI to show "Will modify ~/.claude/settings.json".
    func configURL(for target: RoutingClientWiringTarget) -> URL {
        switch target {
        case .claudeCode:
            return home.appendingPathComponent(".claude/settings.json")
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        case .opencode:
            return home.appendingPathComponent(".config/opencode/opencode.json")
        case .forge:
            return home.appendingPathComponent("forge/.forge.toml")
        case .droid:
            return home.appendingPathComponent(".factory/settings.local.json")
        case .grok:
            return home.appendingPathComponent(".grok/config.toml")
        case .antigravity:
            return home.appendingPathComponent(".gemini/antigravity-cli/settings.json")
        case .cursorAgent:
            return home.appendingPathComponent(".cursor-agent/settings.json")
        }
    }
}
