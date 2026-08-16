import Foundation

// MARK: - CLI Launch Adapter (Foundation-pure resolution + env surface)
//
// Core-decomposition P-15b (docs/CORE_DECOMPOSITION_PROGRAM.md): the pure
// executable-resolution + allowlisted-environment surface of the CLI launch stack,
// extracted DOWN from `OpenBurnBarLaunchServices/SwitcherCLILAunchService.swift` into
// the cross-platform Kernel so two consumers can use it WITHOUT linking the
// AppKit-tainted (Apple-only) OpenBurnBarLaunchServices target:
//   1. the daemon repoint (P-18) — `OpenBurnBarSwitcherShell.shellConfiguration(...)`
//      calls `CLILaunchAdapter.buildCLILaunch(profile:)`;
//   2. the Quota adapters (P-13) — `CodexQuotaAdapter`/`OMPQuotaAdapter` call
//      `resolveExecutable`/`resolvePinnedExecutable`/`buildAllowlistedBaselineEnvironment`/
//      `trustedExecutableEnvironmentPath` with `SwitcherCLIProfileType` `.codex`/`.omp`.
//
// Pure code motion, zero behavior change. The launch coordinator/invoker/store-coupled
// halves (`SwitcherCLILAunchService`, `CLILaunchInvoker`, `CLILaunchCoordinator`,
// `CLIFallback*`, `CLILaunchOutcome`) STAY in LaunchServices; they reach these types
// via LaunchServices' declared Kernel dependency. (`CLILaunchRedactor` — pure
// Foundation, and reached by the daemon repoint — subsequently moved DOWN to
// OpenBurnBarKernel/Platform/CLILaunchRedactor.swift in P-18.) `CLILaunchError`
// moves with the adapter because the adapter's validation surface returns it (symbol
// closure — the type could not stay ABOVE the Kernel while the adapter references it).
//
// The `#if os(macOS)` guard is preserved verbatim from the origin file: the resolution
// machinery is macOS launch semantics and every consumer already gates its calls behind
// `#if os(macOS)` (the Quota adapters) or an all-macOS build (LaunchServices, the daemon
// macOS leg), so off-Apple this type simply does not exist — byte-identical to before the
// move, and Kernel stays assert-zero for UI frameworks (this file imports Foundation only).
#if os(macOS)

public enum CLILaunchAdapter {
    private struct ExecutableResolutionCacheKey: Hashable, Sendable {
        let cliType: SwitcherCLIProfileType
        let homeDirectory: String
    }

    private static let executableResolutionCache = Locked<[ExecutableResolutionCacheKey: String]>([:])

    // MARK: - Launch Result

    /// Result of a CLI launch attempt.
    public enum LaunchResult: Equatable, Sendable {
        case success
        case failure(CLILaunchError)
    }

    // MARK: - Executable Resolution Seam (Testability)

    // nonisolated(unsafe): test-only injection seam, set during single-threaded test setup; reads are effectively immutable in production.
    /// Injectable resolver for executable availability.
    /// Defaults to real filesystem resolution. Override in tests for deterministic behavior.
    public nonisolated(unsafe) static var executableResolver: ((_ cliType: SwitcherCLIProfileType) -> URL?)? {
        didSet { executableResolutionCache.write([:]) }
    }
    // nonisolated(unsafe): test-only injection seam, set during single-threaded test setup; reads are effectively immutable in production.
    nonisolated(unsafe) static var environmentProvider: () -> [String: String] = { ProcessInfo.processInfo.environment } {
        didSet { executableResolutionCache.write([:]) }
    }
    // nonisolated(unsafe): test-only injection seam, set during single-threaded test setup; reads are effectively immutable in production.
    nonisolated(unsafe) static var homeDirectoryProvider: () -> String = { NSHomeDirectory() } {
        didSet { executableResolutionCache.write([:]) }
    }

    // MARK: - Allowlisted Environment Variables

