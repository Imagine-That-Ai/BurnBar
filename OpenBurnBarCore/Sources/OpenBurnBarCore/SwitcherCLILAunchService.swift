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
        let env = filterAllowlistedEnvironment(keys: metadata.envKeysToPass)

        return .success((executableURL, args, env, workingDirectory))
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
    public static var launchHandler: ((URL, [String], [String: String], String?) async -> Result<Void, CLILaunchError>)?

    /// Launches a CLI process with the given configuration.
    /// Returns immediately after spawning the process.
    ///
    /// Testability: If `launchHandler` is set, it is called instead of spawning
    /// a real process, allowing tests to simulate launch outcomes deterministically.
    public static func launchCLI(
        executable: URL,
        args: [String] = [],
        env: [String: String] = [:],
        workingDirectory: String? = nil
    ) async -> Result<Void, CLILaunchError> {
        // Use injected handler if available (for deterministic testing)
        if let handler = launchHandler {
            return await handler(executable, args, env, workingDirectory)
        }

        return await withCheckedContinuation { continuation in
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

            // Capture stderr for error reporting
            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            do {
                try process.run()
                // Process launched successfully - we don't wait for it to complete
                // since CLI tools typically run for extended periods
                continuation.resume(returning: .success(()))
            } catch {
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
                let detail = stderrStr.isEmpty ? error.localizedDescription : "\(error.localizedDescription): \(stderrStr)"
                continuation.resume(returning: .failure(.launchSpawnFailed(detail)))
            }
        }
    }
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

    /// Creates a new CLI launch service.
    public init(profileStore: SwitcherProfileStoreAdapter) {
        self.profileStore = profileStore
        self.coordinator = CLILaunchCoordinator()
    }

    // MARK: - Launch Methods

    /// Launches the CLI for the given profile.
    /// Returns immediately if a launch is already in progress for this profile.
    public func launchCLI(for profileID: String) async -> CLILaunchOutcome {
        // Begin launch coordination
        let sequence = await coordinator.beginLaunch(profileID: profileID)
        guard sequence != nil else {
            // Launch already in progress
            return CLILaunchOutcome(
                success: false,
                error: .launchFailed("Launch already in progress for this profile")
            )
        }

        defer {
            Task {
                await coordinator.endLaunch(profileID: profileID, success: false)
            }
        }

        // Fetch profile
        guard let profile = profileStore.fetchProfile(id: profileID) else {
            return CLILaunchOutcome(
                success: false,
                error: .profileNotFound(profileID)
            )
        }

        // Validate profile is for CLI
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

        // Build launch configuration
        let buildResult = CLILaunchAdapter.buildCLILaunch(profile: profile)

        switch buildResult {
        case .failure(let error):
            return CLILaunchOutcome(success: false, error: error)

        case .success(let (executable, args, env, workingDirectory)):
            // Perform the launch
            let launchResult = await CLILaunchInvoker.launchCLI(
                executable: executable,
                args: args,
                env: env,
                workingDirectory: workingDirectory
            )

            switch launchResult {
            case .success:
                await coordinator.endLaunch(profileID: profileID, success: true)
                return CLILaunchOutcome(success: true, error: nil)
            case .failure(let error):
                return CLILaunchOutcome(success: false, error: error)
            }
        }
    }

    /// Launches a specific CLI type (Codex/Claude/OpenCode) using a profile.
    public func launchCLI(
        cliType: SwitcherCLIProfileType,
        profileID: String
    ) async -> CLILaunchOutcome {
        // Begin launch coordination
        let sequence = await coordinator.beginLaunch(profileID: profileID)
        guard sequence != nil else {
            return CLILaunchOutcome(
                success: false,
                error: .launchFailed("Launch already in progress for this profile")
            )
        }

        defer {
            Task {
                await coordinator.endLaunch(profileID: profileID, success: false)
            }
        }

        // Fetch profile
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
            break
        }

        // Build launch configuration
        let buildResult = CLILaunchAdapter.buildCLILaunch(profile: profile)

        switch buildResult {
        case .failure(let error):
            return CLILaunchOutcome(success: false, error: error)

        case .success(let (executable, args, env, workingDirectory)):
            let launchResult = await CLILaunchInvoker.launchCLI(
                executable: executable,
                args: args,
                env: env,
                workingDirectory: workingDirectory
            )

            switch launchResult {
            case .success:
                await coordinator.endLaunch(profileID: profileID, success: true)
                return CLILaunchOutcome(success: true, error: nil)
            case .failure(let error):
                return CLILaunchOutcome(success: false, error: error)
            }
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
}

// MARK: - Launch Outcome

/// Result of a CLI launch attempt with typed error.
public struct CLILaunchOutcome: Equatable, Sendable {
    public let success: Bool
    public let error: CLILaunchError?

    public init(success: Bool, error: CLILaunchError?) {
        self.success = success
        self.error = error
    }

    public static func == (lhs: CLILaunchOutcome, rhs: CLILaunchOutcome) -> Bool {
        return lhs.success == rhs.success && lhs.error == rhs.error
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
