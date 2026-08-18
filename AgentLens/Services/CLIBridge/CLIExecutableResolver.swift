import Darwin
import Foundation
import OpenBurnBarCore

struct CLIExecutableResolver: Sendable {
    private static let loginShellResolutionTimeout: TimeInterval = 2
    private static let loginShellTerminationGrace: TimeInterval = 0.25

    fileprivate struct CacheKey: Hashable, Sendable {
        let name: String
        let homeDirectory: String
        let path: String
        let shell: String
    }

    private static let cache = ExecutableResolverCache()

    private let environmentProvider: @Sendable () -> [String: String]
    private let homeDirectoryProvider: @Sendable () -> String

    init(
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectoryProvider: @escaping @Sendable () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }
    ) {
        self.environmentProvider = environmentProvider
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    /// Blocking filesystem/login-shell probing runs off the main actor
    /// (`nonisolated` `async`, SE-0338); cancellation propagates from the awaiter.
    func resolveExecutable(named name: String) async -> String? {
        let env = environmentProvider()
        let homeDirectory = homeDirectoryProvider()
        let fileManager = FileManager.default
        let cacheKey = CacheKey(
            name: name,
            homeDirectory: homeDirectory,
            path: env["PATH"] ?? "",
            shell: env["SHELL"] ?? ""
        )

        if let cachedPath = Self.cache.value(for: cacheKey),
           fileManager.isExecutableFile(atPath: cachedPath) {
            return cachedPath
        }

        if let path = Self.resolveExecutable(
            named: name,
            searchDirectories: Self.baseExecutableSearchDirectories(
                environment: env,
                homeDirectory: homeDirectory
            ),
            fileManager: fileManager
        ) {
            Self.cache.set(path, for: cacheKey)
            return path
        }

        if let path = Self.resolveExecutable(
            named: name,
            searchDirectories: Self.userManagedExecutableSearchDirectories(
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            fileManager: fileManager
        ) {
            Self.cache.set(path, for: cacheKey)
            return path
        }

        if let path = Self.resolveExecutableFromLoginShell(
            named: name,
            environment: env,
            fileManager: fileManager
        ) {
            Self.cache.set(path, for: cacheKey)
            return path
        }

        return nil
    }

    static func clearCache() {
        cache.clear()
    }

    static func baseExecutableSearchDirectories(
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        return deduplicatedDirectories(pathEntries + [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ], homeDirectory: homeDirectory)
    }

    static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.asdf/shims",
            "\(homeDirectory)/.mise/shims"
        ]

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.nvm/versions/node",
                appending: "/bin",
                fileManager: fileManager
            )
        )

        directories.append(contentsOf:
            contentsOfDirectory(
                atPath: "\(homeDirectory)/.fnm/node-versions",
                appending: "/installation/bin",
                fileManager: fileManager
            )
        )

        return deduplicatedDirectories(directories, homeDirectory: homeDirectory)
    }

    static func resolveExecutable(
        named name: String,
        searchDirectories: [String],
        fileManager: FileManager = .default
    ) -> String? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func resolveExecutableFromLoginShell(
        named name: String,
        environment: [String: String],
        fileManager: FileManager = .default,
        timeout: TimeInterval = loginShellResolutionTimeout
    ) -> String? {
        let shellPath = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard fileManager.isExecutableFile(atPath: shellPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lic", "command -v -- \(shellQuoted(name)) 2>/dev/null"]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            completion.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if completion.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if completion.wait(timeout: .now() + loginShellTerminationGrace) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + loginShellTerminationGrace)
            }
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let path = parseExecutablePath(fromCommandOutput: output),
              fileManager.isExecutableFile(atPath: path) else {
            return nil
        }

        return path
    }

    static func parseExecutablePath(fromCommandOutput output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first(where: { $0.hasPrefix("/") })
    }

    /// M-040: build the child-process environment for agent CLI / shell spawns
    /// from an ALLOWLISTED baseline instead of the full ambient process
    /// environment.
    ///
    /// Previously this method copied `ProcessInfo.processInfo.environment`
    /// wholesale and only rewrote `PATH`, which leaked every ambient/daemon
    /// secret the app or its daemon happened to hold (OpenBurnBar gateway/socket
    /// tokens, Firebase custom tokens, AWS creds, etc.) into the trusted-agent
    /// CLI and the (un)restricted YOLO shell. We now start from the
    /// `AgentChildProcessEnvironment` allowlist — which preserves what CLI
    /// agents legitimately need (HOME/USER/SHELL/TERM/TMPDIR/LANG/LC_*, the
    /// per-CLI config-dir vars, AND the provider/API-key env the user intends
    /// the agent to use) while STRIPPING app/daemon-internal secrets and
    /// arbitrary ambient vars — and then apply the enriched-PATH logic on top.
    static func enrichedProcessEnvironment(
        executablePath: String? = nil,
        baseEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = AgentChildProcessEnvironment.allowlistedBaseline(baseEnv: baseEnv)
        let homeDirectory = NSHomeDirectory()
        var extra = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(homeDirectory)/.local/bin"
        ]

        if let executablePath {
            let executableDirectory = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            extra.insert(executableDirectory, at: 0)
        }

        extra.append(contentsOf: userManagedExecutableSearchDirectories(homeDirectory: homeDirectory))

        // PATH is taken from the allowlisted baseline (which preserves the
        // ambient PATH), not from re-reading the full ambient env.
        let existing = env["PATH"] ?? baseEnv["PATH"] ?? ""
        let merged = extra + existing.split(separator: ":").map(String.init)
        env["PATH"] = deduplicatedDirectories(merged, homeDirectory: homeDirectory).joined(separator: ":")
        return env
    }

    /// Environment handed to spawned third-party CLI agents.
    ///
    /// Executable resolution may inspect the user's login environment so common
    /// version-manager installs can be found, but the agent process itself must
    /// not inherit OpenBurnBar daemon tokens, cloud credentials, SSH agent
    /// sockets, or CI secrets from the parent process. Profiles can still pass
    /// explicit overrides (for example `CODEX_HOME`) at the call site.
    static func agentProcessEnvironment(
        executablePath: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory()
    ) -> [String: String] {
        var pathEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(homeDirectory)/.local/bin"
        ]

        if let executablePath {
            let executableDirectory = URL(fileURLWithPath: executablePath)
                .deletingLastPathComponent()
                .standardizedFileURL
                .path
            pathEntries.insert(executableDirectory, at: 0)
        }

        pathEntries.append(contentsOf: userManagedExecutableSearchDirectories(homeDirectory: homeDirectory))
        pathEntries.append(contentsOf: (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init))

        var env: [String: String] = [
            "PATH": deduplicatedDirectories(pathEntries, homeDirectory: homeDirectory).joined(separator: ":"),
            "HOME": homeDirectory,
            "SHELL": baseEnvironment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh",
            "TMPDIR": baseEnvironment["TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? NSTemporaryDirectory(),
            "LANG": baseEnvironment["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8",
            "TERM": baseEnvironment["TERM"].flatMap { $0.isEmpty ? nil : $0 } ?? "dumb"
        ]

        for key in ["LC_ALL", "LC_CTYPE", "USER", "LOGNAME"] {
            if let value = baseEnvironment[key], !value.isEmpty {
                env[key] = value
            }
        }

        return env
    }

    private static func contentsOfDirectory(
        atPath path: String,
        appending suffix: String,
        fileManager: FileManager
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { // try?-ok(optional dir enumeration)
            return []
        }

        return entries
            .sorted(by: >)
            .map { "\(path)/\($0)\(suffix)" }
    }

    private static func deduplicatedDirectories(_ directories: [String], homeDirectory: String) -> [String] {
        var seen = Set<String>()

        return directories.compactMap { directory in
            let expandedHome = directory
                .replacingOccurrences(of: "$HOME", with: homeDirectory)
                .replacingOccurrences(of: "${HOME}", with: homeDirectory)
            let expanded = NSString(string: expandedHome).expandingTildeInPath
            guard !expanded.isEmpty else {
                return nil
            }

            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard seen.insert(standardized).inserted else {
                return nil
            }

            return standardized
        }
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private final class ExecutableResolverCache: Sendable {
    private let values = Locked<[CLIExecutableResolver.CacheKey: String]>([:])

    func value(for key: CLIExecutableResolver.CacheKey) -> String? {
        values.withLock { $0[key] }
    }

    func set(_ value: String, for key: CLIExecutableResolver.CacheKey) {
        values.withLock { $0[key] = value }
    }

    func clear() {
        values.withLock { $0.removeAll() }
    }
}

extension CLIBridge {
    nonisolated static func baseExecutableSearchDirectories(
        environment: [String: String],
        homeDirectory: String
    ) -> [String] {
        CLIExecutableResolver.baseExecutableSearchDirectories(
            environment: environment,
            homeDirectory: homeDirectory
        )
    }

    nonisolated static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        CLIExecutableResolver.userManagedExecutableSearchDirectories(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
    }

    nonisolated static func resolveExecutable(
        named name: String,
        searchDirectories: [String],
        fileManager: FileManager = .default
    ) -> String? {
        CLIExecutableResolver.resolveExecutable(
            named: name,
            searchDirectories: searchDirectories,
            fileManager: fileManager
        )
    }

    nonisolated static func resolveExecutableFromLoginShell(
        named name: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> String? {
        CLIExecutableResolver.resolveExecutableFromLoginShell(
            named: name,
            environment: environment,
            fileManager: fileManager
        )
    }

    nonisolated static func parseExecutablePath(fromCommandOutput output: String) -> String? {
        CLIExecutableResolver.parseExecutablePath(fromCommandOutput: output)
    }
}

// MARK: - Agent child-process environment allowlist (M-040)

/// Single, shared source of truth for the environment that AgentLens passes to
/// child processes it spawns to execute agents: the per-CLI agents (Claude,
/// Codex, Droid, Forge, Antigravity, Cursor) AND the broker's `shell_run`
/// (sandbox-exec restricted) and `shell_run_unrestricted` (YOLO `/bin/zsh -f
/// -lc`) shells.
///
/// Security model (M-040): we NEVER hand the full ambient
/// `ProcessInfo.processInfo.environment` to these children. Doing so leaked any
/// app/daemon-held secret (OpenBurnBar gateway/socket auth tokens, Firebase
/// custom tokens, AWS creds, arbitrary ambient vars) into the trusted-agent CLI
/// and the unrestricted shell. Instead we start from an allowlisted baseline.
///
/// The allowlist is built as: the proven Switcher launch baseline
/// (`CLILaunchAdapter.isBaselineEnvKeyAllowlisted`, e.g. HOME/PATH/USER/SHELL/TERM/
/// TMPDIR/LANG/LC_ALL and the per-CLI config-dir vars) PLUS the provider/
/// API-key env an agent legitimately reads from ambient to authenticate
/// (ANTHROPIC_API_KEY, OPENAI_API_KEY, etc.). The Switcher baseline deliberately
/// omits API keys because the Switcher injects them per-profile via
/// `envKeysToPass`; the AgentLens agent-execution path, by contrast, relies on
/// the agent reading them from ambient — so we re-add exactly that set here, in
/// one place, rather than weakening the Switcher allowlist (which has its own
/// fail-closed tests asserting API keys stay out of it).
///
/// `LC_*` (LC_CTYPE, LC_MESSAGES, …) and `LANG` matter for correct CLI text/
/// locale handling, so any `LC_`-prefixed ambient var is allowlisted by prefix.
enum AgentChildProcessEnvironment {
    /// Provider/API-key + provider-base-URL env that agents read from ambient to
    /// authenticate and route. These are the keys the *user intends the agent to
    /// use* — NOT app/daemon-internal secrets. App/daemon-internal tokens
    /// (`OPENBURNBAR_*`, Firebase custom tokens, etc.) are intentionally absent
    /// and therefore stripped.
    static let providerEnvKeys: Set<String> = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "CLAUDE_API_KEY",
        "CODEX_API_KEY",
        "OPENCODE_API_KEY",
        "OPENCODE_GO_API_KEY",
        "OPENROUTER_API_KEY",
        "XAI_API_KEY",
        "DEEPSEEK_API_KEY",
        "DEEPSEEK_BASE_URL",
        "DEEPSEEK_API_BASE_URL",
        "KIMI_API_KEY",
        "KIMI_AUTH_TOKEN",
        "MOONSHOT_API_KEY",
        "MINIMAX_API_KEY",
        "MIMO_API_KEY",
        "OLLAMA_API_KEY",
        "ZAI_API_KEY",
        "Z_AI_API_KEY",
        "ZAI_BASE_URL",
        "ZHIPUAI_API_KEY",
        "GEMINI_API_KEY",
        "GOOGLE_API_KEY",
        "MISTRAL_API_KEY",
        "GROQ_API_KEY",
        "PERPLEXITY_API_KEY",
        "TOGETHER_API_KEY",
        "FIREWORKS_API_KEY"
    ]

    /// Whether `key` is allowlisted for an agent child process: either it is in
    /// the proven Switcher launch baseline, in the agent provider/API-key set, or
    /// it is a locale (`LC_*`) variable.
    static func isAllowlisted(_ key: String) -> Bool {
        CLILaunchAdapter.isBaselineEnvKeyAllowlisted(key)
            || providerEnvKeys.contains(key)
            || key.hasPrefix("LC_")
    }

    /// Builds the allowlisted baseline environment for an agent child process,
    /// drawing values from `baseEnv` (defaults to the current process env).
    /// Only allowlisted keys survive; everything else — including arbitrary
    /// ambient vars and app/daemon-internal secrets — is dropped.
    static func allowlistedBaseline(
        baseEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in baseEnv where isAllowlisted(key) {
            result[key] = value
        }
        return result
    }
}
