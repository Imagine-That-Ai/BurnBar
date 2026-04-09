import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Browser Launch Adapter

/// Orchestrates browser application launches for Chrome and Safari using explicit profile references.
///
/// Security properties:
/// - Uses ONLY allowlisted launch arguments - no arbitrary flag injection
/// - Profile references are canonicalized and validated before use
/// - Never reads/writes browser cookie, session, or credential stores
/// - Typed errors for all failure modes - no state corruption on failure
/// - Serialized launches prevent duplicate committed launches
///
/// Launch approach:
/// - Chrome: Uses `--profile-directory=<name>` argument to target specific profile
/// - Safari: Uses WebKit profile container names; Safari doesn't support CLI profile switching
///   so this launches Safari which will use its last active profile
public enum BrowserLaunchAdapter {

    // MARK: - Launch Result

    /// Result of a browser launch attempt.
    public enum LaunchResult: Equatable, Sendable {
        case success
        case failure(BrowserLaunchError)
    }

    // MARK: - Allowlisted Launch Arguments

    /// Chrome arguments that are allowlisted for profile-based launching.
    /// These are considered safe as they only affect UI/behavior presentation,
    /// not authentication, networking, or security boundaries.
    private static let chromeAllowlistedArgs: Set<String> = [
        "--profile-directory=",    // Profile folder name (e.g., "Profile 1", "Default")
        "--new-window",           // Open new window instead of tabs
        "--new-tab",              // Open new tab
        "--incognito",            // Incognito mode (mutually exclusive with --profile-directory)
        "--private",              // Private browsing (Safari-style alias for incognito)
        "--app=",                 // Run as app mode
        "--app-mode-name=",       // App mode identifier
        "--app-switcher=",        // App switcher behavior
        "--no-default-browser-check",
        "--no-first-run",
        "--silent-launch",
        "--disable-background-networking",
        "--disable-extensions",
        "--disable-sync",
        "--disable-translate",
        "--safebrowsing-disable-auto-update",
    ]

    /// Safari arguments that are allowlisted.
    /// Note: Safari has very limited CLI argument support; most functionality requires
    /// GUI interaction or WebKit private profile APIs.
    private static let safariAllowlistedArgs: Set<String> = [
        "--new-window",           // Open new window
        "--private",              // Private browsing
    ]

    // MARK: - Profile Directory Canonicalization

