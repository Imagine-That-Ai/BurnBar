import Foundation

// MARK: - Parser Root Resolver

/// Resolves the declared log roots for the app-side usage parsers.
///
/// Mirrors the daemon's probe-root override seam (`BurnBarFleetRootResolver`):
/// - `BURNBAR_FLEET_ROOTS_DIR` overrides the base directory for ALL providers:
///   each provider's root becomes `<override>/<provider-root-name>` (`claude`,
///   `factory`, `copilot`, `aider`, `cursor`, `codex`, `kimi`, `cline`,
///   `kilocode`, `roocode`, `forge`, `augment`, `hermes`, `grokbot`, `grok`,
///   `pi`, `gemini`, `goose`; `zai` and `minimax` share the `factory` root
///   because they parse Factory Droid sessions);
/// - per-provider overrides win over the base override
///   (`BURNBAR_FLEET_ROOT_CLAUDE_CODE`, `BURNBAR_FLEET_ROOT_PI`, …).
///
/// With no overrides, paths resolve to the real `~`-based roots.
///
/// Expansion rule: `~` maps to the provider's resolved root, and the
/// provider's own home-relative root prefix is stripped
/// (`~/.claude/projects` → `<override>/claude/projects`;
/// `~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/tasks`
/// → `<override>/cline/tasks`). A path that merely shares a prefix with the
/// root (e.g. `~/.forge.db` for forge) is NOT stripped — only the root
/// directory itself or a path strictly under it is.
///
/// The live process environment is consulted via `getenv` at resolution time
/// (not a launch-time snapshot), so hermetic tests can `setenv` before
/// constructing an aggregator that builds parsers internally. An explicitly
/// passed `environment` dictionary wins over the live env.
enum ParserRootResolver {
    static let environmentKeyBase = "BURNBAR_FLEET_ROOTS_DIR"

    /// The per-provider override environment key, e.g.
    /// `BURNBAR_FLEET_ROOT_CLAUDE_CODE`.
    static func environmentKey(for provider: AgentProvider) -> String {
        "BURNBAR_FLEET_ROOT_\(suffix(for: provider))"
    }

    /// The declared root directory name for the base override (daemon-style).
    static func rootDirectoryName(for provider: AgentProvider) -> String {
        switch provider {
        case .factory,
             .zai,
             .minimax:
            return "factory"
        case .claudeCode:
            return "claude"
        case .copilot:
            return "copilot"
        case .aider:
            return "aider"
        case .cursor:
            return "cursor"
        case .codex:
            return "codex"
        case .kimi:
            return "kimi"
        case .cline:
            return "cline"
        case .kiloCode:
            return "kilocode"
        case .rooCode:
            return "roocode"
        case .forgeDev:
            return "forge"
        case .augment:
            return "augment"
        case .hermes:
            return "hermes"
        case .grokBot:
            return "grokbot"
        case .grokCLI:
            return "grok"
        case .pi:
            return "pi"
        case .geminiCLI:
            return "gemini"
        case .goose:
            return "goose"
        }
    }

    /// The home-relative root path for the provider (e.g. `.claude`).
    static func defaultRootPath(for provider: AgentProvider) -> String {
        switch provider {
        case .factory,
             .zai,
             .minimax:
            return ".factory"
        case .claudeCode:
            return ".claude"
        case .copilot:
            return ".copilot"
        case .aider:
            return ".aider"
        case .cursor:
            return ".cursor"
        case .codex:
            return ".codex"
        case .kimi:
            return ".kimi"
        case .cline:
            return "Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev"
        case .kiloCode:
            return "Library/Application Support/Code/User/globalStorage/kilocode.kilo-code"
        case .rooCode:
            return "Library/Application Support/Code/User/globalStorage"
        case .forgeDev:
            return ".forge"
        case .augment:
            return "Library/Application Support/Code/User/globalStorage/augment.vscode-augment"
        case .hermes:
            return ".hermes"
        case .grokBot:
            return ".grokbot"
        case .grokCLI:
            return ".grok"
        case .pi:
            return ".pi"
        case .geminiCLI:
            return ".gemini"
        case .goose:
            return ".local/share/goose"
        }
    }

    private static func suffix(for provider: AgentProvider) -> String {
        switch provider {
        case .factory:
            return "FACTORY_DROID"
        case .claudeCode:
            return "CLAUDE_CODE"
        case .copilot:
            return "COPILOT"
        case .aider:
            return "AIDER"
        case .cursor:
            return "CURSOR"
        case .codex:
            return "CODEX"
        case .zai:
            return "ZAI"
        case .minimax:
            return "MINIMAX"
        case .kimi:
            return "KIMI"
        case .cline:
            return "CLINE"
        case .kiloCode:
            return "KILO_CODE"
        case .rooCode:
            return "ROO_CODE"
        case .forgeDev:
            return "FORGE_DEV"
        case .augment:
            return "AUGMENT"
        case .hermes:
            return "HERMES"
        case .grokBot:
            return "GROK_BOT"
        case .grokCLI:
            return "GROK_CLI"
        case .pi:
            return "PI"
        case .geminiCLI:
            return "GEMINI_CLI"
        case .goose:
            return "GOOSE"
        }
    }

    /// Resolves the provider ROOT honoring the override seam; nil when no
    /// override is active (the real home is used).
    static func resolvedRoot(
        for provider: AgentProvider,
        environment: [String: String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        var env = ProcessInfo.processInfo.environment
        for key in [environmentKeyBase, environmentKey(for: provider)] {
            if let raw = getenv(key) {
                env[key] = String(cString: raw)
            }
        }
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        let trimmed = { (value: String?) -> String? in
            guard let value else { return nil }
            let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        }
        if let perProbe = trimmed(env[environmentKey(for: provider)]) {
            return perProbe
        }
        if let base = trimmed(env[environmentKeyBase]) {
            return URL(fileURLWithPath: base, isDirectory: true)
                .appendingPathComponent(rootDirectoryName(for: provider), isDirectory: true)
                .path
        }
        return nil
    }

    /// Expands a `~`-relative path under the provider's resolved root.
    static func expand(
        _ path: String,
        for provider: AgentProvider,
        environment: [String: String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard path.hasPrefix("~") else { return path }
        guard let root = resolvedRoot(for: provider, environment: environment, homeDirectory: homeDirectory) else {
            return (path as NSString).expandingTildeInPath
        }
        let rest = String(path.dropFirst())
        let defaultRoot = "/" + defaultRootPath(for: provider)
        if rest == defaultRoot || rest.hasPrefix(defaultRoot + "/") {
            return root + String(rest.dropFirst(defaultRoot.count))
        }
        return root + rest
    }

    /// The provider's log directory honoring the override seam.
    static func resolvedLogDirectory(
        for provider: AgentProvider,
        environment: [String: String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        expand(provider.logDirectory, for: provider, environment: environment, homeDirectory: homeDirectory)
    }

    /// The effective home directory for the provider (`~` under the override
    /// seam). Used by parsers that scan the home directory (ForgeDevParser's
    /// `.forge.db` discovery).
    static func resolvedHomeDirectory(
        for provider: AgentProvider,
        environment: [String: String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        URL(
            fileURLWithPath: expand("~", for: provider, environment: environment, homeDirectory: homeDirectory),
            isDirectory: true
        )
    }
}