    /// Environment variables that may be passed by explicit CLI profile metadata.
    /// Credentials belong here only when profile-scoped; the ambient baseline below
    /// must stay free of API keys and tokens.
    ///
    /// NOTE: Values are NOT stored - only the keys. Values are resolved at launch
    /// from the current process environment.
    public static let allowlistedEnvKeys: Set<String> = [
        "HOME",           // User home directory
        "PATH",           // System path for finding executables
        "USER",           // Current username
        "SHELL",          // User's default shell
        "PWD",            // Current working directory
        "TMPDIR",         // Temporary directory
        "TERM",           // Terminal type
        "TERM_PROGRAM",   // Terminal program name
        "LANG",           // Language/locale settings
        "LC_ALL",         // Locale override
        "EDITOR",         // Default editor
        "VISUAL",         // Visual editor (usually same as EDITOR)
        "PAGER",          // Pager program
        "BROWSER",        // Default browser
        "SSH_AUTH_SOCK",  // SSH authentication socket
        "GIT_EDITOR",     // Git editor
        "HG_EDITOR",      // Mercurial editor
        // Claude-specific safe variables
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_CONFIG_PATH",
        // Codex-specific safe variables
        "CODEX_HOME",
        "CODEX_CONFIG_PATH",
        // OpenCode-specific safe variables
        "OPENCODE_CONFIG_PATH",
        "AGY_CONFIG_HOME",
        "ANTIGRAVITY_HOME",
        "GEMINI_HOME",
        "CURSOR_AGENT_HOME",
        "CURSOR_AGENT_CONFIG_PATH",
        "JUNIE_API_KEY"
    ]

    private static let baselineEnvKeys: Set<String> = allowlistedEnvKeys.subtracting([
        "JUNIE_API_KEY"
    ])

    // MARK: - Additional Arguments Allowlist

    /// Arguments that are allowlisted for CLI profile launching.
    /// These are common CLI flags that don't affect security boundaries.
    private static let allowlistedArgs: Set<String> = [
        "--verbose",
        "--debug",
        "--quiet",
        "--no-color",
        "--version",
        "--help",
        "--dry-run",
        "--working-dir=",
        "--config=",
        "--project="
    ]

    // MARK: - Executable Resolution

