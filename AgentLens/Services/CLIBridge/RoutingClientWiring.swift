import Foundation

// MARK: - Public types

/// Identifies which routed-client target a wiring action applies to.
///
/// The router runs locally on the user's Mac at `127.0.0.1:<gatewayPort>`.
/// Each target speaks a single wire format, so it can only consume one
/// pool's accounts:
///
///   - `.claudeCode` — Anthropic Messages shape (`/v1/messages`). Reads
///     `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` and lives at
///     `~/.claude/settings.json` (`env` block).
///   - `.codex` — OpenAI Chat Completions shape (`/v1/chat/completions`).
///     Reads `OPENAI_BASE_URL` + `OPENAI_API_KEY` and lives at
///     `~/.codex/config.toml` (sentinel-fenced `[model_providers.…]` block).
///   - `.opencode` — OpenAI-compatible provider entry in
///     `~/.config/opencode/opencode.json`.
///   - `.forge` — OpenAI Chat Completions shape (`/v1/chat/completions`).
///     Reads an OpenBurnBar-owned Forge `[[providers]]` entry at
///     `~/forge/.forge.toml`.
///   - `.droid` — Factory Droid custom-model override in
///     `~/.factory/settings.local.json` (`customModels` entries).
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

    /// Which routing pool this client feeds.
    var poolDisplayName: String {
        switch self {
        case .claudeCode: return "Anthropic-family"
        case .codex, .opencode, .forge, .droid: return "OpenAI-family"
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
            return "This client is already wired through the Hydrant."
        case .notEnabled:
            return "This client is not currently wired through the Hydrant."
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
    private static let droidDefaultModels = ["gpt-5.5", "gpt-5", "gpt-5.4-nano"]

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
        gateway: RoutingClientGateway
    ) throws -> RoutingClientWiringChange {
        try assertGatewayConfigured(gateway)
        switch target {
        case .claudeCode:
            return try wireClaudeCode(gateway: gateway)
        case .codex:
            return try wireCodex(gateway: gateway)
        case .opencode:
            return try wireOpenCode(gateway: gateway)
        case .forge:
            return try wireForge(gateway: gateway)
        case .droid:
            return try wireDroid(gateway: gateway)
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
        guard fileManager.fileExists(atPath: url.path) else { return false }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        switch target {
        case .claudeCode:
            // Claude Code stores the env block as a JSON object, so we look
            // for our well-known marker key.
            return text.contains("\"OPENBURNBAR_WIRED\"") || text.contains(Self.sentinelStart)
        case .opencode:
            return text.contains("\"openburnbar\"") && text.contains("OpenBurnBar Gateway")
        case .droid:
            return text.contains("\"customModels\"")
                && (text.localizedCaseInsensitiveContains("openburnbar:")
                    || text.localizedCaseInsensitiveContains("OpenBurnBar "))
        case .codex, .forge:
            return text.contains(Self.sentinelStart)
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
            # OpenBurnBar — wire Claude Code through the Hydrant
            export ANTHROPIC_BASE_URL=\(baseURL)
            export ANTHROPIC_AUTH_TOKEN=\(token)
            """
        case .codex:
            return """
            # OpenBurnBar — wire Codex CLI through the Hydrant
            # `OPENAI_*` env vars are enough on their own — Codex picks them
            # up automatically and bypasses any config-file wiring. If you
            # also want a named provider entry (so `codex --profile
            # openburnbar` works), the OpenBurnBar Settings → Routing pools
            # toggle writes one for you in ~/.codex/config.toml.
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            """
        case .opencode:
            return """
            # OpenBurnBar — wire OpenCode CLI through the Hydrant
            # The config-file toggle adds provider.openburnbar to
            # ~/.config/opencode/opencode.json.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .forge:
            return """
            # OpenBurnBar — wire Forge CLI through the Hydrant
            # The config-file toggle adds a Forge provider named `openburnbar`
            # at ~/forge/.forge.toml. This env var supplies its api_key_var.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
        case .droid:
            return """
            # OpenBurnBar — wire Droid CLI through the Hydrant
            # The config-file toggle writes customModels into
            # ~/.factory/settings.local.json.
            export OPENBURNBAR_GATEWAY_TOKEN=\(token)
            export OPENAI_BASE_URL=\(openAIBaseURL)
            export OPENAI_API_KEY=\(token)
            """
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
        case .codex, .opencode, .forge, .droid:
            probeModel = "gpt-5.4-nano"
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
        case .codex, .opencode, .forge, .droid:
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

    private func wireCodex(gateway: RoutingClientGateway) throws -> RoutingClientWiringChange {
        let url = configURL(for: .codex)
        let existing = readText(at: url) ?? ""
        let stripped = stripSentinelBlock(in: existing)
        let block = codexTOMLBlock(gateway: gateway)
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

    private func codexTOMLBlock(gateway: RoutingClientGateway) -> String {
        // The provider block defines *how* to talk to the gateway; the
        // profile makes one-line activation possible:
        //
        //     codex --profile openburnbar
        //
        // The user still needs to export OPENBURNBAR_GATEWAY_TOKEN so Codex
        // can read the bearer at runtime. The Settings → Routing pools card
        // shows the exact export command and the shell-snippet sheet
        // includes it verbatim.
        """
        \(Self.sentinelStart)
        # Managed by OpenBurnBar. Edit Settings → Routing pools to change.
        # To activate this provider:
        #   1. export OPENBURNBAR_GATEWAY_TOKEN='<your gateway token>'
        #   2. codex --profile openburnbar
        # Or set OPENAI_BASE_URL/OPENAI_API_KEY directly and skip the profile.
        [model_providers.openburnbar]
        name = "OpenBurnBar Hydrant"
        base_url = "\(gateway.baseURL)/v1"
        env_key = "OPENBURNBAR_GATEWAY_TOKEN"
        wire_api = "chat"

        [profiles.openburnbar]
        model_provider = "openburnbar"
        \(Self.sentinelEnd)
        """
    }

    // MARK: - OpenCode (~/.config/opencode/opencode.json)

    private func wireOpenCode(gateway: RoutingClientGateway) throws -> RoutingClientWiringChange {
        let url = configURL(for: .opencode)
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)
        var providers = (root["provider"] as? [String: Any]) ?? [:]
        providers["openburnbar"] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "OpenBurnBar Gateway",
            "options": [
                "baseURL": "\(gateway.baseURL)/v1",
                "apiKey": gateway.effectiveClientToken,
            ],
            "models": [
                "gpt-5.4-nano": [
                    "name": "gpt-5.4-nano",
                ],
            ],
        ]
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
        # Managed by OpenBurnBar. Edit Settings → Routing pools to change.
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

    // MARK: - Droid (~/.factory/settings.local.json)

    private func wireDroid(gateway: RoutingClientGateway) throws -> RoutingClientWiringChange {
        let url = configURL(for: .droid)
        var (root, backupURL) = try loadJSONObjectWithBackup(at: url)
        var customModels = (root["customModels"] as? [[String: Any]]) ?? []
        customModels.removeAll(where: isOpenBurnBarDroidModel)
        let startIndex = customModels.count
        customModels.append(contentsOf: Self.droidDefaultModels.enumerated().map { offset, model in
            [
                "model": model,
                "id": "openburnbar:\(model)",
                "index": startIndex + offset,
                "baseUrl": "\(gateway.baseURL)/v1",
                "apiKey": gateway.effectiveClientToken,
                "displayName": "OpenBurnBar \(model)",
                "maxOutputTokens": 8192,
                "provider": "openai",
            ] as [String: Any]
        })
        root["customModels"] = customModels
        try writeJSONObject(root, to: url)
        return RoutingClientWiringChange(
            target: .droid,
            configURL: url,
            backupURL: backupURL,
            appliedAt: now()
        )
    }

    private func unwireDroid() throws {
        let url = configURL(for: .droid)
        guard fileManager.fileExists(atPath: url.path) else {
            throw RoutingClientWiringError.notEnabled
        }
        var (root, _) = try loadJSONObjectWithBackup(at: url)
        guard var customModels = root["customModels"] as? [[String: Any]],
              customModels.contains(where: isOpenBurnBarDroidModel) else {
            throw RoutingClientWiringError.notEnabled
        }
        customModels.removeAll(where: isOpenBurnBarDroidModel)
        if customModels.isEmpty {
            root.removeValue(forKey: "customModels")
        } else {
            root["customModels"] = customModels
        }
        if root.isEmpty {
            try? fileManager.removeItem(at: url)
        } else {
            try writeJSONObject(root, to: url)
        }
    }

    private func isOpenBurnBarDroidModel(_ entry: [String: Any]) -> Bool {
        let provider = (entry["provider"] as? String)?.lowercased()
        let id = (entry["id"] as? String)?.lowercased()
        let displayName = (entry["displayName"] as? String)?.lowercased()
        let model = (entry["model"] as? String)?.lowercased()
        return provider == "openburnbar"
            || id?.hasPrefix("openburnbar:") == true
            || displayName?.hasPrefix("openburnbar ") == true
            || model?.hasPrefix("openburnbar:") == true
    }

    // MARK: - JSON file helpers

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