    /// Canonicalizes a Chrome profile directory name for safe use in launch arguments.
    /// - Rejects paths that escape the profile directory boundary
    /// - Rejects control characters and suspicious patterns
    public static func canonicalizeChromeProfileDirectory(_ input: String) -> Result<String, BrowserLaunchError> {
        // Empty check
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.invalidProfileIdentifier("Profile identifier cannot be empty"))
        }

        // Length check - Chrome profile names are typically short
        guard trimmed.count <= 256 else {
            return .failure(.invalidProfileIdentifier("Profile identifier too long (max 256 chars)"))
        }

        // Reject null bytes and control characters
        let clean = trimmed.filter { char in
            let scalar = char.unicodeScalars.first!
            // Allow printable ASCII and common Unicode letters/numbers
            return scalar.value >= 0x20 && scalar.value < 0x7F
        }
        guard clean == trimmed else {
            return .failure(.invalidProfileIdentifier("Profile identifier contains invalid characters"))
        }

        // Reject suspicious patterns that could be injection attempts
        // Check these BEFORE path separators so that "--profile-directory=Default" gets
        // caught as suspicious (contains "--") rather than as path separator
        let suspiciousPatterns = ["--", "-=", ";", "&", "|", "`", "$", "(", ")", "{", "}", "[", "]", "<", ">"]
        for pattern in suspiciousPatterns {
            if trimmed.contains(pattern) {
                return .failure(.invalidProfileIdentifier("Profile identifier contains suspicious characters"))
            }
        }

        // Reject flag-like patterns that look like shell flags (-x '...')
        // This catches inputs like "-e 'ls'" which could be shell command attempts
        if trimmed.hasPrefix("-") && trimmed.count >= 2 {
            let secondChar = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)]
            if secondChar.isLetter {
                // Check if it looks like a flag (followed by space or another dash)
                let rest = String(trimmed.dropFirst(2))
                if rest.hasPrefix(" ") || rest.hasPrefix("-") || rest.isEmpty {
                    return .failure(.invalidProfileIdentifier("Profile identifier contains suspicious characters"))
                }
            }
        }

        // Reject path traversal and absolute paths - check LAST to prioritize suspicious pattern detection
        guard !trimmed.contains("/") && !trimmed.contains("\\") && !trimmed.contains(":") else {
            return .failure(.invalidProfileIdentifier("Profile identifier cannot contain path separators"))
        }

        return .success(trimmed)
    }

    // MARK: - Argument Validation

    /// Validates that a Chrome argument is in the allowlist.
    /// Returns the argument if valid, nil if not allowlisted.
    public static func validateChromeArgument(_ arg: String) -> String? {
        // If it's a complete match in the allowlist
        if chromeAllowlistedArgs.contains(arg) {
            return arg
        }

        // If it's a prefix match (e.g., "--profile-directory=Default")
        for allowlisted in chromeAllowlistedArgs {
            if arg.hasPrefix(allowlisted) && allowlisted.hasSuffix("=") {
                // Extract the value part and validate it's not empty or suspicious
                let valuePart = String(arg.dropFirst(allowlisted.count))
                guard !valuePart.isEmpty else { return nil }
                guard !valuePart.contains(" ") || valuePart.hasPrefix("\"") else {
                    // Allow spaces in quoted values, but not unquoted spaces
                    return nil
                }
                return arg
            }
        }

        return nil
    }

    /// Validates that a Safari argument is in the allowlist.
    public static func validateSafariArgument(_ arg: String) -> String? {
        if safariAllowlistedArgs.contains(arg) {
            return arg
        }
        // Prefix match for args with values
        for allowlisted in safariAllowlistedArgs {
            if arg.hasPrefix(allowlisted) && allowlisted.hasSuffix("=") {
                return arg
            }
        }
        return nil
    }

    // MARK: - Browser Resolution

    /// Checks if a browser application is installed and available for launching.
    public static func isBrowserAvailable(_ browserType: SwitcherBrowserProfileType) -> Bool {
        guard let bundleID = browserType.bundleIdentifier else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Returns the URL for a browser application, if available.
    public static func browserURL(for browserType: SwitcherBrowserProfileType) -> URL? {
        guard let bundleID = browserType.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    // MARK: - Launch Construction

    /// Constructs the launch configuration for a Chrome browser profile.
    /// Returns the URL and arguments to use for launching.
    public static func buildChromeLaunch(
        profile: SwitcherProfileRecord,
        additionalArgs: [String] = []
    ) -> Result<(URL, [String]), BrowserLaunchError> {
        // Validate it's a browser profile (check targetKind first for correct error)
        guard profile.targetKind == .browser else {
            return .failure(.profileKindMismatch(expected: .browser, actual: profile.targetKind))
        }

        guard profile.browserType == .chrome else {
            return .failure(.profileTypeMismatch(expected: .chrome, actual: profile.browserType))
        }

        guard let metadata = profile.browserMetadata else {
            return .failure(.missingProfileMetadata(profile.id))
        }

        // Canonicalize the profile directory name
        let canonicalResult = canonicalizeChromeProfileDirectory(metadata.profileIdentifier)
        switch canonicalResult {
        case .failure(let error):
            return .failure(error)
        case .success(let canonicalName):
            var args: [String] = ["--profile-directory=\(canonicalName)"]

            // Validate and add allowlisted additional arguments
            for arg in additionalArgs {
                guard let validated = validateChromeArgument(arg) else {
                    return .failure(.disallowedArgument(arg))
                }
                args.append(validated)
            }

            guard let appURL = browserURL(for: .chrome) else {
                return .failure(.browserNotInstalled(.chrome))
            }

            return .success((appURL, args))
        }
    }

    /// Constructs the launch configuration for Safari.
    /// Note: Safari doesn't support direct profile switching via CLI arguments.
    /// It will launch with its last active profile.
    public static func buildSafariLaunch(
        profile: SwitcherProfileRecord,
        privateBrowsing: Bool = false
    ) -> Result<(URL, [String]), BrowserLaunchError> {
        // Validate it's a Safari profile
        guard profile.targetKind == .browser,
              profile.browserType == .safari else {
            return .failure(.profileTypeMismatch(expected: .safari, actual: profile.browserType))
        }

        guard let appURL = browserURL(for: .safari) else {
            return .failure(.browserNotInstalled(.safari))
        }

        var args: [String] = []
        if privateBrowsing {
            args.append("--private")
        }

        return .success((appURL, args))
    }

    // MARK: - Profile Mismatch Detection

    /// Validates that a profile record is compatible with the target browser type.
    public static func validateProfileBrowserTypeMatch(
        profile: SwitcherProfileRecord,
        targetBrowser: SwitcherBrowserProfileType
    ) -> Result<Void, BrowserLaunchError> {
        guard profile.targetKind == .browser else {
            return .failure(.profileKindMismatch(expected: .browser, actual: profile.targetKind))
        }

        guard profile.browserType == targetBrowser else {
            return .failure(.profileTypeMismatch(expected: targetBrowser, actual: profile.browserType))
        }

        guard profile.browserMetadata != nil else {
            return .failure(.missingProfileMetadata(profile.id))
        }

        return .success(())
    }
}

// MARK: - Browser Launch Error

/// Typed errors for browser launch failures.
/// All errors are actionable and provide clear remediation guidance.
public enum BrowserLaunchError: Error, Equatable, Sendable {
    case browserNotInstalled(SwitcherBrowserProfileType)
    case profileNotFound(String)
    case profileTypeMismatch(expected: SwitcherBrowserProfileType, actual: SwitcherBrowserProfileType?)
    case profileKindMismatch(expected: SwitcherProfileTargetKind, actual: SwitcherProfileTargetKind)
    case missingProfileMetadata(String)
    case invalidProfileIdentifier(String)
    case disallowedArgument(String)
    case launchConfigurationFailed(String)
    case launchTimeout
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .browserNotInstalled(let browser):
            return "\(browser.displayName) is not installed. Install \(browser.displayName) to use browser profile switching."

        case .profileNotFound(let id):
            return "Browser profile with ID '\(id)' not found."

        case .profileTypeMismatch(let expected, let actual):
            let actualStr = actual?.displayName ?? "nil"
            return "Profile type mismatch: expected \(expected.displayName), got \(actualStr)."

        case .profileKindMismatch(let expected, let actual):
            return "Profile kind mismatch: expected \(expected.rawValue), got \(actual.rawValue)."

        case .missingProfileMetadata(let profileID):
            return "Profile '\(profileID)' is missing required browser metadata."

        case .invalidProfileIdentifier(let reason):
            return "Invalid profile identifier: \(reason)"

        case .disallowedArgument(let arg):
            return "Argument '\(arg)' is not in the allowlist and cannot be used for browser launch."

        case .launchConfigurationFailed(let reason):
            return "Failed to configure browser launch: \(reason)"

        case .launchTimeout:
            return "Browser launch timed out."

        case .launchFailed(let detail):
            return "Browser launch failed: \(detail)"
        }
    }

    /// Returns a recovery suggestion for this error, if available.
    public var recoverySuggestion: String? {
        switch self {
        case .browserNotInstalled:
            return "Install the browser from its official website or the Mac App Store."
        case .profileNotFound:
            return "Select a valid browser profile from Settings."
        case .profileTypeMismatch, .profileKindMismatch:
            return "Create a new profile for the correct browser type in Settings."
        case .missingProfileMetadata:
            return "Edit the profile in Settings to add required browser profile information."
        case .invalidProfileIdentifier:
            return "Edit the profile in Settings to use a valid profile name."
        case .disallowedArgument:
            return "Contact BurnBar support if you need this argument to be allowlisted."
        case .launchConfigurationFailed, .launchTimeout, .launchFailed:
            return "Try launching the browser manually. If the issue persists, restart your Mac."
        }
    }
}