    /// Resolves the trusted executable path for a given CLI type.
    /// Returns the resolved path if found, nil if not installed.
    ///
    /// Security: This only checks predefined trusted paths, preventing
    /// PATH/CWD hijack attacks where malicious code could be injected.
    public static func resolveExecutable(for cliType: SwitcherCLIProfileType) -> URL? {
        // Use injected resolver if available (for deterministic testing)
        if let resolver = executableResolver {
            return resolver(cliType)
        }

        let fileManager = FileManager.default
        let homeDirectory = homeDirectoryProvider()
        let cacheKey = ExecutableResolutionCacheKey(
            cliType: cliType,
            homeDirectory: homeDirectory
        )

        if let cachedPath = executableResolutionCache.read()[cacheKey],
           fileManager.isExecutableFile(atPath: cachedPath) {
            return URL(fileURLWithPath: cachedPath)
        }

        if let path = firstExecutable(
            named: cliType.executableName,
            in: fastExecutableSearchDirectories(
                for: cliType,
                homeDirectory: homeDirectory
            ),
            fileManager: fileManager
        ) {
            executableResolutionCache.withLock { $0[cacheKey] = path }
            return URL(fileURLWithPath: path)
        }

        if let path = firstExecutable(
            named: cliType.executableName,
            in: ambientFallbackExecutableSearchDirectories(
                for: cliType,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            ),
            fileManager: fileManager
        ) {
            executableResolutionCache.withLock { $0[cacheKey] = path }
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    public static func resolvePinnedExecutable(for cliType: SwitcherCLIProfileType) -> URL? {
        // Use injected resolver if available (for deterministic testing).
        if let resolver = executableResolver {
            return resolver(cliType)
        }

        let fileManager = FileManager.default
        let homeDirectory = homeDirectoryProvider()
        guard let path = firstExecutable(
            named: cliType.executableName,
            in: fastExecutableSearchDirectories(
                for: cliType,
                homeDirectory: homeDirectory
            ),
            fileManager: fileManager
        ) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    public static func trustedExecutableEnvironmentPath(homeDirectory: String? = nil) -> String {
        deduplicatedDirectories(
            standardExecutableSearchDirectories(
                homeDirectory: homeDirectory ?? homeDirectoryProvider()
            )
        ).joined(separator: ":")
    }

    private static func fastExecutableSearchDirectories(
        for cliType: SwitcherCLIProfileType,
        homeDirectory: String
    ) -> [String] {
        let explicitDirectories = cliType.trustedExecutablePaths.map {
            URL(fileURLWithPath: expandPath($0, homeDirectory: homeDirectory))
                .deletingLastPathComponent()
                .path
        }

        return deduplicatedDirectories(
            explicitDirectories
            + standardExecutableSearchDirectories(homeDirectory: homeDirectory)
        )
    }

    private static func firstExecutable(
        named executableName: String,
        in directories: [String],
        fileManager: FileManager
    ) -> String? {
        for directory in directories {
            let candidatePath = URL(fileURLWithPath: directory)
                .appendingPathComponent(executableName)
                .path
            if fileManager.isExecutableFile(atPath: candidatePath) {
                return candidatePath
            }
        }
        return nil
    }

    public static func clearExecutableResolutionCache() {
        executableResolutionCache.write([:])
    }

    /// Expands ~ in paths to the user's home directory.
    static func expandPath(_ path: String, homeDirectory: String? = nil) -> String {
        let homeDir = homeDirectory ?? homeDirectoryProvider()

        if path == "~" {
            return homeDir
        }
        if path.hasPrefix("~/") {
            return homeDir + String(path.dropFirst(1))
        }
        if path == "$HOME" || path == "${HOME}" {
            return homeDir
        }
        if path.hasPrefix("$HOME/") {
            return homeDir + "/" + String(path.dropFirst("$HOME/".count))
        }
        if path.hasPrefix("${HOME}/") {
            return homeDir + "/" + String(path.dropFirst("${HOME}/".count))
        }
        return path
    }

    private static func standardExecutableSearchDirectories(homeDirectory: String) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
    }

    static func allowsAmbientUserManagedExecutableFallback(for cliType: SwitcherCLIProfileType) -> Bool {
        cliType != .codex
    }

    static func ambientFallbackExecutableSearchDirectories(
        for cliType: SwitcherCLIProfileType,
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        guard allowsAmbientUserManagedExecutableFallback(for: cliType) else {
            return []
        }
        return userManagedExecutableSearchDirectories(homeDirectory: homeDirectory, fileManager: fileManager)
            + ideManagedExecutableSearchDirectories(homeDirectory: homeDirectory, fileManager: fileManager)
    }

    private static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            "\(homeDirectory)/.local/bin",
            "\(homeDirectory)/.codex/bin",
            "\(homeDirectory)/.claude/bin",
            "\(homeDirectory)/.opencode/bin",
            "\(homeDirectory)/.factory/bin",
            "\(homeDirectory)/.forge/bin",
            "\(homeDirectory)/.antigravity/bin",
            "\(homeDirectory)/.gemini/antigravity-cli",
            "\(homeDirectory)/.cursor-agent/bin",
            "\(homeDirectory)/.gemini/bin",
            "\(homeDirectory)/.kimi/bin",
            "\(homeDirectory)/.pi/bin",
            "\(homeDirectory)/.junie/bin",
            "\(homeDirectory)/.cargo/bin",
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

        return directories
    }

    private static func ideManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        let extensionRoots = [
            "\(homeDirectory)/.cursor/extensions",
            "\(homeDirectory)/.vscode/extensions",
            "\(homeDirectory)/.windsurf/extensions"
        ]

        var directories: [String] = []

        for extensionRoot in extensionRoots {
            let binDirectories = contentsOfDirectory(
                atPath: extensionRoot,
                appending: "/bin",
                fileManager: fileManager
            )
            directories.append(contentsOf: binDirectories)

            for binDirectory in binDirectories {
                directories.append(contentsOf:
                    contentsOfDirectory(
                        atPath: binDirectory,
                        appending: "",
                        fileManager: fileManager
                    )
                )
            }
        }

        return directories
    }

