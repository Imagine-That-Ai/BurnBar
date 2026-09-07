import Foundation

// MARK: - MCP Client Wiring
//
// One-click install of OpenBurnBar's MCP server into the coding agents the user
// already runs — the distribution half of "serve the corpus back into every
// agent". BurnBar has safely rewritten eight agent config formats for gateway
// routing (`RoutingClientWiring`); this points the same discipline at MCP:
//
//   Claude Code    — `~/.claude.json`, top-level `mcpServers` object
//   Cursor         — `~/.cursor/mcp.json`, `mcpServers` object
//   Codex CLI      — `~/.codex/config.toml`, sentinel-fenced `[mcp_servers.*]` block
//   Factory Droid  — `~/.factory/mcp.json`, `mcpServers` object with `type: "stdio"`
//   Antigravity    — `~/.gemini/config/mcp_config.json`, `mcpServers` object
//   Gemini CLI     — `~/.gemini/settings.json`, top-level `mcpServers` object
//   Muse           — `$XDG_CONFIG_HOME/muse/settings.json`, top-level `mcpServers`
//                    object with `transport: "stdio"` (and a required
//                    `schema_version` at the root)
//
// Every path and key above is pinned to the client's own documentation or, for
// Muse, to the schema embedded in the shipped binary; the citation lives next
// to the code that writes it (`configURL(for:)`, `serverEntryJSON(for:target:)`,
// `requiredRootKeys(for:)`).
//
// Rules, identical in spirit to the routing wirer:
//   * Surgical edits only: every unrelated key in the user's config survives
//     byte-for-byte (JSON) or line-for-line (TOML outside the fence).
//   * Idempotent: wiring twice yields one entry; unwiring removes exactly ours.
//   * Atomic writes; missing files and directories are created.

/// A JSON object whose keys we do not own. Config files and CLI streams carry
/// third-party keys that MUST round-trip untouched, so these stay untyped by
/// design — the alias names that intent once instead of scattering the
/// untyped-boundary spelling (tracked by the string-any ratchet) per call site.
typealias UntypedJSONObject = [String: Any]

enum MCPClientWiringTarget: String, CaseIterable, Sendable {
    case claudeCode
    case cursor
    case codex
    case droid
    case antigravity
    case geminiCLI
    case muse

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .codex: return "Codex CLI"
        case .droid: return "Factory Droid"
        case .antigravity: return "Antigravity CLI"
        case .geminiCLI: return "Gemini CLI"
        case .muse: return "Muse"
        }
    }
}

/// How to launch the server, decided by the caller (bundled shim, repo
/// checkout, or a custom command). `toolset` becomes `BURNBAR_MCP_TOOLSET`,
/// keeping coding agents on the ~17-tool memory surface instead of paying
/// ~11k tokens/turn for the full ops plane.
struct MCPServerLaunch: Sendable, Equatable {
    var command: String
    var arguments: [String]
    var toolset: String

    init(command: String, arguments: [String], toolset: String = "memory") {
        self.command = command
        self.arguments = arguments
        self.toolset = toolset
    }
}

enum MCPClientWiringError: Error, LocalizedError, Equatable {
    case unreadableConfig(path: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .unreadableConfig(path, detail):
            return "Could not update \(path): \(detail)"
        }
    }
}

struct MCPClientWiringChange: Sendable, Equatable {
    let target: MCPClientWiringTarget
    let configPath: String
    let didMutate: Bool
}

struct MCPClientWiring {
    static let serverKey = "openburnbar"
    static let codexSentinelBegin = "# --- BEGIN OpenBurnBar MCP (managed by OpenBurnBar; do not edit inside) ---"
    static let codexSentinelEnd = "# --- END OpenBurnBar MCP ---"

    let fileManager: FileManager
    let home: URL
    /// XDG config root. Muse reads its settings from
    /// `$XDG_CONFIG_HOME/muse/settings.json`, falling back to `~/.config`;
    /// every other client here is anchored at `home`.
    let configHome: URL

    init(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        configHome: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.home = home
        self.configHome = configHome ?? Self.resolvedConfigHome(home: home, environment: environment)
    }

