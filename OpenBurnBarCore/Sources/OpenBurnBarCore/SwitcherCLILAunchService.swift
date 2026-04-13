import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - CLI Launch Adapter

/// Orchestrates CLI application launches for Codex, Claude, and OpenCode using explicit profile references.
///
/// Security properties:
/// - Uses ONLY allowlisted environment variables - no arbitrary env injection
/// - Resolves only trusted executable paths - rejects PATH/CWD hijack candidates
/// - Constructs explicit argv without shell interpolation
/// - Profile arguments are validated and canonicalized before use
/// - Typed errors for all failure modes - no state corruption on failure
/// - Serialized launches prevent duplicate committed launches
///
/// Launch approach:
/// - Resolve trusted executable from predefined list of known locations
/// - Build explicit argv from profile metadata and validated additional args
/// - Propagate only allowlisted environment variables
/// - Execute via Foundation Process with explicit executable and arguments
public enum CLILaunchAdapter {

    // MARK: - Launch Result

    /// Result of a CLI launch attempt.
    public enum LaunchResult: Equatable, Sendable {
        case success
        case failure(CLILaunchError)
    }

    // MARK: - Executable Resolution Seam (Testability)

    /// Injectable resolver for executable availability.
    /// Defaults to real filesystem resolution. Override in tests for deterministic behavior.
    public static var executableResolver: ((_ cliType: SwitcherCLIProfileType) -> URL?)?
    static var environmentProvider: () -> [String: String] = { ProcessInfo.processInfo.environment }
    static var homeDirectoryProvider: () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }

    // MARK: - Allowlisted Environment Variables

    /// Environment variables that are allowlisted for CLI profile launching.
    /// These are considered safe as they only affect basic OS behavior,
    /// not authentication, credentials, or security boundaries.
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
        "CLAUDE_CONFIG_PATH",
        // Codex-specific safe variables
        "CODEX_HOME",
        "CODEX_CONFIG_PATH",
        // OpenCode-specific safe variables
        "OPENCODE_CONFIG_PATH",
    ]

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
        "--project=",
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
        let environment = environmentProvider()
        let homeDirectory = homeDirectoryProvider()

        for directory in trustedExecutableSearchDirectories(
            for: cliType,
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            let candidatePath = URL(fileURLWithPath: directory)
                .appendingPathComponent(cliType.executableName)
                .path
            if fileManager.isExecutableFile(atPath: candidatePath) {
                return URL(fileURLWithPath: candidatePath)
            }
        }

        if let shellPath = resolveExecutableFromLoginShell(
            named: cliType.executableName,
            environment: environment,
            fileManager: fileManager
        ), isTrustedResolvedExecutable(
            shellPath,
            for: cliType,
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            return URL(fileURLWithPath: shellPath)
        }

        return nil
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

    static func trustedExecutableSearchDirectories(
        for cliType: SwitcherCLIProfileType,
        environment: [String: String],
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        let explicitDirectories = cliType.trustedExecutablePaths.map {
            URL(fileURLWithPath: expandPath($0, homeDirectory: homeDirectory))
                .deletingLastPathComponent()
                .path
        }

        return deduplicatedDirectories(
            explicitDirectories
            + standardExecutableSearchDirectories(homeDirectory: homeDirectory)
            + userManagedExecutableSearchDirectories(homeDirectory: homeDirectory, fileManager: fileManager)
            + ideManagedExecutableSearchDirectories(homeDirectory: homeDirectory, fileManager: fileManager)
        )
    }

    private static func standardExecutableSearchDirectories(homeDirectory: String) -> [String] {
        [
            "\(homeDirectory)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
    }

    private static func userManagedExecutableSearchDirectories(
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = [
            "\(homeDirectory)/.codex/bin",
            "\(homeDirectory)/.claude/bin",
            "\(homeDirectory)/.opencode/bin",
            "\(homeDirectory)/.npm-global/bin",
            "\(homeDirectory)/.bun/bin",
            "\(homeDirectory)/.volta/bin",
            "\(homeDirectory)/.asdf/shims",
            "\(homeDirectory)/.mise/shims",
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
            "\(homeDirectory)/.windsurf/extensions",
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

    private static func isTrustedResolvedExecutable(
        _ path: String,
        for cliType: SwitcherCLIProfileType,
        environment: [String: String],
        homeDirectory: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard fileManager.isExecutableFile(atPath: path) else {
            return false
        }

        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let trustedPaths = cliType.trustedExecutablePaths.map {
            URL(fileURLWithPath: expandPath($0, homeDirectory: homeDirectory)).standardizedFileURL.path
        }
        if trustedPaths.contains(standardizedPath) {
            return true
        }

        let parentDirectory = URL(fileURLWithPath: standardizedPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path

        return trustedExecutableSearchDirectories(
            for: cliType,
            environment: environment,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ).contains(parentDirectory)
    }

    private static func resolveExecutableFromLoginShell(
        named name: String,
        environment: [String: String],
        fileManager: FileManager = .default
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

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        return output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .reversed()
            .first(where: { $0.hasPrefix("/") })
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

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
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
                for pattern in suspicious {
                    if valuePart.contains(pattern) {
                        return nil
                    }
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

        for key in allowlistedEnvKeys {
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
        var workingDirectory: String? = nil
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
        var env = filterAllowlistedEnvironment(keys: metadata.envKeysToPass)
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
            return ["CLAUDE_CONFIG_PATH"]
        case .opencode:
            return ["OPENCODE_CONFIG_PATH"]
        }
    }
}

// MARK: - CLI Launch Error

/// Typed errors for CLI launch failures.
/// All errors are actionable and provide clear remediation guidance.
public enum CLILaunchError: Error, Equatable, Sendable {
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

// MARK: - Concurrent Launch Serialization

/// A serial coordinator that ensures CLI launches are serialized,
/// preventing duplicate committed launches under concurrent requests.
/// Uses an actor to provide thread-safe serialization.
public actor CLILaunchCoordinator {
    private var pendingLaunches: Set<String> = []
    private var lastLaunchedProfileID: String?
    private var lastAttemptedProfileID: String?
    private var launchSequence: Int = 0

    public init() {}

    /// Records that a launch is about to occur for a profile.
    /// Returns the sequence number if the launch should proceed, nil if a launch
    /// for this profile is already in progress.
    public func beginLaunch(profileID: String) -> Int? {
        if pendingLaunches.contains(profileID) {
            return nil
        }
        pendingLaunches.insert(profileID)
        launchSequence += 1
        // Track the profile ID on every attempt (not just success) for test verification
        lastAttemptedProfileID = profileID
        return launchSequence
    }

    /// Records that a launch has completed for a profile.
    public func endLaunch(profileID: String, success: Bool) {
        pendingLaunches.remove(profileID)
        if success {
            lastLaunchedProfileID = profileID
        }
    }

    /// Returns the last successfully launched profile ID.
    public func getLastLaunchedProfileID() -> String? {
        return lastLaunchedProfileID
    }

    /// Returns the last attempted profile ID, regardless of success or failure.
    /// This is used for test verification to prove the correct profile was routed.
    public func getLastAttemptedProfileID() -> String? {
        return lastAttemptedProfileID
    }

    /// Returns true if there's a launch in progress for the given profile.
    public func isLaunchInProgress(profileID: String) -> Bool {
        return pendingLaunches.contains(profileID)
    }

    /// Clears all pending launches. Use for error recovery.
    public func clearPendingLaunches() {
        pendingLaunches.removeAll()
    }
}

// MARK: - Launch Invocation

/// Actually performs the CLI launch using Foundation Process.
/// Isolated to prevent direct invocation outside of the coordinator.
public struct CLILaunchInvoker {
    /// Injectable launch handler for deterministic testing.
    /// When set, replaces the real Process-based launch with the provided handler.
    /// Receives the launch parameters and returns a Result.
    public static var launchHandler: ((SwitcherCLIProfileType, URL, [String], [String: String], String?, (@Sendable (String) -> Void)?) async -> Result<Void, CLILaunchError>)?
    static var startupObservationTimeout: TimeInterval = 1.5

    /// Launches a CLI process with the given configuration.
    /// Returns after the startup observation window passes or a startup failure is detected.
    ///
    /// Testability: If `launchHandler` is set, it is called instead of spawning
    /// a real process, allowing tests to simulate launch outcomes deterministically.
    public static func launchCLI(
        cliType: SwitcherCLIProfileType,
        executable: URL,
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil,
        postLaunchQuotaObserver: (@Sendable (String) -> Void)? = nil
    ) async -> Result<Void, CLILaunchError> {
        // Use injected handler if available (for deterministic testing)
        if let handler = launchHandler {
            return await handler(cliType, executable, args, env, workingDirectory, postLaunchQuotaObserver)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args

        // Set environment - build from allowlisted baseline only, then merge profile-specific keys.
        // Security: We do NOT start with ProcessInfo.processInfo.environment (full ambient env).
        // This prevents sensitive ambient variables (API keys, tokens, etc.) from leaking to CLI.
        var finalEnv = CLILaunchAdapter.buildAllowlistedBaselineEnvironment()
        for (key, value) in env {
            finalEnv[key] = value
        }
        process.environment = finalEnv

        // Set working directory if specified
        if let wd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let quotaRecorder = QuotaSignalRecorder()
        let supervisor = CLITerminalSessionSupervisor(cliType: cliType) { event in
            guard case .quotaExhausted(let detail, _) = event else { return }
            quotaRecorder.record(detail)
            if process.isRunning {
                process.terminate()
            }
        }
        let stdoutTask = Task.detached(priority: .utility) {
            await drainPipe(stdoutPipe, into: supervisor, source: .stdout)
        }
        let stderrTask = Task.detached(priority: .utility) {
            await drainPipe(stderrPipe, into: supervisor, source: .stderr)
        }

        let cleanup = LaunchObservationCleanup {
            stdoutTask.cancel()
            stderrTask.cancel()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
        }

        func finish(_ result: Result<Void, CLILaunchError>) -> Result<Void, CLILaunchError> {
            cleanup.perform()
            return result
        }

        do {
            try process.run()
        } catch {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            let detail = stderrStr.isEmpty ? error.localizedDescription : "\(error.localizedDescription): \(stderrStr)"
            return finish(.failure(.launchSpawnFailed(CLILaunchRedactor.redactSensitiveData(detail))))
        }

        let deadline = Date().addingTimeInterval(startupObservationTimeout)
        while true {
            if let detail = quotaRecorder.snapshot() {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                return finish(.failure(.quotaExhausted(CLILaunchRedactor.redactSensitiveData(detail))))
            }

            if !process.isRunning {
                let combinedOutput = supervisor.snapshot()
                if let detail = quotaRecorder.snapshot()
                    ?? CLIQuotaExhaustionClassifier.classify(for: cliType, in: combinedOutput) {
                    return finish(.failure(.quotaExhausted(CLILaunchRedactor.redactSensitiveData(detail))))
                }
                if process.terminationStatus == 0 {
                    return finish(.success(()))
                }

                let trimmedOutput = combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = trimmedOutput.isEmpty
                    ? "\(cliType.displayName) exited during startup with status \(process.terminationStatus)."
                    : trimmedOutput
                return finish(.failure(.launchFailed(CLILaunchRedactor.redactSensitiveData(detail))))
            }

            if Date() >= deadline {
                Task.detached(priority: .utility) {
                    while true {
                        if let detail = quotaRecorder.snapshot() {
                            if process.isRunning {
                                process.terminate()
                                process.waitUntilExit()
                            }
                            cleanup.perform()
                            postLaunchQuotaObserver?(CLILaunchRedactor.redactSensitiveData(detail))
                            return
                        }

                        if !process.isRunning {
                            let combinedOutput = supervisor.snapshot()
                            if let detail = quotaRecorder.snapshot()
                                ?? CLIQuotaExhaustionClassifier.classify(for: cliType, in: combinedOutput) {
                                postLaunchQuotaObserver?(CLILaunchRedactor.redactSensitiveData(detail))
                            }
                            cleanup.perform()
                            return
                        }

                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
                return .success(())
            }

            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    static func classifyQuotaExhaustion(for cliType: SwitcherCLIProfileType, in output: String) -> String? {
        CLIQuotaExhaustionClassifier.classify(for: cliType, in: output)
    }

    private static func drainPipe(
        _ pipe: Pipe,
        into supervisor: CLITerminalSessionSupervisor,
        source: CLITerminalSessionOutputSource
    ) async {
        let readHandle = pipe.fileHandleForReading
        while true {
            let data = readHandle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else {
                return
            }
            supervisor.ingest(text, source: source)
        }
    }
}

private final class QuotaSignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var detail: String?

    func record(_ detail: String) {
        lock.lock()
        if self.detail == nil {
            self.detail = detail
        }
        lock.unlock()
    }

    func snapshot() -> String? {
        lock.lock()
        let value = detail
        lock.unlock()
        return value
    }
}

private final class LaunchObservationCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var didCleanup = false
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func perform() {
        lock.lock()
        let shouldRun = !didCleanup
        didCleanup = true
        lock.unlock()

        guard shouldRun else { return }
        action()
    }
}

// MARK: - CLI Fallback Planning

public enum CLIFallbackEligibility: Equatable, Sendable {
    case eligible
    case quotaExhausted(reason: String)
    case ineligible(reason: String)
}

public protocol CLIFallbackPlanning: Sendable {
    func orderedCandidates(
        for requestedProfile: SwitcherProfileRecord,
        allProfiles: [SwitcherProfileRecord]
    ) async -> [SwitcherProfileRecord]

    func eligibility(for profile: SwitcherProfileRecord) async -> CLIFallbackEligibility
}

public struct DefaultCLIFallbackPlanner: CLIFallbackPlanning {
    public init() {}

    public func orderedCandidates(
        for requestedProfile: SwitcherProfileRecord,
        allProfiles: [SwitcherProfileRecord]
    ) async -> [SwitcherProfileRecord] {
        [requestedProfile]
    }

    public func eligibility(for profile: SwitcherProfileRecord) async -> CLIFallbackEligibility {
        .eligible
    }
}

public enum CLILaunchServiceEvent: Equatable, Sendable {
    case postLaunchFallbackSucceeded(
        exhaustedProfileID: String,
        recoveredProfileID: String,
        detail: String,
        attemptedProfileIDs: [String]
    )
    case postLaunchFallbackFailed(
        exhaustedProfileID: String,
        detail: String,
        attemptedProfileIDs: [String]
    )
}

// MARK: - Switcher CLI Launch Service

/// High-level service for CLI launch orchestration.
/// Combines profile resolution, launch validation, concurrency handling, and error typing.
///
/// Security invariants:
/// - Uses only trusted executable paths
/// - Uses only allowlisted environment variables
/// - No shell interpolation in argument construction
/// - Typed errors for all failure modes
/// - Serialized launches via coordinator
public final class SwitcherCLILAunchService: @unchecked Sendable {
    private let profileStore: SwitcherProfileStoreAdapter
    private let coordinator: CLILaunchCoordinator
    private let fallbackPlanner: any CLIFallbackPlanning
    private let eventHandler: (@MainActor (CLILaunchServiceEvent) -> Void)?

    /// Creates a new CLI launch service.
    public init(
        profileStore: SwitcherProfileStoreAdapter,
        fallbackPlanner: any CLIFallbackPlanning = DefaultCLIFallbackPlanner(),
        eventHandler: (@MainActor (CLILaunchServiceEvent) -> Void)? = nil
    ) {
        self.profileStore = profileStore
        self.coordinator = CLILaunchCoordinator()
        self.fallbackPlanner = fallbackPlanner
        self.eventHandler = eventHandler
    }

    // MARK: - Launch Methods

    /// Launches the CLI for the given profile.
    /// Returns immediately if a launch is already in progress for this profile.
    public func launchCLI(for profileID: String) async -> CLILaunchOutcome {
        guard let profile = profileStore.fetchProfile(id: profileID) else {
            return CLILaunchOutcome(
                success: false,
                error: .profileNotFound(profileID)
            )
        }

        guard profile.targetKind == .cli else {
            return CLILaunchOutcome(
                success: false,
                error: .profileKindMismatch(expected: .cli, actual: profile.targetKind)
            )
        }

        guard profile.cliType != nil else {
            return CLILaunchOutcome(
                success: false,
                error: .missingProfileMetadata(profileID)
            )
        }

        let allProfiles = profileStore.fetchAllProfiles()
        let plannerCandidates = await fallbackPlanner.orderedCandidates(
            for: profile,
            allProfiles: allProfiles
        )
        let candidates = prioritizedCandidates(
            requestedProfile: profile,
            plannerCandidates: plannerCandidates
        )

        return await launchCandidates(
            requestedProfile: profile,
            candidates: candidates,
            attemptedProfileIDs: []
        )
    }

    /// Launches a specific CLI type (Codex/Claude/OpenCode) using a profile.
    public func launchCLI(
        cliType: SwitcherCLIProfileType,
        profileID: String
    ) async -> CLILaunchOutcome {
        guard let profile = profileStore.fetchProfile(id: profileID) else {
            return CLILaunchOutcome(
                success: false,
                error: .profileNotFound(profileID)
            )
        }

        // Validate profile matches expected CLI type
        let validationResult = CLILaunchAdapter.validateProfileCLITypeMatch(
            profile: profile,
            targetCLI: cliType
        )

        switch validationResult {
        case .failure(let error):
            return CLILaunchOutcome(success: false, error: error)
        case .success:
            return await launchCLI(for: profileID)
        }
    }

    /// Launches the CLI for the current active profile.
    /// This method reads the active profile ID from the store and launches it
    /// without requiring an explicit profile ID override.
    ///
    /// This is the key method for active-state routing - it proves that
    /// the launch adapter consumes the final committed global active profile.
    ///
    /// Returns `.noActiveProfile` if no profile is currently active.
    public func launchUsingActiveProfile() async -> CLILaunchOutcome {
        // Fetch the active profile ID from global state
        guard let activeProfileID = profileStore.fetchActiveProfileID() else {
            return CLILaunchOutcome(
                success: false,
                error: .noActiveProfile
            )
        }

        // Launch using the active profile ID
        return await launchCLI(for: activeProfileID)
    }

    // MARK: - Availability Checking

    /// Checks if a CLI executable is available.
    public func isCLIAvailable(_ cliType: SwitcherCLIProfileType) -> Bool {
        return CLILaunchAdapter.isExecutableAvailable(cliType)
    }

    /// Returns the resolved executable path for a CLI type.
    public func executablePath(for cliType: SwitcherCLIProfileType) -> String? {
        return CLILaunchAdapter.executablePath(for: cliType)
    }

    /// Returns the last attempted profile ID from the coordinator, for test verification.
    /// This allows tests to verify that the correct profile ID was routed through
    /// the launch service, not just that an error occurred.
    public func getLastAttemptedProfileID() async -> String? {
        return await coordinator.getLastAttemptedProfileID()
    }

    private func prioritizedCandidates(
        requestedProfile: SwitcherProfileRecord,
        plannerCandidates: [SwitcherProfileRecord]
    ) -> [SwitcherProfileRecord] {
        var seen = Set<String>()
        var ordered: [SwitcherProfileRecord] = []

        let requestedAndPlanned = [requestedProfile] + plannerCandidates
        for candidate in requestedAndPlanned where seen.insert(candidate.id).inserted {
            ordered.append(candidate)
        }

        return ordered
    }

    private func launchCandidates(
        requestedProfile: SwitcherProfileRecord,
        candidates: [SwitcherProfileRecord],
        attemptedProfileIDs initialAttemptedProfileIDs: [String]
    ) async -> CLILaunchOutcome {
        var attemptedProfileIDs = initialAttemptedProfileIDs
        var lastError: CLILaunchError?

        for (index, candidate) in candidates.enumerated() {
            attemptedProfileIDs.append(candidate.id)
            let eligibility = await fallbackPlanner.eligibility(for: candidate)
            switch eligibility {
            case .eligible:
                break
            case .quotaExhausted(let reason):
                lastError = .quotaExhausted(reason)
                continue
            case .ineligible(let reason):
                lastError = .launchFailed(reason)
                if candidate.id == requestedProfile.id && index == 0 {
                    return CLILaunchOutcome(
                        success: false,
                        error: lastError,
                        launchedProfileID: nil,
                        attemptedProfileIDs: attemptedProfileIDs
                    )
                }
                continue
            }

            let attemptedSnapshot = attemptedProfileIDs
            let remainingCandidates = index + 1 < candidates.count
                ? Array(candidates[(index + 1)...])
                : []

            let outcome = await attemptLaunch(
                profile: candidate,
                postLaunchQuotaObserver: { [weak self] detail in
                    guard let self else { return }
                    Task {
                        await self.handlePostLaunchQuotaExhaustion(
                            exhaustedProfile: candidate,
                            remainingCandidates: remainingCandidates,
                            attemptedProfileIDs: attemptedSnapshot,
                            detail: detail
                        )
                    }
                }
            )
            if outcome.success {
                clearQuotaExhaustion(for: candidate)
                if candidate.id != requestedProfile.id {
                    profileStore.setActiveProfileID(candidate.id)
                }
                return CLILaunchOutcome(
                    success: true,
                    error: nil,
                    launchedProfileID: candidate.id,
                    attemptedProfileIDs: attemptedProfileIDs
                )
            }

            if case .quotaExhausted(let detail) = outcome.error {
                persistQuotaExhaustion(for: candidate, detail: detail)
                lastError = outcome.error
                continue
            }

            return CLILaunchOutcome(
                success: false,
                error: outcome.error,
                launchedProfileID: nil,
                attemptedProfileIDs: attemptedProfileIDs
            )
        }

        return CLILaunchOutcome(
            success: false,
            error: lastError ?? .launchFailed("No eligible CLI profiles are available in the current priority order."),
            launchedProfileID: nil,
            attemptedProfileIDs: attemptedProfileIDs
        )
    }

    private func attemptLaunch(
        profile: SwitcherProfileRecord,
        postLaunchQuotaObserver: (@Sendable (String) -> Void)? = nil
    ) async -> CLILaunchOutcome {
        let profileID = profile.id
        guard let cliType = profile.cliType else {
            return CLILaunchOutcome(
                success: false,
                error: .missingProfileMetadata(profileID),
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )
        }
        let sequence = await coordinator.beginLaunch(profileID: profileID)
        guard sequence != nil else {
            return CLILaunchOutcome(
                success: false,
                error: .launchFailed("Launch already in progress for this profile"),
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )
        }

        defer {
            Task {
                await coordinator.endLaunch(profileID: profileID, success: false)
            }
        }

        guard profile.targetKind == .cli else {
            return CLILaunchOutcome(
                success: false,
                error: .profileKindMismatch(expected: .cli, actual: profile.targetKind),
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )
        }

        let buildResult = CLILaunchAdapter.buildCLILaunch(profile: profile)

        switch buildResult {
        case .failure(let error):
            return CLILaunchOutcome(
                success: false,
                error: error,
                launchedProfileID: nil,
                attemptedProfileIDs: [profileID]
            )

        case .success(let (executable, args, env, workingDirectory)):
            let launchResult = await CLILaunchInvoker.launchCLI(
                cliType: cliType,
                executable: executable,
                args: args,
                env: env,
                workingDirectory: workingDirectory,
                postLaunchQuotaObserver: postLaunchQuotaObserver
            )

            switch launchResult {
            case .success:
                await coordinator.endLaunch(profileID: profileID, success: true)
                return CLILaunchOutcome(
                    success: true,
                    error: nil,
                    launchedProfileID: profileID,
                    attemptedProfileIDs: [profileID]
                )
            case .failure(let error):
                return CLILaunchOutcome(
                    success: false,
                    error: error,
                    launchedProfileID: nil,
                    attemptedProfileIDs: [profileID]
                )
            }
        }
    }

    private func handlePostLaunchQuotaExhaustion(
        exhaustedProfile: SwitcherProfileRecord,
        remainingCandidates: [SwitcherProfileRecord],
        attemptedProfileIDs: [String],
        detail: String
    ) async {
        persistQuotaExhaustion(for: exhaustedProfile, detail: detail)
        let outcome = await launchCandidates(
            requestedProfile: exhaustedProfile,
            candidates: remainingCandidates,
            attemptedProfileIDs: attemptedProfileIDs
        )

        if outcome.success, let recoveredProfileID = outcome.launchedProfileID {
            profileStore.setActiveProfileID(recoveredProfileID)
            notifyEvent(.postLaunchFallbackSucceeded(
                exhaustedProfileID: exhaustedProfile.id,
                recoveredProfileID: recoveredProfileID,
                detail: detail,
                attemptedProfileIDs: outcome.attemptedProfileIDs
            ))
        } else {
            notifyEvent(.postLaunchFallbackFailed(
                exhaustedProfileID: exhaustedProfile.id,
                detail: outcome.error?.errorDescription ?? detail,
                attemptedProfileIDs: outcome.attemptedProfileIDs.isEmpty ? attemptedProfileIDs : outcome.attemptedProfileIDs
            ))
        }
    }

    private func persistQuotaExhaustion(for profile: SwitcherProfileRecord, detail: String) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType else {
            return
        }

        let safeDetail = CLILaunchRedactor.redactSensitiveData(detail)
        let now = Date()
        let exhaustedUntil = exhaustionWindowEnd(from: safeDetail, now: now)
        let existingMetadata = profile.cliMetadata ?? SwitcherCLIProfileMetadata()
        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription,
                lastQuotaExhaustedAt: now,
                exhaustedUntil: exhaustedUntil,
                lastQuotaExhaustionDetail: safeDetail
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )

        profileStore.updateProfile(updatedProfile)
    }

    private func clearQuotaExhaustion(for profile: SwitcherProfileRecord) {
        guard profile.targetKind == .cli,
              let cliType = profile.cliType,
              let existingMetadata = profile.cliMetadata,
              existingMetadata.lastQuotaExhaustedAt != nil
                || existingMetadata.exhaustedUntil != nil
                || existingMetadata.lastQuotaExhaustionDetail != nil else {
            return
        }

        let updatedProfile = SwitcherProfileRecord(
            id: profile.id,
            targetKind: .cli,
            cliType: cliType,
            cliMetadata: SwitcherCLIProfileMetadata(
                workingDirectory: existingMetadata.workingDirectory,
                additionalArgs: existingMetadata.additionalArgs,
                envKeysToPass: existingMetadata.envKeysToPass,
                displayLabel: existingMetadata.displayLabel,
                configDirectory: existingMetadata.configDirectory,
                accountDescription: existingMetadata.accountDescription
            ),
            sortKey: profile.sortKey,
            createdAt: profile.createdAt
        )

        profileStore.updateProfile(updatedProfile)
    }

    private func exhaustionWindowEnd(from detail: String, now: Date) -> Date? {
        let normalized = detail.lowercased()
        if normalized.contains("weekly") || normalized.contains("week") {
            return now.addingTimeInterval(7 * 24 * 60 * 60)
        }
        if normalized.contains("5-hour")
            || normalized.contains("5 hour")
            || normalized.contains("5h")
            || normalized.contains("hour window") {
            return now.addingTimeInterval(5 * 60 * 60)
        }
        return nil
    }

    private func notifyEvent(_ event: CLILaunchServiceEvent) {
        guard let eventHandler else { return }
        Task { @MainActor in
            eventHandler(event)
        }
    }
}

// MARK: - Launch Outcome

/// Result of a CLI launch attempt with typed error.
public struct CLILaunchOutcome: Equatable, Sendable {
    public let success: Bool
    public let error: CLILaunchError?
    public let launchedProfileID: String?
    public let attemptedProfileIDs: [String]

    public var didUseFallback: Bool {
        guard let launchedProfileID,
              let firstAttempt = attemptedProfileIDs.first else {
            return false
        }
        return launchedProfileID != firstAttempt || attemptedProfileIDs.count > 1
    }

    public init(
        success: Bool,
        error: CLILaunchError?,
        launchedProfileID: String? = nil,
        attemptedProfileIDs: [String] = []
    ) {
        self.success = success
        self.error = error
        self.launchedProfileID = launchedProfileID
        self.attemptedProfileIDs = attemptedProfileIDs
    }

    public static func == (lhs: CLILaunchOutcome, rhs: CLILaunchOutcome) -> Bool {
        lhs.success == rhs.success
            && lhs.error == rhs.error
            && lhs.launchedProfileID == rhs.launchedProfileID
            && lhs.attemptedProfileIDs == rhs.attemptedProfileIDs
    }
}

// MARK: - Environment Redaction

/// Provides secret-safe logging and redaction utilities for CLI launch operations.
public struct CLILaunchRedactor {
    /// Keys that are considered sensitive and should never appear in logs.
    private static let sensitiveKeys: Set<String> = [
        "API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "AUTH",
        "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY",
    ]

    /// Redacts sensitive patterns from a string for safe logging.
    public static func redactSensitiveData(_ input: String) -> String {
        var result = input

        // Redact sensitive environment key patterns (key=value or key:value)
        // We look for patterns that indicate a secret is present:
        // 1. API key patterns (sk-ant-, sk- followed by 20+ chars, etc.)
        // Note: Longer patterns must come first in alternation to match correctly
        result = result.replacingOccurrences(
            of: #"(?i)(sk-[a-zA-Z0-9]{20,}|sk-ant-)"#,
            with: "[API_KEY_REDACTED]",
            options: .regularExpression
        )

        // 2. Bearer token patterns
        result = result.replacingOccurrences(
            of: #"(?i)Bearer[_\s]+[A-Za-z0-9_\-\.]+"#,
            with: "[TOKEN_REDACTED]",
            options: .regularExpression
        )

        // 3. Generic key=value patterns where value looks like a secret
        // Pattern: word characters followed by = or : followed by what looks like a token/secret
        result = result.replacingOccurrences(
            of: #"(?i)(api_key|apikey|secret|password|token|auth|access_token)[=:][^,\s]+"#,
            with: "[SECRET_REDACTED]",
            options: .regularExpression
        )

        return result
    }

    /// Redacts sensitive environment variables from a dictionary for safe logging.
    public static func redactEnvironment(_ env: [String: String]) -> [String: String] {
        var result: [String: String] = [:]

        for (key, value) in env {
            let isSensitive = sensitiveKeys.contains { key.uppercased().contains($0) }
            if isSensitive {
                result[key] = "[REDACTED]"
            } else {
                result[key] = redactSensitiveData(value)
            }
        }

        return result
    }
}