    private static func contentsOfDirectory(
        atPath path: String,
        appending suffix: String,
        fileManager: FileManager = .default
    ) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else {
            return []
        }

        return entries
            .sorted(by: >)
            .map { "\(path)/\($0)\(suffix)" }
    }

    private static func deduplicatedDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()

        return directories.compactMap { directory in
            let expanded = expandPath(directory)
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

    /// Checks if a CLI executable is installed and available for launching.
    public static func isExecutableAvailable(_ cliType: SwitcherCLIProfileType) -> Bool {
        return resolveExecutable(for: cliType) != nil
    }

    /// Returns the resolved executable path for a CLI type, if available.
    public static func executablePath(for cliType: SwitcherCLIProfileType) -> String? {
        return resolveExecutable(for: cliType)?.path
    }

    // MARK: - Working Directory Validation

    /// Validates that a working directory path is safe to use.
    /// Rejects paths that escape the user's home directory boundary.
    public static func validateWorkingDirectory(_ path: String) -> Result<String, CLILaunchError> {
        let expanded = expandPath(path)
        let trimmed = expanded.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return .failure(.invalidWorkingDirectory("Working directory cannot be empty"))
        }

        // Check for null bytes and control characters
        for scalar in trimmed.unicodeScalars {
            guard scalar.value >= 0x20 && scalar.value < 0x7F else {
                return .failure(.invalidWorkingDirectory("Working directory contains invalid characters"))
            }
        }

        // Resolve to absolute path and verify it exists
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trimmed, isDirectory: &isDirectory) else {
            return .failure(.invalidWorkingDirectory("Working directory does not exist"))
        }

        guard isDirectory.boolValue else {
            return .failure(.invalidWorkingDirectory("Working directory is not a directory"))
        }

        // Verify it's within user's home or a known safe location
        let homeDir = NSHomeDirectory()
        let isInsideHome = trimmed.hasPrefix(homeDir)
        let isInTemp = trimmed.hasPrefix(NSTemporaryDirectory())
        let isInVar = trimmed.hasPrefix("/var/folders/")

        guard isInsideHome || isInTemp || isInVar else {
            return .failure(.invalidWorkingDirectory("Working directory must be within home directory or temp"))
        }

        return .success(trimmed)
    }

    // MARK: - Argument Validation

    /// Validates that an argument is in the allowlist.
    /// Returns the argument if valid, nil if not allowlisted.
    public static func validateArgument(_ arg: String) -> String? {
        // Empty check
        guard !arg.isEmpty else { return nil }

        // Check for control characters
        for scalar in arg.unicodeScalars {
            guard scalar.value >= 0x20 && scalar.value < 0x7F else {
                return nil
            }
        }

        // If it's a complete match in the allowlist
        if allowlistedArgs.contains(arg) {
            return arg
        }

        // If it's a prefix match (e.g., "--working-dir=/path")
        for allowlisted in allowlistedArgs {
            if arg.hasPrefix(allowlisted) && allowlisted.hasSuffix("=") {
                let valuePart = String(arg.dropFirst(allowlisted.count))
                guard !valuePart.isEmpty else { return nil }
                // Verify the value doesn't contain suspicious patterns
                let suspicious = [";", "&", "|", "`", "$", "(", ")", "{", "}", "[", "]", "<", ">"]
                for pattern in suspicious where valuePart.contains(pattern) {
                    return nil
                }
                return arg
            }
        }

        return nil
    }

    /// Validates additional arguments from profile metadata.
    /// Returns the validated arguments if all are allowlisted.
    public static func validateArguments(_ args: [String]) -> Result<[String], CLILaunchError> {
        var validated: [String] = []

        for arg in args {
            guard let validatedArg = validateArgument(arg) else {
                return .failure(.disallowedArgument(arg))
            }
            validated.append(validatedArg)
        }

        return .success(validated)
    }

    // MARK: - Environment Variable Validation

    /// Validates that an environment variable key is in the allowlist.
    /// Returns true if the key is allowlisted, false otherwise.
    public static func isEnvKeyAllowlisted(_ key: String) -> Bool {
        return allowlistedEnvKeys.contains(key)
    }

    /// Returns true only for keys that are safe in the cross-CLI ambient baseline.
    /// Profile-scoped credentials such as `JUNIE_API_KEY` may be accepted by
    /// `filterAllowlistedEnvironment` but must not leak through child-process
    /// baselines for unrelated agents.
    public static func isBaselineEnvKeyAllowlisted(_ key: String) -> Bool {
        return baselineEnvKeys.contains(key)
    }

    /// Filters environment variables to only allowlisted keys.
    /// Values are taken from the current process environment.
    public static func filterAllowlistedEnvironment(
        keys: [String],
        baseEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]

        for key in keys {
            if isEnvKeyAllowlisted(key), let value = baseEnv[key] {
                // Additional sanitization: ensure value doesn't contain newlines or control chars
                let sanitized = sanitizeEnvValue(value)
                if !sanitized.isEmpty {
                    result[key] = sanitized
                }
            }
        }

        return result
    }

    /// Builds a clean baseline environment containing ONLY allowlisted keys from the given base env.
    /// This is the foundational environment for CLI launches - no ambient/unknown variables are included.
    ///
    /// Security: This method ensures that only explicitly allowlisted environment variables
    /// are passed to CLI processes, preventing sensitive ambient variables from leaking.
    ///
    /// - Parameter baseEnv: The source environment to draw values from. Defaults to current process env.
    /// - Returns: A dictionary containing only allowlisted keys and their sanitized values.
    public static func buildAllowlistedBaselineEnvironment(
        baseEnv: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result: [String: String] = [:]

        for key in baselineEnvKeys {
            if let value = baseEnv[key] {
                let sanitized = sanitizeEnvValue(value)
                if !sanitized.isEmpty {
                    result[key] = sanitized
                }
            }
        }

        return result
    }

    /// Sanitizes an environment variable value.
    /// Removes newlines and control characters that could be used for injection.
    private static func sanitizeEnvValue(_ value: String) -> String {
        return value.unicodeScalars
            .filter { $0.value >= 0x20 && $0.value < 0x7F || $0.value == 0x09 }
            .map { String($0) }
            .joined()
    }

    // MARK: - Profile Validation

    /// Validates that a profile record is a valid CLI profile.
    public static func validateCLIProfile(_ profile: SwitcherProfileRecord) -> Result<Void, CLILaunchError> {
        guard profile.targetKind == .cli else {
            return .failure(.profileKindMismatch(expected: .cli, actual: profile.targetKind))
        }

        guard profile.cliType != nil else {
            return .failure(.missingProfileMetadata(profile.id))
        }

        guard profile.cliMetadata != nil else {
            return .failure(.missingProfileMetadata(profile.id))
        }

        return .success(())
    }

    /// Validates that a CLI profile matches the expected CLI type.
    public static func validateProfileCLITypeMatch(
        profile: SwitcherProfileRecord,
        targetCLI: SwitcherCLIProfileType
    ) -> Result<Void, CLILaunchError> {
        // First check it's a CLI profile
        guard profile.targetKind == .cli else {
            return .failure(.profileKindMismatch(expected: .cli, actual: profile.targetKind))
        }

        guard profile.cliType == targetCLI else {
            return .failure(.profileTypeMismatch(expected: targetCLI, actual: profile.cliType))
        }

        guard profile.cliMetadata != nil else {
            return .failure(.missingProfileMetadata(profile.id))
        }

        return .success(())
    }

    // MARK: - Launch Construction

    /// Constructs the launch configuration for a CLI profile.
    /// Returns the executable URL, arguments, environment, and working directory.
    public static func buildCLILaunch(
        profile: SwitcherProfileRecord,
        additionalArgs: [String] = []
    ) -> Result<(executable: URL, args: [String], env: [String: String], workingDirectory: String?), CLILaunchError> {
        // Validate it's a CLI profile
        guard profile.targetKind == .cli else {
            return .failure(.profileKindMismatch(expected: .cli, actual: profile.targetKind))
        }

        guard let cliType = profile.cliType else {
            return .failure(.missingProfileMetadata(profile.id))
        }

        guard let metadata = profile.cliMetadata else {
            return .failure(.missingProfileMetadata(profile.id))
        }

        // Resolve trusted executable
        guard let executableURL = resolveExecutable(for: cliType) else {
            return .failure(.executableNotFound(cliType))
        }

        // Build argument list
        var args: [String] = []

        // Validate and add additional arguments from profile
        if !metadata.additionalArgs.isEmpty {
            let validatedArgsResult = validateArguments(metadata.additionalArgs)
            switch validatedArgsResult {
            case .failure(let error):
                return .failure(error)
            case .success(let validatedArgs):
                args.append(contentsOf: validatedArgs)
            }
        }

        // Validate and add caller-provided additional args
        if !additionalArgs.isEmpty {
            let validatedArgsResult = validateArguments(additionalArgs)
            switch validatedArgsResult {
            case .failure(let error):
                return .failure(error)
            case .success(let validatedArgs):
                args.append(contentsOf: validatedArgs)
            }
        }

        // Validate working directory if specified
        var workingDirectory: String?
        if let wd = metadata.workingDirectory, !wd.isEmpty {
            let wdResult = validateWorkingDirectory(wd)
            switch wdResult {
            case .failure(let error):
                return .failure(error)
            case .success(let validatedWD):
                workingDirectory = validatedWD
            }
        }

        // Build environment - only allowlisted keys
        var env = filterAllowlistedEnvironment(
            keys: metadata.envKeysToPass,
            baseEnv: environmentProvider()
        )
        if let configDirectory = metadata.configDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDirectory.isEmpty {
            for configEnvKey in configEnvironmentKeys(for: cliType) {
                env[configEnvKey] = configDirectory
            }
        }

        return .success((executableURL, args, env, workingDirectory))
    }

    private static func configEnvironmentKeys(for cliType: SwitcherCLIProfileType) -> [String] {
        switch cliType {
        case .codex:
            return ["CODEX_HOME", "CODEX_CONFIG_PATH"]
        case .claude:
            return ["CLAUDE_CONFIG_DIR", "CLAUDE_CONFIG_PATH"]
        case .opencode:
            return ["OPENCODE_CONFIG_PATH", "OPENCODE_DATA", "OPENCODE_DATA_HOME"]
        case .droid:
            return ["FACTORY_HOME", "DROID_HOME"]
        case .forge:
            return ["FORGE_HOME", "FORGE_CONFIG_HOME"]
        case .antigravity:
            return ["AGY_CONFIG_HOME", "ANTIGRAVITY_HOME", "GEMINI_HOME"]
        case .grok:
            return ["GROK_HOME", "XAI_API_KEY"]
        case .cursorAgent:
            return ["CURSOR_AGENT_HOME", "CURSOR_AGENT_CONFIG_PATH"]
        case .gemini:
            return ["GEMINI_HOME", "GEMINI_API_KEY", "GOOGLE_API_KEY"]
        case .kimi:
            return ["KIMI_HOME", "KIMI_API_KEY", "MOONSHOT_API_KEY"]
        case .pi:
            return ["PI_HOME", "PI_CONFIG_HOME"]
        case .junie:
            return ["JUNIE_HOME"]
        case .omp:
            return ["OMP_HOME", "OMP_CONFIG_HOME"]
        case .primeAgent:
            return ["PRIME_HOME", "PRIME_AGENT_HOME"]
        }
    }
}