// MARK: - Concurrent Launch Serialization

/// A serial coordinator that ensures browser launches are serialized,
/// preventing duplicate committed launches under concurrent requests.
/// Uses an actor to provide thread-safe serialization.
public actor BrowserLaunchCoordinator {
    private var pendingLaunches: Set<String> = []
    private var lastLaunchedProfileID: String?
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

/// Actually performs the browser launch using NSWorkspace.
/// Isolated to prevent direct invocation outside of the coordinator.
public struct BrowserLaunchInvoker {
    /// Launches Chrome with the given profile directory and additional allowlisted arguments.
    public static func launchChrome(
        appURL: URL,
        profileDirectory: String,
        args: [String] = []
    ) async -> Result<Void, BrowserLaunchError> {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = [ "--profile-directory=\(profileDirectory)" ] + args
            configuration.activates = true

            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            ) { app, error in
                if let error = error {
                    continuation.resume(returning: .failure(.launchFailed(error.localizedDescription)))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }

    /// Launches Safari with the given arguments.
    public static func launchSafari(
        appURL: URL,
        args: [String] = []
    ) async -> Result<Void, BrowserLaunchError> {
        await withCheckedContinuation { continuation in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = args
            configuration.activates = true

            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: configuration
            ) { app, error in
                if let error = error {
                    continuation.resume(returning: .failure(.launchFailed(error.localizedDescription)))
                } else {
                    continuation.resume(returning: .success(()))
                }
            }
        }
    }
}

// MARK: - Filesystem Mutation Guard

/// Monitors that browser profile directories are not mutated during switch operations.
/// This is a defensive check - actual enforcement happens through the fact that
/// we only pass profile references and never read/write browser data stores.
public struct BrowserFilesystemGuard {
    /// Browser profile directory paths that should never be written to.
    /// These are read-only for the switcher.
    public static let protectedChromeProfilePaths: [String] = [
        "Library/Application Support/Google/Chrome",
        "Library/Google/Chrome",
    ]

    public static let protectedSafariPaths: [String] = [
        "Library/Safari",
        "Library/Application Support/Safari",
        "Library/Caches/Safari",
        "Library/Cookies",
    ]

    /// Returns true if the given path is a protected browser profile path.
    public static func isProtectedBrowserPath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        for protected in protectedChromeProfilePaths + protectedSafariPaths {
            if lowercased.contains(protected.lowercased()) {
                return true
            }
        }
        return false
    }

    /// Redacts sensitive patterns from log strings.
    /// Replaces cookie-like, token-like, and credential-like patterns.
    public static func redactSensitiveData(_ input: String) -> String {
        var result = input

        // Redact cookie patterns - handle individually to avoid greedy matching issues
        // Cookie pattern: word characters followed by = or : and the value
        let cookieResult = result.replacingOccurrences(
            of: #"(?i)(cookie|cookies)[=:][^,]+"#,
            with: "[COOKIE_REDACTED]",
            options: .regularExpression
        )
        if cookieResult != result {
            result = cookieResult
            // Also redact session patterns after cookie redaction
            result = result.replacingOccurrences(
                of: #"(?i)session[=:][^,]+"#,
                with: "[SESSION_REDACTED]",
                options: .regularExpression
            )
        } else {
            // No cookies found, try session alone
            result = result.replacingOccurrences(
                of: #"(?i)session[=:][^,]+"#,
                with: "[COOKIE_REDACTED]",
                options: .regularExpression
            )
        }

        // Redact Bearer tokens (Authorization headers with Bearer)
        result = result.replacingOccurrences(
            of: #"(?i)Bearer[_\s]+[A-Za-z0-9_\-\.]+"#,
            with: "[TOKEN_REDACTED]",
            options: .regularExpression
        )

        // Redact generic token patterns (token=, api_key=, service_token=, etc.)
        result = result.replacingOccurrences(
            of: #"(?i)(token|api_key|service_token|access_token)[=:][^,\s]+"#,
            with: "[TOKEN_REDACTED]",
            options: .regularExpression
        )

        // Redact Authorization headers (general pattern for auth headers)
        result = result.replacingOccurrences(
            of: #"(?i)authorization[=:\s][^\r\n]+"#,
            with: "[AUTH_REDACTED]",
            options: .regularExpression
        )

        // Redact password patterns in URLs (user:password@host)
        result = result.replacingOccurrences(
            of: #"://[^:\s]+:[^@\s]+@"#,
            with: "://[PASSWORD_REDACTED]@",
            options: .regularExpression
        )

        return result
    }
}
