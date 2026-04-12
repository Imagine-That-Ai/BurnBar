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
    public let accountDescription: String?

    public var id: String { cliType.rawValue }

    public init(
        cliType: SwitcherCLIProfileType,
        isInstalled: Bool,
        executablePath: String?,
        authState: CLIAuthState,
        configDirectory: String? = nil,
        accountDescription: String? = nil
    ) {
        self.cliType = cliType
        self.isInstalled = isInstalled
        self.executablePath = executablePath
        self.authState = authState
        self.configDirectory = configDirectory
        self.accountDescription = accountDescription
    }
}

// MARK: - CLI Auth Discovery

/// Discovers CLI installation and authentication states.
///
/// Security: Only reads non-sensitive local auth metadata needed for display.
/// Raw API keys, OAuth tokens, and credentials are never stored or surfaced.
/// When token-backed auth is present, only safe identity claims like name/email
/// are extracted in-memory for UI labels.
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
                configDirectory: FileManager.default.fileExists(atPath: configDir) ? configDir : nil,
                accountDescription: codexAccountDescription(home: home, authState: authState)
            )

        case .claude:
            let configDir = "\(home)/.claude"
            let authState = discoverClaudeAuthState(home: home)
            return CLIAuthInfo(
                cliType: cliType,
                isInstalled: executablePath != nil,
                executablePath: executablePath,
                authState: authState,
                configDirectory: FileManager.default.fileExists(atPath: configDir) ? configDir : nil,
                accountDescription: claudeAccountDescription(
                    executablePath: executablePath,
                    authState: authState
                )
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

    // MARK: - Account Identity Helpers

    static func codexAccountDescription(home: String, authState: CLIAuthState) -> String? {
        guard case .authenticated = authState else { return nil }

        let authPath = "\(home)/.codex/auth.json"
        guard let data = FileManager.default.contents(atPath: authPath) else {
            return nil
        }

        return extractCodexAccountDescription(fromAuthJSONData: data)
    }

    static func extractCodexAccountDescription(fromAuthJSONData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else {
            return nil
        }

        if let idToken = tokens["id_token"] as? String,
           let claims = parseJWTClaims(from: idToken) {
            let name = claims["name"] as? String
            let email = claims["email"] as? String
            if let formatted = formattedAccountDescription(name: name, email: email) {
                return formatted
            }
        }

        if let accessToken = tokens["access_token"] as? String,
           let claims = parseJWTClaims(from: accessToken),
           let profile = claims["https://api.openai.com/profile"] as? [String: Any] {
            let email = profile["email"] as? String
            return formattedAccountDescription(name: nil, email: email)
        }

        return nil
    }

    static func claudeAccountDescription(
        executablePath: String?,
        authState: CLIAuthState
    ) -> String? {
        guard case .authenticated = authState,
              let executablePath else {
            return nil
        }

        guard let data = runCommand(
            executablePath: executablePath,
            arguments: ["auth", "status", "--json"],
            timeout: 1.5
        ) else {
            return nil
        }

        return extractClaudeAccountDescription(fromStatusJSONData: data)
    }

    static func extractClaudeAccountDescription(fromStatusJSONData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let email = json["email"] as? String
        let orgName = json["orgName"] as? String

        if let email, !email.isEmpty {
            return email
        }

        if let orgName, !orgName.isEmpty {
            return orgName
        }

        return nil
    }

    static func formattedAccountDescription(name: String?, email: String?) -> String? {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let trimmedName, !trimmedName.isEmpty,
           let trimmedEmail, !trimmedEmail.isEmpty {
            return "\(trimmedName) • \(trimmedEmail)"
        }

        if let trimmedName, !trimmedName.isEmpty {
            return trimmedName
        }

        if let trimmedEmail, !trimmedEmail.isEmpty {
            return trimmedEmail
        }

        return nil
    }

    static func parseJWTClaims(from token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    private static func runCommand(
        executablePath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        return stdout.fileHandleForReading.readDataToEndOfFile()
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
