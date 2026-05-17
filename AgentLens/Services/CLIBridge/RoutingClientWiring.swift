import Foundation

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
enum RoutingClientWiringTarget: String, CaseIterable, Identifiable, Sendable {
    case claudeCode
    case codex
    case opencode
    case forge
    case droid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .opencode: return "OpenCode CLI"
        case .forge: return "Forge CLI"
        case .droid: return "Droid CLI"
        }
    }

    /// Which local endpoint family this client feeds.
    var poolDisplayName: String {
        switch self {
        case .claudeCode: return "Anthropic Messages"
        case .codex, .opencode, .forge, .droid: return "OpenAI-style gateway"
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
    let routeEligible: Bool

    init(
        id: String,
        displayName: String,
        providerID: String,
        providerName: String,
        formatFamily: String = "openai_compat",
        servedEndpoints: [String] = ["/v1/chat/completions", "/v1/responses"],
        capabilities: [String] = [],
        routeEligible: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.providerID = providerID
        self.providerName = providerName
        self.formatFamily = formatFamily
        self.servedEndpoints = servedEndpoints
        self.capabilities = capabilities
        self.routeEligible = routeEligible
    }

    var isGatewayServedModelCandidate: Bool {
        guard routeEligible else { return false }
        return servedEndpoints.isEmpty
            || servedEndpoints.contains("/v1/chat/completions")
            || servedEndpoints.contains("/v1/responses")
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
        if providerText.contains("openai") || providerText.contains("azure openai") {
            return "openai"
        }
        return "generic-chat-completion-api"
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

    private static let sentinelStart = "# openburnbar:routing — start"
    private static let sentinelEnd = "# openburnbar:routing — end"
    /// Probe model used by `probe(target: .claudeCode, …)`. Mirrors
    /// `AnthropicCredentialProbe.defaultProbeModel` — keep in lockstep.
    private static let anthropicProbeModel = "claude-haiku-4-5"

    private let fileManager: FileManager
    private let home: URL
    private let now: () -> Date

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
            return try wireClaudeCode(gateway: gateway)
        case .codex:
            return try wireCodex(gateway: gateway, advertisedModels: advertisedModels)
        case .opencode:
            return try wireOpenCode(gateway: gateway, advertisedModels: advertisedModels)
        case .forge:
            return try wireForge(gateway: gateway)
        case .droid:
            return try wireDroid(gateway: gateway, advertisedModels: advertisedModels)
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
        }
    }

    /// Whether the helper currently sees the OpenBurnBar marker in the
    /// target's config file. Surfaces use this to render an accurate
    /// "wired / not wired" pill without having to track the toggle state
    /// in user defaults.
    func isWired(target: RoutingClientWiringTarget) -> Bool {
        let url = configURL(for: target)
        switch target {
        case .claudeCode:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            if let root = try? readJSONObject(at: url),
               let env = root["env"] as? [String: Any] {
                if env["OPENBURNBAR_WIRED"] != nil { return true }
                if let baseURL = env["ANTHROPIC_BASE_URL"] as? String,
                   isLocalGatewayURL(baseURL) {
                    return true
                }
            }
            return text.contains(Self.sentinelStart)
        case .opencode:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            if let root = try? readJSONObject(at: url),
               let providers = root["provider"] as? [String: Any],
               let provider = providers["openburnbar"] as? [String: Any] {
                if let options = provider["options"] as? [String: Any],
                   let baseURL = options["baseURL"] as? String,
                   isLocalGatewayURL(baseURL) {
                    return true
                }
                if let models = provider["models"] as? [String: Any], !models.isEmpty {
                    return true
                }
            }
            return text.contains("\"openburnbar\"") && text.localizedCaseInsensitiveContains("OpenBurnBar Gateway")
        case .droid:
            return droidConfigURLs().contains { url in
                guard fileManager.fileExists(atPath: url.path),
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return false
                }
                if let root = try? readJSONObject(at: url) {
                    let settingsModels = (root["customModels"] as? [[String: Any]]) ?? []
                    let configModels = (root["custom_models"] as? [[String: Any]]) ?? []
                    if (settingsModels + configModels).contains(where: { isOpenBurnBarDroidModel($0) }) {
                        return true
                    }
                }
                return (text.contains("\"customModels\"") || text.contains("\"custom_models\""))
                    && (text.localizedCaseInsensitiveContains("custom:OpenBurnBar")
                        || text.localizedCaseInsensitiveContains("openburnbar:")
                        || text.localizedCaseInsensitiveContains("OpenBurnBar "))
            }
        case .codex:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(Self.sentinelStart)
                || (text.contains("[model_providers.openburnbar]") && text.contains("base_url") && text.contains(":8317"))
                || text.range(of: #"base_url\s*=\s*"https?://(127\.0\.0\.1|localhost):8317(/v1)?/?.*""#, options: .regularExpression) != nil
        case .forge:
            guard fileManager.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains(Self.sentinelStart)
                || (text.contains(#"id = "openburnbar""#) && text.contains(":8317"))
                || text.range(of: #"url\s*=\s*"https?://(127\.0\.0\.1|localhost):8317(/v1)?/chat/completions""#, options: .regularExpression) != nil
        }
    }

    /// Compares a routed client's on-disk OpenBurnBar model entries with the
    /// live route-eligible catalog. Today only Droid needs this because its
    /// BYOK model picker caches concrete model rows instead of asking
    /// `/v1/models` on every launch.
    func modelSyncStatus(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) -> RoutingClientModelSyncStatus {
        switch target {
        case .droid:
            let expected = gatewayServedModelIDs(advertisedModels)
            let installed = installedDroidOpenBurnBarModelIDs(gateway: gateway)
            guard !installed.isEmpty else { return .notWired }
            guard Set(installed) == Set(expected) else {
                return .stale(installedModelIDs: installed, expectedModelIDs: expected)
            }
            return .current(modelIDs: installed)
        case .claudeCode, .codex, .opencode, .forge:
            return isWired(target: target) ? .current(modelIDs: []) : .notWired
        }
    }

    // MARK: - Snippet-mode wiring

    /// A copy/pasteable shell block that achieves the same wiring without
    /// touching any config file. Users on managed dotfiles or non-standard
    /// shells prefer this path. The snippet is always self-contained and can
    /// be pasted into `~/.zshrc`, `~/.bashrc`, or sourced ad-hoc.
    ///
    /// Tokens are emitted inside single quotes so `$`, backticks, double
    /// quotes, and backslashes pass through verbatim. Any literal `'` in
    /// the token is escaped with the standard `'\''` POSIX dance.
    func shellSnippet(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway
    ) -> String {
        let baseURL = Self.shellQuote(gateway.baseURL)
        let openAIBaseURL = Self.shellQuote("\(gateway.baseURL)/v1")
        let token = Self.shellQuote(gateway.effectiveClientToken)
        switch target {
        case .claudeCode:
            return """
            # OpenBurnBar — wire Claude Code through the local gateway
            export ANTHROPIC_BASE_URL=\(baseURL)
            export ANTHROPIC_AUTH_TOKEN=\(token)
            """
        case .codex:
            return """
            # OpenBurnBar — wire Codex CLI through the local gateway
            # `OPENAI_*` env vars are enough on their own — Codex picks them
            # up automatically and bypasses any config-file wiring. If you
            # also want a named provider entry (so `codex --profile
            # openburnbar` works), OpenBurnBar Settings -> Agents -> CLIs
            # writes one for you in ~/.codex/config.toml.
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            """
        case .opencode:
            return """
            # OpenBurnBar — wire OpenCode CLI through the local gateway
            # The Settings -> Agents -> CLIs Connect button adds provider.openburnbar to
            # ~/.config/opencode/opencode.json.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .forge:
            return """
            # OpenBurnBar — wire Forge CLI through the local gateway
            # The Settings -> Agents -> CLIs Connect button adds a Forge provider named `openburnbar`
            # at ~/forge/.forge.toml. This env var supplies its api_key_var.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .droid:
            return """
            # OpenBurnBar — wire Droid CLI through the local gateway
            # In OpenBurnBar Settings -> Agents -> CLIs, press Connect + Sync
            # or Sync models to write live BurnBar models under ~/.factory/.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        }
    }

    func advertisedModels(
        gateway: RoutingClientGateway,
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 8
    ) async -> [RoutingClientAdvertisedModel] {
        guard let url = URL(string: gateway.baseURL)?.appending(path: "v1/models") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        if !gateway.authToken.isEmpty {
            request.setValue("Bearer \(gateway.authToken)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["data"] as? [[String: Any]] else {
                return []
            }
            return rows.compactMap { row in
                guard let id = (row["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !id.isEmpty else {
                    return nil
                }
                let providerID = (row["provider_id"] as? String)
                    ?? (row["owned_by"] as? String)
                    ?? "openburnbar"
                let providerName = (row["provider_name"] as? String)
                    ?? providerID
                return RoutingClientAdvertisedModel(
                    id: id,
                    displayName: (row["display_name"] as? String) ?? id,
                    providerID: providerID,
                    providerName: providerName,
                    formatFamily: (row["format_family"] as? String) ?? "openai_compat",
                    servedEndpoints: (row["served_endpoints"] as? [String]) ?? [],
                    capabilities: (row["capabilities"] as? [String]) ?? [],
                    routeEligible: (row["route_eligible"] as? Bool) ?? true
                )
            }
        } catch {
            return []
        }
    }

    /// POSIX-safe single-quoted shell argument. Embedded single quotes are
    /// emitted as the standard `'\''` sequence.
    static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    // MARK: - Probe

    /// Hit the local gateway with a `max_tokens: 1` request shaped for the
    /// target's wire format. Confirms the gateway responds before the helper
    /// reports "wired". Surfaces the upstream status code so failures point
    /// the user at the right account-management UI.
    func probe(
        target: RoutingClientWiringTarget,
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel] = [],
        session: URLSession = .shared,
        timeoutSeconds: TimeInterval = 8
    ) async -> RoutingClientWiringProbe {
        guard let url = probeURL(target: target, gateway: gateway) else {
            return .skipped(reason: "Could not construct probe URL for \(gateway.baseURL).")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        if !gateway.authToken.isEmpty {
            request.setValue("Bearer \(gateway.authToken)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any]
        let probeModel: String
        switch target {
        case .claudeCode:
            probeModel = Self.anthropicProbeModel
            // Anthropic Messages uses `max_tokens`. Older versions of the
            // Messages API rejected requests that didn't include this field,
            // so we send it explicitly even for a 1-token probe.
            body = [
                "model": probeModel,
                "max_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
        case .codex:
            let models = advertisedModels.isEmpty
                ? await self.advertisedModels(gateway: gateway, session: session, timeoutSeconds: timeoutSeconds)
                : advertisedModels
            guard let liveModel = firstGatewayServedModel(models) else {
                return .failed(
                    status: 503,
                    message: "No route-eligible gateway models are advertised by /v1/models."
                )
            }
            probeModel = liveModel.id
            body = [
                "model": probeModel,
                "input": "ping",
                "max_output_tokens": 1,
            ]
        case .opencode, .forge, .droid:
            let models = advertisedModels.isEmpty
                ? await self.advertisedModels(gateway: gateway, session: session, timeoutSeconds: timeoutSeconds)
                : advertisedModels
            guard let liveModel = firstGatewayServedModel(models) else {
                return .failed(
                    status: 503,
                    message: "No route-eligible gateway models are advertised by /v1/models."
                )
            }
            probeModel = liveModel.id
            // OpenAI Chat Completions deprecated `max_tokens` for reasoning-
            // capable models in favor of `max_completion_tokens`. The
            // gateway's structured-executor tests use `max_completion_tokens`
            // (OpenBurnBarHTTPGatewayServerTests.swift:258), so we match.
            body = [
                "model": probeModel,
                "max_completion_tokens": 1,
                "messages": [["role": "user", "content": "ping"]]
            ]
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            return .failed(status: 0, message: "could not encode probe body: \(error.localizedDescription)")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed(status: 0, message: "missing HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .ok(modelID: probeModel)
            }
            let bodyText = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            return .failed(status: http.statusCode, message: String(bodyText))
        } catch {
            return .failed(status: 0, message: error.localizedDescription)
        }
    }

    // MARK: - Private helpers

    private func assertGatewayConfigured(_ gateway: RoutingClientGateway) throws {
        if gateway.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw RoutingClientWiringError.gatewayMisconfigured(detail: "Gateway host is empty.")
        }
        if gateway.port <= 0 || gateway.port > 65_535 {
            throw RoutingClientWiringError.gatewayMisconfigured(detail: "Gateway port \(gateway.port) is out of range.")
        }
        if gateway.authToken.isEmpty && !gateway.isLoopbackHost {
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "A non-loopback gateway needs an auth token. Generate one under Settings → Daemon → HTTP gateway before wiring a client."
            )
        }
    }

    private func probeURL(target: RoutingClientWiringTarget, gateway: RoutingClientGateway) -> URL? {
        let base = URL(string: gateway.baseURL)
        switch target {
        case .claudeCode:
            return base?.appending(path: "v1/messages")
        case .codex:
            return base?.appending(path: "v1/responses")
        case .opencode, .forge, .droid:
            return base?.appending(path: "v1/chat/completions")
        }
    }

    // MARK: - Claude Code (~/.claude/settings.json)

    private func wireClaudeCode(gateway: RoutingClientGateway) throws -> RoutingClientWiringChange {
        let url = configURL(for: .claudeCode)
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)

        var env = (root["env"] as? [String: Any]) ?? [:]
        env["ANTHROPIC_BASE_URL"] = gateway.baseURL
        env["ANTHROPIC_AUTH_TOKEN"] = gateway.effectiveClientToken
        // Used by `isWired(...)` for round-trip detection. Never read by
        // Claude Code itself.
        env["OPENBURNBAR_WIRED"] = "1"
        root["env"] = env

        try writeJSONObject(root, to: url)
        return RoutingClientWiringChange(
            target: .claudeCode,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    private func unwireClaudeCode() throws {
        let url = configURL(for: .claudeCode)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RoutingClientWiringError.notEnabled
        }
        var (root, _) = try loadJSONObjectWithBackup(at: url)
        guard var env = root["env"] as? [String: Any] else {
            throw RoutingClientWiringError.notEnabled
        }
        env.removeValue(forKey: "ANTHROPIC_BASE_URL")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        env.removeValue(forKey: "OPENBURNBAR_WIRED")
        if env.isEmpty {
            root.removeValue(forKey: "env")
        } else {
            root["env"] = env
        }
        try writeJSONObject(root, to: url)
    }

    // MARK: - Codex (~/.codex/config.toml)

    private func wireCodex(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .codex)
        let existing = readText(at: url) ?? ""
        let stripped = stripSentinelBlock(in: existing)
        let block = codexTOMLBlock(gateway: gateway, advertisedModels: advertisedModels)
        let separator = stripped.isEmpty || stripped.hasSuffix("\n") ? "" : "\n"
        let next = stripped + separator + block + "\n"

        let backupURL = try backupIfExists(url: url)
        try writeText(next, to: url)
        return RoutingClientWiringChange(
            target: .codex,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    private func unwireCodex() throws {
        let url = configURL(for: .codex)
        guard let existing = readText(at: url) else {
            throw RoutingClientWiringError.notEnabled
        }
        guard existing.contains(Self.sentinelStart) else {
            throw RoutingClientWiringError.notEnabled
        }
        let next = stripSentinelBlock(in: existing)
        if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            _ = try? backupIfExists(url: url)
            try writeText(next, to: url)
        }
    }

    private func codexTOMLBlock(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) -> String {
        // The provider block defines *how* to talk to the gateway; the
        // profile makes one-line activation possible:
        //
        //     codex --profile openburnbar
        //
        // The user still needs to export OPENBURNBAR_GATEWAY_TOKEN so Codex
        // can read the bearer at runtime. The Settings -> Agents -> CLIs row
        // shows the exact export command and the shell-snippet sheet
        // includes it verbatim.
        let modelLine = firstGatewayServedModel(advertisedModels)
            .map { "\nmodel = \"\($0.id)\"" }
            ?? ""
        return """
        \(Self.sentinelStart)
        # Managed by OpenBurnBar. Edit Settings -> Agents -> CLIs to change.
        # To activate this provider:
        #   1. export OPENBURNBAR_GATEWAY_TOKEN='<your gateway token>'
        #   2. codex --profile openburnbar
        # Or set OPENAI_BASE_URL/OPENAI_API_KEY directly and skip the profile.
        [model_providers.openburnbar]
        name = "OpenBurnBar Gateway"
        base_url = "\(gateway.baseURL)/v1"
        env_key = "OPENBURNBAR_GATEWAY_TOKEN"
        wire_api = "responses"

        [profiles.openburnbar]
        model_provider = "openburnbar"
        \(modelLine)
        \(Self.sentinelEnd)
        """
    }

    // MARK: - OpenCode (~/.config/opencode/opencode.json)

    private func wireOpenCode(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .opencode)
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)
        var providers = (root["provider"] as? [String: Any]) ?? [:]
        let liveModels = try gatewayServedModelsOrThrow(advertisedModels)
        providers["openburnbar"] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "OpenBurnBar Gateway",
            "options": [
                "baseURL": "\(gateway.baseURL)/v1",
                "apiKey": gateway.effectiveClientToken,
            ],
            "models": Dictionary(
                uniqueKeysWithValues: liveModels.map { model in
                    (model.id, ["name": model.displayName.isEmpty ? model.id : model.displayName])
                }
            ),
        ]
        root["model"] = "openburnbar/\(liveModels[0].id)"
        root["provider"] = providers
        try writeJSONObject(root, to: url)
        return RoutingClientWiringChange(
            target: .opencode,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    private func unwireOpenCode() throws {
        let url = configURL(for: .opencode)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RoutingClientWiringError.notEnabled
        }
        var (root, _) = try loadJSONObjectWithBackup(at: url)
        guard var providers = root["provider"] as? [String: Any],
              providers["openburnbar"] != nil else {
            throw RoutingClientWiringError.notEnabled
        }
        providers.removeValue(forKey: "openburnbar")
        if providers.isEmpty {
            root.removeValue(forKey: "provider")
        } else {
            root["provider"] = providers
        }
        try writeJSONObject(root, to: url)
    }

    // MARK: - Forge (~/forge/.forge.toml)

    private func wireForge(gateway: RoutingClientGateway) throws -> RoutingClientWiringChange {
        let url = configURL(for: .forge)
        let existing = readText(at: url) ?? ""
        let stripped = stripSentinelBlock(in: existing)
        let block = forgeTOMLBlock(gateway: gateway)
        let separator = stripped.isEmpty || stripped.hasSuffix("\n") ? "" : "\n"
        let next = stripped + separator + block + "\n"

        let backupURL = try backupIfExists(url: url)
        try writeText(next, to: url)
        return RoutingClientWiringChange(
            target: .forge,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    private func unwireForge() throws {
        let url = configURL(for: .forge)
        guard let existing = readText(at: url) else {
            throw RoutingClientWiringError.notEnabled
        }
        guard existing.contains(Self.sentinelStart) else {
            throw RoutingClientWiringError.notEnabled
        }
        let next = stripSentinelBlock(in: existing)
        if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            _ = try? backupIfExists(url: url)
            try writeText(next, to: url)
        }
    }

    private func forgeTOMLBlock(gateway: RoutingClientGateway) -> String {
        // Forge supports a chat-completions URL plus a separate models URL.
        // We do not change the active `[session]` provider so users can opt
        // in deliberately.
        """
        \(Self.sentinelStart)
        # Managed by OpenBurnBar. Edit Settings -> Agents -> CLIs to change.
        # To activate in Forge, select provider `openburnbar` or set it in
        # your Forge session after exporting OPENBURNBAR_GATEWAY_TOKEN.
        [[providers]]
        id = "openburnbar"
        api_key_var = "OPENBURNBAR_GATEWAY_TOKEN"
        url = "\(gateway.baseURL)/v1/chat/completions"
        models = "\(gateway.baseURL)/v1/models"
        response_type = "OpenAI"
        \(Self.sentinelEnd)
        """
    }

    // MARK: - Droid (~/.factory/{settings.local.json,settings.json,config.json})

    private func wireDroid(
        gateway: RoutingClientGateway,
        advertisedModels: [RoutingClientAdvertisedModel]
    ) throws -> RoutingClientWiringChange {
        let url = configURL(for: .droid)
        let liveModels = try gatewayServedModelsOrThrow(advertisedModels)
        let backupURL = try writeDroidSettingsStyleModels(
            to: url,
            gateway: gateway,
            liveModels: liveModels
        )
        try writeDroidSettingsStyleModels(
            to: home.appendingPathComponent(".factory/settings.json"),
            gateway: gateway,
            liveModels: liveModels
        )
        try writeDroidConfigStyleModels(
            to: home.appendingPathComponent(".factory/config.json"),
            gateway: gateway,
            liveModels: liveModels
        )
        return RoutingClientWiringChange(
            target: .droid,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    private func unwireDroid() throws {
        var removedAny = false
        for url in droidConfigURLs() where fileManager.fileExists(atPath: url.path) {
            var (root, _) = try loadJSONObjectWithBackup(at: url)
            let removedSettings = removeOpenBurnBarDroidModels(
                key: "customModels",
                from: &root
            )
            let removedConfig = removeOpenBurnBarDroidModels(
                key: "custom_models",
                from: &root
            )
            let removedDefaults = removeManagedDroidDefaultModel(from: &root)
            guard removedSettings || removedConfig || removedDefaults else { continue }
            removedAny = true
            if root.isEmpty {
                try? fileManager.removeItem(at: url)
            } else {
                try writeJSONObject(root, to: url)
            }
        }
        guard removedAny else {
            throw RoutingClientWiringError.notEnabled
        }
    }

    @discardableResult
    private func writeDroidSettingsStyleModels(
        to url: URL,
        gateway: RoutingClientGateway,
        liveModels: [RoutingClientAdvertisedModel]
    ) throws -> URL? {
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)
        var customModels = (root["customModels"] as? [[String: Any]]) ?? []
        customModels.removeAll { isOpenBurnBarDroidModel($0, gateway: gateway) }
        let startIndex = customModels.count
        let openBurnBarModels = liveModels.enumerated().map { offset, model in
            droidSettingsStyleModelEntry(
                model: model,
                gateway: gateway,
                index: startIndex + offset
            )
        }
        customModels.append(contentsOf: openBurnBarModels)
        root["customModels"] = customModels
        updateDroidDefaultModelIfManaged(
            root: &root,
            fallbackModelID: openBurnBarModels.first?["id"] as? String
        )
        try writeJSONObject(root, to: url)
        return backupURL
    }

    private func writeDroidConfigStyleModels(
        to url: URL,
        gateway: RoutingClientGateway,
        liveModels: [RoutingClientAdvertisedModel]
    ) throws {
        var (root, _) = try loadJSONObjectWithBackup(at: url)
        var customModels = (root["custom_models"] as? [[String: Any]]) ?? []
        customModels.removeAll { isOpenBurnBarDroidModel($0, gateway: gateway) }
        customModels.append(contentsOf: liveModels.map { model in
            [
                "model_display_name": "OpenBurnBar \(model.displayName.isEmpty ? model.id : model.displayName)",
                "model": model.id,
                "base_url": "\(gateway.baseURL)/v1",
                "api_key": gateway.effectiveClientToken,
                "max_output_tokens": 8192,
                "provider": model.droidProviderType,
            ] as [String: Any]
        })
        root["custom_models"] = customModels
        try writeJSONObject(root, to: url)
    }

    private func droidSettingsStyleModelEntry(
        model: RoutingClientAdvertisedModel,
        gateway: RoutingClientGateway,
        index: Int
    ) -> [String: Any] {
        [
            "model": model.id,
            "id": droidCustomModelID(for: model, index: index),
            "index": index,
            "baseUrl": "\(gateway.baseURL)/v1",
            "apiKey": gateway.effectiveClientToken,
            "displayName": "OpenBurnBar \(model.displayName.isEmpty ? model.id : model.displayName)",
            "maxOutputTokens": 8192,
            "provider": model.droidProviderType,
        ]
    }

    private func droidCustomModelID(
        for model: RoutingClientAdvertisedModel,
        index: Int
    ) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = model.id
            .unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()
        let slug = sanitized
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
            .isEmpty ? "model" : sanitized
        return "custom:OpenBurnBar-\(slug)-\(index)"
    }

    private func removeOpenBurnBarDroidModels(
        key: String,
        from root: inout [String: Any]
    ) -> Bool {
        guard var customModels = root[key] as? [[String: Any]],
              customModels.contains(where: { isOpenBurnBarDroidModel($0) }) else {
            return false
        }
        customModels.removeAll { isOpenBurnBarDroidModel($0) }
        if customModels.isEmpty {
            root.removeValue(forKey: key)
        } else {
            root[key] = customModels
        }
        return true
    }

    private func droidConfigURLs() -> [URL] {
        [
            configURL(for: .droid),
            home.appendingPathComponent(".factory/settings.json"),
            home.appendingPathComponent(".factory/config.json"),
        ]
    }

    private func isOpenBurnBarDroidModel(
        _ entry: [String: Any],
        gateway: RoutingClientGateway? = nil
    ) -> Bool {
        let provider = (entry["provider"] as? String)?.lowercased()
        let id = (entry["id"] as? String)?.lowercased()
        let displayName = (entry["displayName"] as? String)?.lowercased()
            ?? (entry["model_display_name"] as? String)?.lowercased()
        let model = (entry["model"] as? String)?.lowercased()
        let baseURL = (entry["baseUrl"] as? String) ?? (entry["base_url"] as? String)
        let isGatewayEntry = baseURL.map { isLocalGatewayURL($0) || matchesGatewayURL($0, gateway: gateway) } == true
        return provider == "openburnbar"
            || id?.hasPrefix("custom:openburnbar") == true
            || id?.hasPrefix("openburnbar:") == true
            || id?.contains("vibeproxy") == true
            || displayName?.hasPrefix("openburnbar ") == true
            || displayName?.contains("vibeproxy") == true
            || model?.hasPrefix("openburnbar:") == true
            || ((provider == "openai"
                 || provider == "anthropic"
                 || provider == "generic-chat-completion-api")
                && isGatewayEntry)
    }

    private func updateDroidDefaultModelIfManaged(
        root: inout [String: Any],
        fallbackModelID: String?
    ) {
        guard let fallbackModelID else { return }
        if shouldReplaceDroidDefaultModel(root["model"] as? String) {
            root["model"] = fallbackModelID
        }
        if var sessionDefaultSettings = root["sessionDefaultSettings"] as? [String: Any],
           shouldReplaceDroidDefaultModel(sessionDefaultSettings["model"] as? String) {
            sessionDefaultSettings["model"] = fallbackModelID
            root["sessionDefaultSettings"] = sessionDefaultSettings
        }
    }

    private func shouldReplaceDroidDefaultModel(_ value: String?) -> Bool {
        guard let value else { return true }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return isManagedDroidDefaultModel(trimmed)
    }

    private func isManagedDroidDefaultModel(_ value: String?) -> Bool {
        guard let value else { return false }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowercased = trimmed.lowercased()
        return lowercased.hasPrefix("custom:openburnbar")
            || lowercased.hasPrefix("openburnbar:")
            || lowercased.contains("vibeproxy")
    }

    @discardableResult
    private func removeManagedDroidDefaultModel(from root: inout [String: Any]) -> Bool {
        var removed = false
        if isManagedDroidDefaultModel(root["model"] as? String) {
            root.removeValue(forKey: "model")
            removed = true
        }
        if var sessionDefaultSettings = root["sessionDefaultSettings"] as? [String: Any],
           isManagedDroidDefaultModel(sessionDefaultSettings["model"] as? String) {
            sessionDefaultSettings.removeValue(forKey: "model")
            if sessionDefaultSettings.isEmpty {
                root.removeValue(forKey: "sessionDefaultSettings")
            } else {
                root["sessionDefaultSettings"] = sessionDefaultSettings
            }
            removed = true
        }
        return removed
    }

    private func isLocalGatewayURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              components.port == 8317 else {
            return false
        }
        return true
    }

    private func matchesGatewayURL(_ rawValue: String, gateway: RoutingClientGateway?) -> Bool {
        guard let gateway,
              let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let gatewayComponents = URLComponents(string: gateway.baseURL),
              let host = components.host?.lowercased(),
              let gatewayHost = gatewayComponents.host?.lowercased(),
              host == gatewayHost,
              components.port == gatewayComponents.port else {
            return false
        }
        return true
    }

    private func firstGatewayServedModel(
        _ advertisedModels: [RoutingClientAdvertisedModel]
    ) -> RoutingClientAdvertisedModel? {
        advertisedModels.first(where: \.isGatewayServedModelCandidate)
    }

    private func gatewayServedModelsOrThrow(
        _ advertisedModels: [RoutingClientAdvertisedModel]
    ) throws -> [RoutingClientAdvertisedModel] {
        let models = advertisedModels.filter(\.isGatewayServedModelCandidate)
        guard !models.isEmpty else {
            throw RoutingClientWiringError.gatewayMisconfigured(
                detail: "No route-eligible gateway models are advertised by /v1/models. Add or enable an account/provider before wiring this CLI."
            )
        }
        return models
    }

    private func gatewayServedModelIDs(
        _ advertisedModels: [RoutingClientAdvertisedModel]
    ) -> [String] {
        advertisedModels
            .filter(\.isGatewayServedModelCandidate)
            .map(\.id)
            .uniquedPreservingOrder()
    }

    private func installedDroidOpenBurnBarModelIDs(
        gateway: RoutingClientGateway
    ) -> [String] {
        var installed: [String] = []
        for url in droidConfigURLs() where fileManager.fileExists(atPath: url.path) {
            guard let root = try? readJSONObject(at: url) else { continue }
            let settingsModels = (root["customModels"] as? [[String: Any]]) ?? []
            let configModels = (root["custom_models"] as? [[String: Any]]) ?? []
            for entry in settingsModels + configModels where isOpenBurnBarDroidModel(entry, gateway: gateway) {
                guard let model = entry["model"] as? String,
                      !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                installed.append(model)
            }
        }
        return installed.uniquedPreservingOrder()
    }

    // MARK: - JSON file helpers

    private func readJSONObject(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        let stripped = stripJSONComments(String(decoding: data, as: UTF8.self))
        guard !stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any]) ?? [:]
    }

    private func loadJSONObjectWithBackup(at url: URL) throws -> (root: [String: Any], backupURL: URL?) {
        guard fileManager.fileExists(atPath: url.path) else {
            return ([:], nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw RoutingClientWiringError.configReadFailed(path: url.path, detail: error.localizedDescription)
        }
        let stripped = stripJSONComments(String(decoding: data, as: UTF8.self))
        let object: [String: Any]
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object = [:]
        } else {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] else {
                throw RoutingClientWiringError.configReadFailed(
                    path: url.path,
                    detail: "could not parse JSON"
                )
            }
            object = parsed
        }
        let backupURL = try backupIfExists(url: url)
        return (object, backupURL)
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try ensureParentDirectory(of: url)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            throw RoutingClientWiringError.configWriteFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    private func stripJSONComments(_ source: String) -> String {
        // Claude Code's settings.json sometimes ships with `//` comments.
        // Strip them defensively before parsing so we don't lose user edits.
        var result = ""
        result.reserveCapacity(source.count)
        var inString = false
        var iterator = source.makeIterator()
        var lookahead: Character?
        while let ch = lookahead ?? iterator.next() {
            lookahead = nil
            if ch == "\\", let nextChar = iterator.next() {
                result.append(ch)
                result.append(nextChar)
                continue
            }
            if ch == "\"" {
                inString.toggle()
                result.append(ch)
                continue
            }
            if !inString, ch == "/" {
                guard let next = iterator.next() else {
                    result.append(ch)
                    break
                }
                if next == "/" {
                    while let c = iterator.next(), c != "\n" { _ = c }
                    result.append("\n")
                    continue
                }
                if next == "*" {
                    var prev: Character? = nil
                    while let c = iterator.next() {
                        if prev == "*" && c == "/" { break }
                        prev = c
                    }
                    continue
                }
                result.append(ch)
                lookahead = next
                continue
            }
            result.append(ch)
        }
        return result
    }

    // MARK: - Text file helpers

    private func readText(at url: URL) -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try ensureParentDirectory(of: url)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw RoutingClientWiringError.configWriteFailed(path: url.path, detail: error.localizedDescription)
        }
    }

    private func stripSentinelBlock(in source: String) -> String {
        guard let startRange = source.range(of: Self.sentinelStart) else { return source }
        guard let endRange = source.range(of: Self.sentinelEnd, range: startRange.upperBound..<source.endIndex) else {
            // Sentinel start without end — bail out and leave the file alone
            // rather than corrupt it.
            return source
        }
        var stripped = source
        stripped.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: "")
        // Collapse the trailing newline left from the removed block.
        while stripped.hasSuffix("\n\n") {
            stripped.removeLast()
        }
        return stripped
    }

    private func ensureParentDirectory(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw RoutingClientWiringError.configWriteFailed(path: directory.path, detail: error.localizedDescription)
            }
        }
    }

    private func backupIfExists(url: URL) throws -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let stamp = backupStamp()
        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).openburnbar-backup-\(stamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            return backupURL
        }
        do {
            try fileManager.copyItem(at: url, to: backupURL)
        } catch {
            throw RoutingClientWiringError.backupFailed(path: url.path, detail: error.localizedDescription)
        }
        return backupURL
    }

    private func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: now())
    }
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