    static func resolvedConfigHome(home: URL, environment: [String: String]) -> URL {
        guard let raw = environment["XDG_CONFIG_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else {
            return home.appendingPathComponent(".config")
        }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// Returns the path the wirer would modify — for the UI's
    /// "Will modify ~/.claude.json" disclosure line.
    func configURL(for target: MCPClientWiringTarget) -> URL {
        switch target {
        case .claudeCode: return home.appendingPathComponent(".claude.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .codex: return home.appendingPathComponent(".codex/config.toml")
        // Factory: "User-level: `~/.factory/mcp.json`" with an `mcpServers`
        // object — https://docs.factory.ai/cli/configuration/mcp
        case .droid: return home.appendingPathComponent(".factory/mcp.json")
        // Google Antigravity: "Global: `~/.gemini/config/mcp_config.json`"
        // (workspace-local `.agents/mcp_config.json` is deliberately not
        // touched) — https://antigravity.google/docs/cli/mcp/
        case .antigravity: return home.appendingPathComponent(".gemini/config/mcp_config.json")
        // Gemini CLI: "Location: `~/.gemini/settings.json`", `mcpServers.<name>`
        // — https://geminicli.com/docs/reference/configuration
        case .geminiCLI: return home.appendingPathComponent(".gemini/settings.json")
        // Muse: `SettingsFile` is loaded from `$XDG_CONFIG_HOME/muse/settings.json`
        // (default `~/.config/muse/settings.json`) and carries an `mcpServers`
        // member. Verified against the shipped `muse` binary's own schema
        // (`struct SettingsFile { … mcpServers, mcp_servers … }`,
        // `struct McpServerSettings { enabled, mode, transport, command, args,
        // env, framing, url, headers }`) and by round-tripping a written entry
        // through `muse exec --provider echo`.
        case .muse: return configHome.appendingPathComponent("muse/settings.json")
        }
    }

    /// Whether OUR server entry is currently present in the target's config.
    /// A read-only probe for the Settings card's installed-state; never throws
    /// (an unreadable config simply reads as "not wired").
    func isWired(target: MCPClientWiringTarget) -> Bool {
        let url = configURL(for: target)
        switch target {
        case .claudeCode, .cursor, .droid, .antigravity, .geminiCLI, .muse:
            guard let root = (try? readJSONObject(at: url)) ?? nil, // try?-ok(read probe; unreadable config reads as not-wired)
                  let servers = root["mcpServers"] as? UntypedJSONObject else { return false }
            return servers[Self.serverKey] != nil
        case .codex:
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return false } // try?-ok(read probe; missing file reads as not-wired)
            return contents.contains(Self.codexSentinelBegin)
        }
    }

    @discardableResult
    func wire(target: MCPClientWiringTarget, launch: MCPServerLaunch) throws -> MCPClientWiringChange {
        switch target {
        case .claudeCode, .cursor, .droid, .antigravity, .geminiCLI, .muse:
            return try wireJSON(target: target, launch: launch)
        case .codex:
            return try wireCodexTOML(launch: launch)
        }
    }

    @discardableResult
    func unwire(target: MCPClientWiringTarget) throws -> MCPClientWiringChange {
        switch target {
        case .claudeCode, .cursor, .droid, .antigravity, .geminiCLI, .muse:
            return try unwireJSON(target: target)
        case .codex:
            return try unwireCodexTOML()
        }
    }

    // MARK: - JSON targets (Claude Code, Cursor, Droid, Antigravity, Gemini CLI, Muse)

    /// Every JSON client above takes the same `command` / `args` / `env`
    /// triple under `mcpServers.<name>`; these are the extra keys each
    /// client's own schema wants on top of it.
    private func serverEntryJSON(for launch: MCPServerLaunch, target: MCPClientWiringTarget) -> UntypedJSONObject {
        var entry: UntypedJSONObject = [
            "command": launch.command,
            "args": launch.arguments,
            "env": ["BURNBAR_MCP_TOOLSET": launch.toolset]
        ]
        switch target {
        // Factory documents `"type": "stdio"` on local-process servers
        // (optional, defaults to stdio) — https://docs.factory.ai/cli/configuration/mcp
        case .droid:
            entry["type"] = "stdio"
        // Muse's `McpServerSettings` rejects an entry whose transport cannot be
        // inferred ("transport requires command or url"); naming it removes the
        // ambiguity the validator complains about.
        case .muse:
            entry["transport"] = "stdio"
        case .claudeCode, .cursor, .codex, .antigravity, .geminiCLI:
            break
        }
        return entry
    }

    /// Keys the client's schema requires at the ROOT of a file we might be
    /// creating from nothing.
    ///
    /// Muse refuses to load a settings file without `schema_version` —
    /// "malformed settings file at …: missing field `schema_version`" — so a
    /// bare `{"mcpServers": …}` would break the CLI we were trying to help.
    /// Existing values are never overwritten.
    private func requiredRootKeys(for target: MCPClientWiringTarget) -> UntypedJSONObject {
        switch target {
        case .muse:
            return ["schema_version": 1]
        case .claudeCode, .cursor, .codex, .droid, .antigravity, .geminiCLI:
            return [:]
        }
    }

    private func wireJSON(target: MCPClientWiringTarget, launch: MCPServerLaunch) throws -> MCPClientWiringChange {
        let url = configURL(for: target)
        var root = try readJSONObject(at: url) ?? [:]
        var servers = (root["mcpServers"] as? UntypedJSONObject) ?? [:]
        let entry = serverEntryJSON(for: launch, target: target)

        let required = requiredRootKeys(for: target)
        let rootIsComplete = required.allSatisfy { root[$0.key] != nil }
        let existing = servers[Self.serverKey] as? UntypedJSONObject
        if let existing, rootIsComplete, NSDictionary(dictionary: existing).isEqual(to: entry) {
            return MCPClientWiringChange(target: target, configPath: url.path, didMutate: false)
        }
        for (key, value) in required where root[key] == nil {
            root[key] = value
        }
        servers[Self.serverKey] = entry
        root["mcpServers"] = servers
        try writeJSONObject(root, to: url)
        return MCPClientWiringChange(target: target, configPath: url.path, didMutate: true)
    }

    private func unwireJSON(target: MCPClientWiringTarget) throws -> MCPClientWiringChange {
        let url = configURL(for: target)
        guard var root = try readJSONObject(at: url),
              var servers = root["mcpServers"] as? UntypedJSONObject,
              servers[Self.serverKey] != nil else {
            return MCPClientWiringChange(target: target, configPath: url.path, didMutate: false)
        }
        servers.removeValue(forKey: Self.serverKey)
        // An empty object we created disappears again; a user's other servers stay.
        if servers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = servers
        }
        try writeJSONObject(root, to: url)
        return MCPClientWiringChange(target: target, configPath: url.path, didMutate: true)
    }