// MARK: - CLI Launch Error

/// Typed errors for CLI launch failures.
/// All errors are actionable and provide clear remediation guidance.
public enum CLILaunchError: LocalizedError, Equatable, Sendable {
    case executableNotFound(SwitcherCLIProfileType)
    case profileNotFound(String)
    case profileTypeMismatch(expected: SwitcherCLIProfileType, actual: SwitcherCLIProfileType?)
    case profileKindMismatch(expected: SwitcherProfileTargetKind, actual: SwitcherProfileTargetKind)
    case missingProfileMetadata(String)
    case invalidWorkingDirectory(String)
    case disallowedArgument(String)
    case launchConfigurationFailed(String)
    case launchSpawnFailed(String)
    case launchTimeout
    case quotaExhausted(String)
    case launchFailed(String)
    case noActiveProfile

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let cliType):
            return "\(cliType.displayName) executable not found. Install \(cliType.displayName) to use CLI profile switching."

        case .profileNotFound(let id):
            return "CLI profile with ID '\(id)' not found."

        case .profileTypeMismatch(let expected, let actual):
            let actualStr = actual?.displayName ?? "nil"
            return "Profile type mismatch: expected \(expected.displayName), got \(actualStr)."

        case .profileKindMismatch(let expected, let actual):
            return "Profile kind mismatch: expected \(expected.rawValue), got \(actual.rawValue)."

        case .missingProfileMetadata(let profileID):
            return "Profile '\(profileID)' is missing required CLI metadata."

        case .invalidWorkingDirectory(let reason):
            return "Invalid working directory: \(reason)"

        case .disallowedArgument(let arg):
            return "Argument '\(arg)' is not in the allowlist and cannot be used for CLI launch."

        case .launchConfigurationFailed(let reason):
            return "Failed to configure CLI launch: \(reason)"

        case .launchSpawnFailed(let detail):
            return "Failed to spawn CLI process: \(detail)"

        case .launchTimeout:
            return "CLI launch timed out."

        case .quotaExhausted(let detail):
            return "CLI quota exhausted: \(detail)"

        case .launchFailed(let detail):
            return "CLI launch failed: \(detail)"

        case .noActiveProfile:
            return "No active CLI profile is set."
        }
    }

    /// Returns a recovery suggestion for this error, if available.
    public var recoverySuggestion: String? {
        switch self {
        case .executableNotFound:
            return "Install the CLI from its official source. For Claude Code: npm install -g @anthropic-ai/claude-code"
        case .profileNotFound:
            return "Select a valid CLI profile from Settings."
        case .profileTypeMismatch, .profileKindMismatch:
            return "Create a new profile for the correct CLI type in Settings."
        case .missingProfileMetadata:
            return "Edit the profile in Settings to add required CLI profile information."
        case .invalidWorkingDirectory:
            return "Edit the profile in Settings to specify a valid working directory within your home folder."
        case .disallowedArgument:
            return "Edit the profile to remove disallowed arguments."
        case .quotaExhausted:
            return "Switch to another account or wait for the 5-hour or weekly quota window to reset."
        case .launchConfigurationFailed, .launchSpawnFailed, .launchTimeout, .launchFailed:
            return "Try launching the CLI manually. If the issue persists, check your installation."
        case .noActiveProfile:
            return "Set an active CLI profile in Settings, Dashboard, or the menu bar popover."
        }
    }
}

#endif
