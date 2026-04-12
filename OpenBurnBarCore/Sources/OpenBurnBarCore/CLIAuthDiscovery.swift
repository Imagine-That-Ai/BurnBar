import Foundation

// MARK: - CLI Auth State

/// The authentication state of a CLI tool.
public enum CLIAuthState: Equatable, Sendable {
    /// OAuth session is valid, optionally with last refresh time.
    case authenticated(lastRefresh: Date?)
    /// An API key file exists (key value NOT stored — just presence check).
    case apiKeyPresent
    /// CLI is installed but not authenticated.
    case notAuthenticated
    /// CLI is not installed on this system.
    case notInstalled
}

// MARK: - CLI Auth Info

/// Non-sensitive metadata about a CLI tool's installation and auth state.
public struct CLIAuthInfo: Identifiable, Equatable, Sendable {
    public let cliType: SwitcherCLIProfileType
    public let isInstalled: Bool
    public let executablePath: String?
    public let authState: CLIAuthState
    public let configDirectory: String?

    public var id: String { cliType.rawValue }

    public init(
        cliType: SwitcherCLIProfileType,
        isInstalled: Bool,
        executablePath: String?,
        authState: CLIAuthState,
        configDirectory: String? = nil
    ) {
        self.cliType = cliType
        self.isInstalled = isInstalled
        self.executablePath = executablePath
        self.authState = authState
        self.configDirectory = configDirectory
    }
}

// MARK: - CLI Auth Discovery

/// Discovers CLI installation and authentication states.
///
/// Security: Only checks for the PRESENCE of auth files and tokens.
/// No API keys, OAuth tokens, or credentials are read or stored.
/// Key values are checked for non-emptiness only (boolean result).
public enum CLIAuthDiscovery {

    /// Scans all CLI types and returns their auth states.
    public static func discoverAuthStates() -> [CLIAuthInfo] {
        return SwitcherCLIProfileType.allCases.map { cliType in
            discoverAuthState(for: cliType)
        }
    }

    /// Discovers auth state for a single CLI type.
    public static func discoverAuthState(for cliType: SwitcherCLIProfileType) -> CLIAuthInfo {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let executablePath = CLILaunchAdapter.executablePath(for: cliType)

        switch cliType {
        case .codex:
            let configDir = "\(home)/.codex"
            let authState = discoverCodexAuthState(home: home)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: FileManager.default.fileExists(atPath: configDir) ? configDir : nil
            )

        case .claude:
            let configDir = "\(home)/.claude"
            let authState = discoverClaudeAuthState(home: home)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: FileManager.default.fileExists(atPath: configDir) ? configDir : nil
            )

        case .opencode:
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: executablePath != nil ? .notAuthenticated : .notInstalled
            )
        }
    }

    // MARK: - Codex Auth Detection

    /// Checks Codex auth.json for key presence (value not read).
    private static func discoverCodexAuthState(home: String) -> CLIAuthState {
        let authPath = "\(home)/.codex/auth.json"
        let fm = FileManager.default

        guard fm.fileExists(atPath: authPath),
              let data = fm.contents(atPath: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No auth file — check if installed
            return fm.fileExists(atPath: "\(home)/.codex") ? .notAuthenticated : .notInstalled
        }

        // Check for OPENAI_API_KEY presence (boolean only — never read the value)
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
            return .apiKeyPresent
        }

        // Check for tokens object presence
        if let tokens = json["tokens"] as? [String: Any], !tokens.isEmpty {
            let lastRefresh = parseDate(from: json["last_refresh"])
            return .authenticated(lastRefresh: lastRefresh)
        }

        return .notAuthenticated
    }

    // MARK: - Claude Code Auth Detection

    /// Checks Claude Code directory for session/auth state.
    private static func discoverClaudeAuthState(home: String) -> CLIAuthState {
        let fm = FileManager.default
        let claudeDir = "\(home)/.claude"

        guard fm.fileExists(atPath: claudeDir) else {
            return .notInstalled
        }

        // Check for settings.json (indicates configuration)
        let settingsPath = "\(claudeDir)/settings.json"
        let hasSettings = fm.fileExists(atPath: settingsPath)

        // Check for sessions directory (indicates active usage)
        let sessionsPath = "\(claudeDir)/sessions"
        let hasSessions = fm.fileExists(atPath: sessionsPath)

        // Check for chrome subdirectory (OAuth credentials from browser auth)
        let chromePath = "\(claudeDir)/chrome"
        let hasChromeAuth = fm.fileExists(atPath: chromePath)

        if hasChromeAuth || hasSessions {
            return .authenticated(lastRefresh: nil)
        }

        if hasSettings {
            return .notAuthenticated
        }

        return .notAuthenticated
    }

    // MARK: - Date Parsing

    private static func parseDate(from value: Any?) -> Date? {
        if let str = value as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: str)
        }
        if let timeInterval = value as? TimeInterval {
            return Date(timeIntervalSince1970: timeInterval)
        }
        return nil
    }
}