    private func readJSONObject(at url: URL) throws -> UntypedJSONObject? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MCPClientWiringError.unreadableConfig(path: url.path, detail: error.localizedDescription)
        }
        guard data.isEmpty == false else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data), // try?-ok(parse probe; the guard throws unreadableConfig below)
              let dictionary = object as? UntypedJSONObject else {
            // Never clobber a config we cannot faithfully re-serialize.
            throw MCPClientWiringError.unreadableConfig(
                path: url.path,
                detail: "The file is not a JSON object; refusing to rewrite it."
            )
        }
        return dictionary
    }

    private func writeJSONObject(_ root: UntypedJSONObject, to url: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Codex (TOML, sentinel-fenced)

    private func codexBlock(for launch: MCPServerLaunch) -> String {
        let args = launch.arguments
            .map { "\"\(tomlEscaped($0))\"" }
            .joined(separator: ", ")
        return """
        \(Self.codexSentinelBegin)
        [mcp_servers.\(Self.serverKey)]
        command = "\(tomlEscaped(launch.command))"
        args = [\(args)]
        env = { BURNBAR_MCP_TOOLSET = "\(tomlEscaped(launch.toolset))" }
        \(Self.codexSentinelEnd)
        """
    }

    private func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func wireCodexTOML(launch: MCPServerLaunch) throws -> MCPClientWiringChange {
        let url = configURL(for: .codex)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? "" // try?-ok(missing config starts empty by design)
        let stripped = removingCodexSentinelBlock(from: existing)
        let block = codexBlock(for: launch)
        var next = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        next = next.isEmpty ? block : next + "\n\n" + block
        next += "\n"
        guard next != existing else {
            return MCPClientWiringChange(target: .codex, configPath: url.path, didMutate: false)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try next.data(using: .utf8)?.write(to: url, options: .atomic)
        return MCPClientWiringChange(target: .codex, configPath: url.path, didMutate: true)
    }

    private func unwireCodexTOML() throws -> MCPClientWiringChange {
        let url = configURL(for: .codex)
        guard let existing = try? String(contentsOf: url, encoding: .utf8), // try?-ok(missing file = nothing to unwire)
              existing.contains(Self.codexSentinelBegin) else {
            return MCPClientWiringChange(target: .codex, configPath: url.path, didMutate: false)
        }
        var next = removingCodexSentinelBlock(from: existing)
        if next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next = ""
        }
        try next.data(using: .utf8)?.write(to: url, options: .atomic)
        return MCPClientWiringChange(target: .codex, configPath: url.path, didMutate: true)
    }

    /// Remove OUR fenced block only; every line the user wrote stays.
    private func removingCodexSentinelBlock(from contents: String) -> String {
        guard let beginRange = contents.range(of: Self.codexSentinelBegin) else { return contents }
        guard let endRange = contents.range(of: Self.codexSentinelEnd, range: beginRange.upperBound ..< contents.endIndex) else {
            // A begin without an end means someone edited inside the fence.
            // Refuse to guess: leave the file untouched.
            return contents
        }
        var result = contents
        var removalEnd = endRange.upperBound
        // Swallow the newline that trailed our block so unwire leaves no gap.
        if removalEnd < result.endIndex, result[removalEnd] == "\n" {
            removalEnd = result.index(after: removalEnd)
        }
        var removalStart = beginRange.lowerBound
        // And the blank separator line we inserted above the block.
        while removalStart > result.startIndex {
            let previous = result.index(before: removalStart)
            guard result[previous] == "\n" else { break }
            removalStart = previous
            if removalStart > result.startIndex,
               result[result.index(before: removalStart)] != "\n" {
                break
            }
        }
        result.removeSubrange(removalStart ..< removalEnd)
        return result
    }
}

// MARK: - Launch Resolution

/// Where the MCP server actually lives on THIS Mac, resolved in preference
/// order. The unresolved case is a first-class answer: the Settings card shows
/// its reason instead of writing a config entry that points at nothing —
/// a wired-but-broken server is the uninstall trigger this feature exists to
/// prevent.
///
/// Order:
///   1. `OPENBURNBAR_MCP_SERVER_PYTHON` + `OPENBURNBAR_MCP_SERVER_PATH` env
///      overrides (power users, CI).
///   2. A bundled server inside the app (`Resources/openburnbar-mcp/`) — not
///      shipped yet; the probe exists so bundling lights this up with no code
///      change.
///   3. A source checkout: the user-configured path, then the conventional
///      development locations.
enum MCPServerLaunchResolver {
    struct Resolution {
        let launch: MCPServerLaunch?
        /// Human sentence for the Settings card when `launch` is nil.
        let unavailabilityReason: String?
    }

    static func resolve(
        fileManager: FileManager = .default,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        configuredCheckoutPath: String? = nil
    ) -> Resolution {
        func launchIfServable(python: URL, server: URL) -> MCPServerLaunch? {
            guard fileManager.isExecutableFile(atPath: python.path),
                  fileManager.fileExists(atPath: server.path) else { return nil }
            return MCPServerLaunch(command: python.path, arguments: [server.path])
        }

        // 1. Explicit env override.
        if let pythonOverride = environment["OPENBURNBAR_MCP_SERVER_PYTHON"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let serverOverride = environment["OPENBURNBAR_MCP_SERVER_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           pythonOverride.isEmpty == false, serverOverride.isEmpty == false,
           let launch = launchIfServable(
               python: URL(fileURLWithPath: pythonOverride),
               server: URL(fileURLWithPath: serverOverride)
           ) {
            return Resolution(launch: launch, unavailabilityReason: nil)
        }

        // 2. Bundled server (future-proof probe).
        if let bundleResourceURL {
            let bundled = bundleResourceURL.appendingPathComponent("openburnbar-mcp", isDirectory: true)
            if let launch = launchIfServable(
                python: bundled.appendingPathComponent(".venv/bin/python"),
                server: bundled.appendingPathComponent("server.py")
            ) {
                return Resolution(launch: launch, unavailabilityReason: nil)
            }
        }

        // 3. Source checkouts: configured path first, then conventional homes.
        var checkoutRoots: [URL] = []
        if let configuredCheckoutPath,
           configuredCheckoutPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            checkoutRoots.append(URL(fileURLWithPath: (configuredCheckoutPath as NSString).expandingTildeInPath))
        }
        checkoutRoots.append(contentsOf: [
            home.appendingPathComponent("Documents/Developer/BurnBar"),
            home.appendingPathComponent("Developer/BurnBar")
        ])
        for root in checkoutRoots {
            let toolDirectory = root.appendingPathComponent("tools/openburnbar-mcp", isDirectory: true)
            if let launch = launchIfServable(
                python: toolDirectory.appendingPathComponent(".venv/bin/python"),
                server: toolDirectory.appendingPathComponent("server.py")
            ) {
                return Resolution(launch: launch, unavailabilityReason: nil)
            }
        }

        return Resolution(
            launch: nil,
            unavailabilityReason: "No OpenBurnBar MCP server found on this Mac. Point OPENBURNBAR_MCP_SERVER_PATH at a checkout's tools/openburnbar-mcp/server.py, or set the checkout path below."
        )
    }
}
